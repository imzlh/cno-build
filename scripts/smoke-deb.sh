#!/bin/sh
set -eu

package=${1:?Usage: smoke-deb.sh PACKAGE VERSION}
version=${2:?Missing expected version}
[ "$(id -u)" -eq 0 ] || { printf 'smoke-deb.sh must run as root\n' >&2; exit 1; }
[ -f "$package" ] || { printf 'package not found: %s\n' "$package" >&2; exit 1; }
package=$(realpath "$package")

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "$package"

[ "$(readlink /usr/bin/cno)" = ../lib/cno/cno ]
[ -x /usr/lib/cno/cno ]
[ -f /usr/lib/cno/ext/oxc.so ]
test "$(cno --version)" = "cno $version"
ldd /usr/lib/cno/cno > /tmp/cno-ldd-runtime.log
ldd /usr/lib/cno/ext/oxc.so > /tmp/cno-ldd-oxc.log
if grep -q 'not found' /tmp/cno-ldd-runtime.log /tmp/cno-ldd-oxc.log; then
    printf 'unresolved shared library in installed package\n' >&2
    exit 1
fi

smoke_dir=$(mktemp -d /tmp/cno-deb-smoke.XXXXXX)
trap 'rm -rf -- "$smoke_dir"' EXIT HUP INT TERM
printf '%s\n' 'const answer: number = 6 * 7; console.log(`CNO_PACKAGE_OK=${answer}`);' \
    > "$smoke_dir/smoke.ts"
DEBUG=transformer CTS_CACHE_DIR="$smoke_dir/cache" \
    cno run --disable-cache "$smoke_dir/smoke.ts" > "$smoke_dir/output.log" 2>&1
grep -Fx 'CNO_PACKAGE_OK=42' "$smoke_dir/output.log"
grep -Eiq 'oxc( bytes)?:' "$smoke_dir/output.log"

apt-get purge -y cno
[ ! -e /usr/bin/cno ]
[ ! -e /usr/lib/cno ]
printf '[smoke-deb] install, runtime, OXC and purge passed\n'

