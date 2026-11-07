#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

usage() {
    printf '%s\n' \
        'Usage: build-openwrt.sh FORMAT RELEASE TARGET SUBTARGET EXPECTED_ARCH CPU_TUNE' \
        '       ENDIAN FLOAT_ABI RUST_TARGET RUST_CPU RUST_FEATURES EMULATOR WAMR_TARGET WASM' \
        '       MACHINE_REGEX VERSION SOURCE_COMMIT SOURCE_ARCHIVE BUNDLE OUTPUT_DIR' >&2
    exit 2
}

[ "$#" -eq 20 ] || usage
format=$1
release=$2
target=$3
subtarget=$4
expected_arch=$5
cpu_tune=$6
endian=$7
float_abi=$8
rust_target=$9
shift 9
rust_cpu=$1
rust_features=$2
emulator=$3
wamr_target=$4
wasm=$5
machine_regex=$6
version=$7
source_commit=$8
source_archive=$9
shift 9
bundle=$1
output_dir=$2

case $format in ipk|apk) ;; *) die "OpenWrt format must be ipk or apk: $format" ;; esac
case $release in snapshots) [ "$format" = apk ] || die 'snapshots must use apk' ;; *[!0-9.]*) die "invalid OpenWrt release: $release" ;; esac
case $endian in little|big) ;; *) die "invalid endian value: $endian" ;; esac
case $float_abi in hard|soft|none) ;; *) die "invalid float ABI: $float_abi" ;; esac
case $rust_features in
    default|arm-soft-nofp|arm-hard-d16|arm-hard-neon) ;;
    *) die "invalid Rust feature profile: $rust_features" ;;
esac
case $wasm in ON|OFF) ;; *) die "invalid WASM value: $wasm" ;; esac
for value in "$target" "$subtarget" "$expected_arch" "$cpu_tune" "$rust_target" \
    "$rust_cpu" "$emulator" "$wamr_target"; do
    validate_arch "$value"
done
printf '%s\n' "$machine_regex" | grep -Eq '^[A-Za-z0-9_.+ -]+$' \
    || die "invalid ELF machine expression: $machine_regex"
case $source_commit in ''|*[!0-9a-fA-F]*) die "invalid cno source commit: $source_commit" ;; esac
[ "${#source_commit}" -eq 40 ] || die 'cno source commit must contain 40 hexadecimal characters'
validate_version "$version"
[ -f "$source_archive" ] || die "source archive not found: $source_archive"
[ -f "$bundle" ] || die "JavaScript bundle not found: $bundle"

for command_name in curl sha256sum tar make "$emulator" readelf rustup cargo; do
    need_command "$command_name"
done
if [ "$format" = ipk ]; then need_command ar; fi

if [ "$release" = snapshots ]; then
    sdk_base="https://downloads.openwrt.org/snapshots/targets/$target/$subtarget"
else
    sdk_base="https://downloads.openwrt.org/releases/$release/targets/$target/$subtarget"
fi

work=$(make_temp_dir "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
curl_args='--fail --location --show-error --silent --retry 3 --retry-all-errors'
# shellcheck disable=SC2086
curl $curl_args "$sdk_base/sha256sums" -o "$work/sha256sums"
# shellcheck disable=SC2086
curl $curl_args "$sdk_base/" -o "$work/index.html"

sdk_name=$(
    sed -n 's/.*href="\([^"]*openwrt-sdk-[^"]*\.tar\.\(zst\|xz\)\)".*/\1/p' "$work/index.html" \
        | sort -u \
        | head -n 1
)
[ -n "$sdk_name" ] || die "cannot find an SDK at $sdk_base"
validate_asset_name "$sdk_name"
expected_sdk_sha256=$(
    awk -v wanted="$sdk_name" '
        { name=$2; sub(/^\*/, "", name) }
        name == wanted { print $1; found++ }
        END { if (found != 1) exit 1 }
    ' "$work/sha256sums"
) || die "sha256sums does not contain exactly one entry for $sdk_name"
# shellcheck disable=SC2086
curl $curl_args "$sdk_base/$sdk_name" -o "$work/$sdk_name"
sdk_sha256=$(sha256sum "$work/$sdk_name" | awk '{print $1}')
[ "$sdk_sha256" = "$expected_sdk_sha256" ] || die "OpenWrt SDK checksum mismatch: $sdk_name"

case $sdk_name in
    *.tar.zst) need_command zstd; tar --zstd -xf "$work/$sdk_name" -C "$work" ;;
    *.tar.xz) tar -xJf "$work/$sdk_name" -C "$work" ;;
    *) die "unsupported SDK archive: $sdk_name" ;;
