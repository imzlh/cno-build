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
            | select(length == 14)
            | . as $row
            | ($row[0] | split("+"))[]
            | {
                format: .,
                target: $row[1],
                subtarget: $row[2],
                expected_arch: $row[3],
                cpu_tune: $row[4],
                endian: $row[5],
                float_abi: $row[6],
                rust_target: $row[7],
                rust_cpu: $row[8],
                rust_features: $row[9],
                emulator: $row[10],
                wamr_target: $row[11],
                wasm: $row[12],
                machine_regex: $row[13]
              }
        ]' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv"
        ;;
    *) die "unknown matrix: $matrix" ;;
esac

