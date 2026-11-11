#!/usr/bin/env bash
set -euo pipefail

# Prints a release's release.yaml: what the cluster config pins.
#   ./release-manifest.sh TAG COMMIT SHAPE=INSTALLER_REF...
#   ./release-manifest.sh --check-tag TAG
# Every shape with an `installer` output needs exactly one SHAPE=INSTALLER_REF,
# where INSTALLER_REF is the tag@digest reference build.sh wrote to
# _out/<shape>/installer.ref. Each shape's entry lists the extensions its
# profile pins, so the cluster config can be checked against them without
# this repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAPES_FILE="shapes.yaml"
REPOSITORY="KeenWill/talos-images"
INSTALLER_REGISTRY="ghcr.io/keenwill/talos-images"

usage() {
	echo "usage: $0 TAG COMMIT SHAPE=INSTALLER_REF..." >&2
	echo "       $0 --check-tag TAG" >&2
	exit 2
}

fail() {
	echo "error: $*" >&2
	exit 1
}

# Release tags are the Talos version and a revision: v1.12.12-r1.
check_tag() {
	local tag="$1" talos_version
	talos_version="$(yq -r '.imager | sub("^[^:]*:", "") | sub("@.*$", "")' "$SHAPES_FILE")"
	[[ "$tag" =~ ^${talos_version//./\\.}-r[1-9][0-9]*$ ]] ||
		fail "release tag ${tag} is not ${talos_version}-r<N> (the Talos version shapes.yaml pins)"
}

main() {
	[[ $# -ge 1 ]] || usage
	command -v yq >/dev/null 2>&1 || fail "required command not found: yq"
	cd "$SCRIPT_DIR"

	if [[ "$1" == --check-tag ]]; then
		[[ $# -eq 2 ]] || usage
		check_tag "$2"
		return
	fi
	[[ $# -ge 3 ]] || usage
	local tag="$1" commit="$2"
	shift 2
	check_tag "$tag"
	[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "commit is not a full SHA: ${commit}"

	local -A installers=()
	local argument shape reference
	for argument in "$@"; do
		[[ "$argument" == *=* ]] || usage
		shape="${argument%%=*}"
		reference="${argument#*=}"
		[[ -z "${installers[$shape]:-}" ]] || fail "${shape} given twice"
		[[ "$reference" =~ ^${INSTALLER_REGISTRY//./\\.}/${shape}-installer:${tag//./\\.}@sha256:[0-9a-f]{64}$ ]] ||
			fail "${shape} installer is not ${INSTALLER_REGISTRY}/${shape}-installer:${tag} pinned by digest: ${reference}"
		installers[$shape]="$reference"
	done

	local expected_shapes
	mapfile -t expected_shapes < <(yq -r '.shapes | to_entries[] | select(.value.localInputs != true) | select(.value.outputs[] == "installer") | .key' "$SHAPES_FILE")
	[[ "$(printf '%s\n' "${!installers[@]}" | sort)" == "$(printf '%s\n' "${expected_shapes[@]}" | sort)" ]] ||
		fail "installers given for: ${!installers[*]}; shapes with an installer: ${expected_shapes[*]}"

	local manifest
	manifest="$(REPOSITORY="$REPOSITORY" TAG="$tag" COMMIT="$commit" yq -n '
		.repository = strenv(REPOSITORY) |
		.tag = strenv(TAG) |
		.commit = strenv(COMMIT) |
		.imager = load("shapes.yaml").imager |
		.shapes = {}')"
	for shape in "${expected_shapes[@]}"; do
		manifest="$(printf '%s\n' "$manifest" | SHAPE="$shape" INSTALLER="${installers[$shape]}" PROFILE="profiles/${shape}.yaml" yq '
			.shapes[strenv(SHAPE)] = {
				"talosVersion": load(strenv(PROFILE)).version,
				"installer": strenv(INSTALLER),
				"extensions": [load(strenv(PROFILE)).input.systemExtensions[].imageRef]
			}')"
	done
	printf '# Release manifest written by release-manifest.sh; do not edit.\n%s\n' "$manifest"
}

main "$@"
