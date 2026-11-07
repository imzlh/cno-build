#!/bin/sh
set -eu

usage() {
    printf '%s\n' \
        'Usage: verify-openwrt-elf.sh SDK EXPECTED_ARCH_PACKAGES ENDIAN MACHINE_REGEX FLOAT_ABI RUST_TARGET RUST_FEATURES CNO OXC' \
        '  ENDIAN: little|big; FLOAT_ABI: hard|soft|none' \
        '  RUST_FEATURES: default|aarch64-no-crypto|arm-soft-nofp|arm-hard-d16|arm-hard-neon' >&2
    exit 2
}

[ "$#" -eq 9 ] || usage
sdk=$1
expected_arch=$2
endian=$3
machine_regex=$4
float_abi=$5
rust_target=$6
rust_features=$7
cno=$8
oxc=$9
case $endian in little|big) ;; *) usage ;; esac
case $float_abi in hard|soft|none) ;; *) usage ;; esac
case $rust_features in
    default|aarch64-no-crypto|arm-soft-nofp|arm-hard-d16|arm-hard-neon) ;;
    *) usage ;;
esac
case $rust_target in
    x86_64-*|aarch64-*|riscv64*) expected_class=ELF64 ;;
    i586-*|arm-*|armv5te-*|armv7-*|mips-*|mipsel-*) expected_class=ELF32 ;;
    *) printf 'unsupported Rust target for ELF-class verification: %s\n' "$rust_target" >&2; exit 2 ;;
esac
[ -d "$sdk/staging_dir" ] || { printf 'invalid OpenWrt SDK: %s\n' "$sdk" >&2; exit 1; }
[ -x "$cno" ] || { printf 'cno is not executable: %s\n' "$cno" >&2; exit 1; }
[ -f "$oxc" ] || { printf 'OXC module not found: %s\n' "$oxc" >&2; exit 1; }

readelf_command=${READELF:-readelf}
command -v "$readelf_command" >/dev/null 2>&1 || { printf 'readelf not found\n' >&2; exit 1; }

actual_arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES=//p' "$sdk/.config" \
    | tr -d '"' | head -n 1)
[ -n "$actual_arch" ] || { printf 'SDK .config has no CONFIG_TARGET_ARCH_PACKAGES\n' >&2; exit 1; }
[ "$actual_arch" = "$expected_arch" ] || {
    printf 'SDK package architecture mismatch: expected %s, got %s\n' "$expected_arch" "$actual_arch" >&2
    exit 1
}

elf_identity() {
    headers=$($readelf_command -hW "$1")
    class=$(printf '%s\n' "$headers" | sed -n 's/^[[:space:]]*Class:[[:space:]]*//p')
    data=$(printf '%s\n' "$headers" | sed -n 's/^[[:space:]]*Data:[[:space:]]*//p')
    machine=$(printf '%s\n' "$headers" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
    flags=$(printf '%s\n' "$headers" | sed -n 's/^[[:space:]]*Flags:[[:space:]]*//p')
    [ -n "$class" ] && [ -n "$data" ] && [ -n "$machine" ] && [ -n "$flags" ] || return 1
    printf 'Class: %s\nData: %s\nMachine: %s\nFlags: %s\n' "$class" "$data" "$machine" "$flags"
}

cno_identity=$(elf_identity "$cno") || { printf 'cannot identify cno ELF\n' >&2; exit 1; }
oxc_identity=$(elf_identity "$oxc") || { printf 'cannot identify OXC ELF\n' >&2; exit 1; }
printf '%s\n' "$cno_identity" | grep -Fx "Class: $expected_class" >/dev/null || {
    printf 'unexpected ELF class for %s; expected %s:\n%s\n' \
        "$rust_target" "$expected_class" "$cno_identity" >&2
    exit 1
}
identity_core() {
    printf '%s\n' "$1" | sed '/^Flags:/d'
}
[ "$(identity_core "$cno_identity")" = "$(identity_core "$oxc_identity")" ] || {
    printf 'cno and OXC ELF class/data/machine differ:\n-- cno --\n%s\n-- OXC --\n%s\n' \
        "$cno_identity" "$oxc_identity" >&2
    exit 1
}
printf '%s\n' "$cno_identity" | grep -E "^Machine: .*($machine_regex)" >/dev/null || {
    printf 'unexpected ELF machine; expected /%s/\n%s\n' "$machine_regex" "$cno_identity" >&2
    exit 1
}
case $endian in
    little) printf '%s\n' "$cno_identity" | grep -F 'little endian' >/dev/null ;;
    big) printf '%s\n' "$cno_identity" | grep -F 'big endian' >/dev/null ;;
