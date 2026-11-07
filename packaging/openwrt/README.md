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
CNO_QEMU                  qemu-user executable for this target
CNO_BIG_ENDIAN            1 only for big-endian targets
CNO_TARGET_FLOAT_ABI      explicit none, soft, or hard calling ABI assertion
CNO_WASM                  ON or OFF
CNO_WAMR_TARGET           WAMR target such as AARCH64 or ARMV7_VFP
CNO_OPENWRT_DEPENDS       optional exact dependency expression for this SDK
```

`CNO_OPENWRT_DEPENDS` defaults to the OpenWrt 24.10 names used by the common
libraries.  A workflow should inspect the selected SDK/feed metadata and
override it if a release renamed a package.  The intended linkage is dynamic
against OpenWrt's target libraries; no private `$ORIGIN/lib` bundle is made.

The Rust archive is only one half of OXC.  `Makefile` compiles and links the C
binding with that SDK's `TARGET_CC`, `TARGET_CFLAGS`, and `TARGET_LDFLAGS`, so
the module receives the same endianness, float ABI, and platform flags as cno.

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
package architecture.

`rust_features` is one of `default`, `arm-soft-nofp`, `arm-hard-d16`, or
`arm-hard-neon`. It is a controlled profile rather than arbitrary Rust flags:
the soft/no-FP profile disables FP registers and NEON, the D16 profile disables
D32 and NEON, and the NEON profile enables Advanced SIMD. The final ELF
attributes must prove the selected profile for both cno and OXC.

For MIPS32 OpenWrt soft-float rows use `mips-unknown-linux-musl` or
`mipsel-unknown-linux-musl`, build Rust `std` with nightly, and set WAMR off
until WAMR's native-call ABI is proven on that SDK. ARMv5 and ARMv6 rows also
keep WAMR off for the initial matrix. Do not reuse cno-cli's musl.cc MIPS
helper: it intentionally changes MIPS to hard-float.
