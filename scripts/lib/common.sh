#!/bin/sh

set -eu

if [ -z "${CNO_BUILDS_ROOT:-}" ]; then
    CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fi

# shellcheck source=../../config/project.env
. "$CNO_BUILDS_ROOT/config/project.env"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_version() {
    case ${1:-} in
        ''|*[!0-9A-Za-z.+~-]*) die "invalid package version: ${1:-<empty>}" ;;
    esac
    printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.+~-]+)?$' \
        || die "version must begin with MAJOR.MINOR.PATCH: $1"
}

validate_tag() {
    case ${1:-} in
        v*) validate_version "${1#v}" ;;
        *) die "release tag must start with v: ${1:-<empty>}" ;;
    esac
}

validate_arch() {
    case ${1:-} in
        ''|*[!A-Za-z0-9_.+-]*) die "invalid architecture: ${1:-<empty>}" ;;
    esac
}

validate_asset_name() {
    case ${1:-} in
        ''|*/*|.*|*[!A-Za-z0-9_.+-]*) die "invalid release asset name: ${1:-<empty>}" ;;
    esac
}

make_temp_dir() {
    parent=${1:-${TMPDIR:-/tmp}}
    mkdir -p "$parent"
    mktemp -d "$parent/cno-builds.XXXXXX"
}

normalize_tree_mtime() {
    tree=$1
    epoch=$2
    find "$tree" -exec touch -h -d "@$epoch" {} +
}

assert_safe_archive() {
    archive=$1
    need_command tar
    tar -tvzf "$archive" | while IFS= read -r line; do
        type=$(printf '%s' "$line" | cut -c 1)
        case $type in
            -|d) ;;
            *) die "unsupported archive entry type in $archive: $line" ;;
        esac
    done
    tar -tzf "$archive" | while IFS= read -r entry; do
        clean=${entry#./}
        case $clean in
            ''|.) continue ;;
            /*|../*|*/../*|*/..) die "unsafe path in $archive: $entry" ;;
        esac
    done
}

extract_release_archive() {
    archive=$1
    destination=$2
    assert_safe_archive "$archive"
    mkdir -p "$destination"
    tar -xzf "$archive" -C "$destination" --no-same-owner --no-same-permissions
    [ -f "$destination/cno" ] || die "$archive does not contain cno"
    [ -x "$destination/cno" ] || chmod 0755 "$destination/cno"
}

copy_optional_tree() {
    source=$1
    destination=$2
    [ -d "$source" ] || return 0
    mkdir -p "$destination"
    cp -a "$source/." "$destination/"
}

