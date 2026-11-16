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
    default|aarch64-no-crypto|arm-soft-nofp|arm-hard-d16|arm-hard-neon) ;;
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
# Resolve qemu-user before entering the SDK make environment. OpenWrt prepends
# staging_dir/host/bin to PATH, where a same-named host wrapper may inject its
# x86_64 runas.so through LD_PRELOAD. Passing an absolute system executable
# keeps that host wrapper out of target cjsc/qjsc invocations.
emulator_path=$(command -v "$emulator")
case $emulator_path in
    /*) ;;
    *) die "qemu-user executable did not resolve to an absolute path: $emulator_path" ;;
esac
[ -x "$emulator_path" ] || die "qemu-user executable is not executable: $emulator_path"

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
if grep -Eq '^[[:space:]]*[+]?\$\(NINJA\)' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile"; then
    die 'OpenWrt package recipe bypasses the official CMake compile macro'
fi
cp "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" "$sdk_dir/package/cno/Makefile"
cp "$CNO_BUILDS_ROOT/packaging/openwrt/openwrt-project.cmake" \
    "$sdk_dir/package/cno/openwrt-project.cmake"
cp "$source_archive" "$sdk_dir/dl/$source_name"
cp "$bundle" "$sdk_dir/dl/$bundle_name"
cp "$oxc_archive" "$sdk_dir/dl/$oxc_name"

# The SDK is deliberately stripped down. Its feeds.conf.default supplies a
# pinned base feed for core recipes and a packages feed for community recipes.
# Install only the recipes in cno's active dependency closure. In particular,
# do not pass libcurl to scripts/feeds: the feed installer follows every
# conditional dependency in curl's recipe, including disabled LDAP, HTTP/3,
# and alternate TLS backends. Link curl itself after installing only the
# OpenSSL, zlib, and HTTP/2 recipes selected below.
if [ -x "$sdk_dir/scripts/feeds" ]; then
    (
        cd "$sdk_dir"
        ./scripts/feeds update base packages
        ./scripts/feeds install -p base zlib ca-certificates
        ./scripts/feeds install -p packages libsqlite3 libffi libexpat libnghttp2

        [ -f feeds/packages/net/curl/Makefile ] \
            || die 'packages feed does not contain the curl recipe'
        openssl_source=
        for candidate in \
            feeds/base/package/libs/openssl \
            feeds/base/libs/openssl
        do
            if [ -f "$candidate/Makefile" ]; then
                [ -z "$openssl_source" ] \
                    || die "base feed contains ambiguous OpenSSL recipes: $openssl_source and $candidate"
                openssl_source=$candidate
            fi
        done
        [ -n "$openssl_source" ] \
            || die 'base feed does not contain the OpenSSL recipe in a supported layout'
        sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
            feeds/packages/net/curl/Makefile \
            "$openssl_source/Makefile"
        mkdir -p package/feeds/base package/feeds/packages
        openssl_recipe=package/feeds/base/openssl
        if [ -e "$openssl_recipe" ] || [ -L "$openssl_recipe" ]; then
            [ -L "$openssl_recipe" ] \
                || die "refusing to replace non-symlink OpenSSL recipe: $openssl_recipe"
            rm -f -- "$openssl_recipe"
        fi
        ln -s "../../../$openssl_source" "$openssl_recipe"
        curl_recipe=package/feeds/packages/curl
        if [ -e "$curl_recipe" ] || [ -L "$curl_recipe" ]; then
            [ -L "$curl_recipe" ] \
                || die "refusing to replace non-symlink curl recipe: $curl_recipe"
            rm -f -- "$curl_recipe"
        fi
        ln -s ../../../feeds/packages/net/curl "$curl_recipe"
    )
fi

# QuickJS uses 64-bit __atomic intrinsics. MIPS32 and ARMv5 have no native
# instruction for them, so the compiled code calls into libatomic and the
# package must declare that runtime dependency.
libatomic_needed=0
case $rust_target in
    mips-*|mipsel-*|armv5te-*) libatomic_needed=1 ;;
esac
# The Cortex-A5 FPU implements VFPv4-D16 only, while the SDK toolchain defaults
# to a D32-capable vfpv4 selection. The Cortex-A9 D16 rows already receive a
# D16 FPU from the SDK toolchain configuration, so only the A5 row needs the
# explicit override; appending it after the default flags lets GCC pick it.
arm_fpu_d16=
if [ "$rust_features" = arm-hard-d16 ] && [ "$cpu_tune" = cortex-a5 ]; then
    arm_fpu_d16=vfpv4-d16
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
            CNO_QEMU="$emulator_path" \
            CNO_BIG_ENDIAN="$([ "$endian" = big ] && printf 1 || printf 0)" \
            CNO_TARGET_FLOAT_ABI="$float_abi" \
            CNO_WASM="$wasm" \
            CNO_WAMR_TARGET="$wamr_target" \
            CNO_NEED_LIBATOMIC="$libatomic_needed" \
            CNO_ARM_FPU_D16="$arm_fpu_d16" \
            "$@"
    )
}

sdk_defconfig() {
    phase=$1
    defconfig_log="$work/defconfig-$phase.log"
    if sdk_make defconfig > "$defconfig_log" 2>&1; then
        :
    else
        defconfig_status=$?
        cat "$defconfig_log" >&2
        die "SDK defconfig failed during $phase (exit $defconfig_status)"
    fi
    cat "$defconfig_log"
    # Kconfig can report a recursive dependency yet return success after
    # writing a partially normalized .config. The curl and OpenSSL recipe
    # normalization above removes their conditional package edges, so every
    # recursion is an unexpected metadata error and remains fatal.
    if grep -Fqi 'recursive dependency detected' "$defconfig_log"; then
        die "SDK defconfig reported a recursive Kconfig dependency during $phase"
    fi
}

# Published SDKs default ALL to y, which also enables ALL_NONSHARED and
# ALL_KMODS. Disable all three before the first defconfig; once expanded, their
# blanket PACKAGE_*=m selections are not reliably undone by clearing the parent
# switches later. A freshly extracted SDK may not contain .config yet.
touch "$sdk_dir/.config"
for config_name in ALL ALL_NONSHARED ALL_KMODS; do
    sed -i \
        "/^CONFIG_${config_name}=/d;/^# CONFIG_${config_name} is not set$/d" \
        "$sdk_dir/.config"
done
printf '%s\n' \
    '# CONFIG_ALL is not set' \
    '# CONFIG_ALL_NONSHARED is not set' \
    '# CONFIG_ALL_KMODS is not set' >> "$sdk_dir/.config"
sdk_defconfig initial
sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-disabled-options.sh" \
    "$sdk_dir/.config" ALL ALL_NONSHARED ALL_KMODS
sed -i '/^# CONFIG_PACKAGE_cno is not set$/d;/^CONFIG_PACKAGE_cno=/d' "$sdk_dir/.config"
printf '%s\n' 'CONFIG_PACKAGE_cno=m' >> "$sdk_dir/.config"
# defconfig consumes the explicit package selection and its dependencies.
sdk_defconfig cno
grep -q '^CONFIG_PACKAGE_cno=m$' "$sdk_dir/.config" \
    || die 'SDK defconfig did not retain CONFIG_PACKAGE_cno=m'

# cno uses OpenSSL directly. Select the same backend for libcurl explicitly so
# SDKs cannot retain HTTPS without a usable TLS implementation. Keep curl's
# default HTTP/2 and zlib support, seed every corresponding logical package,
# and explicitly disable options whose dependency recipes were deliberately
# left out of package metadata above.
for config_name in \
    PACKAGE_libcurl PACKAGE_libopenssl PACKAGE_libnghttp2 PACKAGE_zlib \
    LIBCURL_WOLFSSL LIBCURL_GNUTLS LIBCURL_OPENSSL \
    LIBCURL_MBEDTLS LIBCURL_NOSSL LIBCURL_ZLIB LIBCURL_ZSTD \
    LIBCURL_THREADED_RESOLVER LIBCURL_LDAP LIBCURL_LIBIDN2 \
    LIBCURL_SSH2 LIBCURL_HTTP2 LIBCURL_HTTP3 LIBCURL_KERBEROS_AUTH \
    PACKAGE_libopenssl-afalg PACKAGE_libopenssl-devcrypto \
    PACKAGE_libopenssl-padlock \
    OPENSSL_WITH_COMPRESSION OPENSSL_ENGINE_BUILTIN_AFALG \
    OPENSSL_ENGINE_BUILTIN_DEVCRYPTO OPENSSL_ENGINE_BUILTIN_PADLOCK
do
    sed -i \
        "/^CONFIG_${config_name}=/d;/^# CONFIG_${config_name} is not set$/d" \
        "$sdk_dir/.config"
done
printf '%s\n' \
    'CONFIG_PACKAGE_libcurl=m' \
    'CONFIG_PACKAGE_libopenssl=m' \
    'CONFIG_PACKAGE_libnghttp2=m' \
    'CONFIG_PACKAGE_zlib=m' \
    'CONFIG_LIBCURL_OPENSSL=y' \
    'CONFIG_LIBCURL_HTTP2=y' \
    'CONFIG_LIBCURL_ZLIB=y' \
    '# CONFIG_LIBCURL_WOLFSSL is not set' \
    '# CONFIG_LIBCURL_GNUTLS is not set' \
    '# CONFIG_LIBCURL_MBEDTLS is not set' \
    '# CONFIG_LIBCURL_NOSSL is not set' \
    '# CONFIG_LIBCURL_ZSTD is not set' \
    '# CONFIG_LIBCURL_THREADED_RESOLVER is not set' \
    '# CONFIG_LIBCURL_LDAP is not set' \
    '# CONFIG_LIBCURL_LIBIDN2 is not set' \
    '# CONFIG_LIBCURL_SSH2 is not set' \
    '# CONFIG_LIBCURL_HTTP3 is not set' \
    '# CONFIG_LIBCURL_KERBEROS_AUTH is not set' \
    '# CONFIG_PACKAGE_libopenssl-afalg is not set' \
    '# CONFIG_PACKAGE_libopenssl-devcrypto is not set' \
    '# CONFIG_PACKAGE_libopenssl-padlock is not set' \
    '# CONFIG_OPENSSL_WITH_COMPRESSION is not set' \
    '# CONFIG_OPENSSL_ENGINE_BUILTIN_AFALG is not set' \
    '# CONFIG_OPENSSL_ENGINE_BUILTIN_DEVCRYPTO is not set' \
    '# CONFIG_OPENSSL_ENGINE_BUILTIN_PADLOCK is not set' >> "$sdk_dir/.config"
sdk_defconfig curl-openssl
grep -q '^CONFIG_PACKAGE_cno=m$' "$sdk_dir/.config" \
    || die 'SDK defconfig dropped CONFIG_PACKAGE_cno=m while selecting curl TLS'
for config_name in LIBCURL_OPENSSL LIBCURL_HTTP2 LIBCURL_ZLIB; do
    grep -q "^CONFIG_${config_name}=y$" "$sdk_dir/.config" \
        || die "SDK defconfig did not retain CONFIG_${config_name}=y"
done
for package_name in libcurl libopenssl libnghttp2 zlib; do
    grep -Eq "^CONFIG_PACKAGE_${package_name}=[my]$" "$sdk_dir/.config" \
        || die "SDK defconfig did not select $package_name"
done
sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-disabled-options.sh" \
    "$sdk_dir/.config" \
    LIBCURL_WOLFSSL LIBCURL_GNUTLS LIBCURL_MBEDTLS LIBCURL_NOSSL \
    LIBCURL_ZSTD LIBCURL_THREADED_RESOLVER LIBCURL_LDAP \
    LIBCURL_LIBIDN2 LIBCURL_SSH2 LIBCURL_HTTP3 LIBCURL_KERBEROS_AUTH \
    PACKAGE_libopenssl-afalg PACKAGE_libopenssl-devcrypto \
    PACKAGE_libopenssl-padlock \
    OPENSSL_WITH_COMPRESSION OPENSSL_ENGINE_BUILTIN_AFALG \
    OPENSSL_ENGINE_BUILTIN_DEVCRYPTO OPENSSL_ENGINE_BUILTIN_PADLOCK

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
if ! sdk_make -j"$openwrt_jobs" package/cno/compile V=sc; then
    # Parallel dependency output can continue after package/cno has already
    # failed and bury the useful compiler line. Reuse the populated SDK and
    # retry serially so the fatal command and its diagnostic remain adjacent.
    printf '%s\n' '[openwrt-sdk] parallel build failed; retrying package/cno serially' >&2
    sdk_make -j1 package/cno/compile V=sc
fi

package=$(find "$sdk_dir/bin/packages" -type f \( -name "cno[-_]*.$format" -o -name "cno.$format" \) \
    ! -name '*-dbg*' -print \
    | sort)
[ -n "$package" ] || die "the SDK did not produce a cno .$format package"
[ "$(printf '%s\n' "$package" | wc -l)" -eq 1 ] \
    || die "the SDK produced more than one cno .$format package"
runtime=$(find "$sdk_dir/build_dir" -type f -path '*/cno/usr/lib/cno/cno' -print \
    | sort | head -n 1)
