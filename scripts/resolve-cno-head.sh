#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

need_command curl
need_command jq

api_base=${GITHUB_API_URL:-https://api.github.com}
api_base=${api_base%/}
case $api_base in
    http://*|https://*) ;;
    *) die "invalid GitHub API URL: $api_base" ;;
esac

work=$(make_temp_dir)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

github_get() {
    endpoint=$1
    output=$2
    case $endpoint in /*) ;; *) die "invalid GitHub API endpoint: $endpoint" ;; esac
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl --fail --location --show-error --silent --retry 3 --retry-all-errors \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            "$api_base$endpoint" -o "$output"
    else
        curl --fail --location --show-error --silent --retry 3 --retry-all-errors \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$api_base$endpoint" -o "$output"
    fi
}

is_commit_id() {
    printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{40}$'
}

uri_encode() {
    jq -nr --arg value "$1" '$value | @uri'
}

# Resolve the repository's configured default branch first.  Do not assume
# that it is named main or master, and never leave a moving ref in the output.
github_get "/repos/$CNO_REPOSITORY" "$work/repository.json"
default_branch=$(jq -er \
    '.default_branch | select(type == "string" and length > 0)' \
    "$work/repository.json") || die 'GitHub repository response has no default branch'
branch_ref=$(uri_encode "$default_branch")

github_get "/repos/$CNO_REPOSITORY/commits/$branch_ref" "$work/commit.json"
commit=$(jq -er '.sha | select(type == "string")' "$work/commit.json") \
    || die 'GitHub commit response has no commit SHA'
is_commit_id "$commit" || die "default branch resolved to an invalid commit: $commit"
commit=$(printf '%s' "$commit" | tr 'A-F' 'a-f')
commit_date=$(jq -er \
    '(.commit.committer.date // .commit.author.date) | select(type == "string")' \
    "$work/commit.json") || die 'GitHub commit response has no commit date'
source_date_epoch=$(jq -enr --arg value "$commit_date" \
    '$value | fromdateiso8601') || die "cannot parse commit timestamp: $commit_date"
case $source_date_epoch in ''|*[!0-9]*) die "invalid commit epoch: $source_date_epoch" ;; esac

commit_ref=$(uri_encode "$commit")
github_get "/repos/$CNO_REPOSITORY/contents/package.json?ref=$commit_ref" \
    "$work/package-content.json"
package_version=$(jq -er '
    select(.encoding == "base64")
    | .content
    | select(type == "string")
    | gsub("\\s"; "")
    | @base64d
    | fromjson
    | .version
    | select(type == "string")
' "$work/package-content.json") || die 'cannot read version from package.json at HEAD'
validate_version "$package_version"
base_version=$(printf '%s\n' "$package_version" \
    | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
[ -n "$base_version" ] || die "package.json has no base semantic version: $package_version"

resolve_tag_object() {
    stable_tag=$1
    object_type=$2
    object_sha=$3
    depth=0
    is_commit_id "$object_sha" \
        || die "tag $stable_tag points to an invalid object ID: $object_sha"
    object_sha=$(printf '%s' "$object_sha" | tr 'A-F' 'a-f')
    while [ "$object_type" = tag ]; do
        depth=$((depth + 1))
        [ "$depth" -le 4 ] || die "tag indirection is too deep: $stable_tag"
        github_get "/repos/$CNO_REPOSITORY/git/tags/$object_sha" \
            "$work/tag-$stable_tag-$depth.json"
        object_type=$(jq -er '.object.type | select(type == "string")' \
            "$work/tag-$stable_tag-$depth.json") \
            || die "annotated tag has no object type: $stable_tag"
        object_sha=$(jq -er '.object.sha | select(type == "string")' \
            "$work/tag-$stable_tag-$depth.json") \
            || die "annotated tag has no object ID: $stable_tag"
        is_commit_id "$object_sha" \
            || die "tag $stable_tag points to an invalid object ID: $object_sha"
        object_sha=$(printf '%s' "$object_sha" | tr 'A-F' 'a-f')
    done
    [ "$object_type" = commit ] \
        || die "stable tag does not resolve to a commit: $stable_tag ($object_type)"
    printf '%s\n' "$object_sha"
}

# A stable tag may be lightweight or annotated.  Enumerate every strict
# vMAJOR.MINOR.PATCH ref and peel annotated tags rather than trusting a release
# object or target_commitish, either of which may still name a branch.
: > "$work/head-tags"
page=1
while :; do
    refs_file="$work/refs-$page.json"
    github_get "/repos/$CNO_REPOSITORY/git/matching-refs/tags/v?per_page=100&page=$page" \
        "$refs_file"
    ref_count=$(jq -er 'if type == "array" then length else error("not an array") end' \
        "$refs_file") || die 'GitHub matching-refs response is not an array'
    jq -e 'all(.[];
        (.ref | type == "string") and
        (.object | type == "object") and
        (.object.type | type == "string") and
        (.object.sha | type == "string"))' "$refs_file" >/dev/null \
        || die 'GitHub matching-refs response contains invalid tag objects'
    jq -r '.[]
        | select(.ref | type == "string")
        | select(.ref | test("^refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | [.ref, .object.type, .object.sha]
        | @tsv' "$refs_file" > "$work/ref-candidates-$page"
    while IFS="$(printf '\t')" read -r ref object_type object_sha; do
        [ -n "$ref" ] || continue
        stable_tag=${ref#refs/tags/}
        validate_tag "$stable_tag"
        resolved_commit=$(resolve_tag_object "$stable_tag" "$object_type" "$object_sha")
        if [ "$resolved_commit" = "$commit" ]; then
            printf '%s\n' "$stable_tag" >> "$work/head-tags"
        fi
    done < "$work/ref-candidates-$page"
    [ "$ref_count" -eq 100 ] || break
    page=$((page + 1))
done

tag_count=$(wc -l < "$work/head-tags" | tr -d '[:space:]')
case $tag_count in
    0)
        tag=
        # apk-tools accepts numeric dotted components but rejects an arbitrary
        # hexadecimal suffix in pkgver. Encode the first 14 hex digits as a
        # decimal integer (at most 17 digits, within apk-tools' numeric limit).
        # The timestamp plus 56 commit bits makes this stable and unambiguous
        # enough for package identity; the Release marker retains the full SHA.
        commit_prefix=$(printf '%.14s' "$commit")
        commit_number=$(printf '%d' "0x$commit_prefix")
        case $commit_number in ''|*[!0-9]*) die "cannot encode commit as a package version: $commit" ;; esac
        version="$base_version.$source_date_epoch.$commit_number"
        prerelease=true
        ;;
    1)
        tag=$(sed -n '1p' "$work/head-tags")
        tag_version=${tag#v}
        [ "$tag_version" = "$base_version" ] || die \
            "HEAD tag $tag disagrees with package.json base version $base_version"
        version=$tag_version
        prerelease=false
        ;;
    *)
        head_tags=$(paste -sd, "$work/head-tags")
        die "HEAD has more than one stable version tag: $head_tags"
        ;;
esac
validate_version "$version"

printf 'tag=%s\n' "$tag"
printf 'version=%s\n' "$version"
printf 'base_version=%s\n' "$base_version"
printf 'commit=%s\n' "$commit"
printf 'commit_date=%s\n' "$commit_date"
printf 'source_date_epoch=%s\n' "$source_date_epoch"
printf 'prerelease=%s\n' "$prerelease"
printf 'source_url=%s/commit/%s\n' "$CNO_HOMEPAGE" "$commit"
