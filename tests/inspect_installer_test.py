"""Exercise inspect-installer.py on small synthetic installer images."""

import hashlib
import io
import json
import lzma
import os
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "inspect-installer.py"
# INSPECT_TEST_YQ names a yq binary to use; otherwise the one on PATH is used.
YQ_PATH = (
    [str(Path(os.environ["INSPECT_TEST_YQ"]).resolve().parent)]
    if "INSPECT_TEST_YQ" in os.environ
    else []
)
UKI = "usr/install/amd64/vmlinuz.efi"
BOOT = "usr/install/amd64/systemd-boot.efi"
WIPE = "talos.experimental.wipe=system:EPHEMERAL,STATE"
FACTORY_SCHEMATIC = """
    - image: {index}.sqsh
      metadata:
        name: schematic
        version: 00b36099b4e8f836a102e532efda01e2403c1112ca1e77d86574b16f152476d3
        author: Image Factory (https://factory.talos.dev/)
"""
Extensions = tuple[tuple[str, str], ...]


def pe(sections: list[tuple[str, bytes]]) -> bytes:
    """A PE file with just enough headers for a section table."""
    header, optional = 0x40, 0xF0
    table = header + 24 + optional
    offset = table + 40 * len(sections)
    rows, bodies = b"", b""
    for name, body in sections:
        pointer = offset + len(bodies)
        rows += struct.pack("<8sIIII", name.encode(), len(body), 0, len(body), pointer)
        rows += b"\0" * 16
        bodies += body
    dos = b"MZ" + b"\0" * 0x3A + struct.pack("<I", header)
    coff = b"PE\0\0" + struct.pack("<HH", 0x8664, len(sections)) + b"\0" * 12
    coff += struct.pack("<HH", optional, 0)
    return dos + coff + b"\0" * optional + rows + bodies


def cpio(members: list[tuple[str, bytes]]) -> bytes:
    """A newc archive; its padding is relative to its own start, as in Talos."""
    out = b""
    for name, body in [*members, ("TRAILER!!!", b"")]:
        encoded = name.encode() + b"\0"
        fields = [0, 0o100644, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(encoded), 0]
        out += b"070701" + b"".join(b"%08X" % field for field in fields) + encoded
        out += b"\0" * (-len(out) % 4)
        out += body + b"\0" * (-len(body) % 4)
    return out


def extensions_yaml(extensions: Extensions, *, factory: bool) -> str:
    text = "layers:\n"
    for index, (name, version) in enumerate(extensions):
        text += f"    - image: {index}.sqsh\n      metadata:\n        name: {name}\n"
        text += f"        version: {version}\n        author: Sidero Labs\n"
    return text + (FACTORY_SCHEMATIC.format(index=len(extensions)) if factory else "")


def installer(
    cmdline: str = "talos.platform=metal console=tty0",
    extensions: Extensions = (("nvme-cli", "v2.14"),),
    *,
    factory: bool = False,
    build: bytes = b"",
    compress: bool = False,
    stub: bytes = b"stub code",
) -> bytes:
    """A UKI whose extension squashfs bytes include `build`, standing in for file times."""
    rootfs = cpio([("rootfs.sqsh", b"root filesystem")])
    files = [
        (f"{index}.sqsh", b"hsqs" + name.encode() + build)
        for index, (name, _) in enumerate(extensions)
    ]
    if factory:
        files.append((f"{len(extensions)}.sqsh", b"hsqs schematic"))
    files.append(("extensions.yaml", extensions_yaml(extensions, factory=factory).encode()))
    # One separator byte leaves the extension archive off 4-byte alignment.
    initrd = rootfs + b"\0" + cpio(files)
    if compress:
        initrd = lzma.compress(initrd, format=lzma.FORMAT_XZ)
    return pe(
        [
            (".text", stub),
            (".osrel", b'NAME="Talos"\nVERSION_ID=v1.12.12\n'),
            (".cmdline", cmdline.encode()),
            (".uname", b"6.18.49-talos"),
            (".linux", b"kernel"),
            (".initrd", initrd),
            (".profile", b"ID=main"),
            (".profile", b"ID=reset-maintenance\nTITLE=Reset"),
            (".cmdline", f"{cmdline} {WIPE}".encode()),
        ]
    )


def add(archive: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))