[ -n "$runtime" ] || die 'cannot find the OpenWrt-staged cno runtime'
staged_root=${runtime%/usr/lib/cno/cno}
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
    "$rust_target" "$rust_features" "$runtime" "$oxc" \
    "$arm_fpu_d16" staged

mkdir -p "$output_dir"
output_name="${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-openwrt-${release}-${expected_arch}-${target}-${subtarget}.${format}"
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
            || die 'cannot find the SDK host apk tool for ADB package extraction'
        # Snapshot SDKs sign their packages with a build key generated in the
        # SDK root (key-build.pub on the classic layout, public-key.pem for
        # apk-tools v3 SDKs), which no installed keyring trusts. Keep
        # signature verification on by trusting the SDK's own public build
        # key, and fall back to the documented untrusted install only when
        # no public key file exists. OpenWrt snapshot packages use apk-tools
        # v3's ADB format, so they cannot be unpacked as Alpine-style gzip
        # tarballs. Extracting directly also avoids asking the solver to
        # resolve target dependencies in this deliberately empty root. The
        # QEMU smoke test below supplies their target DSOs from the SDK
        # staging sysroot.
        keys_dir="$work/apk-keys"
        mkdir -p "$keys_dir"
        untrusted=
        sdk_pub_key=
        for candidate in key-build.pub public-key.pem; do
            if [ -f "$sdk_dir/$candidate" ]; then
                sdk_pub_key=$candidate
                break
            fi
        done
        if [ -n "$sdk_pub_key" ]; then
            cp "$sdk_dir/$sdk_pub_key" "$keys_dir/$sdk_pub_key"
        else
            untrusted=--allow-untrusted
            printf '%s\n' '[openwrt-apk] SDK ships no public build key; extracting untrusted' >&2
        fi
        # shellcheck disable=SC2086
        "$host_apk" --keys-dir "$keys_dir" $untrusted \
            extract --destination "$packaged_root" --no-chown "$package_abs"
        ;;
esac
assert_staged_payload "$packaged_root"
sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-elf.sh" \
    "$sdk_dir" "$expected_arch" "$endian" "$machine_regex" "$float_abi" \
    "$rust_target" "$rust_features" \
    "$packaged_root/usr/lib/cno/cno" "$packaged_root/usr/lib/cno/ext/oxc.so" \
    "$arm_fpu_d16" packaged
runtime_archive="$work/$output_name.runtime.tar.gz"
tar -czf "$runtime_archive" -C "$packaged_root" .
sh "$CNO_BUILDS_ROOT/scripts/smoke-openwrt.sh" \
    "$runtime_archive" "$sdk_dir" "$version" "$emulator_path"

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
