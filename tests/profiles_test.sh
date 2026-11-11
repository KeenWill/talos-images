#!/usr/bin/env bash
# Checks that shapes.yaml and the profiles pin every input and list the same
# shapes, that build.sh feeds each output's profile to the pinned imager, and
# that release-manifest.sh writes what the cluster config pins. docker and tar
# are stubs; needs bash, yq (mikefarah v4) and coreutils.
# The cluster config's own checks (its schematics, per-node USB scripts and
# installer pins against a release's release.yaml) run where that config lives.
set -euo pipefail

export GHCR_TOKEN="" UPGRADE_IMAGE=""

images_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shapes_file="$images_dir/shapes.yaml"
profiles_dir="$images_dir/profiles"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

pinned_digest='@sha256:[0-9a-f]{64}$'

profile_extensions() {
	yq -r '.input.systemExtensions[] | select(has("imageRef")) | .imageRef' "$1" | sort
}

installer_imager="$(yq -r .imager "$shapes_file")"
[[ "$installer_imager" =~ ^ghcr\.io/siderolabs/imager:(v[0-9]+\.[0-9]+\.[0-9]+)${pinned_digest} ]] ||
	fail "shapes.yaml imager is not a Talos release pinned by digest: $installer_imager"
talos_version="${BASH_REMATCH[1]}"

# Every shape has a profile, every profile a shape, and only build.sh's
# output kinds are listed.
shapes="$(yq -r '.shapes | keys | .[]' "$shapes_file" | sort)"
[[ "$shapes" == "$(find "$profiles_dir" -maxdepth 1 -name "*.yaml" -printf "%f\n" | sed 's/\.yaml$//' | sort)" ]] ||
	fail "shapes.yaml and profiles/ list different shapes"
while read -r output; do
	[[ " installer metal-raw iso aws gcp hcloud initramfs " == *" $output "* ]] || fail "shapes.yaml lists unknown output: $output"
done < <(yq -r '.shapes[].outputs[]' "$shapes_file")
[[ -z "$(yq -r '.shapes[] | select((.outputs | length) == 0 or (.outputs | unique | length) != (.outputs | length))' "$shapes_file")" ]] ||
	fail "a shape has no outputs or repeats one"