esac || { printf 'ELF endianness mismatch: expected %s\n' "$endian" >&2; exit 1; }

verify_float() {
    identity=$1
    file=$2
    case $float_abi in
        hard)
            if printf '%s\n' "$identity" | grep -q '^Machine: ARM$'; then
                attributes=$($readelf_command -AW "$file")
                if printf '%s\n' "$attributes" | grep -q 'Tag_ABI_VFP_args: VFP registers'; then
                    :
                else
                    printf '%s\n' "$identity" | grep -Eiq 'hard.float|hard float'
                fi
            elif printf '%s\n' "$identity" | grep -q '^Machine: MIPS'; then
                attributes=$($readelf_command -AW "$file")
                printf '%s\n' "$attributes" | grep -Eiq \
                    '(FP ABI|Tag_GNU_MIPS_ABI_FP):.*hard float'
            else
                printf '%s\n' "$identity" | grep -Eiq 'hard.float|hard float'
            fi
            ;;
        soft)
            if printf '%s\n' "$identity" | grep -q '^Machine: ARM$'; then
                attributes=$($readelf_command -AW "$file")
                if printf '%s\n' "$attributes" | grep -q 'Tag_ABI_VFP_args: VFP registers'; then
                    false
                elif printf '%s\n' "$identity" | grep -Eiq 'hard.float|hard float'; then
                    false
                else
                    printf '%s\n' "$attributes" | grep -Eq 'Tag_CPU_(arch|name)'
                fi
            elif printf '%s\n' "$identity" | grep -q '^Machine: MIPS'; then
                attributes=$($readelf_command -AW "$file")
                printf '%s\n' "$attributes" | grep -Eiq \
                    '(FP ABI|Tag_GNU_MIPS_ABI_FP):.*soft float'
            else
                printf '%s\n' "$identity" | grep -Eiq 'soft.float|soft float'
            fi
            ;;
        none) return 0 ;;
    esac || {
        printf 'ELF flags do not prove %s-float ABI for %s\n%s\n' \
            "$float_abi" "$file" "$identity" >&2
        exit 1
    }
}
verify_float "$cno_identity" "$cno"
verify_float "$oxc_identity" "$oxc"

verify_arm_features() {
    file=$1
    attributes=$($readelf_command -AW "$file")
    case $rust_features in
        default) return 0 ;;
        aarch64-no-crypto) return 0 ;;
        arm-soft-nofp)
            if printf '%s\n' "$attributes" | grep -Eq \
                'Tag_(Advanced_SIMD_arch|FP_arch):'; then
                printf 'ARM soft/no-FP profile contains FP or SIMD attributes: %s\n%s\n' \
                    "$file" "$attributes" >&2
                exit 1
            fi
            ;;
        arm-hard-d16)
            printf '%s\n' "$attributes" | grep -Eq \
                'Tag_FP_arch: (VFPv3-D16|VFPv4-D16)' || {
                    printf 'ARM D16 profile is not limited to a D16 FPU: %s\n%s\n' \
                        "$file" "$attributes" >&2
                    exit 1
                }
            if printf '%s\n' "$attributes" | grep -q 'Tag_Advanced_SIMD_arch:'; then
                printf 'ARM D16 profile unexpectedly enables NEON: %s\n%s\n' \
                    "$file" "$attributes" >&2
                exit 1
            fi
            ;;
        arm-hard-neon)
            printf '%s\n' "$attributes" | grep -Eq \
                'Tag_Advanced_SIMD_arch: (NEONv1|NEONv2|NEON for ARMv8)' || {
                    printf 'ARM NEON profile does not prove Advanced SIMD support: %s\n%s\n' \
                        "$file" "$attributes" >&2
                    exit 1
                }
            ;;
    esac
}
case $rust_features in
arm-*)
    printf '%s\n' "$cno_identity" | grep -q '^Machine: ARM$' || {
        printf 'ARM Rust feature profile used for a non-ARM ELF: %s\n' "$rust_features" >&2
        exit 1
    }
    verify_arm_features "$cno"
    verify_arm_features "$oxc"
    ;;
esac

