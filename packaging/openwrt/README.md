# OpenWrt source-build package

This directory is the SDK-side half of the OpenWrt source build. It compiles
the selected cno release from source and never repackages a generic Linux
binary.

Every matrix row must use a different official OpenWrt SDK and must rebuild
the C runtime, QuickJS, libuv, WAMR (when enabled), the OXC C binding, and the
final package.  Builds must not be deduplicated by `ARCH_PACKAGES`: for
example, `ramips/mt7621` may use the same package architecture label as a 24Kc
target while the SDK actually tunes C code for 1004Kc.

## Inputs

Copy this directory to `SDK/package/cno` and copy the three artifacts below to
the SDK `dl/` directory.  Pass the following variables to every SDK `make`
invocation, including `defconfig` and `package/cno/compile`:

```text
CNO_VERSION               upstream version
CNO_PACKAGE_RELEASE       OpenWrt package revision
CNO_SOURCE_ARCHIVE        deterministic source archive, including submodules
CNO_SOURCE_SHA256         SHA-256 of that archive
CNO_BUNDLE_FILE           host-generated cno-cli.min.js
CNO_BUNDLE_SHA256         SHA-256 of the bundle
CNO_OXC_ARCHIVE           target Rust staticlib produced per matrix row
CNO_OXC_SHA256            SHA-256 of the Rust staticlib
CNO_QEMU                  absolute system qemu-user executable for this target
CNO_BIG_ENDIAN            1 only for big-endian targets
CNO_TARGET_FLOAT_ABI      explicit none, soft, or hard calling ABI assertion
CNO_WASM                  ON or OFF
CNO_WAMR_TARGET           WAMR target such as AARCH64 or ARMV7_VFP
CNO_OPENWRT_DEPENDS       optional exact dependency expression for this SDK
```

`CNO_OPENWRT_DEPENDS` defaults to the logical package names used by OpenWrt
24.10 and snapshots.  Recipes must use names such as `libcurl`, `libopenssl`,
and `libsqlite3`, not their generated repository filenames (`libcurl4`,
`libopenssl3`, or `libsqlite3-0`).  OpenWrt uses the logical names to build and
stage development files, then adds ABI suffixes to final runtime dependencies
itself.  The intended linkage is dynamic against OpenWrt's target libraries;
no private `$ORIGIN/lib` bundle is made.

The SDK configuration explicitly selects OpenSSL, zlib, and HTTP/2 support for
libcurl and seeds their logical packages: `libopenssl`, `zlib`, and
`libnghttp2`. Merely selecting `libcurl` does not choose a TLS backend reliably
across SDK releases. All other curl options with conditional package
dependencies are explicitly disabled.

The SDK's own `feeds.conf.default` pins both its OpenWrt base source and the
packages feed. Both indexes must be updated: SDK archives contain only a small
subset of core recipes, while OpenSSL, zlib, and CA certificates come from the
pinned base source. Only cno's active dependency recipes are installed.
`scripts/feeds install libcurl` and `scripts/feeds install openssl` must not be
used because they recursively install recipes for every conditional dependency,
including disabled LDAP, HTTP/3, alternate TLS backends, and OpenSSL engines.
The pinned curl and OpenSSL source recipes are linked directly after installing
only the active zlib, HTTP/2, certificate, and cno dependency closure.
OpenWrt 24.10 stores that base-feed OpenSSL recipe under
`package/libs/openssl`, while snapshots store it under `libs/openssl`; the
builder accepts exactly one of those pinned layouts and rejects an ambiguous or
unknown layout.

Before linking curl, its SDK-local recipe is normalized fail-closed. The active
OpenSSL, zlib, and HTTP/2 dependencies become unconditional package edges, and
all disabled conditional package edges are removed. Active source tokens and
`ca-bundle` must occur exactly once; known disabled tokens may be absent in a
release but may not be duplicated, and unknown conditional tokens are fatal.
All conditional dependency tokens must be absent afterward, and the four
resulting dependencies (`libopenssl`, `zlib`, `libnghttp2`, and `ca-bundle`)
must each occur exactly once. This prevents
OpenWrt package metadata from generating `PACKAGE_libcurl` / `LIBCURL_*`
structural Kconfig cycles. Any recursive-dependency diagnostic remains fatal.
The SDK-local OpenSSL recipe is normalized by the same helper: its compression,
AFALG, devcrypto, and Padlock conditional dependency tokens are removed when
present because all four features are explicitly disabled. Duplicate known
tokens and unknown conditional tokens are fatal. Zlib remains staged through
curl's unconditional dependency. Any unsafe upstream dependency-shape drift
aborts before `defconfig`.

After `defconfig`, enabled curl features and their packages must still be
selected. Disabled optional features may appear as `# CONFIG_* is not set` or
may be absent when that OpenWrt release does not define the symbol; any
`CONFIG_*=...` assignment for one of those disabled features is fatal.

The Rust archive is only one half of OXC.  `Makefile` compiles and links the C
binding with that SDK's `TARGET_CC`, `TARGET_CFLAGS`, and `TARGET_LDFLAGS`, so
the module receives the same endianness, float ABI, and platform flags as cno.
The caller resolves `CNO_QEMU` before entering the SDK environment. Target
`cjsc` and `qjsc` wrappers also clear host loader variables before executing
that absolute path, so an SDK host wrapper cannot inject `runas.so` into a
target musl process.

## Matrix contract

The caller's matrix should record these columns explicitly:

```text
format release target subtarget expected_arch_packages cpu_tune endian
float_abi rust_target rust_cpu rust_features qemu wamr_target wasm machine_regex
```

Before building, compare `expected_arch_packages` with the SDK's actual
`CONFIG_TARGET_ARCH_PACKAGES`, validate the resulting ELF against
`machine_regex`, and record the SDK's target optimization flags in build
provenance. The matrix key is `format + release + target + subtarget`, not the
package architecture. Job, artifact, and release-asset names should lead with
the verified package architecture and retain target/subtarget as a suffix; the
suffix prevents collisions when multiple SDKs publish the same architecture
label with different tuning.

`rust_features` is one of `default`, `aarch64-no-crypto`, `arm-soft-nofp`,
`arm-hard-d16`, or `arm-hard-neon`. It is a controlled profile rather than
arbitrary Rust flags: the AArch64 profile retains A53/A72 scheduling while
disabling optional AES/SHA2 instructions, the soft/no-FP profile disables FP
registers and NEON, the D16 profile disables D32 and NEON, and the NEON profile
enables Advanced SIMD. The final ELF attributes must prove each ARM profile
for both cno and OXC.

For MIPS32 OpenWrt soft-float rows use `mips-unknown-linux-musl` or
`mipsel-unknown-linux-musl`, build Rust `std` with nightly, and set WAMR off
until WAMR's native-call ABI is proven on that SDK. ARMv5 and ARMv6 rows also
keep WAMR off for the initial matrix. Do not reuse cno-cli's musl.cc MIPS
helper: it intentionally changes MIPS to hard-float.