def layer(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, data in files.items():
            add(archive, name, data)
    return buffer.getvalue()


def installer_layers(uki: bytes) -> list[bytes]:
    return [layer({"usr/bin/installer": b"installer"}), layer({UKI: uki, BOOT: b"systemd-boot"})]


def docker_archive(path: Path, uki: bytes) -> None:
    base, top = installer_layers(uki)
    manifest = [{"Config": "config.json", "Layers": ["base.tar.gz", "top.tar.gz"]}]
    with tarfile.open(path, "w") as archive:
        add(archive, "manifest.json", json.dumps(manifest).encode())
        add(archive, "base.tar.gz", base)
        add(archive, "top.tar.gz", top)


def oci_layout(directory: Path, uki: bytes) -> None:
    """OCI layout whose index nests a multi-platform index, like skopeo copies."""
    blobs = directory / "blobs" / "sha256"
    blobs.mkdir(parents=True)

    def put(data: bytes) -> dict[str, object]:
        digest = hashlib.sha256(data).hexdigest()
        (blobs / digest).write_bytes(data)
        return {"digest": f"sha256:{digest}", "size": len(data)}

    manifest = put(json.dumps({"layers": [put(data) for data in installer_layers(uki)]}).encode())
    other = put(json.dumps({"layers": []}).encode())
    platforms = [
        {**other, "platform": {"architecture": "arm64", "os": "linux"}},
        {**manifest, "platform": {"architecture": "amd64", "os": "linux"}},
    ]
    nested = put(json.dumps({"manifests": platforms}).encode())
    (directory / "index.json").write_text(json.dumps({"manifests": [nested]}))


def skopeo_dir(directory: Path, uki: bytes) -> None:
    """skopeo `dir:` transport: manifest.json plus blobs named by hex digest."""
    directory.mkdir()
    layers = []
    for data in installer_layers(uki):
        digest = hashlib.sha256(data).hexdigest()
        (directory / digest).write_bytes(data)
        layers.append({"digest": f"sha256:{digest}", "size": len(data)})
    manifest = {"schemaVersion": 2, "layers": layers}
    (directory / "manifest.json").write_text(json.dumps(manifest))
    (directory / "version").write_text("Directory Transport Version: 1.1\n")


class InspectInstallerTest(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def image(self, name: str, uki: bytes | None = None) -> str:
        path = self.root / f"{name}.tar"
        docker_archive(path, installer() if uki is None else uki)
        return str(path)

    def run_inspector(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        path = os.pathsep.join([*YQ_PATH, os.environ.get("PATH", "")])
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            env={**os.environ, "PATH": path},
            check=False,
        )

    def test_summary_reads_versions_command_lines_and_extensions(self) -> None:
        image = self.image(
            "ours", installer(extensions=(("nvme-cli", "v2.14"), ("iscsi-tools", "v0.2.0")))
        )
        result = self.run_inspector(image)
        self.assertEqual(result.returncode, 0, result.stderr)
        [summary] = json.loads(result.stdout)
        self.assertEqual(summary["talos"], "v1.12.12")
        self.assertEqual(summary["uname"], "6.18.49-talos")
        self.assertEqual(summary["linux"], hashlib.sha256(b"kernel").hexdigest())
        self.assertEqual(summary["rootfs"], hashlib.sha256(b"root filesystem").hexdigest())
        self.assertEqual(
            [{key: entry[key] for key in ("profile", "args")} for entry in summary["cmdline"]],
            [
                {"profile": "main", "args": "talos.platform=metal console=tty0"},
                {
                    "profile": "reset-maintenance",
                    "args": f"talos.platform=metal console=tty0 {WIPE}",
                },
            ],
        )
        self.assertEqual(
            [(extension["name"], extension["version"]) for extension in summary["extensions"]],
            [("iscsi-tools", "v0.2.0"), ("nvme-cli", "v2.14")],
        )
        self.assertEqual(
            summary["extensions"][1]["squashfs"], hashlib.sha256(b"hsqsnvme-cli").hexdigest()
        )

    def test_factory_schematic_is_not_a_difference(self) -> None:
        factory = self.root / "factory"
        oci_layout(factory, installer(factory=True, compress=True))
        result = self.run_inspector("--compare", self.image("ours"), str(factory))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ignored Factory schematic extension 00b36099", result.stderr)
        self.assertIn("SAME", result.stderr)

    def test_skopeo_directory_matches_its_docker_archive(self) -> None:
        published = self.root / "published"
        skopeo_dir(published, installer())
        result = self.run_inspector("--compare", self.image("built"), str(published))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_extension_bytes_differ_unless_digests_are_ignored(self) -> None:
        old, new = (
            self.image("old", installer(build=b"2026-11-01")),
            self.image("new", installer(build=b"2019-06-01")),
        )
        result = self.run_inspector("--compare", old, new)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DIFFERENT: extensions", result.stderr)
        result = self.run_inspector("--compare", "--ignore-extension-digests", old, new)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_compare_reports_a_different_uki_stub(self) -> None:
        other = self.image("b", installer(stub=b"other stub code"))
        result = self.run_inspector("--compare", self.image("a"), other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DIFFERENT: uki_stub", result.stderr)

    def test_compare_reports_a_different_command_line(self) -> None:
        other = self.image("b", installer(cmdline="talos.platform=metal"))
        result = self.run_inspector("--compare", self.image("a"), other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DIFFERENT: cmdline", result.stderr)

    def test_ignoring_digests_still_reports_a_different_extension_version(self) -> None:
        other = self.image("b", installer(extensions=(("nvme-cli", "v2.15"),)))
        result = self.run_inspector(
            "--compare", "--ignore-extension-digests", self.image("a"), other
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("DIFFERENT: extensions", result.stderr)

    def test_compare_reports_a_missing_extension(self) -> None:
        result = self.run_inspector(
            "--compare", self.image("a"), self.image("b", installer(extensions=()))
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("DIFFERENT: extensions", result.stderr)

    def test_compare_needs_two_images(self) -> None:
        result = self.run_inspector("--compare", self.image("a"))
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
