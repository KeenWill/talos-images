# Talos images

Imager profiles and a build script for control planes, MS-A2 workers, CPU/GPU
ephemeral prototypes, basic discovery media and cloud workers. Registry inputs are pinned by digest, and Renovate keeps their pins current.
The local CPU prototype also requires caller-built inputs, described below. Machine configs, addresses and secrets are not here: the
cluster's private config pins each node's installer by digest from a release
of this repository.

- `shapes.yaml` lists each shape (a kind of node) and its outputs, and pins
  the default imager. A shape can pin its matching imager when its Talos
  release differs; the CPU prototype retains its patched release.
- `profiles/<shape>.yaml` is what goes into a shape: Talos version, installer
  base and registry extensions pinned by digest, or explicit local CPU inputs. A profile sets no
  platform or output; `build.sh` adds those per output.
- `build.sh SHAPE [OUTPUT...]` builds a shape's outputs (all of them when none
  is named) into `_out/<shape>/`.

| Output | File | Use |
| ------ | ---- | --- |
| `installer` | `installer-amd64.tar` | `talosctl upgrade --image`, after it is pushed to a registry |
| `metal-raw` | `metal-amd64.raw.zst` | Flash to a USB stick; boots to maintenance mode with no machine config |
| `iso` | `metal-amd64.iso` | Discovery/install media |
| `aws` | `aws-amd64.raw.zst` | Local disk artifact for a separate AWS import |
| `gcp` | `gcp-amd64.raw.tar.gz` | GCP archive containing `disk.raw` |
| `hcloud` | `hcloud-amd64.raw.zst` | Local disk artifact for a separate Hetzner upload |
| `initramfs` | `initramfs-metal-amd64.xz` | Direct kernel boot with the matching kernel; content uses zstd |

| Shape | Contents | Outputs |
| ----- | -------- | ------- |
| `controlplane` | NVMe tools | installer, metal-raw |
| `worker` | Storage tools, RoCE DCB, NIC temperature | installer, metal-raw |
| `worker-kata` | Worker extensions plus Kata (Cloud Hypervisor, virtio-fs) | installer, metal-raw |
| `gpu-ephemeral` | NVIDIA open LTS modules/toolkit, Tailscale | all seven |
| `cpu-ephemeral` | Patched CPU base, lifecycle agent, Tailscale | all seven; local only |
| `basic` | Stock Talos, no extensions | installer, metal-raw, iso, initramfs |
| `cloud-worker` | Tailscale | all seven |

Cloud files use their provider platform, with the imager's disk defaults:
8 GiB requested for AWS/GCP, 1246 MiB for metal/Hetzner. Talos adds partition
space beyond the requested size. Building these files does not register cloud
images, start instances, enroll Tailscale or configure a machine. File
inspection and local boot checks do not establish provider or GPU hardware
compatibility.

```bash
./build.sh controlplane
./build.sh worker installer
```

A `metal-raw` image takes its machine config over the network:

```bash
zstd -dc _out/worker/metal-amd64.raw.zst | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync
talosctl apply-config --insecure --nodes <maintenance-ip> --file <node config>
```

## Kata workers

