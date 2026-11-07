#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

format=${1:?Usage: build-openwrt.sh ipk|apk RELEASE TARGET SUBTARGET CNO_TARGET VERSION ARCHIVE OUTPUT_DIR}
release=${2:?Missing OpenWrt release or snapshots}
target=${3:?Missing OpenWrt target}
subtarget=${4:?Missing OpenWrt subtarget}
cno_target=${5:?Missing cno release target}
version=${6:?Missing cno version}
archive=${7:?Missing cno release archive}
output_dir=${8:?Missing output directory}

case $format in ipk|apk) ;; *) die "OpenWrt format must be ipk or apk: $format" ;; esac
case $release in snapshots) ;; *[!0-9.]*) die "invalid OpenWrt release: $release" ;; esac
validate_arch "$target"
validate_arch "$subtarget"
validate_arch "$cno_target"
validate_version "$version"
[ -f "$archive" ] || die "release archive not found: $archive"
assert_safe_archive "$archive"
need_command curl
need_command sha256sum
need_command tar
need_command make

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
expected=$(
    awk -v wanted="$sdk_name" '
        { name=$2; sub(/^\*/, "", name) }
        name == wanted { print $1; found++ }
        END { if (found != 1) exit 1 }
    ' \
        "$work/sha256sums"
) || die "sha256sums does not contain exactly one entry for $sdk_name"
# shellcheck disable=SC2086
curl $curl_args "$sdk_base/$sdk_name" -o "$work/$sdk_name"
actual=$(sha256sum "$work/$sdk_name" | awk '{print $1}')
[ "$actual" = "$expected" ] || die "OpenWrt SDK checksum mismatch: $sdk_name"

case $sdk_name in
    *.tar.zst) need_command zstd; tar --zstd -xf "$work/$sdk_name" -C "$work" ;;
    *.tar.xz) tar -xJf "$work/$sdk_name" -C "$work" ;;
    *) die "unsupported SDK archive: $sdk_name" ;;
esac
sdk_dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'openwrt-sdk-*' -print | head -n 1)
if [ -z "$sdk_dir" ] || [ ! -d "$sdk_dir" ]; then
    die "cannot locate extracted OpenWrt SDK"
fi

mkdir -p "$sdk_dir/package/cno" "$sdk_dir/dl"
cp "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" "$sdk_dir/package/cno/Makefile"
asset="cno-linux-musl-$cno_target.tar.gz"
cp "$archive" "$sdk_dir/dl/$asset"
source_sha256=$(sha256sum "$archive" | awk '{print $1}')

make_args="CNO_VERSION=$version CNO_PACKAGE_RELEASE=$CNO_PACKAGE_RELEASE CNO_RELEASE_TARGET=$cno_target CNO_SOURCE_SHA256=$source_sha256"
(
    cd "$sdk_dir"
    # These are controlled scalar values validated above; make needs them as
    # individual command-line variable assignments.
    # shellcheck disable=SC2086
    make $make_args defconfig
    # shellcheck disable=SC2086
    make $make_args package/cno/compile V=s
)

package=$(find "$sdk_dir/bin/packages" -type f -name "cno[-_]*.$format" ! -name '*-dbg*' -print | sort | head -n 1)
[ -n "$package" ] || die "the SDK did not produce a cno .$format package"
mkdir -p "$output_dir"
output_name="${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-openwrt-${release}-${target}-${subtarget}.${format}"
cp "$package" "$output_dir/$output_name"

# Exercise the binary after OpenWrt's package staging and strip passes. The
# sidecar is a CI-only input and is excluded by collect-release.sh.
staged_binary=$(find "$sdk_dir/build_dir" -type f -path '*/ipkg-*/cno/usr/bin/cno' -print | sort | head -n 1)
if [ -z "$staged_binary" ]; then
    staged_binary=$(find "$sdk_dir/build_dir" -type f -path '*/.pkgdir/cno/usr/bin/cno' -print | sort | head -n 1)
fi
[ -n "$staged_binary" ] || die "cannot find the OpenWrt-staged cno binary"
cp "$staged_binary" "$output_dir/$output_name.runtime"
chmod 0755 "$output_dir/$output_name.runtime"

cat > "$output_dir/$output_name.buildinfo" <<EOF
cno_version=$version
cno_release_target=$cno_target
cno_source_sha256=$source_sha256
openwrt_release=$release
openwrt_target=$target
openwrt_subtarget=$subtarget
openwrt_sdk=$sdk_name
openwrt_sdk_sha256=$actual
package_format=$format
EOF
printf '[openwrt-%s] %s/%s\n' "$format" "$output_dir" "$output_name"

