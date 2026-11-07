#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

version=${1:?Usage: build-alpine.sh VERSION ALPINE_ARCH RELEASE_ARCHIVE OUTPUT_DIR [SOURCE_DATE_EPOCH]}
alpine_arch=${2:?Missing Alpine architecture}
archive=${3:?Missing cno release archive}
output_dir=${4:?Missing output directory}
source_date_epoch=${5:-${SOURCE_DATE_EPOCH:-0}}

validate_version "$version"
validate_arch "$alpine_arch"
case $source_date_epoch in ''|*[!0-9]*) die "invalid SOURCE_DATE_EPOCH: $source_date_epoch" ;; esac
[ -f "$archive" ] || die "release archive not found: $archive"
assert_safe_archive "$archive"
need_command abuild
need_command sha512sum
need_command openssl

host_arch=$(apk --print-arch)
[ "$host_arch" = "$alpine_arch" ] \
    || die "Alpine package must be built on its target architecture (host $host_arch, requested $alpine_arch)"

work=$(make_temp_dir "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
package_dir="$work/cno"
repo_dir="$work/repository"
build_user=$(id -un)
user_home=$(awk -F: -v user="$build_user" '$1 == user { print $6; found++ } END { if (found != 1) exit 1 }' /etc/passwd) \
    || die "cannot determine the home directory for $build_user"
case $user_home in
    /*) ;;
    *) die "invalid home directory for $build_user: $user_home" ;;
esac
abuild_config_dir="$user_home/.abuild"
mkdir -p "$package_dir" "$repo_dir" "$output_dir" "$abuild_config_dir"
source_name="cno-$version.tar.gz"
cp "$archive" "$package_dir/$source_name"
cp "$CNO_BUILDS_ROOT/LICENSE" "$package_dir/LICENSE"
sha512=$(sha512sum "$package_dir/$source_name" | awk '{print $1}')

sed \
    -e "s|@VERSION@|$version|g" \
    -e "s|@RELEASE@|$CNO_PACKAGE_RELEASE|g" \
    -e "s|@ARCH@|$alpine_arch|g" \
    -e "s|@HOMEPAGE@|$CNO_HOMEPAGE|g" \
    -e "s|@MAINTAINER_NAME@|$CNO_MAINTAINER_NAME|g" \
    -e "s|@MAINTAINER_EMAIL@|$CNO_MAINTAINER_EMAIL|g" \
    -e "s|@SHA512@|$sha512|g" \
    "$CNO_BUILDS_ROOT/packaging/alpine/APKBUILD.in" > "$package_dir/APKBUILD"

export PACKAGER="$CNO_MAINTAINER_NAME <$CNO_MAINTAINER_EMAIL>"
export SOURCE_DATE_EPOCH="$source_date_epoch"
if [ -n "${ABUILD_PRIVATE_KEY:-}" ]; then
    [ -f "$ABUILD_PRIVATE_KEY" ] || die "ABUILD_PRIVATE_KEY does not exist: $ABUILD_PRIVATE_KEY"
    private_key="$abuild_config_dir/$(basename -- "$ABUILD_PRIVATE_KEY")"
    cp "$ABUILD_PRIVATE_KEY" "$private_key"
    chmod 0600 "$private_key"
    public_key="$private_key.pub"
    if [ -f "$ABUILD_PRIVATE_KEY.pub" ]; then
        cp "$ABUILD_PRIVATE_KEY.pub" "$public_key"
    else
        openssl rsa -in "$ABUILD_PRIVATE_KEY" -pubout -out "$public_key"
    fi
else
    private_key="$abuild_config_dir/cno-$version-$alpine_arch.rsa"
    public_key="$private_key.pub"
    openssl genrsa -out "$private_key" 2048
    openssl rsa -in "$private_key" -pubout -out "$public_key"
    chmod 0600 "$private_key"
fi
printf 'PACKAGER_PRIVKEY=%s\n' "$private_key" > "$abuild_config_dir/abuild.conf"

(
    cd "$package_dir"
    REPODEST="$repo_dir" SRCDEST="$package_dir" abuild -F -r
)

set -- "$repo_dir"/*/"$alpine_arch"/"${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}.apk"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    die "abuild did not produce exactly one expected cno package"
fi
output="$output_dir/${CNO_PACKAGE_NAME}-${version}-r${CNO_PACKAGE_RELEASE}-${alpine_arch}.apk"
cp "$1" "$output"
mkdir -p "$output_dir/keys"
cp "$public_key" "$output_dir/keys/"
printf '[apk] %s\n' "$output"

