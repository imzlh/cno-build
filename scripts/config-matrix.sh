#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

matrix=${1:?Usage: config-matrix.sh debian|alpine|openwrt}
need_command jq

case $matrix in
    debian)
        jq -Rnc '[
            inputs
            | select(length > 0 and (startswith("#") | not))
            | split("\t")
            | select(length == 4)
            | {
                cno_target: .[0],
                deb_arch: .[1],
                platform: .[2],
                image: .[3]
              }
        ]' "$CNO_BUILDS_ROOT/config/debian-targets.tsv"
        ;;
    alpine)
        jq -Rnc '[
            inputs
            | select(length > 0 and (startswith("#") | not))
            | split("\t")
            | select(length == 3)
            | {
                cno_target: .[0],
                alpine_arch: .[1],
                platform: .[2]
              }
        ]' "$CNO_BUILDS_ROOT/config/alpine-targets.tsv"
        ;;
    openwrt)
        jq -Rnc '[
            inputs
            | select(length > 0 and (startswith("#") | not))
            | split("\t")
            | select(length == 4)
            | . as $row
            | ("ipk", "apk")
            | {
                format: .,
                target: $row[0],
                subtarget: $row[1],
                cno_target: $row[2],
                platform: $row[3]
              }
        ]' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv"
        ;;
    *) die "unknown matrix: $matrix" ;;
esac