`worker-kata` is an opt-in shape so a single worker can qualify Kata before
other workers change. It preserves the worker storage and NIC extensions.
The [Talos v1.12.12 extension](https://github.com/siderolabs/extensions/tree/v1.12.12/container-runtime/kata-containers)
ships Kata 3.26.0, Cloud Hypervisor and virtiofsd, and registers containerd
handler `kata` with `privileged_without_host_devices = true`. It does not
ship QEMU or Firecracker. The cluster must provide a RuntimeClass, admission
and egress policies, and label only nodes whose Kata runtime has passed a
smoke test. Building this shape does not install it on a node.

## Building

Needs `docker`, `tar` and [yq](https://github.com/mikefarah/yq) v4. The imager
reads the profile on stdin and writes a tar to stdout, so its output never
lands on the host as root. Disk outputs (`metal-raw`, `aws`, `gcp`, `hcloud`)
run with `--privileged -v /dev:/dev` for loop-device partitioning. Installer,
ISO and initramfs outputs need no privileges.

The script fixes `SOURCE_DATE_EPOCH` to the value Talos releases use, so
extension images carry no build time. Image tarballs still differ between
builds, so compare contents rather than digests. `GHCR_TOKEN` (with
`GHCR_USERNAME`) authenticates the imager's pulls when an extension image is
not public. Setting `UPGRADE_IMAGE` also pushes the built installer to that
reference and writes its `tag@digest` to `_out/<shape>/installer.ref`.

## CPU prototype inputs

`cpu-ephemeral` preserves the Talos 1.12.6 patched base and lifecycle agent
from [mono PR 1070](https://github.com/KeenWill/mono/pull/1070), including its
required retirement supervisor. It is not a stock Tailscale-only replacement.
Build the two inputs with that tree's `scripts/build-patched-base.sh` and
`extension/Dockerfile`, following its README, then provide the resulting files:

```bash
CPU_INPUT_DIR=/absolute/path/to/cpu-build/out ./build.sh cpu-ephemeral
```

The directory must contain nonempty `ephemeral-worker-base.xz` and
`ephemeral-worker-agent.tar`. Only those two files are mounted read-only.
Missing inputs fail before the imager starts; there is no stock fallback.
Their provenance is the caller's responsibility: retain the source commit,
patch hash, build log and input SHA256s with validation evidence. The build
script does not authenticate arbitrary caller-provided local bytes.

The CPU source patch remains in mono. CPU outputs are local experiments and
cannot be published through `UPGRADE_IMAGE`; CI, the release matrix and the
release manifest exclude this shape. Packaging a patched installer is not
proof of lifecycle correctness after install/upgrade. Modal guest boot,
provider configuration, enrollment and retirement need their own acceptance
checks; none follows from an image reaching maintenance mode.

## Releases

A release tag is the Talos version the profiles pin plus a revision, such as
`v1.12.12-r1`. Publishing a GitHub release runs
[`release.yml`](.github/workflows/release.yml) on GitHub-hosted runners: it
builds each registry-backed shape's installer from the tagged commit, pushes it to
`ghcr.io/keenwill/talos-images/<shape>-installer:<tag>`, records build
provenance for the pushed digest, and attaches `release.yaml`, written by
`release-manifest.sh` and attested the same way:

```yaml
repository: KeenWill/talos-images
tag: v1.12.12-r1
commit: <the tagged commit>
imager: ghcr.io/siderolabs/imager:v1.12.12@sha256:...
shapes:
  worker:
    talosVersion: v1.12.12
    installer: ghcr.io/keenwill/talos-images/worker-installer:v1.12.12-r1@sha256:...
    extensions:
      - ghcr.io/siderolabs/iscsi-tools:v0.2.0@sha256:...
```

The cluster config copies that file and pins each installer by its digest.
Check a pin's provenance with:

```bash
gh attestation verify oci://ghcr.io/keenwill/talos-images/worker-installer@sha256:<digest> --repo KeenWill/talos-images
gh attestation verify release.yaml --repo KeenWill/talos-images
```

## Updating Talos

Renovate opens one PR per Talos minor release for the imager and installer
base, and PRs for extensions that move on their own; none automerges. In the
Talos bump PR, set each profile's `version` and take the official extensions
from that release's catalog, `ghcr.io/siderolabs/extensions:<version>`, whose
`/image-digests` file lists each extension's ref and digest (so builds match
Image Factory's). Extensions with kernel modules are rebuilt for the release,
since Talos signs modules with a per-release key. Before merging,
build `metal-raw` and boot it (QEMU is enough): maintenance mode answers, and
`talosctl get extensions --insecure` lists the profile's extensions.

## Comparing installers

`inspect-installer.py` summarizes an installer: Talos version, kernel and
rootfs digests, each UKI profile's kernel command line, and every extension's
version and squashfs digest. With `--compare` it checks two images, ignoring
Image Factory's virtual `schematic` extension. It needs `zstd` and `yq`. The
control-plane build compares equal to Factory's installer for the same
schematic, extension bytes included:

```bash
skopeo --insecure-policy copy --override-arch amd64 --override-os linux \
  docker://factory.talos.dev/metal-installer/00b36099b4e8f836a102e532efda01e2403c1112ca1e77d86574b16f152476d3@sha256:a29ee8eb7c66543d6968ae50ea6882364b1d35e8272200eb753f94f9469235a0 \
  oci:/tmp/factory-controlplane:installer
python3 inspect-installer.py --compare \
  _out/controlplane/installer-amd64.tar /tmp/factory-controlplane
```

For an image built without the fixed epoch, `--ignore-extension-digests`
compares extension names, versions and authors only.

## Tests and CI

```bash
tests/profiles_test.sh
python3 tests/inspect_installer_test.py
```

`profiles_test.sh` checks that shapes.yaml and the profiles pin every input and
list the same shapes, that `build.sh` gives each output its platform and output
block (with docker stubbed), and that `release-manifest.sh` writes and refuses
what it should.

[CI](.github/workflows/ci.yml) runs those checks and builds each registry-backed installer on
GitHub-hosted runners only. No self-hosted runner serves this repository, so a
fork's pull request never runs on the cluster's hardware, and fork pull
requests wait for a maintainer's approval before they run at all.

## License

[MIT](LICENSE)