esac
sdk_dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'openwrt-sdk-*' -print | head -n 1)
[ -n "$sdk_dir" ] && [ -d "$sdk_dir" ] || die 'cannot locate extracted OpenWrt SDK'

# This archive is created by prepare-openwrt-source.sh. Still reject absolute
# paths and parent traversal before using it outside the SDK build system.
tar -tzf "$source_archive" | while IFS= read -r entry; do
    case $entry in /*|../*|*/../*|*/..) die "unsafe source archive path: $entry" ;; esac
done
source_dir="$work/cno-source"
mkdir -p "$source_dir"
tar -xzf "$source_archive" --strip-components=1 -C "$source_dir" --no-same-owner
[ -f "$source_dir/CMakeLists.txt" ] || die 'cno source archive is incomplete'
[ -f "$source_dir/ext-oxc/Cargo.toml" ] || die 'cno source archive is missing ext-oxc'
archived_commit=$(sed -n 's/^cno_commit=//p' "$source_dir/OPENWRT-SOURCE-INFO.txt" | head -n 1)
[ "$archived_commit" = "$source_commit" ] \
    || die "source archive commit mismatch: expected $source_commit, got ${archived_commit:-<missing>}"

oxc_dir="$work/oxc"
sh "$CNO_BUILDS_ROOT/scripts/build-openwrt-oxc.sh" \
    "$source_dir" "$rust_target" "$rust_cpu" "$rust_features" "$float_abi" "$oxc_dir"
oxc_archive="$oxc_dir/libcjs_oxc_core.a"
source_sha256=$(sha256sum "$source_archive" | awk '{print $1}')
bundle_sha256=$(sha256sum "$bundle" | awk '{print $1}')
oxc_sha256=$(sha256sum "$oxc_archive" | awk '{print $1}')
source_name="cno-source-$version.tar.gz"
bundle_name="cno-cli-$version.min.js"
oxc_name="cno-oxc-$version-$target-$subtarget.a"

mkdir -p "$sdk_dir/package/cno" "$sdk_dir/dl"
grep -Fxq 'PKG_INSTALL:=1' "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt package recipe must enable PKG_INSTALL'
if grep -Eq '^[[:space:]]*CMAKE_INSTALL[[:space:]]*:=' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile"; then
    die 'OpenWrt package recipe uses CMAKE_INSTALL instead of PKG_INSTALL'
fi
if grep -Eq '^[[:space:]]*\+\$\(NINJA\)' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile"; then
    die 'OpenWrt package recipe bypasses the official CMake compile macro'
fi
cp "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" "$sdk_dir/package/cno/Makefile"
cp "$CNO_BUILDS_ROOT/packaging/openwrt/openwrt-project.cmake" \
    "$sdk_dir/package/cno/openwrt-project.cmake"
cp "$source_archive" "$sdk_dir/dl/$source_name"
cp "$bundle" "$sdk_dir/dl/$bundle_name"
cp "$oxc_archive" "$sdk_dir/dl/$oxc_name"

# Development headers for cno's system shared libraries live in the packages
# feed. Install its recipes before selecting cno.
if [ -x "$sdk_dir/scripts/feeds" ]; then
    (
        cd "$sdk_dir"
        ./scripts/feeds update packages
        ./scripts/feeds install -a -p packages
    )
fi

sdk_make() {
    (
        cd "$sdk_dir"
        make \
            CNO_VERSION="$version" \
            CNO_PACKAGE_RELEASE="$CNO_PACKAGE_RELEASE" \
            CNO_SOURCE_ARCHIVE="$source_name" \
            CNO_SOURCE_SHA256="$source_sha256" \
            CNO_BUNDLE_FILE="$bundle_name" \
            CNO_BUNDLE_SHA256="$bundle_sha256" \
            CNO_OXC_ARCHIVE="$oxc_name" \
            CNO_OXC_SHA256="$oxc_sha256" \
            CNO_QEMU="$emulator" \
            CNO_BIG_ENDIAN="$([ "$endian" = big ] && printf 1 || printf 0)" \
            CNO_TARGET_FLOAT_ABI="$float_abi" \
            CNO_WASM="$wasm" \
            CNO_WAMR_TARGET="$wamr_target" \
            "$@"
    )
}

sdk_make defconfig
sed -i '/^# CONFIG_PACKAGE_cno is not set$/d;/^CONFIG_PACKAGE_cno=/d' "$sdk_dir/.config"
printf '%s\n' 'CONFIG_PACKAGE_cno=m' >> "$sdk_dir/.config"
# defconfig consumes the explicit package selection and its dependencies.
sdk_make defconfig
grep -q '^CONFIG_PACKAGE_cno=m$' "$sdk_dir/.config" \
    || die 'SDK defconfig did not retain CONFIG_PACKAGE_cno=m'

