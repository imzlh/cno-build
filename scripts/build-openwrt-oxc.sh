#!/bin/sh
set -eu

usage() {
    printf '%s\n' \
        'Usage: build-openwrt-oxc.sh SOURCE_DIR RUST_TARGET RUST_CPU RUST_FEATURES FLOAT_ABI OUTPUT_DIR' \
        '  RUST_FEATURES: default|arm-soft-nofp|arm-hard-d16|arm-hard-neon' \
        '  FLOAT_ABI: hard|soft|none' >&2
    exit 2
}

[ "$#" -eq 6 ] || usage
source_dir=$1
rust_target=$2
rust_cpu=$3
rust_features=$4
float_abi=$5
output_dir=$6

[ -f "$source_dir/ext-oxc/Cargo.toml" ] || { printf 'missing ext-oxc source\n' >&2; exit 1; }
[ -f "$source_dir/scripts/ci/oxc/Cargo.lock" ] || { printf 'missing pinned OXC Cargo.lock\n' >&2; exit 1; }
[ -f "$source_dir/.cargo/config.toml" ] || {
    printf 'missing repository Cargo configuration for the pinned OXC patch\n' >&2
    exit 1
}
[ -f "$source_dir/scripts/ci/oxc/vendor/oxc_sourcemap/Cargo.toml" ] || {
    printf 'missing library-only oxc_sourcemap patch\n' >&2
    exit 1
}
grep -Fq 'oxc_sourcemap = { path = "scripts/ci/oxc/vendor/oxc_sourcemap" }' \
    "$source_dir/.cargo/config.toml" || {
        printf 'repository Cargo configuration does not select the pinned oxc_sourcemap patch\n' >&2
        exit 1
    }
case $rust_target in *[!0-9A-Za-z_.-]*|'') printf 'invalid Rust target: %s\n' "$rust_target" >&2; exit 2 ;; esac
case $rust_cpu in *[!0-9A-Za-z_.+-]*|'') printf 'invalid Rust CPU: %s\n' "$rust_cpu" >&2; exit 2 ;; esac
case $rust_features in
    default|arm-soft-nofp|arm-hard-d16|arm-hard-neon) ;;
    *) usage ;;
esac
case $float_abi in hard|soft|none) ;; *) usage ;; esac
command -v rustup >/dev/null 2>&1 || { printf 'rustup is required\n' >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { printf 'cargo is required\n' >&2; exit 1; }
command -v rustc >/dev/null 2>&1 || { printf 'rustc is required\n' >&2; exit 1; }

case $rust_target/$float_abi in
    arm*-musleabihf/hard) ;;
    arm*-musleabi/soft) ;;
    mips-unknown-linux-musl/soft|mipsel-unknown-linux-musl/soft) ;;
    */none) ;;
    *)
        printf 'Rust target %s does not encode requested float ABI %s\n' "$rust_target" "$float_abi" >&2
        exit 1
        ;;
esac
case $rust_features:$rust_target:$float_abi in
    default:*) ;;
    arm-soft-nofp:arm*-musleabi:soft) ;;
    arm-hard-d16:arm*-musleabihf:hard) ;;
    arm-hard-neon:arm*-musleabihf:hard) ;;
    *)
        printf 'Rust feature profile %s is incompatible with %s/%s\n' \
            "$rust_features" "$rust_target" "$float_abi" >&2
        exit 1
        ;;
esac

mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
source_dir=$(CDPATH= cd -- "$source_dir" && pwd)
cp "$source_dir/scripts/ci/oxc/Cargo.lock" "$source_dir/ext-oxc/Cargo.lock"

tier3=false
case $rust_target in mips*-unknown-linux-musl*) tier3=true ;; esac
if [ "$tier3" = true ]; then
    # MIPS tier-3 targets publish no std component. Rebuild std with a pinned
    # nightly newer than the 1.95 dependency baseline and record its identity.
    toolchain=${CNO_OXC_RUST_NIGHTLY:-nightly-2026-10-15}
    rustup toolchain install "$toolchain" --profile minimal --no-self-update --component rust-src
    set -- -Z build-std=std,panic_abort
else
    toolchain=${CNO_OXC_RUST_TOOLCHAIN:-1.95.0}
    rustup toolchain install "$toolchain" --profile minimal --no-self-update --target "$rust_target"
    set --
fi

# `-Ctarget-cpu` has historically degraded an unknown CPU to a warning and a
# generic target.  Validate against the exact pinned compiler used below, not
# only against whichever stable rustc happens to be installed on the runner.
rustc "+$toolchain" --target "$rust_target" --print target-cpus \
    | awk -v wanted="$rust_cpu" '$1 == wanted { found=1 } END { exit !found }' || {
        printf 'Rust CPU %s is unavailable for %s in %s\n' \
            "$rust_cpu" "$rust_target" "$toolchain" >&2
        exit 1
    }
