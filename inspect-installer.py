#!/usr/bin/env python3
"""Summarize a Talos installer image so two builds can be compared.

Reads a docker-archive tarball (what the imager writes), an OCI image layout
directory or tarball (`skopeo copy docker://... oci:DIR`), or a skopeo `dir:`
image. It prints JSON with the Talos version, kernel and rootfs digests, a
digest of the rest of the UKI (its EFI stub sections), the kernel command line
of each UKI profile, and every system extension with its version and squashfs
digest.

With --compare it takes exactly two images and exits 1 if they differ. Image
Factory adds a virtual `schematic` extension that carries only the schematic
ID; --compare ignores it, and reports it so the reader can see it was there.

Extension squashfs images embed file times, so their digests match only between
builds made with the same SOURCE_DATE_EPOCH (build.sh and
Image Factory use Talos's). For an image built without it,
--ignore-extension-digests compares extension names, versions and authors only.
Needs `zstd` and `yq` on PATH.
"""

import argparse
import hashlib
import io
import json
import lzma
import struct
import subprocess
import sys
import tarfile
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

UKI_PATH = "usr/install/amd64/vmlinuz.efi"
SYSTEMD_BOOT_PATH = "usr/install/amd64/systemd-boot.efi"
FACTORY_AUTHOR_PREFIX = "Image Factory"
NEWC_HEADER = 110
# UKI sections summarized on their own; every other section (the EFI stub's
# code and data, .sbat, .splash, ...) goes into the `uki_stub` digest.
UKI_CONTENT_SECTIONS = {".osrel", ".cmdline", ".uname", ".linux", ".initrd", ".profile"}

Summary = dict[str, Any]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Image:
    """Layer blobs of one image, from docker-archive, OCI layout or skopeo `dir:`."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._has: Callable[[str], bool]
        self._read: Callable[[str], bytes]
        if Path(path).is_dir():
            self._has = lambda name: Path(path, name).is_file()
            self._read = lambda name: Path(path, name).read_bytes()
        else:
            archive = tarfile.open(path)  # noqa: SIM115 - read lazily for the process lifetime
            members = {member.name.removeprefix("./"): member for member in archive.getmembers()}
            self._has = lambda name: name in members
            self._read = lambda name: _member_bytes(archive, members[name])

    def layers(self) -> list[bytes]:
        if self._has("manifest.json"):
            manifest = json.loads(self._read("manifest.json"))
            if isinstance(manifest, dict):
                # skopeo `dir:` image: one manifest, blobs named by their hex digest.
                return [
                    self._read(layer["digest"].split(":", 1)[1]) for layer in manifest["layers"]
                ]
            if len(manifest) != 1:
                raise SystemExit(f"{self.path}: expected one image, found {len(manifest)}")
            return [self._read(layer) for layer in manifest[0]["Layers"]]
        descriptor = json.loads(self._read("index.json"))["manifests"][0]
        while True:
            document = json.loads(self._blob(descriptor["digest"]))
            if "layers" in document:
                return [self._blob(layer["digest"]) for layer in document["layers"]]
            candidates = [
                entry
                for entry in document["manifests"]
                if entry.get("platform", {}).get("architecture") == "amd64"
                and entry.get("platform", {}).get("os") == "linux"
            ]
            if len(candidates) != 1:
                raise SystemExit(f"{self.path}: no single linux/amd64 manifest")
            descriptor = candidates[0]

    def _blob(self, digest: str) -> bytes:
        algorithm, value = digest.split(":", 1)
        return self._read(f"blobs/{algorithm}/{value}")

    def files(self, wanted: set[str]) -> dict[str, bytes]:
        """Return {path: bytes} for wanted paths, upper layers winning."""
        found: dict[str, bytes] = {}
        for layer in reversed(self.layers()):
            with tarfile.open(fileobj=io.BytesIO(layer), mode="r:*") as archive:
                for member in archive.getmembers():
                    name = member.name.removeprefix("./")
                    if name in wanted and name not in found and member.isfile():
                        found[name] = _member_bytes(archive, member)
        missing = sorted(wanted - set(found))
        if missing:
            raise SystemExit(f"{self.path}: missing {', '.join(missing)}")
        return found


def _member_bytes(archive: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    stream = archive.extractfile(member)
    if stream is None:
        raise SystemExit(f"{member.name} is not a regular file")
    with stream:
        return stream.read()


def pe_sections(data: bytes) -> Iterator[tuple[str, bytes]]:
    """Yield (name, bytes) for each PE section, in file order."""
    if data[:2] != b"MZ":
        raise SystemExit("UKI is not a PE file")
    header = struct.unpack_from("<I", data, 0x3C)[0]
    if data[header : header + 4] != b"PE\0\0":
        raise SystemExit("UKI has no PE header")
    count = struct.unpack_from("<H", data, header + 6)[0]
    optional_size = struct.unpack_from("<H", data, header + 20)[0]
    table = header + 24 + optional_size
    for index in range(count):
        raw_name, virtual_size, _, raw_size, raw_pointer = struct.unpack_from(
            "<8sIIII", data, table + 40 * index
        )
        size = min(virtual_size, raw_size) if virtual_size else raw_size
        yield raw_name.rstrip(b"\0").decode(), data[raw_pointer : raw_pointer + size]


def key_values(data: bytes) -> dict[str, str]:
    return dict(line.split("=", 1) for line in data.decode().splitlines() if "=" in line)


def uki_profiles(
    sections: Iterator[tuple[str, bytes]],
) -> tuple[dict[str, bytes], list[tuple[str, dict[str, bytes]]]]:
    """Split UKI sections into the base set and each .profile's overrides."""
    base: dict[str, bytes] = {}
    profiles: list[tuple[str, dict[str, bytes]]] = []
    for name, data in sections:
        if name == ".profile":
            profiles.append((key_values(data).get("ID", ""), {}))
        elif profiles:
            profiles[-1][1][name] = data
        else:
            base[name] = data
    return base, profiles


