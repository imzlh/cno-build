#!/bin/sh
set -eu

package=${1:?Usage: smoke-alpine.sh PACKAGE PUBLIC_KEY VERSION}
public_key=${2:?Missing signing public key}
version=${3:?Missing expected version}
[ "$(id -u)" -eq 0 ] || { printf 'smoke-alpine.sh must run as root\n' >&2; exit 1; }
[ -f "$package" ] || { printf 'package not found: %s\n' "$package" >&2; exit 1; }
[ -f "$public_key" ] || { printf 'public key not found: %s\n' "$public_key" >&2; exit 1; }

apk add --no-cache ca-certificates pax-utils
cp "$public_key" "/etc/apk/keys/$(basename -- "$public_key")"
apk add "$package"

[ "$(readlink /usr/bin/cno)" = ../lib/cno/cno ]
[ -x /usr/lib/cno/cno ]
[ -f /usr/lib/cno/ext/oxc.so ]
test "$(cno --version)" = "cno $version"
scanelf -n /usr/lib/cno/cno /usr/lib/cno/ext/oxc.so >/dev/null

smoke_dir=$(mktemp -d /tmp/cno-alpine-smoke.XXXXXX)
trap 'rm -rf -- "$smoke_dir"' EXIT HUP INT TERM
printf '%s\n' 'const answer: number = 6 * 7; console.log(`CNO_PACKAGE_OK=${answer}`);' \
    > "$smoke_dir/smoke.ts"
DEBUG=transformer CTS_CACHE_DIR="$smoke_dir/cache" \
    cno run --disable-cache "$smoke_dir/smoke.ts" > "$smoke_dir/output.log" 2>&1
grep -Fx 'CNO_PACKAGE_OK=42' "$smoke_dir/output.log"
grep -Eiq 'oxc( bytes)?:' "$smoke_dir/output.log"

apk del cno
[ ! -e /usr/bin/cno ]
[ ! -e /usr/lib/cno ]
printf '[smoke-alpine] install, runtime, OXC and uninstall passed\n'

