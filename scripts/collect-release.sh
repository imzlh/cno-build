#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

input_dir=${1:?Usage: collect-release.sh INPUT_DIR OUTPUT_DIR VERSION}
output_dir=${2:?Missing output directory}
version=${3:?Missing version}
validate_version "$version"
[ -d "$input_dir" ] || die "artifact directory not found: $input_dir"

mkdir -p "$output_dir"
find "$input_dir" -type f \( \
    -name '*.deb' -o -name '*.ipk' -o -name '*.apk' -o \
    -name '*.rsa.pub' -o -name '*.buildinfo' \
\) -print | sort | while IFS= read -r source; do
    name=$(basename -- "$source")
    destination="$output_dir/$name"
    if [ -e "$destination" ]; then
        cmp -s "$source" "$destination" \
            || die "release asset basename collision: $name"
    else
        cp "$source" "$destination"
    fi
done

count_rows() {
    awk '!/^#/ && NF { count++ } END { print count + 0 }' "$1"
}
count_files() {
    find "$output_dir" -maxdepth 1 -type f -name "$1" -print | wc -l
}
require_file() {
    [ -f "$output_dir/$1" ] || die "missing release asset: $1"
}

expected_deb=$(count_rows "$CNO_BUILDS_ROOT/config/debian-targets.tsv")
expected_alpine=$(count_rows "$CNO_BUILDS_ROOT/config/alpine-targets.tsv")
expected_openwrt=$(count_rows "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv")
actual_deb=$(count_files "${CNO_PACKAGE_NAME}_${version}-${CNO_PACKAGE_RELEASE}_*.deb")
actual_ipk=$(count_files "${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-openwrt-*.ipk")
actual_apk=$(count_files '*.apk')
actual_buildinfo=$(count_files '*.buildinfo')
actual_keys=$(count_files '*.rsa.pub')
expected_apk=$((expected_alpine + expected_openwrt))
expected_buildinfo=$((expected_openwrt * 2))

[ "$actual_deb" -eq "$expected_deb" ] \
    || die "expected $expected_deb Debian packages, found $actual_deb"
[ "$actual_ipk" -eq "$expected_openwrt" ] \
    || die "expected $expected_openwrt OpenWrt IPK packages, found $actual_ipk"
[ "$actual_apk" -eq "$expected_apk" ] \
    || die "expected $expected_apk APK packages, found $actual_apk"
[ "$actual_buildinfo" -eq "$expected_buildinfo" ] \
    || die "expected $expected_buildinfo OpenWrt buildinfo files, found $actual_buildinfo"
[ "$actual_keys" -gt 0 ] && [ "$actual_keys" -le "$expected_alpine" ] \
    || die "expected between 1 and $expected_alpine Alpine public keys, found $actual_keys"

awk -F '\t' '!/^#/ && NF { print $2 }' "$CNO_BUILDS_ROOT/config/debian-targets.tsv" \
    | while IFS= read -r arch; do
        require_file "${CNO_PACKAGE_NAME}_${version}-${CNO_PACKAGE_RELEASE}_${arch}.deb"
    done
awk -F '\t' '!/^#/ && NF { print $2 }' "$CNO_BUILDS_ROOT/config/alpine-targets.tsv" \
    | while IFS= read -r arch; do
        require_file "${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-${arch}.apk"
    done
awk -F '\t' '!/^#/ && NF { print $1, $2 }' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv" \
    | while read -r target subtarget; do
        stable_count=$(count_files "${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-openwrt-*-${target}-${subtarget}.ipk")
        [ "$stable_count" -eq 1 ] \
            || die "expected one OpenWrt IPK for $target/$subtarget, found $stable_count"
        require_file "${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-openwrt-snapshots-${target}-${subtarget}.apk"
    done

cat > "$output_dir/RELEASE-INFO.txt" <<EOF
cno version: $version
package release: $CNO_PACKAGE_RELEASE
upstream: $CNO_HOMEPAGE/releases/tag/v$version
Debian baseline: Debian 12 / glibc $CNO_MIN_GLIBC
Ubuntu baseline: Ubuntu 24.04 / glibc $CNO_MIN_GLIBC or newer
Alpine baseline: Alpine $CNO_ALPINE_BASELINE / musl
OpenWrt IPK series: $CNO_OPENWRT_IPK_SERIES
OpenWrt APK channel: snapshots
EOF
(
    cd "$output_dir"
    find . -maxdepth 1 -type f \( \
        -name '*.deb' -o -name '*.ipk' -o -name '*.apk' -o \
        -name '*.rsa.pub' -o -name '*.buildinfo' -o -name 'RELEASE-INFO.txt' \
    \) -printf '%f\0' \
        | sort -z \
        | xargs -0 -r sha256sum > SHA256SUMS.txt
)
printf '[release] collected %s files in %s\n' "$(find "$output_dir" -maxdepth 1 -type f | wc -l)" "$output_dir"

