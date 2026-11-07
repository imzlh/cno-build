# cno system packages

This repository builds native system packages for published
[`cno-cli`](https://github.com/imzlh/cno-cli) releases. Debian/Ubuntu and
Alpine packages wrap the release archives that match those systems. OpenWrt is
different: every target/subtarget is cross-compiled from the immutable release
source by its own official SDK.

The workflow resolves a `vMAJOR.MINOR.PATCH` tag to a full commit, verifies all
downloaded assets, and never follows a moving source branch. It does not modify
`../cno-cli`, initialize a new repository, or create commits.

## Package set

| System | Format | Build input |
| --- | --- | --- |
| Debian 12 / Ubuntu 24.04+ | `.deb` | published `glibc-minimal` archive |
| Alpine 3.21+ | `.apk` | published `musl-dynamic` archive |
| OpenWrt 24.10.x | `.ipk` | release source + the selected official SDK |
| OpenWrt snapshots | `.apk` | release source + the selected official SDK |

Debian architectures are amd64, i386, arm64, and armhf. Alpine architectures
are x86_64, x86, aarch64, armv7, armhf, and riscv64.

OpenWrt coverage is organized by SDK target/subtarget, not by a generic release
architecture. The initial matrix includes x86-64, Pentium 4, generic AArch64,
Cortex-A53, Cortex-A72, Cortex-A5, Cortex-A7 soft- and hard-float, Cortex-A9
soft- and hard-float, Cortex-A15, ARM1176/ARMv6, ARM926/ARMv5, XScale/ARMv5,
MIPS 24Kc in both byte orders, MIPS 74Kc, MIPS 1004Kc, and RV64GC. Each row is
built twice where available: once for OpenWrt 24.10 IPK and once for the current
snapshot APK format.

The exact rows and their expected SDK metadata live in
[`config/openwrt-targets.tsv`](config/openwrt-targets.tsv). A row is never
deduplicated by `ARCH_PACKAGES`: for example, `ramips/mt7621` can carry a 24Kc
package label while its SDK actually tunes C code for 1004Kc.

## OpenWrt build model

One host job prepares a reproducible archive containing the release commit and
all recursive submodules, plus the generated JavaScript bundle. Every OpenWrt
matrix job then independently:

1. downloads and checksums the official SDK for that target/subtarget;
2. verifies the SDK's actual package architecture against the matrix;
3. compiles cno, QuickJS, libuv, and WAMR (when enabled) with the SDK compiler,
   sysroot, CPU flags, endianness, and floating-point ABI;
4. builds the OXC Rust core for the same ISA/ABI and links its C binding with
   that SDK's compiler;
5. runs the target `cjsc` through QEMU so embedded bytecode has the target byte
   order, including regenerated QuickJS builtins on big-endian MIPS;
6. packages a dynamic OpenWrt-musl runtime using OpenWrt system libraries;
7. validates ELF class, machine, endianness, float ABI, loader, dependencies,
   exports, RPATH/TEXTREL policy, and executes a TypeScript/OXC smoke test under
   QEMU.

ARMv7 OXC builds also use a named Rust feature profile from the matrix. Soft
float Cortex-A7/A9 rows disable FP registers and NEON entirely; Cortex-A5 and
the VFPv3-D16 Cortex-A9 row disable D32 and NEON; NEON/VFPv4 Cortex-A7/A15
rows explicitly enable NEON. The resulting ARM ELF attributes are checked on
both the runtime and `oxc.so`, so selecting a CPU cannot silently introduce
instructions absent from that OpenWrt subtype.

ARMv5, ARMv6, and MIPS32 OpenWrt rows disable WAMR in the first version until
its native-call ABI is proven, while the cno core and OXC remain enabled.
MIPS32 OpenWrt rows are soft-float. LLVM does not expose the OpenWrt marketing
CPU names 24Kc, 74Kc, and 1004Kc; the Rust half of OXC therefore uses the
matching MIPS32 ISA/soft-float baseline,
while the C binding and complete cno runtime still receive the exact SDK flags.
This distinction is recorded in each `.buildinfo` file.

MIPS 4KEc, MIPS 24Kf hard-float, MIPS64, PowerPC/SPE, ARC, and LoongArch are not
claimed yet. They need Rust target or ABI work and a real SDK/QEMU validation;
publishing a package that merely has the right filename but can raise an illegal
instruction would be worse than leaving the row out.

The expected OpenWrt package architecture and dependency names are checked
fail-closed. They are high-confidence inputs, but the first live workflow run is
also the authoritative test against the current 24.10 and snapshot SDKs. A
target rename, feed package rename, or `cmake.mk` interface change may need a
small follow-up based on that run's log.

## Run the workflow

After pushing this repository, open **Actions → Build system packages → Run
workflow**. `cno_release` accepts `latest`, `v1.1.0`, or `1.1.0`. Set `publish`
to false for an artifact-only trial run.

For durable Alpine releases, add an Actions secret named
`ALPINE_SIGNING_KEY_BASE64` containing a base64-encoded RSA private key. Without
it, trial jobs create temporary per-architecture signing keys which do not form
a stable trust root. One way to generate the secret is:

```sh
openssl genrsa -out cno-alpine.rsa 4096
base64 -w0 cno-alpine.rsa
```

Keep the private key out of Git. Upstream automation can trigger the workflow
with:

```sh
gh api --method POST repos/OWNER/cno-builds/dispatches \
  -f event_type=cno-release \
  -F 'client_payload={"tag":"v1.1.0","publish":true}'
```

Published releases use `packages-v<version>-r<package-release>`, separate from
cno-cli source tags. The release contains package files, Alpine public keys,
OpenWrt build provenance, and `SHA256SUMS.txt`.

## Install packages

Download the package matching the operating system and CPU, then verify it
against `SHA256SUMS.txt`.

Debian or Ubuntu:

```sh
sudo apt install ./cno_1.1.0-2_amd64.deb
```

Alpine (copy the matching public key first):

```sh
sudo cp cno-1.1.0-x86_64.rsa.pub /etc/apk/keys/
sudo apk add ./cno-1.1.0-r2-x86_64.apk
```

OpenWrt 24.10.x example:

```sh
opkg install ./cno-1.1.0-r2-openwrt-24.10.4-bcm27xx-bcm2710.ipk
```

OpenWrt snapshot APKs use the SDK's local build key rather than a firmware trust
key, so a downloaded standalone package is installed explicitly as untrusted:

```sh
apk add --allow-untrusted ./cno-1.1.0-r2-openwrt-snapshots-bcm27xx-bcm2710.apk
```

Then verify the runtime:

```sh
cno --version
cno setup
```

Removal remains native: `apt remove cno`, `apk del cno`, or `opkg remove cno`.

## Local checks

On Debian/Ubuntu, install `shellcheck`, `ripgrep`, `jq`, and `dpkg-dev`, then
run:

```sh
sh scripts/check.sh
```

The check validates shell syntax and all matrices, builds the same Debian
fixture twice to verify reproducibility, and assembles a complete synthetic
release set. Actual OpenWrt compilation stays in GitHub Actions because every
row requires a downloaded target SDK and QEMU runtime root.

Shared configuration is in [`config/project.env`](config/project.env).
Increment `CNO_PACKAGE_RELEASE` when packaging changes without a new cno
version. Generated files go under `downloads/`, `work/`, and `dist/`.

## Design boundaries

- Debian packages require glibc 2.36 or newer; Debian 12 and Ubuntu 24.04 are
  the tested baselines.
- Alpine packages retain the upstream private dynamic libraries and OXC module.
- OpenWrt packages use the selected SDK's musl loader and system shared
  libraries. They do not use the generic static cno archive and do not carry a
  private `$ORIGIN/lib` RPATH.
- ARM float ABI variants and CPU generations are separate rows whenever the
  official SDK exposes them.
- The upstream glibc ARMv6 archive is not labeled Debian armel, because armel
  also permits ARMv5 CPUs.
- This repository never writes to or commits `../cno-cli`; source is checked out
  afresh at the immutable release commit by the workflow.