if printf '%s\n' "$cno_identity" | grep -q '^Machine: MIPS'; then
    for identity in "$cno_identity" "$oxc_identity"; do
        printf '%s\n' "$identity" | grep -Eiq '^Flags: .*o32' || {
            printf 'MIPS ELF does not prove the required o32 ABI:\n%s\n' \
                "$identity" >&2
            exit 1
        }
    done
    for file in "$cno" "$oxc"; do
        attributes=$($readelf_command -AW "$file")
        printf '%s\n' "$attributes" | grep -Eq 'ISA:[[:space:]]+MIPS32r2' || {
            printf 'MIPS ELF does not prove the required MIPS32r2 ISA: %s\n%s\n' \
                "$file" "$attributes" >&2
            exit 1
        }
    done
fi

# The sifiveu row is RV64GC/lp64d.  RISC-V records both the compressed ISA and
# floating-point calling convention in e_flags rather than GNU attributes.
if printf '%s\n' "$cno_identity" | grep -q '^Machine: RISC-V$'; then
    for identity in "$cno_identity" "$oxc_identity"; do
        printf '%s\n' "$identity" | grep -Eiq \
            '^Flags: .*RVC.*double-float ABI' || {
            printf 'RISC-V ELF does not prove the required RV64GC/lp64d ABI:\n%s\n' \
                "$identity" >&2
            exit 1
        }
    done
fi

program_headers=$($readelf_command -lW "$cno")
interpreter=$(printf '%s\n' "$program_headers" | sed -n \
    's/.*Requesting program interpreter: \([^]]*\)\].*/\1/p')
printf '%s\n' "$interpreter" | grep -Eq '^/lib/ld-musl-[[:alnum:]_+.-]+\.so\.1$' || {
    printf 'unexpected cno PT_INTERP: %s\n' "$interpreter" >&2
    exit 1
}
if $readelf_command -lW "$oxc" | grep -q 'Requesting program interpreter'; then
    printf 'shared OXC module unexpectedly contains PT_INTERP\n' >&2
    exit 1
fi

find_target_library() {
    wanted_soname=$1
    for target_root in "$sdk"/staging_dir/target-* "$sdk"/staging_dir/toolchain-*; do
        [ -d "$target_root" ] || continue
        candidate=$(find "$target_root" \( -type f -o -type l \) \
            -name "$wanted_soname" -print -quit)
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

verify_dynamic() {
    dynamic=$($readelf_command -dW "$1")
    if printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH|TEXTREL)\)'; then
        printf 'forbidden RPATH/RUNPATH/TEXTREL in %s:\n%s\n' "$1" "$dynamic" >&2
        exit 1
    fi
    printf '%s\n' "$dynamic" | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' \
        | while IFS= read -r soname; do
            [ -n "$soname" ] || continue
            case $soname in
                */*|.*|*[!0-9A-Za-z_.+-]*)
                    printf 'invalid DT_NEEDED name in %s: %s\n' "$1" "$soname" >&2
                    exit 1
                    ;;
            esac
            case $soname in libc.so|libc.musl-*.so.1|ld-musl-*.so.1) continue ;; esac
            # Never accept a same-named host/hostpkg DSO as proof that a
            # target dependency exists.  Those directories contain x86 host
            # tools even for ARM/MIPS SDKs.
            if ! find_target_library "$soname" >/dev/null; then
                printf 'cannot resolve %s required by %s in SDK staging\n' "$soname" "$1" >&2
                exit 1
            fi
        done
}
verify_dynamic "$cno"
verify_dynamic "$oxc"

$readelf_command --dyn-syms --wide "$cno" | grep -Eq \
    'GLOBAL[[:space:]]+DEFAULT[[:space:]]+[0-9]+[[:space:]]+JS_[A-Za-z0-9_]+' || {
    printf 'cno does not export the QuickJS API needed by OXC\n' >&2
    exit 1
}
$readelf_command --dyn-syms --wide "$oxc" | grep -Eq \
    'GLOBAL[[:space:]]+DEFAULT[[:space:]]+[0-9]+[[:space:]]+tjs_module_info$' || {
    printf 'OXC does not export tjs_module_info\n' >&2
    exit 1
}

printf '[openwrt-elf] %s (%s, %s endian, %s float, Rust features=%s) and OXC passed\n' \
    "$actual_arch" "$machine_regex" "$endian" "$float_abi" "$rust_features"