target_cfg=$(rustc "+$toolchain" --target "$rust_target" --print cfg)
case $rust_target/$float_abi in
    arm*-musleabihf/hard)
        printf '%s\n' "$target_cfg" | grep -Fx 'target_abi="eabihf"' >/dev/null || {
            printf 'Rust target %s does not report the hard-float EABI\n' "$rust_target" >&2
            exit 1
        }
        ;;
    arm*-musleabi/soft)
        printf '%s\n' "$target_cfg" | grep -Fx 'target_abi="eabi"' >/dev/null || {
            printf 'Rust target %s does not report the soft-float EABI\n' "$rust_target" >&2
            exit 1
        }
        ;;
    mips-unknown-linux-musl/soft|mipsel-unknown-linux-musl/soft)
        # These built-in tier-3 specifications are o32/MIPS32r2/soft-float.
        # Reassert that contract before rebuilding std with this nightly.
        target_spec=$(rustc "+$toolchain" -Z unstable-options \
            --target "$rust_target" --print target-spec-json)
        printf '%s\n' "$target_spec" | grep -F '"llvm-abiname": "o32"' >/dev/null || {
            printf 'Rust target %s is no longer the MIPS o32 ABI\n' "$rust_target" >&2
            exit 1
        }
        printf '%s\n' "$target_spec" | grep -Eq \
            '"features": ".*\+mips32r2([,+"]|$)' || {
                printf 'Rust target %s no longer enables MIPS32r2\n' "$rust_target" >&2
                exit 1
            }
        printf '%s\n' "$target_spec" | grep -Eq \
            '"features": ".*\+soft-float([,+"]|$)' || {
                printf 'Rust target %s is no longer soft-float\n' "$rust_target" >&2
                exit 1
            }
        ;;
esac
rustc_version=$(rustc "+$toolchain" --version --verbose | tr '\n' ';')
rustc_release=$(printf '%s\n' "$rustc_version" | sed -n 's/.*release: \([0-9][0-9.]*\).*/\1/p')
rustc_major=$(printf '%s\n' "$rustc_release" | cut -d. -f1)
rustc_minor=$(printf '%s\n' "$rustc_release" | cut -d. -f2)
case $rustc_major in ''|*[!0-9]*) rustc_major=0 ;; esac
case $rustc_minor in ''|*[!0-9]*) rustc_minor=0 ;; esac
if [ "$rustc_major" -lt 1 ] || { [ "$rustc_major" -eq 1 ] && [ "$rustc_minor" -lt 95 ]; }; then
    printf 'OXC requires Rust 1.95 or newer; got %s\n' "$rustc_version" >&2
    exit 1
fi

target_features=-crt-static
if [ "$float_abi" = soft ] && [ "$tier3" = true ]; then
    # OpenWrt MIPS32 is normally o32 soft-float.  This is intentionally the
    # opposite of cno-cli's musl.cc helper, which removes soft-float and asserts
    # a hard-float ABI.  The flag also applies while nightly rebuilds std.
    target_features="$target_features,+soft-float"
fi
# Selecting an ARM CPU in LLVM also selects that core's optional floating-point
# units. The target triple controls the calling convention, but does not stop
# LLVM from emitting VFP/NEON opcodes. Apply a named profile per SDK row so
# non-FPU boards stay integer-only and D16 boards never use d16-d31/NEON.
case $rust_features in
    default) ;;
    arm-soft-nofp)
        target_features="$target_features,+soft-float,-neon,-fpregs"
        ;;
    arm-hard-d16)
        target_features="$target_features,-d32,-neon"
        ;;
    arm-hard-neon)
        target_features="$target_features,+neon"
        ;;
esac
rustflags="${RUSTFLAGS:+$RUSTFLAGS }-Crelocation-model=pic -Ctarget-feature=$target_features -Ctarget-cpu=$rust_cpu"
if [ "$tier3" = false ]; then
    # Stable musl targets ship self-contained CRT objects. They are not wanted
    # in a loadable module, so use the upstream cno OXC policy for those rows.
    # MIPS rebuilds std itself and is linked into oxc.so later by TARGET_CC;
    # forcing this unstable tier-3 knob has regressed across nightly releases.
    rustflags="$rustflags -Clink-self-contained=no"
fi

(
    cd "$source_dir"
    unset CARGO_ENCODED_RUSTFLAGS
    RUSTFLAGS="$rustflags" cargo "+$toolchain" rustc "$@" \
        --manifest-path "$source_dir/ext-oxc/Cargo.toml" --locked --release --lib \
        --target "$rust_target" --target-dir "$output_dir/cargo" \
        -- --print native-static-libs
)

archive="$output_dir/libcjs_oxc_core.a"
cp "$output_dir/cargo/$rust_target/release/libcjs_oxc_core.a" "$archive"
cat > "$output_dir/OXC-RUST-BUILD-INFO.txt" <<EOF
rust_target=$rust_target
rust_cpu=$rust_cpu
rust_features=$rust_features
cpu_tune_scope=rust-isa-baseline-c-binding-recompiled-by-sdk
float_abi=$float_abi
rust_toolchain=$toolchain
rustc_version=$rustc_version
rustflags=$rustflags
EOF
sha256sum "$archive" > "$archive.sha256"
printf '[openwrt-oxc-rust] %s (%s, cpu=%s, features=%s, float=%s)\n' \
    "$archive" "$rust_target" "$rust_cpu" "$rust_features" "$float_abi"