def decompress(data: bytes) -> bytes:
    if data[:4] == b"\x28\xb5\x2f\xfd":
        command = ["zstd", "-q", "-d", "-c"]
        return subprocess.run(command, input=data, capture_output=True, check=True).stdout
    if data[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(data)
    if data[:6] == b"070701":
        return data
    raise SystemExit("initramfs is neither zstd, xz nor cpio")


def cpio_archives(data: bytes) -> Iterator[list[tuple[str, bytes]]]:
    """Yield [(name, bytes)] for each concatenated newc archive."""
    position = 0
    while position < len(data):
        if data[position] == 0:
            position += 1
            continue
        start, members = position, []
        while True:
            header = data[position : position + NEWC_HEADER]
            if header[:6] != b"070701":
                raise SystemExit(f"bad cpio header at offset {position}")
            fields = [int(header[6 + 8 * i : 14 + 8 * i], 16) for i in range(13)]
            size, name_size = fields[6], fields[11]
            name = data[position + NEWC_HEADER : position + NEWC_HEADER + name_size - 1].decode()
            # newc pads to four bytes from the start of its own archive.
            body_start = start + ((position - start + NEWC_HEADER + name_size + 3) & ~3)
            body = data[body_start : body_start + size]
            position = start + ((body_start - start + size + 3) & ~3)
            if name == "TRAILER!!!":
                break
            members.append((name, body))
        yield members


def parse_yaml(data: bytes) -> Any:
    command = ["yq", "-o=json", "."]
    return json.loads(subprocess.run(command, input=data, capture_output=True, check=True).stdout)


def sections_digest(sections: dict[str, bytes]) -> str:
    """Digest of named sections, independent of their order in the file."""
    digest = hashlib.sha256()
    for name in sorted(sections):
        digest.update(f"{name}\0{len(sections[name])}\0".encode())
        digest.update(sections[name])
    return digest.hexdigest()


def summarize(path: str) -> Summary:
    files = Image(path).files({UKI_PATH, SYSTEMD_BOOT_PATH})
    base, profiles = uki_profiles(pe_sections(files[UKI_PATH]))
    stub = {name: data for name, data in base.items() if name not in UKI_CONTENT_SECTIONS}

    archives = list(cpio_archives(decompress(base[".initrd"])))
    rootfs = [body for members in archives for name, body in members if name == "rootfs.sqsh"]
    if len(rootfs) != 1:
        raise SystemExit(f"{path}: expected one rootfs.sqsh, found {len(rootfs)}")
    extension_files = {name: body for members in archives[1:] for name, body in members}
    layers = []
    if "extensions.yaml" in extension_files:
        layers = parse_yaml(extension_files["extensions.yaml"])["layers"] or []
    extensions = [
        {
            "name": layer["metadata"]["name"],
            "version": str(layer["metadata"]["version"]),
            "author": layer["metadata"].get("author", ""),
            "squashfs": sha256(extension_files[layer["image"]]),
        }
        for layer in layers
    ]

    return {
        "image": path,
        "talos": key_values(base[".osrel"]).get("VERSION_ID", "").strip('"'),
        "uname": base[".uname"].decode().strip(),
        "linux": sha256(base[".linux"]),
        "rootfs": sha256(rootfs[0]),
        "systemd_boot": sha256(files[SYSTEMD_BOOT_PATH]),
        "uki_stub": sections_digest(stub),
        "cmdline": [
            {
                "profile": profile,
                "args": overrides.get(".cmdline", base[".cmdline"]).decode().strip("\0 \n"),
                "other_overrides": sections_digest(
                    {name: data for name, data in overrides.items() if name != ".cmdline"}
                ),
            }
            for profile, overrides in (profiles or [("", {})])
        ],
        "extensions": sorted(extensions, key=lambda extension: extension["name"]),
    }


def is_factory_schematic(extension: dict[str, str]) -> bool:
    return extension["name"] == "schematic" and extension["author"].startswith(
        FACTORY_AUTHOR_PREFIX
    )


def comparable(summary: Summary, *, extension_digests: bool) -> Summary:
    kept = {key: value for key, value in summary.items() if key != "image"}
    kept["extensions"] = [
        {key: value for key, value in extension.items() if extension_digests or key != "squashfs"}
        for extension in summary["extensions"]
        if not is_factory_schematic(extension)
    ]
    return kept


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "images", nargs="+", help="docker-archive tar, OCI layout (directory or tar) or dir: image"
    )
    parser.add_argument(
        "--compare", action="store_true", help="compare exactly two images; exit 1 on difference"
    )
    parser.add_argument(
        "--ignore-extension-digests",
        action="store_true",
        help="compare extension names, versions and authors only",
    )
    arguments = parser.parse_args()
    if arguments.compare and len(arguments.images) != 2:
        parser.error("--compare takes exactly two images")

    summaries = [summarize(path) for path in arguments.images]
    print(json.dumps(summaries, indent=2))
    if not arguments.compare:
        return 0
    for summary in summaries:
        for extension in summary["extensions"]:
            if is_factory_schematic(extension):
                print(
                    f"{summary['image']}: ignored Factory schematic extension "
                    f"{extension['version']}",
                    file=sys.stderr,
                )
    left, right = (
        comparable(summary, extension_digests=not arguments.ignore_extension_digests)
        for summary in summaries
    )
    differences = sorted(
        key for key in left.keys() | right.keys() if left.get(key) != right.get(key)
    )
    if differences:
        print(f"DIFFERENT: {', '.join(differences)}", file=sys.stderr)
        return 1
    print(
        "SAME: kernel, rootfs, UKI stub, boot loader, command lines and extensions", file=sys.stderr
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
