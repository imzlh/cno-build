# Local upstream patches

`cno-cli-openwrt-cross-abi.patch` is an explicit packaging patch for the
sibling `cno-cli` repository. The workflow applies it only to the temporary,
immutable source payload, so it never changes the developer's sibling checkout
or pretends the packaging fixes are already part of upstream.

The patch adds configure-time target ABI assertions.  An OpenWrt SDK build can
pass, for example:

```text
-DCNO_TARGET_ENDIAN=big
-DCNO_TARGET_FLOAT_ABI=soft
```

For ARM, `soft` means the base procedure-call standard shared by true
soft-float and softfp builds; it does not claim that no VFP instruction can be
emitted.  The packaging matrix's separate Rust/ELF feature checks enforce the
no-FPU rows.  For MIPS, the compiler must expose the matching
`__mips_soft_float` or `__mips_hard_float` ABI macro.  ARM and MIPS may not use
`none`; that value is reserved for targets such as x86 and AArch64 whose ABI is
not selected by this field.

The assertions deliberately do not invent CPU flags or a sysroot.  OpenWrt's
toolchain file and `TARGET_CFLAGS` remain authoritative, so Cortex-A5, A7, A53,
ARMv5/v6/v7 and the MIPS subtargets are genuinely compiled in their individual
SDK jobs rather than differentiated only by archive name.  This packaging
repository passes both assertion values from its OpenWrt matrix. Its nested
CMake hook checks the patch's success marker and fails configuration if CMake
merely accepted the unknown `-D` variables without consuming them.

For local experimentation, apply from a disposable `cno-cli` checkout:

```sh
git apply --check ../cno-builds/patches/cno-cli-openwrt-cross-abi.patch
git apply ../cno-builds/patches/cno-cli-openwrt-cross-abi.patch
```

The package workflow already applies the patch to its temporary source payload
and records the patch SHA-256. Committing it upstream is optional; if upstream
later contains equivalent assertions, refresh or retire this patch explicitly.

The same patch also makes the RISC-V libuv compatibility edit reliable after
the source is archived without nested Git metadata. `git apply` invoked from
the former libuv submodule directory can silently skip its only path when Git
discovers the enclosing packaging checkout and still exit successfully. The
patched helper uses `patch` against an explicit directory and then asserts that
the old `.insn` spelling is gone before invoking the musl.cc assembler.

Do not use this patch to label the existing musl.cc MIPS release as soft-float.
That upstream helper explicitly checks for o32 hard-float.  OpenWrt's MIPS
soft-float packages must continue to be built with each official SDK's compiler,
sysroot and flags.
