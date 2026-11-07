#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

requested=${1:-latest}
need_command curl
need_command jq

case $requested in
    latest) endpoint="https://api.github.com/repos/$CNO_REPOSITORY/releases/latest" ;;
    v*) validate_tag "$requested"; endpoint="https://api.github.com/repos/$CNO_REPOSITORY/releases/tags/$requested" ;;
    *) validate_version "$requested"; endpoint="https://api.github.com/repos/$CNO_REPOSITORY/releases/tags/v$requested" ;;
esac

temp_dir=$(make_temp_dir)
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM
set -- --fail --location --show-error --silent --retry 3 --retry-all-errors \
    -H 'Accept: application/vnd.github+json'
if [ -n "${GITHUB_TOKEN:-}" ]; then
    set -- "$@" -H "Authorization: Bearer $GITHUB_TOKEN"
fi
curl "$@" "$endpoint" -o "$temp_dir/release.json"

tag=$(jq -er 'select(.draft == false) | .tag_name' "$temp_dir/release.json") \
    || die "GitHub response is not a published release"
validate_tag "$tag"
version=${tag#v}
published_at=$(jq -er '.published_at // .created_at' "$temp_dir/release.json")
epoch=$(date -u -d "$published_at" +%s) || die "cannot parse release timestamp: $published_at"

printf 'tag=%s\n' "$tag"
printf 'version=%s\n' "$version"
printf 'published_at=%s\n' "$published_at"
printf 'source_date_epoch=%s\n' "$epoch"
printf 'source_url=%s/releases/tag/%s\n' "$CNO_HOMEPAGE" "$tag"

