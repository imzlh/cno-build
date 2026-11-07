#!/bin/sh
set -eu

archive=${1:?Usage: smoke-static-archive.sh ARCHIVE VERSION}
version=${2:?Missing expected version}
[ -f "$archive" ] || { printf 'archive not found: %s\n' "$archive" >&2; exit 1; }

smoke_dir=$(mktemp -d /tmp/cno-static-smoke.XXXXXX)
trap 'rm -rf -- "$smoke_dir"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$smoke_dir"
test "$("$smoke_dir/cno" --version)" = "cno $version"
printf '%s\n' 'const answer: number = 6 * 7; console.log(`CNO_STATIC_OK=${answer}`);' \
    > "$smoke_dir/smoke.ts"
CTS_CACHE_DIR="$smoke_dir/cache" "$smoke_dir/cno" run --no-oxc --disable-cache \
    "$smoke_dir/smoke.ts" | grep -Fx 'CNO_STATIC_OK=42'
printf '[smoke-static] runtime passed\n'

