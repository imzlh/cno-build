#!/bin/sh
set -eu

usage() {
    printf '%s\n' \
        'Usage: prepare-openwrt-source.sh SOURCE_DIR EXPECTED_COMMIT VERSION OUTPUT_DIR SOURCE_DATE_EPOCH' >&2
    exit 2
}

[ "$#" -eq 5 ] || usage
source_dir=$1
expected_commit=$2
version=$3
output_dir=$4
source_date_epoch=$5

case $expected_commit in *[!0-9a-fA-F]*|'') printf 'invalid commit: %s\n' "$expected_commit" >&2; exit 2 ;; esac
[ "${#expected_commit}" -eq 40 ] || { printf 'commit must contain 40 hex characters\n' >&2; exit 2; }
case $version in *[!0-9A-Za-z.+~-]*|'') printf 'invalid version: %s\n' "$version" >&2; exit 2 ;; esac
case $source_date_epoch in *[!0-9]*|'') printf 'invalid SOURCE_DATE_EPOCH: %s\n' "$source_date_epoch" >&2; exit 2 ;; esac
[ -d "$source_dir/.git" ] || { printf 'not a Git checkout: %s\n' "$source_dir" >&2; exit 1; }

for command_name in git pnpm curl sha256sum tar gzip; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'required command not found: %s\n' "$command_name" >&2
        exit 1
    }
done

source_dir=$(CDPATH= cd -- "$source_dir" && pwd)
actual_commit=$(git -C "$source_dir" rev-parse --verify HEAD)
[ "$actual_commit" = "$expected_commit" ] || {
    printf 'cno source commit mismatch: expected %s, got %s\n' "$expected_commit" "$actual_commit" >&2
    exit 1
}

# A leading '-' means a missing checkout, '+' means a submodule is not at the
# recorded commit, and 'U' means conflicts.  QuickJS deliberately declares its
# enormous test262 checkout with `update = none`; it is not a build input and
# Git therefore leaves only its empty gitlink directory during recursive
# checkout.  Every other recursive submodule must be present at the recorded
# commit.
submodule_state=$(git -C "$source_dir" submodule status --recursive)
invalid_submodules=$(printf '%s\n' "$submodule_state" | awk '
    /^[+U]/ { print; next }
    /^-/ && $2 != "circu.js/deps/quickjs/test262" { print }
')
if [ -n "$invalid_submodules" ]; then
    printf 'required cno submodules are missing or not at recorded commits:\n%s\n' \
        "$invalid_submodules" >&2
    exit 1
fi
if printf '%s\n' "$submodule_state" \
    | awk '$1 ~ /^-/ && $2 == "circu.js/deps/quickjs/test262" { found=1 } END { exit !found }'
then
    test262_update=$(git -C "$source_dir/circu.js/deps/quickjs" \
        config --file .gitmodules --get submodule.test262.update || true)
    [ "$test262_update" = none ] || {
        printf 'QuickJS test262 is missing but is not declared update=none\n' >&2
        exit 1
    }
fi

# The file list below is read from the index but tar reads bytes from the work
# tree.  Refuse tracked modifications in the root or any initialized submodule
# so the archive is exactly the release commit rather than merely named after
# it. Untracked dependency/install trees remain harmless because ls-files does
# not include them.
git -C "$source_dir" diff --quiet --ignore-submodules=none -- || {
    printf 'cno checkout has tracked worktree changes\n' >&2
    exit 1
}
git -C "$source_dir" diff --cached --quiet -- || {
    printf 'cno checkout has staged changes\n' >&2
    exit 1
}
if ! git -C "$source_dir" submodule foreach --quiet --recursive \
    'git diff --quiet --ignore-submodules=none -- && git diff --cached --quiet --'
then
    printf 'a cno submodule has tracked or staged changes\n' >&2
    exit 1
fi

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cno-openwrt-source.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
root_name="cno-$version"
payload="$work/$root_name"
mkdir -p "$payload" "$output_dir"

# Copy only Git-tracked content from the root repository and all initialized
# submodules.  This excludes build trees, node_modules, and every nested .git.
# Keep these as separate commands: POSIX `set -e` observes only the last command
# in a pipeline, which could otherwise hide a failed git or source-side tar.
tracked_files="$work/tracked-files.zlist"
tracked_tar="$work/tracked-source.tar"
git -C "$source_dir" ls-files -z --recurse-submodules > "$tracked_files"
[ -s "$tracked_files" ] || { printf 'cno tracked file list is empty\n' >&2; exit 1; }
tar -C "$source_dir" --null --no-recursion -T "$tracked_files" -cf "$tracked_tar"
tar -C "$payload" -xf "$tracked_tar"

# circu.js otherwise downloads llhttp during CMake configure.  Vendor one
# immutable upstream release into the source payload and verify it first.
llhttp_url=https://github.com/nodejs/llhttp/archive/refs/tags/release/v9.3.0.tar.gz
llhttp_sha256=1a2b45cb8dda7082b307d336607023aa65549d6f060da1d246b1313da22b685a
curl --fail --location --show-error --silent --retry 3 --retry-all-errors \
    "$llhttp_url" -o "$work/llhttp.tar.gz"
printf '%s  %s\n' "$llhttp_sha256" "$work/llhttp.tar.gz" | sha256sum -c -
mkdir -p "$payload/vendor/llhttp"
tar -xzf "$work/llhttp.tar.gz" --strip-components=1 -C "$payload/vendor/llhttp"

# Generate JavaScript on the host, but keep it separate from the source tar.
# The SDK will still build and execute its own target cjsc to create bytecode.
polyfill_commit=$(git -C "$source_dir/cno" rev-parse --verify HEAD)
printf '%s\n' "$polyfill_commit" | grep -Eq '^[0-9a-fA-F]{40}$' || {
    printf 'invalid cno submodule commit: %s\n' "$polyfill_commit" >&2
    exit 1
}
(
    cd "$source_dir"
    pnpm install --frozen-lockfile
    pnpm --dir cno install --frozen-lockfile
    pnpm --dir cts install --frozen-lockfile
    CNO_POLYFILL_REVISION="$polyfill_commit" \
        CNO_BUNDLE_OUTFILE="$work/cno-cli.min.js" pnpm run bundle:js:min
)

cat > "$payload/OPENWRT-SOURCE-INFO.txt" <<EOF
cno_commit=$actual_commit
cno_polyfill_commit=$polyfill_commit
cno_version=$version
source_date_epoch=$source_date_epoch
llhttp_url=$llhttp_url
llhttp_sha256=$llhttp_sha256
EOF

archive="$output_dir/cno-source-$version.tar.gz"
bundle="$output_dir/cno-cli-$version.min.js"
payload_tar="$work/cno-source.tar"
tar --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner \
    -C "$work" -cf "$payload_tar" "$root_name"
gzip -n -9 < "$payload_tar" > "$archive"
cp "$work/cno-cli.min.js" "$bundle"
sha256sum "$archive" > "$archive.sha256"
sha256sum "$bundle" > "$bundle.sha256"
printf '[openwrt-source] %s\n[openwrt-bundle] %s\n' "$archive" "$bundle"
