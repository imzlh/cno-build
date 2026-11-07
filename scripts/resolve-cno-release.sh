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

# GitHub releases may report a branch in target_commitish. Resolve the tag ref
# itself to a peeled commit so every source checkout is immutable.
tag_endpoint="https://api.github.com/repos/$CNO_REPOSITORY/git/ref/tags/$tag"
curl "$@" "$tag_endpoint" -o "$temp_dir/tag.json"
commit=$(jq -er '.object.sha' "$temp_dir/tag.json")
object_type=$(jq -er '.object.type' "$temp_dir/tag.json")
peel_count=0
while [ "$object_type" = tag ]; do
    peel_count=$((peel_count + 1))
    [ "$peel_count" -le 4 ] || die "release tag indirection is too deep: $tag"
    curl "$@" "https://api.github.com/repos/$CNO_REPOSITORY/git/tags/$commit" \
        -o "$temp_dir/annotated-tag-$peel_count.json"
    object_type=$(jq -er '.object.type' "$temp_dir/annotated-tag-$peel_count.json")
    commit=$(jq -er '.object.sha' "$temp_dir/annotated-tag-$peel_count.json")
done
[ "$object_type" = commit ] || die "release tag does not resolve to a commit: $tag"
printf '%s\n' "$commit" | grep -Eq '^[0-9a-fA-F]{40}$' \
    || die "release tag resolved to an invalid commit: $commit"

printf 'tag=%s\n' "$tag"
printf 'version=%s\n' "$version"
printf 'commit=%s\n' "$commit"
printf 'published_at=%s\n' "$published_at"
printf 'source_date_epoch=%s\n' "$epoch"
printf 'source_url=%s/releases/tag/%s\n' "$CNO_HOMEPAGE" "$tag"

