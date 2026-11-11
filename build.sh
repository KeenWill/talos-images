#!/usr/bin/env bash
set -euo pipefail

# Builds a shape's images from its imager profile in profiles/:
#   ./build.sh controlplane              # every output shapes.yaml lists
#   ./build.sh worker installer          # one output
# Outputs land in _out/<shape>/. Profiles pin registry inputs by digest; the
# CPU prototype also requires local inputs. shapes.yaml pins each imager; this script adds only the platform and output.
# With UPGRADE_IMAGE set, the installer is also pushed there and its
# tag@digest reference written to _out/<shape>/installer.ref.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAPES_FILE="shapes.yaml"
OUTPUT_DIR="_out"
# Talos release builds and Image Factory stamp squashfs images with this epoch
# (Talos's first commit). Without it each extension image carries the build
# time and no rebuild matches an earlier one.
SOURCE_DATE_EPOCH_VALUE="1559424892"
# The disk size of the imager's built-in `metal` profile (MinRAWDiskSize in
# pkg/imager/profile), which the per-node scripts use. The imager needs a size
# and lays its partitions out beyond it: v1.12.12 writes a 4.5 GB image.
METAL_RAW_DISK_SIZE_BYTES="$((1246 * 1024 * 1024))"
CLOUD_DISK_SIZE_BYTES="$((8192 * 1024 * 1024))"
CPU_INPUT_DIR="${CPU_INPUT_DIR:-}"
LOCAL_INPUTS=false
UPGRADE_IMAGE="${UPGRADE_IMAGE:-}"
GHCR_USERNAME="${GHCR_USERNAME:-KeenWill}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
REGISTRY_AUTH_CONFIG_DIR=""
STAGING_DIR=""

usage() {
	echo "usage: $0 SHAPE [OUTPUT...]" >&2
	echo "shapes and their outputs are listed in ${SHAPES_FILE}" >&2
	exit 2
}

require_command() {
	local command_name="$1"

	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "error: required command not found: $command_name" >&2
		exit 1
	fi
}

cleanup_on_exit() {
	if [[ -n "$REGISTRY_AUTH_CONFIG_DIR" ]]; then
		rm -rf "$REGISTRY_AUTH_CONFIG_DIR"
	fi
	if [[ -n "$STAGING_DIR" ]]; then
		rm -rf "$STAGING_DIR"
	fi
}

create_registry_auth_config() {
	if [[ -z "$GHCR_TOKEN" ]]; then
		return
	fi

	require_command base64

	REGISTRY_AUTH_CONFIG_DIR="$(mktemp -d)"

	local auth
	auth="$(printf '%s:%s' "$GHCR_USERNAME" "$GHCR_TOKEN" | base64 | tr -d '\n')"

	printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$auth" >"${REGISTRY_AUTH_CONFIG_DIR}/config.json"
}

# The platform and output block each output kind adds to a profile.
output_overlay() {
	local output="$1"

	case "$output" in
	installer)
		echo '{"platform": "metal", "output": {"kind": "installer", "outFormat": "raw"}}'
		;;
	iso | initramfs)
		printf '{"platform": "metal", "output": {"kind": "%s", "outFormat": "raw"}}\n' "$output"
		;;
	aws | gcp | hcloud)
		local format=".zst" size="$CLOUD_DISK_SIZE_BYTES"
		[[ "$output" != gcp ]] || format=".tar.gz"
		[[ "$output" != hcloud ]] || size="$METAL_RAW_DISK_SIZE_BYTES"
		printf '{"platform": "%s", "output": {"kind": "image", "outFormat": "%s", "imageOptions": {"diskSize": %s, "diskFormat": "raw"}}}\n' "$output" "$format" "$size"
		;;
	metal-raw)
		printf '{"platform": "metal", "output": {"kind": "image", "outFormat": ".zst", "imageOptions": {"diskSize": %s, "diskFormat": "raw"}}}\n' \
			"$METAL_RAW_DISK_SIZE_BYTES"
		;;
	*)
		echo "error: unknown output kind: $output" >&2
		exit 1
		;;
	esac
}

# The file the imager writes for an output kind.
output_file_name() {
	local output="$1" arch="$2"

	case "$output" in
	installer) echo "installer-${arch}.tar" ;;
	metal-raw) echo "metal-${arch}.raw.zst" ;;
	iso) echo "metal-${arch}.iso" ;;
	initramfs) echo "initramfs-metal-${arch}.xz" ;;
	aws | hcloud) echo "${output}-${arch}.raw.zst" ;;
	gcp) echo "gcp-${arch}.raw.tar.gz" ;;
	esac
}

