#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

requested=${1:-$CNO_OPENWRT_IPK_SERIES}
case $requested in
    *[!0-9.]*) die "invalid OpenWrt release or series: $requested" ;;
esac

if printf '%s\n' "$requested" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf '%s\n' "$requested"
    exit 0
fi
printf '%s\n' "$requested" | grep -Eq '^[0-9]+\.[0-9]+$' \
    || die "OpenWrt release must be X.Y or X.Y.Z: $requested"

need_command curl
listing=$(curl --fail --location --show-error --silent --retry 3 --retry-all-errors \
    https://downloads.openwrt.org/releases/)
resolved=$(
    printf '%s\n' "$listing" \
        | sed -n 's/.*href="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\/".*/\1/p' \
        | awk -F. -v series="$requested" '$1 "." $2 == series' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -n 1
)
[ -n "$resolved" ] || die "no released OpenWrt patch version found for $requested"
printf '%s\n' "$resolved"