actual_arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES=//p' "$sdk_dir/.config" | tr -d '"' | head -n 1)
[ -n "$actual_arch" ] || die 'SDK .config has no CONFIG_TARGET_ARCH_PACKAGES'
[ "$actual_arch" = "$expected_arch" ] \
    || die "SDK package architecture mismatch: expected $expected_arch, got $actual_arch"
grep -q "^CONFIG_TARGET_${target}=y$" "$sdk_dir/.config" \
    || die "SDK configuration does not select target $target"
grep -q "^CONFIG_TARGET_${target}_${subtarget}=y$" "$sdk_dir/.config" \
    || die "SDK configuration does not select subtarget $target/$subtarget"

target_cflags=$(sdk_make -s val.TARGET_CFLAGS 2>/dev/null || true)
target_ldflags=$(sdk_make -s val.TARGET_LDFLAGS 2>/dev/null || true)
target_cflags=$(printf '%s' "$target_cflags" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
target_ldflags=$(printf '%s' "$target_ldflags" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
if [ -n "$target_cflags" ]; then
    case $float_abi in
        hard)
            printf '%s\n' "$target_cflags" | grep -Eq -- '(^| )-mfloat-abi=hard( |$)' \
                || die "SDK TARGET_CFLAGS do not confirm hard-float: $target_cflags"
            ;;
        soft)
            if printf '%s\n' "$machine_regex" | grep -q '^ARM$'; then
                printf '%s\n' "$target_cflags" | grep -Eq -- '(^| )-mfloat-abi=(soft|softfp)( |$)' \
                    || die "SDK TARGET_CFLAGS do not confirm ARM soft-float: $target_cflags"
            elif printf '%s\n' "$machine_regex" | grep -q '^MIPS$'; then
                printf '%s\n' "$target_cflags" | grep -Eq -- '(^| )-msoft-float( |$)' \
                    || die "SDK TARGET_CFLAGS do not confirm MIPS soft-float: $target_cflags"
            fi
            ;;
    esac
fi
printf '[openwrt-sdk] %s/%s arch=%s expected-cpu=%s\n' \
    "$target" "$subtarget" "$actual_arch" "$cpu_tune"
printf '[openwrt-sdk] TARGET_CFLAGS=%s\n' "${target_cflags:-<reported in compile log>}"

openwrt_jobs=${CNO_OPENWRT_JOBS:-2}
case $openwrt_jobs in ''|*[!0-9]*) die "invalid CNO_OPENWRT_JOBS: $openwrt_jobs" ;; esac
[ "$openwrt_jobs" -gt 0 ] || die 'CNO_OPENWRT_JOBS must be positive'
sdk_make -j"$openwrt_jobs" package/cno/compile V=sc

package=$(find "$sdk_dir/bin/packages" -type f \( -name "cno[-_]*.$format" -o -name "cno.$format" \) \
    ! -name '*-dbg*' -print \
    | sort)
[ -n "$package" ] || die "the SDK did not produce a cno .$format package"
[ "$(printf '%s\n' "$package" | wc -l)" -eq 1 ] \
    || die "the SDK produced more than one cno .$format package"
staged_root=$(find "$sdk_dir/build_dir" -type d -path '*/ipkg-*/cno' -print | sort | head -n 1)
if [ -z "$staged_root" ]; then
    staged_root=$(find "$sdk_dir/build_dir" -type d -path '*/.pkgdir/cno' -print | sort | head -n 1)
fi
if [ -z "$staged_root" ]; then
    staged_root=$(find "$sdk_dir/build_dir" -type d -path '*/.pkgdir/cno.installed' -print \
        | sort | head -n 1)
fi
[ -n "$staged_root" ] || die 'cannot find the OpenWrt-staged cno root'
runtime="$staged_root/usr/lib/cno/cno"
oxc="$staged_root/usr/lib/cno/ext/oxc.so"
assert_staged_payload() {
    root=$1
    [ -x "$root/usr/lib/cno/cno" ] || die 'staged package is missing the cno runtime'
    [ -f "$root/usr/lib/cno/ext/oxc.so" ] || die 'staged package is missing OXC'
    [ "$(readlink "$root/usr/bin/cno")" = ../lib/cno/cno ] \
        || die 'staged package has an invalid /usr/bin/cno link'
}
assert_staged_payload "$staged_root"

sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-elf.sh" \
    "$sdk_dir" "$expected_arch" "$endian" "$machine_regex" "$float_abi" \
    "$rust_target" "$rust_features" "$runtime" "$oxc"