build_output() {
	local shape="$1" output="$2" imager_image="$3" arch="$4"
	local profile="profiles/${shape}.yaml"
	local shape_output_dir="${OUTPUT_DIR}/${shape}"
	local file_name
	file_name="$(output_file_name "$output" "$arch")"
	local published="${shape_output_dir}/${file_name}"

	# A failed build must not leave an earlier output at the published name.
	mkdir -p "$shape_output_dir"
	rm -f "$published"
	if [[ "$output" == installer ]]; then
		rm -f "${shape_output_dir}/installer.ref"
	fi
	STAGING_DIR="$(mktemp -d "${OUTPUT_DIR}/.staging.XXXXXX")"

	local overlay
	overlay="$(output_overlay "$output")"
	OVERLAY="$overlay" yq -e '. * (strenv(OVERLAY) | from_json) | ... style=""' "$profile" >"${STAGING_DIR}/profile.yaml"

	local imager_docker_args=(-e "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH_VALUE}")
	# Disk images are partitioned through loop devices; nothing else needs
	# privileges or host devices.
	if [[ "$output" == metal-raw || "$output" == aws || "$output" == gcp || "$output" == hcloud ]]; then
		imager_docker_args+=(--privileged -v /dev:/dev)
	fi
	if [[ "$LOCAL_INPUTS" == true ]]; then
		imager_docker_args+=(
			-v "${CPU_INPUT_DIR}/ephemeral-worker-base.xz:/inputs/ephemeral-worker-base.xz:ro"
			-v "${CPU_INPUT_DIR}/ephemeral-worker-agent.tar:/inputs/ephemeral-worker-agent.tar:ro"
		)
	fi
	if [[ -n "$REGISTRY_AUTH_CONFIG_DIR" ]]; then
		imager_docker_args+=(
			-e "HOME=/root"
			-e "DOCKER_CONFIG=/root/.docker"
			-e "REGISTRY_AUTH_FILE=/root/.docker/config.json"
			-v "${REGISTRY_AUTH_CONFIG_DIR}/config.json:/root/.docker/config.json:ro"
		)
	fi

	# The profile arrives on stdin and the output leaves as a tar on stdout, so
	# nothing the root-run imager writes lands on the host.
	docker run --rm -i \
		"${imager_docker_args[@]}" \
		"$imager_image" \
		- --tar-to-stdout <"${STAGING_DIR}/profile.yaml" >"${STAGING_DIR}/output.tar"
	tar -xf "${STAGING_DIR}/output.tar" -C "$STAGING_DIR" "$file_name"
	mv "${STAGING_DIR}/${file_name}" "$published"
	rm -rf "$STAGING_DIR"
	STAGING_DIR=""
	echo "wrote ${published}"

	if [[ "$output" == installer && -n "$UPGRADE_IMAGE" ]]; then
		local loaded_image
		loaded_image="$(docker load -i "$published" | sed -n -e 's/^Loaded image: //p' -e 's/^Loaded image ID: //p' | tail -n1)"
		if [[ -z "$loaded_image" ]]; then
			echo "error: docker load did not report an image" >&2
			exit 1
		fi

		docker tag "$loaded_image" "$UPGRADE_IMAGE"
		docker push "$UPGRADE_IMAGE"
		# The registry digest is what nodes pin; tags can be moved.
		local repository_digest
		repository_digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$UPGRADE_IMAGE" |
			sed -n "s#^${UPGRADE_IMAGE%:*}@\(sha256:[0-9a-f]\{64\}\)\$#\1#p" | head -n1)"
		if [[ -z "$repository_digest" ]]; then
			echo "error: no registry digest for ${UPGRADE_IMAGE} after the push" >&2
			exit 1
		fi
		echo "${UPGRADE_IMAGE}@${repository_digest}" >"${shape_output_dir}/installer.ref"
		echo "pushed ${UPGRADE_IMAGE}@${repository_digest}"
	fi
}

main() {
	[[ $# -ge 1 ]] || usage
	local shape="$1"
	shift

	require_command yq
	cd "$SCRIPT_DIR"

	if ! SHAPE="$shape" yq -e '.shapes | has(strenv(SHAPE))' "$SHAPES_FILE" >/dev/null 2>&1; then
		echo "error: unknown shape: $shape" >&2
		usage
	fi
	local shape_outputs=()
	mapfile -t shape_outputs < <(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].outputs[]' "$SHAPES_FILE")

	local outputs=("${shape_outputs[@]}")
	if [[ $# -gt 0 ]]; then
		outputs=("$@")
	fi
	local output
	for output in "${outputs[@]}"; do
		if [[ " ${shape_outputs[*]} " != *" ${output} "* ]]; then
			echo "error: ${shape} has no ${output} output; ${SHAPES_FILE} lists: ${shape_outputs[*]}" >&2
			exit 2
		fi
	done

	local profile="profiles/${shape}.yaml"
	if [[ ! -f "$profile" ]]; then
		echo "error: profile not found: $profile" >&2
		exit 1
	fi
	local imager_image arch
	imager_image="$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].imager // .imager' "$SHAPES_FILE")"
	LOCAL_INPUTS="$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].localInputs // false' "$SHAPES_FILE")"
	if [[ "$LOCAL_INPUTS" == true ]]; then
		if [[ -n "$UPGRADE_IMAGE" ]]; then
			echo "error: local CPU inputs are not release artifacts; publishing is disabled" >&2
			exit 2
		fi
		for asset in ephemeral-worker-base.xz ephemeral-worker-agent.tar; do
			if [[ -z "$CPU_INPUT_DIR" || ! -s "$CPU_INPUT_DIR/$asset" ]]; then
				echo "error: CPU_INPUT_DIR must contain $asset built from the CPU prototype source" >&2
				exit 2
			fi
		done
		CPU_INPUT_DIR="$(cd "$CPU_INPUT_DIR" && pwd)"
	fi
	arch="$(yq -r '.arch' "$profile")"

	require_command docker
	require_command tar
	mkdir -p "$OUTPUT_DIR"
	trap cleanup_on_exit EXIT
	create_registry_auth_config

	for output in "${outputs[@]}"; do
		build_output "$shape" "$output" "$imager_image" "$arch"
	done
}

main "$@"