# Each profile is one Talos release, every input pinned: the imager provides
# kernel, initramfs and boot stubs; installer base and extensions are images.
for shape in $shapes; do
	profile="$profiles_dir/${shape}.yaml"
	shape_imager="$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].imager // .imager' "$shapes_file")"
	[[ "$shape_imager" =~ ^ghcr\.io/siderolabs/imager:(v[0-9]+\.[0-9]+\.[0-9]+)${pinned_digest} ]] || fail "$shape imager is not pinned"
	shape_version="${BASH_REMATCH[1]}"
	[[ "$(yq -r .version "$profile")" == "$shape_version" ]] || fail "$shape profile version is not the imager's $talos_version"
	[[ "$(yq -r '[.arch, .secureboot] | join(" ")' "$profile")" == "amd64 false" ]] ||
		fail "$shape profile is not amd64 without secure boot"
	[[ "$(yq -r '(has("platform") or has("output"))' "$profile")" == false ]] ||
		fail "$shape profile sets its platform or output; build.sh adds those per output"
	# Same kernel arguments as the Factory schematics: none beyond Talos's own.
	[[ "$(yq -r '.customization // {} | length' "$profile")" == 0 ]] || fail "$shape profile customizes the image"
	inputs=(kernel initramfs sdStub sdBoot)
	if [[ "$shape" == cpu-ephemeral ]]; then
		inputs=(kernel sdStub sdBoot)
		[[ "$(yq -r .input.initramfs.path "$profile")" == /inputs/ephemeral-worker-base.xz ]] || fail "CPU base must be patched"
		[[ "$(yq -r '.input.systemExtensions[] | select(has("tarballPath")) | .tarballPath' "$profile")" == /inputs/ephemeral-worker-agent.tar ]] || fail "CPU agent missing"
	fi
	for input in "${inputs[@]}"; do
		[[ "$(INPUT="$input" yq -r '.input[strenv(INPUT)] | keys | join(",")' "$profile")" == path ]] ||
			fail "$shape profile $input must come from the pinned imager"
		[[ "$(INPUT="$input" yq -r '.input[strenv(INPUT)].path' "$profile")" == /usr/install/amd64/* ]] ||
			fail "$shape profile $input is not a pinned imager asset"
	done
	[[ "$(yq -r .input.baseInstaller.imageRef "$profile")" =~ ^ghcr\.io/siderolabs/installer-base:${shape_version//./\.}${pinned_digest} ]] ||
		fail "$shape profile base installer is not pinned"
	[[ -z "$(yq -r '.input.systemExtensions[] | select(has("tarballPath") == false) | keys | join(",") | select(. != "imageRef")' "$profile")" ]] ||
		fail "$shape profile has an extension that is not an image reference"
	while read -r reference; do
		[[ -z "$reference" || "$reference" =~ $pinned_digest ]] || fail "$shape extension is not pinned by digest: $reference"
		if [[ "$reference" == ghcr.io/siderolabs/nvidia-open-gpu-kernel-modules-* ]]; then
			[[ "$reference" == *"-${shape_version}@sha256:"* ]] || fail "$shape NVIDIA modules target a different Talos release"
		fi
	done < <(profile_extensions "$profile")
	[[ -z "$(profile_extensions "$profile" | uniq -d)" ]] || fail "$shape profile repeats an extension"
done

for file in "$shapes_file" "$profiles_dir"/*.yaml "$images_dir/build.sh" "$images_dir/release-manifest.sh"; do
	grep -v '^[[:space:]]*#' "$file" | grep -q 'factory\.talos\.dev' && fail "${file##*/} uses Image Factory"
done

# build.sh and release-manifest.sh, with docker and tar stubbed.
mkdir -p "$test_dir/src/profiles" "$test_dir/bin"
cp "$images_dir/build.sh" "$images_dir/release-manifest.sh" "$shapes_file" "$test_dir/src/"
cp "$profiles_dir"/*.yaml "$test_dir/src/profiles/"
export CALL_LOG="$test_dir/calls"
cat >"$test_dir/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALL_LOG"
case "$1" in
run)
	for argument in "$@"; do
		if [[ "$argument" == *:/root/.docker/config.json:ro ]]; then
			grep -q '"ghcr.io"' "${argument%%:*}" && echo auth-present >>"$CALL_LOG"
		fi
	done
	[[ "${STUB_RUN_FAIL:-0}" == 0 ]] || exit 1
	# Stand-in for the imager's output tar: the profile it received.
	cat
	;;
load)
	case "${STUB_LOAD_MODE:-tag}" in
	tag) echo "Loaded image: ghcr.io/siderolabs/installer-base:v1.12.12" ;;
	id) echo "Loaded image ID: sha256:$(printf '2%.0s' {1..64})" ;;
	unknown) echo "unexpected output" ;;
	esac
	;;
inspect)
	# A pull of another repository leaves its digest beside the pushed one.
	image="${*: -1}"
	echo "ghcr.io/siderolabs/installer-base@sha256:$(printf '1%.0s' {1..64})"
	[[ -n "${STUB_NO_DIGEST:-}" ]] || echo "${image%:*}@sha256:$(printf 'a%.0s' {1..64})"
	;;
tag | push) ;;
*) exit 97 ;;
esac
STUB
cat >"$test_dir/bin/tar" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'tar %s\n' "$*" >>"$CALL_LOG"
[[ "$1" == -xf && "$3" == -C && $# -eq 5 ]] || exit 98
cp "$2" "$4/$5"
STUB
chmod +x "$test_dir/bin/docker" "$test_dir/bin/tar"
PATH="$test_dir/bin:$PATH"

# The build stages under _out/.staging.*; none may survive it.
no_staging_left() {
	local leftovers=("$test_dir"/src/_out/.staging.*)
	[[ ! -e "${leftovers[0]}" ]]
}

run_build() {
	: >"$CALL_LOG"
	(cd "$test_dir" && bash src/build.sh "$@") >"$test_dir/output" 2>&1
}

for arguments in "" "bogus" "worker bogus" "bogus installer"; do
	# shellcheck disable=SC2086 # split the argument list on purpose
	if run_build $arguments; then fail "accepted arguments: '$arguments'"; fi
	[[ ! -s "$CALL_LOG" ]] || fail "ran docker for arguments: '$arguments'"
done

# Each output's profile is the shape's profile plus that output's platform and
# output block, and only disk images get loop devices.
imager_run="run --rm -i -e SOURCE_DATE_EPOCH=1559424892"
# CPU inputs are mandatory, and local prototypes cannot be pushed.
run_build cpu-ephemeral installer && fail "accepted missing CPU inputs"
[[ ! -s "$CALL_LOG" ]] || fail "ran docker without CPU inputs"
export CPU_INPUT_DIR="$test_dir/cpu inputs"
mkdir "$CPU_INPUT_DIR"
printf 'patched base' >"$CPU_INPUT_DIR/ephemeral-worker-base.xz"
run_build cpu-ephemeral initramfs && fail "accepted missing CPU agent"
printf 'agent' >"$CPU_INPUT_DIR/ephemeral-worker-agent.tar"
UPGRADE_IMAGE=example.invalid/cpu:test run_build cpu-ephemeral installer && fail "published local CPU prototype"
[[ ! -s "$CALL_LOG" ]] || fail "ran docker for CPU publication"

for shape in $shapes; do
	shape_imager="$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].imager // .imager' "$shapes_file")"
	while read -r output; do
		case "$output" in
		installer)
			file=installer-amd64.tar
			expected="metal installer raw"
			privileged=false
			;;
		iso)
			file=metal-amd64.iso
			expected="metal iso raw"
			privileged=false
			;;
		initramfs)
			file=initramfs-metal-amd64.xz
			expected="metal initramfs raw"
			privileged=false
			;;
		metal-raw)
			file=metal-amd64.raw.zst
			expected="metal image .zst raw 1306525696"
			privileged=true
			;;
		aws)
			file=aws-amd64.raw.zst
			expected="aws image .zst raw 8589934592"
			privileged=true
			;;
		gcp)
			file=gcp-amd64.raw.tar.gz
			expected="gcp image .tar.gz raw 8589934592"
			privileged=true
			;;
		hcloud)
			file=hcloud-amd64.raw.zst
			expected="hcloud image .zst raw 1306525696"
			privileged=true
			;;
		esac
		run_build "$shape" "$output" || fail "$shape $output build failed: $(<"$test_dir/output")"
		built="$test_dir/src/_out/$shape/$file"
		[[ "$(yq -r '[.platform, .output.kind, .output.outFormat, .output.imageOptions.diskFormat, .output.imageOptions.diskSize] | map(select(. != null)) | join(" ")' "$built")" == "$expected" ]] || fail "$shape $output profile has the wrong output"
		[[ "$(yq 'del(.platform, .output)' "$built")" == "$(yq . "$test_dir/src/profiles/$shape.yaml")" ]] || fail "$shape $output changed the profile contents"
		expected_call="$imager_run"
		[[ "$privileged" == false ]] || expected_call+=" --privileged -v /dev:/dev"
		if [[ "$shape" == cpu-ephemeral ]]; then
			expected_call+=" -v $CPU_INPUT_DIR/ephemeral-worker-base.xz:/inputs/ephemeral-worker-base.xz:ro -v $CPU_INPUT_DIR/ephemeral-worker-agent.tar:/inputs/ephemeral-worker-agent.tar:ro"
		fi
		[[ "$(head -n1 "$CALL_LOG")" == "$expected_call $shape_imager - --tar-to-stdout" ]] || fail "unexpected $shape $output imager call: $(head -n1 "$CALL_LOG")"
		grep -q -E '^(load|tag|push) ' "$CALL_LOG" && fail "$shape build published without UPGRADE_IMAGE"
		no_staging_left || fail "$shape $output left staging files"
		# Every output removes its stale file when the imager fails.
		STUB_RUN_FAIL=1 run_build "$shape" "$output" && fail "accepted failed $shape $output build"
		[[ ! -e "$built" ]] || fail "stale $shape $output left after failure"
		no_staging_left || fail "failed $shape $output left staging files"
	done < <(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].outputs[]' "$shapes_file")
done

# With no output named, a shape builds every output shapes.yaml lists.
rm -rf "$test_dir/src/_out"
run_build controlplane || fail "controlplane build failed: $(<"$test_dir/output")"
[[ "$(grep -c '^run ' "$CALL_LOG")" == 2 ]] || fail "controlplane did not build both outputs"
[[ -f "$test_dir/src/_out/controlplane/installer-amd64.tar" && -f "$test_dir/src/_out/controlplane/metal-amd64.raw.zst" ]] ||
	fail "controlplane outputs missing"

# A failed build removes the previous output instead of leaving it in place.
STUB_RUN_FAIL=1 run_build controlplane installer && fail "build succeeded although the imager failed"
[[ ! -e "$test_dir/src/_out/controlplane/installer-amd64.tar" ]] || fail "stale installer left after a failed build"
no_staging_left || fail "failed build left staging files"

GHCR_TOKEN=token-for-test run_build worker installer || fail "authenticated build failed"
grep -qx auth-present "$CALL_LOG" || fail "registry credentials were not mounted"
grep -q token-for-test "$CALL_LOG" "$test_dir/output" && fail "registry token reached the command line or output"
mounted="$(sed -n 's#.*-v \([^ ]*\)/config\.json:/root/\.docker/config\.json:ro.*#\1#p' "$CALL_LOG")"
[[ -n "$mounted" && ! -e "$mounted" ]] || fail "registry credentials outlived the build"

# Publishing pushes the loaded installer and records its registry digest.
published_image=ghcr.io/keenwill/talos-images/worker-installer:v1.12.12-r1
UPGRADE_IMAGE="$published_image" run_build worker installer || fail "publishing build failed: $(<"$test_dir/output")"
grep -qx "tag ghcr.io/siderolabs/installer-base:v1.12.12 $published_image" "$CALL_LOG" ||
	fail "loaded installer was not tagged for publishing"
grep -qx "push $published_image" "$CALL_LOG" || fail "installer was not pushed"
[[ "$(<"$test_dir/src/_out/worker/installer.ref")" == "${published_image}@sha256:$(printf 'a%.0s' {1..64})" ]] ||
	fail "installer.ref is not the pushed repository's digest: $(<"$test_dir/src/_out/worker/installer.ref")"
# Imager archives can be untagged: Docker reports their image ID instead.
STUB_LOAD_MODE=id UPGRADE_IMAGE="$published_image" run_build worker installer ||
	fail "publishing an untagged installer failed: $(<"$test_dir/output")"
grep -qx "tag sha256:$(printf '2%.0s' {1..64}) $published_image" "$CALL_LOG" ||
	fail "loaded installer ID was not tagged for publishing"
STUB_LOAD_MODE=unknown UPGRADE_IMAGE="$published_image" run_build worker installer &&
	fail "publishing succeeded without a loaded image identity"
grep -q -E '^(tag|push) ' "$CALL_LOG" && fail "unknown load output reached publishing"
[[ ! -e "$test_dir/src/_out/worker/installer.ref" ]] || fail "stale ref after unknown load output"
STUB_NO_DIGEST=1 UPGRADE_IMAGE="$published_image" run_build worker installer &&
	fail "publishing succeeded without a registry digest"
[[ ! -e "$test_dir/src/_out/worker/installer.ref" ]] || fail "stale installer.ref left after a failed publish"
UPGRADE_IMAGE="$published_image" run_build worker metal-raw || fail "metal-raw build with UPGRADE_IMAGE failed"
grep -q -E '^(load|tag|push) ' "$CALL_LOG" && fail "metal-raw build published an image"

# release-manifest.sh: one installer per shape that has one, each pinned under
# this release's tag, and the extensions straight from the profile.
manifest() {
	(cd "$test_dir" && bash src/release-manifest.sh "$@") 2>"$test_dir/output"
}
tag="${talos_version}-r1"
commit="0123456789abcdef0123456789abcdef01234567"
digest="sha256:$(printf 'c%.0s' {1..64})"
installer_arguments=()
for shape in $(yq -r '.shapes | to_entries[] | select(.value.localInputs != true) | select(.value.outputs[] == "installer") | .key' "$shapes_file"); do
	installer_arguments+=("${shape}=ghcr.io/keenwill/talos-images/${shape}-installer:${tag}@${digest}")
done
manifest "$tag" "$commit" "${installer_arguments[@]}" >"$test_dir/release.yaml" || fail "manifest failed: $(<"$test_dir/output")"
[[ "$(yq -r '[.repository, .tag, .commit, .imager] | join(" ")' "$test_dir/release.yaml")" == "KeenWill/talos-images $tag $commit $installer_imager" ]] ||
	fail "manifest header is wrong"
for argument in "${installer_arguments[@]}"; do
	shape="${argument%%=*}"
	[[ "$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].installer' "$test_dir/release.yaml")" == "${argument#*=}" ]] ||
		fail "manifest $shape installer is wrong"
	[[ "$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].talosVersion' "$test_dir/release.yaml")" == "$talos_version" ]] ||
		fail "manifest $shape Talos version is wrong"
	[[ "$(SHAPE="$shape" yq -r '.shapes[strenv(SHAPE)].extensions[]' "$test_dir/release.yaml")" == "$(yq -r '.input.systemExtensions[].imageRef' "$profiles_dir/$shape.yaml")" ]] ||
		fail "manifest $shape extensions differ from its profile"
done
[[ "$(yq -r '.shapes | length' "$test_dir/release.yaml")" == "${#installer_arguments[@]}" ]] || fail "manifest lists extra shapes"

manifest --check-tag "$tag" || fail "rejected tag $tag"
for bad_tag in "$talos_version" "${talos_version}-r0" "v0.0.1-r1" "${talos_version}-r1x" "${talos_version/./x}-r1"; do
	manifest --check-tag "$bad_tag" && fail "accepted tag $bad_tag"
done
manifest "$tag" "$commit" "${installer_arguments[@]:1}" >/dev/null && fail "manifest accepted a missing shape"
manifest "$tag" "$commit" "${installer_arguments[@]}" "${installer_arguments[0]}" >/dev/null && fail "manifest accepted a repeated shape"
manifest "$tag" "$commit" "${installer_arguments[@]}" "unlisted=ghcr.io/keenwill/talos-images/unlisted-installer:${tag}@${digest}" >/dev/null &&
	fail "manifest accepted a shape shapes.yaml does not list"
manifest "$tag" "${commit:0:12}" "${installer_arguments[@]}" >/dev/null && fail "manifest accepted a short commit"
manifest "$tag" "$commit" "${installer_arguments[@]/@sha256:*/}" >/dev/null && fail "manifest accepted an installer without a digest"
manifest "$tag" "$commit" "${installer_arguments[@]/:${tag}@/:${talos_version}-r2@}" >/dev/null &&
	fail "manifest accepted an installer from another release"
manifest "$tag" "$commit" "${installer_arguments[@]/ghcr.io\/keenwill\/talos-images/ghcr.io/someone/talos-images}" >/dev/null &&
	fail "manifest accepted an installer from another registry path"

echo "talos images: OK"
