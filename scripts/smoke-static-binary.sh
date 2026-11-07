#!/bin/sh
set -eu

binary=${1:?Usage: smoke-static-binary.sh BINARY VERSION}
version=${2:?Missing expected version}
[ -f "$binary" ] || { printf 'binary not found: %s\n' "$binary" >&2; exit 1; }
[ -x "$binary" ] || { printf 'binary is not executable: %s\n' "$binary" >&2; exit 1; }

smoke_dir=$(mktemp -d /tmp/cno-static-binary.XXXXXX)
trap 'rm -rf -- "$smoke_dir"' EXIT HUP INT TERM
test "$("$binary" --version)" = "cno $version"
printf '%s\n' 'const answer: number = 6 * 7; console.log(`CNO_OPENWRT_OK=${answer}`);' \
    > "$smoke_dir/smoke.ts"
CTS_CACHE_DIR="$smoke_dir/cache" "$binary" run --no-oxc --disable-cache \
    "$smoke_dir/smoke.ts" | grep -Fx 'CNO_OPENWRT_OK=42'
printf '[smoke-openwrt] staged runtime passed\n'

