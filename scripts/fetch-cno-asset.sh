#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

tag=${1:?Usage: fetch-cno-asset.sh TAG ASSET OUTPUT}
asset=${2:?Missing release asset name}
output=${3:?Missing output path}

validate_tag "$tag"
validate_asset_name "$asset"
need_command curl
need_command sha256sum

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir"
temp_dir=$(make_temp_dir "$output_dir")
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

base_url="https://github.com/$CNO_REPOSITORY/releases/download/$tag"
curl_args='--fail --location --show-error --silent --retry 3 --retry-all-errors'
# Word splitting is intentional: curl_args contains fixed, argument-free flags.
# shellcheck disable=SC2086
curl $curl_args "$base_url/SHA256SUMS.txt" -o "$temp_dir/SHA256SUMS.txt"
# shellcheck disable=SC2086
curl $curl_args "$base_url/$asset" -o "$temp_dir/$asset"

expected=$(
    awk -v wanted="$asset" '
        {
            name=$2
            sub(/^\*/, "", name)
            sub(/^\.\//, "", name)
            if (name == wanted) {
                print $1
                found++
            }
        }
        END { if (found != 1) exit 1 }
    ' "$temp_dir/SHA256SUMS.txt"
) || die "SHA256SUMS.txt does not contain exactly one checksum for $asset"

actual=$(sha256sum "$temp_dir/$asset" | awk '{print $1}')
[ "$actual" = "$expected" ] || die "checksum mismatch for $asset: expected $expected, got $actual"

mv "$temp_dir/$asset" "$output"
printf '%s  %s\n' "$actual" "$asset" > "$output.sha256"
printf '[fetch] %s %s (%s)\n' "$tag" "$asset" "$actual"

