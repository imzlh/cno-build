#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

version=${1:?Usage: build-deb.sh VERSION DEB_ARCH RELEASE_ARCHIVE OUTPUT_DIR [SOURCE_DATE_EPOCH]}
deb_arch=${2:?Missing Debian architecture}
archive=${3:?Missing cno release archive}
output_dir=${4:?Missing output directory}
source_date_epoch=${5:-${SOURCE_DATE_EPOCH:-0}}

validate_version "$version"
validate_arch "$deb_arch"
case $source_date_epoch in ''|*[!0-9]*) die "invalid SOURCE_DATE_EPOCH: $source_date_epoch" ;; esac
[ -f "$archive" ] || die "release archive not found: $archive"
need_command dpkg-deb
need_command gzip
need_command md5sum

work=$(make_temp_dir "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
payload="$work/payload"
root="$work/root"
extract_release_archive "$archive" "$payload"

install -Dm755 "$payload/cno" "$root/usr/lib/cno/cno"
install -d "$root/usr/bin"
ln -s ../lib/cno/cno "$root/usr/bin/cno"
copy_optional_tree "$payload/lib" "$root/usr/lib/cno/lib"
copy_optional_tree "$payload/ext" "$root/usr/lib/cno/ext"
if [ -f "$payload/BUILD-INFO.txt" ]; then
    install -Dm644 "$payload/BUILD-INFO.txt" "$root/usr/share/doc/cno/BUILD-INFO.txt"
fi
install -Dm644 "$CNO_BUILDS_ROOT/packaging/debian/copyright.in" \
    "$root/usr/share/doc/cno/copyright"

mkdir -p "$root/usr/share/doc/cno"
changelog="$work/changelog"
cat > "$changelog" <<EOF
cno ($version-$CNO_PACKAGE_RELEASE) stable; urgency=medium

  * Package upstream cno $version.

 -- $CNO_MAINTAINER_NAME <$CNO_MAINTAINER_EMAIL>  $(date -u -d "@$source_date_epoch" -R)
EOF
gzip -n -9 < "$changelog" > "$root/usr/share/doc/cno/changelog.gz"

installed_size=$(du -sk "$root/usr" | awk '{print $1}')
mkdir -p "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<EOF
Package: $CNO_PACKAGE_NAME
Version: $version-$CNO_PACKAGE_RELEASE
Section: interpreters
Priority: optional
Architecture: $deb_arch
Maintainer: $CNO_MAINTAINER_NAME <$CNO_MAINTAINER_EMAIL>
Installed-Size: $installed_size
Depends: ca-certificates, libc6 (>= $CNO_MIN_GLIBC)
Homepage: $CNO_HOMEPAGE
Description: Deno-compatible TypeScript and JavaScript runtime
 cno runs TypeScript and JavaScript directly and provides Deno-style commands,
 Web APIs, and practical compatibility with Node.js packages.
EOF

find "$root" -type d -exec chmod 0755 {} +
find "$root" -type f ! -path "$root/usr/lib/cno/cno" -exec chmod 0644 {} +
chmod 0755 "$root/usr/lib/cno/cno"
normalize_tree_mtime "$root" "$source_date_epoch"
(
    cd "$root"
    find usr -type f -print0 | LC_ALL=C sort -z | xargs -0 -r md5sum > DEBIAN/md5sums
)
normalize_tree_mtime "$root" "$source_date_epoch"

mkdir -p "$output_dir"
output="$output_dir/${CNO_PACKAGE_NAME}_${version}-${CNO_PACKAGE_RELEASE}_${deb_arch}.deb"
SOURCE_DATE_EPOCH=$source_date_epoch dpkg-deb --root-owner-group \
    --threads-max=1 -Zxz -z9 --build "$root" "$output"
dpkg-deb --info "$output" >/dev/null
dpkg-deb --contents "$output" | grep -Eq '[[:space:]]\./usr/bin/cno([[:space:]]+->.*)?$' \
    || die "built package is missing /usr/bin/cno"
printf '[deb] %s\n' "$output"

