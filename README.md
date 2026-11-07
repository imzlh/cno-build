# cno system packages

This repository turns published
[`cno-cli`](https://github.com/imzlh/cno-cli) Linux archives into packages that
install and uninstall through the operating system's native package manager.
It does not build cno source code again and does not track moving branches: each
job resolves one published `vMAJOR.MINOR.PATCH` release, downloads its immutable
assets, and verifies them against that release's `SHA256SUMS.txt` before any
package is made.

## Package set

| System | Format | Architectures | Upstream archive |
| --- | --- | --- | --- |
| Debian 12 / Ubuntu 24.04+ | `.deb` | amd64, i386, arm64, armhf | `glibc-minimal` |
| Alpine 3.21+ | `.apk` | x86_64, x86, aarch64, armv7, armhf, riscv64 | `musl-dynamic` |
| OpenWrt 24.10.x | `.ipk` | x86_64, x86, arm64, armv7 | static musl |
| OpenWrt snapshots | `.apk` | x86_64, x86, arm64, armv7 | static musl |

The Debian/Ubuntu and Alpine packages keep the upstream directory layout under
`/usr/lib/cno`: the runtime, its private shared libraries, and `ext/oxc.so` stay
together. `/usr/bin/cno` is a relative symlink. This lets the runtime discover
OXC automatically and preserves the upstream relative RPATHs.

OpenWrt packages contain only the fully static runtime. Native dynamic modules
are intentionally omitted because static musl executables cannot load them;
TypeScript transformation uses cno's bundled Sucrase path instead. Building in
the official OpenWrt SDK gives each package the exact metadata and container
format expected by that OpenWrt release.

## Run the workflow

After initializing and pushing this repository, open **Actions → Build system
packages → Run workflow**. `cno_release` accepts `latest`, `v1.1.0`, or `1.1.0`.
Set `publish` to false for an artifact-only trial run.

For durable Alpine releases, add a repository Actions secret named
`ALPINE_SIGNING_KEY_BASE64` containing a base64-encoded RSA private key. The
workflow uses that key for every Alpine architecture and publishes its public
key. If the secret is absent, each architecture gets a temporary signing key;
that is convenient for trial runs but does not provide a stable trust root
between releases. Generate a suitable secret locally with:

```sh
openssl genrsa -out cno-alpine.rsa 4096
base64 -w0 cno-alpine.rsa
```

Keep the private key out of Git and store the printed value only in the Actions
secret.

The workflow can also be triggered by an upstream automation:

```sh
gh api --method POST repos/OWNER/cno-builds/dispatches \
  -f event_type=cno-release \
  -F 'client_payload={"tag":"v1.1.0","publish":true}'
```

That request needs a token allowed to dispatch workflows in this repository.
Published package releases use the tag `packages-v<version>-r<package-release>`;
this deliberately cannot collide with cno-cli source tags.

The workflow performs these checks before publishing:

- validates every upstream archive against the upstream release checksum;
- installs, runs TypeScript with OXC, and uninstalls every Debian and Alpine
  architecture in a clean target-architecture container;
- repeats the amd64 and arm64 `.deb` test on Ubuntu 24.04;
- builds both OpenWrt formats with official SDKs, then executes the SDK-staged
  static runtime on the target CPU through QEMU where necessary;
- publishes `SHA256SUMS.txt`, build provenance for OpenWrt packages, and Alpine
  public signing keys with the packages.

## Install packages

Download the package matching the operating system and CPU from this
repository's package release, then verify it against `SHA256SUMS.txt`.

Debian or Ubuntu:

```sh
sudo apt install ./cno_1.1.0-1_amd64.deb
```

Alpine packages are signed with the public key shipped beside the release. Copy
the release key before installation (the auto-generated trial keys include the
architecture in their filename):

```sh
sudo cp cno-1.1.0-x86_64.rsa.pub /etc/apk/keys/
sudo apk add ./cno-1.1.0-r1-x86_64.apk
```

OpenWrt 24.10.x (opkg/IPK):

```sh
opkg install ./cno-1.1.0-r1-openwrt-24.10.4-x86-64.ipk
```

OpenWrt snapshots (apk-tools/APK) use a locally built SDK key that is not part
of the firmware trust store, so install a downloaded standalone package with:

```sh
apk add --allow-untrusted ./cno-1.1.0-r1-openwrt-snapshots-x86-64.apk
```

In all cases, verify the installation with:

```sh
cno --version
cno setup
```

Package removal is native as well: `apt remove cno`, `apk del cno`, or
`opkg remove cno`.

## Local checks

On Debian/Ubuntu, install `shellcheck`, `ripgrep`, and `dpkg-dev`, then run:

```sh
sh scripts/check.sh
```

The check builds the same `.deb` fixture twice and compares the bytes, in
addition to shell syntax, metadata, paths, permissions, and symlink checks.
Actual Alpine and OpenWrt builds stay in GitHub Actions because they require a
target Alpine environment or a downloaded OpenWrt SDK.

Configuration is centralized in [`config/project.env`](config/project.env).
Increase `CNO_PACKAGE_RELEASE` when packaging changes without a new cno version.
Generated files go under `downloads/`, `work/`, and `dist/`, all ignored by Git.

## Design boundaries

- The glibc package baseline is Debian 12 (`glibc >= 2.36`). It also covers
  Ubuntu 24.04 and newer releases; older distributions are not claimed.
- Alpine dynamic packages target the Alpine 3.21 musl ABI and retain upstream
  private libraries, including the OXC accelerator.
- OpenWrt targets are deliberately conservative. Add a row only after the cno
  static binary's CPU ABI is known to match that OpenWrt subtarget; similar CPU
  names do not guarantee compatible float or instruction-set ABIs.
- The upstream glibc `armv6` archive is not published as Debian `armel`: armel
  permits ARMv5 CPUs, while that runtime intentionally requires ARMv6. A package
  that installs successfully and then raises an illegal-instruction fault would
  be misleading.
- This repository never modifies or commits `../cno-cli`. A package build uses
  only assets already published by that project.