mkdir -p "$output_dir"
output_name="${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-openwrt-${release}-${target}-${subtarget}.${format}"
cp "$package" "$output_dir/$output_name"
# Exercise the payload extracted from the final package rather than only the
# SDK's pre-archive staging tree. This catches format/strip/install mistakes.
packaged_root="$work/packaged-root"
mkdir -p "$packaged_root"
case $format in
    ipk)
        package_extract="$work/package-ipk"
        mkdir -p "$package_extract"
        package_abs=$(CDPATH= cd -- "$(dirname -- "$package")" && pwd)/$(basename -- "$package")
        if ar t "$package_abs" >/dev/null 2>&1; then
            (cd "$package_extract" && ar x "$package_abs")
        elif tar -tf "$package_abs" >/dev/null 2>&1; then
            tar -xf "$package_abs" -C "$package_extract"
        else
            die 'IPK is neither an ar archive nor a supported tar archive'
        fi
        data_archive=$(find "$package_extract" -maxdepth 1 -type f \
            \( -name 'data.tar' -o -name 'data.tar.gz' -o -name 'data.tar.zst' \
               -o -name 'data.tar.xz' -o -name 'data.tar.bz2' \) \
            -print | head -n 1)
        [ -n "$data_archive" ] || die 'IPK has no supported data archive'
        case $data_archive in
            *.tar.zst) tar --zstd -xf "$data_archive" -C "$packaged_root" ;;
            *) tar -xf "$data_archive" -C "$packaged_root" ;;
        esac
        ;;
    apk)
        package_abs=$(CDPATH= cd -- "$(dirname -- "$package")" && pwd)/$(basename -- "$package")
        host_apk=$(find "$sdk_dir/staging_dir/host" "$sdk_dir/staging_dir/hostpkg" \
            \( -type f -o -type l \) -path '*/bin/apk' -print 2>/dev/null | head -n 1)
        [ -n "$host_apk" ] && [ -x "$host_apk" ] \
            || die 'cannot find the SDK host apk tool for ADB package installation'
        # OpenWrt snapshot packages use apk-tools v3's ADB format, so they
        # cannot be unpacked as Alpine-style gzip tarballs.  Install the local
        # package into an empty database instead.  An explicit architecture is
        # essential here: the host apk executable itself is x86_64, while the
        # package may be AArch64, ARM, MIPS, or RISC-V.  Dependencies remain
        # deliberately unresolved in this temporary root; the QEMU smoke test
        # below supplies their target DSOs from the SDK staging sysroot.
        "$host_apk" add --root "$packaged_root" --arch "$expected_arch" \
            --usermode --initdb --allow-untrusted --no-network --no-scripts \
            --force-broken-world "$package_abs"
        ;;
esac
assert_staged_payload "$packaged_root"
sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-elf.sh" \
    "$sdk_dir" "$expected_arch" "$endian" "$machine_regex" "$float_abi" \
    "$rust_target" "$rust_features" \
    "$packaged_root/usr/lib/cno/cno" "$packaged_root/usr/lib/cno/ext/oxc.so"
runtime_archive="$work/$output_name.runtime.tar.gz"
tar -czf "$runtime_archive" -C "$packaged_root" .
sh "$CNO_BUILDS_ROOT/scripts/smoke-openwrt.sh" \
    "$runtime_archive" "$sdk_dir" "$version" "$emulator"

cat > "$output_dir/$output_name.buildinfo" <<EOF
cno_version=$version
cno_source_commit=$source_commit
cno_source_sha256=$source_sha256
cno_bundle_sha256=$bundle_sha256
cno_oxc_rust_sha256=$oxc_sha256
openwrt_release=$release
openwrt_target=$target
openwrt_subtarget=$subtarget
openwrt_arch_packages=$actual_arch
expected_cpu_tune=$cpu_tune
cpu_tune_scope=c-runtime-and-oxc-c-binding-use-sdk-flags-rust-core-uses-rust_cpu
target_cflags=$target_cflags
target_ldflags=$target_ldflags
rust_target=$rust_target
rust_cpu=$rust_cpu
rust_features=$rust_features
float_abi=$float_abi
endian=$endian
wasm=$wasm
wamr_target=$wamr_target
openwrt_sdk=$sdk_name
openwrt_sdk_sha256=$sdk_sha256
package_format=$format
linkage=dynamic-openwrt-musl-system-libraries
oxc=usr/lib/cno/ext/oxc.so
EOF
printf '[openwrt-%s] %s/%s\n' "$format" "$output_dir" "$output_name"
