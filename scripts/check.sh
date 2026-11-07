#!/bin/sh
set -eu

CNO_BUILDS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CNO_BUILDS_ROOT
# shellcheck source=lib/common.sh
. "$CNO_BUILDS_ROOT/scripts/lib/common.sh"

need_command shellcheck
need_command dpkg-deb
need_command jq
need_command rg
need_command rustc
need_command tar

find "$CNO_BUILDS_ROOT/scripts" -type f -name '*.sh' -print | sort \
    | while IFS= read -r script; do sh -n "$script"; done
# common.sh is a sourced library and intentionally has no shebang invocation.
shellcheck -x -s sh \
    -e SC1007 -e SC2015 -e SC2016 -e SC2119 \
    -P "$CNO_BUILDS_ROOT" \
    -P "$CNO_BUILDS_ROOT/scripts" \
    -P "$CNO_BUILDS_ROOT/scripts/lib" \
    "$CNO_BUILDS_ROOT"/scripts/*.sh "$CNO_BUILDS_ROOT"/scripts/lib/*.sh

for table_spec in \
    "$CNO_BUILDS_ROOT/config/debian-targets.tsv:4" \
    "$CNO_BUILDS_ROOT/config/alpine-targets.tsv:3" \
    "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv:14"
do
    table=${table_spec%:*}
    expected_columns=${table_spec##*:}
    awk -F '\t' '
        /^#/ || NF == 0 { next }
        NF != expected { print FILENAME ":" FNR ": expected " expected " TSV columns, got " NF > "/dev/stderr"; bad=1 }
        { for (i=1; i<=NF; i++) if ($i == "") { print FILENAME ":" FNR ": empty field" > "/dev/stderr"; bad=1 } }
        END { exit bad }
    ' expected="$expected_columns" "$table"
done

awk -F '\t' '
    /^#/ || NF == 0 { next }
    $1 != "ipk" && $1 != "apk" && $1 != "ipk+apk" {
        print FILENAME ":" FNR ": invalid OpenWrt formats field: " $1 > "/dev/stderr"
        bad=1
    }
    ($2 SUBSEP $3) in target_seen {
        print FILENAME ":" FNR ": duplicate OpenWrt target/subtarget: " $2 "/" $3 > "/dev/stderr"
        bad=1
    }
    { target_seen[$2 SUBSEP $3]=1 }
    END { exit bad }
' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv"

debian_matrix=$(sh "$CNO_BUILDS_ROOT/scripts/config-matrix.sh" debian)
alpine_matrix=$(sh "$CNO_BUILDS_ROOT/scripts/config-matrix.sh" alpine)
openwrt_matrix=$(sh "$CNO_BUILDS_ROOT/scripts/config-matrix.sh" openwrt)
[ "$(printf '%s' "$debian_matrix" | jq 'length')" -gt 0 ]
[ "$(printf '%s' "$alpine_matrix" | jq 'length')" -gt 0 ]
[ "$(printf '%s' "$openwrt_matrix" | jq 'length')" -gt 0 ]
[ "$(printf '%s' "$openwrt_matrix" | jq 'length')" -eq \
    "$(awk -F '\t' '!/^#/ && NF { n += split($1, formats, "+") } END { print n + 0 }' \
        "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv")" ]
printf '%s' "$debian_matrix" | jq -e 'all(.[]; has("deb_arch") and has("image"))' >/dev/null
printf '%s' "$alpine_matrix" | jq -e 'all(.[]; has("alpine_arch") and has("platform"))' >/dev/null
printf '%s' "$openwrt_matrix" | jq -e \
    'all(.[];
        (.format == "ipk" or .format == "apk") and
        has("subtarget") and has("expected_arch") and has("cpu_tune") and
        has("rust_target") and has("rust_cpu") and has("emulator") and
        (.rust_features == "default" or
         .rust_features == "arm-soft-nofp" or
         .rust_features == "arm-hard-d16" or
         .rust_features == "arm-hard-neon") and
        (.endian == "little" or .endian == "big") and
        (.float_abi == "hard" or .float_abi == "soft" or .float_abi == "none") and
        (.wasm == "ON" or .wasm == "OFF"))' >/dev/null
printf '%s' "$openwrt_matrix" | jq -e \
    'group_by([.format, .target, .subtarget]) | all(.[]; length == 1)' >/dev/null
printf '%s' "$openwrt_matrix" | jq -r '.[] | "\(.rust_target)\t\(.rust_cpu)"' \
    | sort -u \
    | while IFS="$(printf '\t')" read -r rust_target rust_cpu; do
        rustc --target "$rust_target" --print target-cpus 2>/dev/null \
            | awk -v wanted="$rust_cpu" '$1 == wanted { found=1 } END { exit !found }' \
            || die "Rust CPU $rust_cpu is unavailable for $rust_target"
    done

# These profiles are deliberately constrained names, not arbitrary compiler
# flags supplied by the matrix. Keep the profile/target ABI combinations
# explicit so an edit cannot accidentally re-enable ARM FPU instructions.
printf '%s' "$openwrt_matrix" | jq -e '
    all(.[];
        if .rust_features == "arm-soft-nofp" then
            (.rust_target | test("^arm.*-musleabi$")) and .float_abi == "soft"
        elif (.rust_features == "arm-hard-d16" or .rust_features == "arm-hard-neon") then
            (.rust_target | test("^arm.*-musleabihf$")) and .float_abi == "hard"
        else true end)' >/dev/null

if rg -n '@[A-Z_]+@' "$CNO_BUILDS_ROOT/packaging" \
    --glob '!APKBUILD.in' >/dev/null; then
    die "unexpected unresolved template placeholder"
fi

# OpenWrt package recipes are expanded once by BuildPackage's eval and once by
# make before the shell sees them.  The QEMU wrappers must retain a literal
# "$@" so target cjsc/qjsc receive their CMake arguments, not make's target.
wrapper_arg_lines=$(rg -c -F '"$$$$@"' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile")
[ "$wrapper_arg_lines" -eq 2 ] \
    || die 'OpenWrt QEMU wrappers must double-escape their positional arguments'
grep -Fq -- '-DCNO_TARGET_ENDIAN=$(if $(filter 1,$(CNO_BIG_ENDIAN)),big,little)' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt package recipe must pass the asserted target byte order'
grep -Fq -- '-DCNO_TARGET_FLOAT_ABI=$(CNO_TARGET_FLOAT_ABI)' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt package recipe must pass the asserted floating-point ABI'
grep -Fq 'NOT COMMAND _cno_assert_target_abi OR NOT CNO_TARGET_ABI_ASSERTIONS_OK' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/openwrt-project.cmake" \
    || die 'OpenWrt CMake hook must reject cno-cli without ABI assertions'
grep -Fq 'NOT CNO_TARGET_ENDIAN OR NOT CNO_TARGET_FLOAT_ABI' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/openwrt-project.cmake" \
    || die 'OpenWrt CMake hook must require both target ABI values'

work=$(make_temp_dir)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

# Resolve-default-branch tests use a fake curl executable and static GitHub API
# fixtures.  They exercise annotated tag peeling, commit-derived versions,
# ambiguity rejection, API failure propagation, and token forwarding without
# relying on network access or the current state of cno-cli.
head_fixture="$work/head-fixture"
mkdir -p "$head_fixture/bin" "$head_fixture/json"
cat > "$head_fixture/bin/curl" <<'EOF'
#!/bin/sh
set -eu

output=
url=
while [ "$#" -gt 0 ]; do
    case $1 in
        -o)
            [ "$#" -ge 2 ] || exit 2
            output=$2
            shift 2
            ;;
        -H)
            [ "$#" -ge 2 ] || exit 2
            printf '%s\n' "$2" >> "$FAKE_CURL_LOG"
            shift 2
            ;;
        --retry)
            [ "$#" -ge 2 ] || exit 2
            shift 2
            ;;
        --fail|--location|--show-error|--silent|--retry-all-errors)
            shift
            ;;
        http://*|https://*)
            url=$1
            shift
            ;;
        *)
            printf 'fake curl: unexpected argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ] || exit 2
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"

case $url in
    */repos/imzlh/cno-cli) fixture=repository.json ;;
    */repos/imzlh/cno-cli/commits/main) fixture=commit.json ;;
    */repos/imzlh/cno-cli/contents/package.json?ref=*) fixture=package-content.json ;;
    */repos/imzlh/cno-cli/git/matching-refs/tags/v?*)
        [ "$FAKE_GITHUB_MODE" != api-failure ] || exit 22
        fixture="refs-$FAKE_GITHUB_MODE.json"
        ;;
    */repos/imzlh/cno-cli/git/tags/2222222222222222222222222222222222222222)
        fixture=annotated-tag.json
        ;;
    *)
        printf 'fake curl: unexpected URL: %s\n' "$url" >&2
        exit 22
        ;;
esac
cp "$FAKE_GITHUB_FIXTURES/$fixture" "$output"
EOF
chmod 0755 "$head_fixture/bin/curl"
cat > "$head_fixture/json/repository.json" <<'EOF'
{"default_branch":"main"}
EOF
cat > "$head_fixture/json/commit.json" <<'EOF'
{
  "sha":"1111111111111111111111111111111111111111",
  "commit":{"committer":{"date":"2026-11-07T04:05:06Z"}}
}
EOF
cat > "$head_fixture/json/package-content.json" <<'EOF'
{"encoding":"base64","content":"eyJ2ZXJzaW9uIjoiMS4yLjMifQo="}
EOF
cat > "$head_fixture/json/annotated-tag.json" <<'EOF'
{
  "object":{
    "type":"commit",
    "sha":"1111111111111111111111111111111111111111"
  }
}
EOF
cat > "$head_fixture/json/refs-tagged.json" <<'EOF'
[
  {
    "ref":"refs/tags/v1.2.3",
    "object":{
      "type":"tag",
      "sha":"2222222222222222222222222222222222222222"
    }
  },
  {
    "ref":"refs/tags/v9.9.9",
    "object":{
      "type":"commit",
      "sha":"3333333333333333333333333333333333333333"
    }
  },
  {
    "ref":"refs/tags/v1.2.3-rc.1",
    "object":{
      "type":"commit",
      "sha":"1111111111111111111111111111111111111111"
    }
  }
]
EOF
cat > "$head_fixture/json/refs-untagged.json" <<'EOF'
[]
EOF
cat > "$head_fixture/json/refs-ambiguous.json" <<'EOF'
[
  {
    "ref":"refs/tags/v1.2.3",
    "object":{
      "type":"commit",
      "sha":"1111111111111111111111111111111111111111"
    }
  },
  {
    "ref":"refs/tags/v1.2.4",
    "object":{
      "type":"commit",
      "sha":"1111111111111111111111111111111111111111"
    }
  }
]
EOF
: > "$head_fixture/curl.log"

tagged_head=$(
    PATH="$head_fixture/bin:$PATH" \
    GITHUB_API_URL=https://fixture.invalid \
    GITHUB_TOKEN=fixture-token \
    FAKE_GITHUB_MODE=tagged \
    FAKE_GITHUB_FIXTURES="$head_fixture/json" \
    FAKE_CURL_LOG="$head_fixture/curl.log" \
    sh "$CNO_BUILDS_ROOT/scripts/resolve-cno-head.sh"
)
for expected in \
    'tag=v1.2.3' \
    'version=1.2.3' \
    'base_version=1.2.3' \
    'commit=1111111111111111111111111111111111111111' \
    'commit_date=2026-11-07T04:05:06Z' \
    'source_date_epoch=1794024306' \
    'prerelease=false' \
    'source_url=https://github.com/imzlh/cno-cli/commit/1111111111111111111111111111111111111111'
do
    printf '%s\n' "$tagged_head" | grep -Fx "$expected" >/dev/null \
        || die "tagged HEAD output is missing: $expected"
done
grep -Fx 'Authorization: Bearer fixture-token' "$head_fixture/curl.log" >/dev/null \
    || die 'HEAD resolver did not pass GITHUB_TOKEN to the GitHub API'

untagged_head=$(
    PATH="$head_fixture/bin:$PATH" \
    GITHUB_API_URL=https://fixture.invalid \
    FAKE_GITHUB_MODE=untagged \
    FAKE_GITHUB_FIXTURES="$head_fixture/json" \
    FAKE_CURL_LOG="$head_fixture/curl.log" \
    sh "$CNO_BUILDS_ROOT/scripts/resolve-cno-head.sh"
)
for expected in \
    'tag=' \
    'version=1.2.3.1794024306.4803839602528529' \
    'base_version=1.2.3' \
    'prerelease=true'
do
    printf '%s\n' "$untagged_head" | grep -Fx "$expected" >/dev/null \
        || die "untagged HEAD output is missing: $expected"
done

if PATH="$head_fixture/bin:$PATH" \
    GITHUB_API_URL=https://fixture.invalid \
    FAKE_GITHUB_MODE=ambiguous \
    FAKE_GITHUB_FIXTURES="$head_fixture/json" \
    FAKE_CURL_LOG="$head_fixture/curl.log" \
    sh "$CNO_BUILDS_ROOT/scripts/resolve-cno-head.sh" >/dev/null 2>&1
then
    die 'HEAD resolver accepted two stable tags for the same commit'
fi
if PATH="$head_fixture/bin:$PATH" \
    GITHUB_API_URL=https://fixture.invalid \
    FAKE_GITHUB_MODE=api-failure \
    FAKE_GITHUB_FIXTURES="$head_fixture/json" \
    FAKE_CURL_LOG="$head_fixture/curl.log" \
    sh "$CNO_BUILDS_ROOT/scripts/resolve-cno-head.sh" >/dev/null 2>&1
then
    die 'HEAD resolver swallowed a GitHub API failure'
fi

mkdir -p "$work/payload/ext" "$work/payload/lib" "$work/out-a" "$work/out-b"
cat > "$work/payload/cno" <<'EOF'
#!/bin/sh
printf '%s\n' 'cno 1.2.3'
EOF
chmod 0755 "$work/payload/cno"
printf '%s\n' fixture > "$work/payload/ext/oxc.so"
printf '%s\n' fixture > "$work/payload/lib/libfixture.so"
printf '%s\n' 'fixture build' > "$work/payload/BUILD-INFO.txt"
tar -czf "$work/cno-linux-minimal-x86_64.tar.gz" -C "$work/payload" .

mkdir -p "$work/unsafe"
ln -s /etc/passwd "$work/unsafe/cno"
tar -czf "$work/unsafe.tar.gz" -C "$work/unsafe" .
if (extract_release_archive "$work/unsafe.tar.gz" "$work/unsafe-output") 2>/dev/null; then
    die "archive safety check accepted a symbolic link"
fi

sh "$CNO_BUILDS_ROOT/scripts/build-deb.sh" \
    1.2.3 amd64 "$work/cno-linux-minimal-x86_64.tar.gz" "$work/out-a" 1700000000
sh "$CNO_BUILDS_ROOT/scripts/build-deb.sh" \
    1.2.3 amd64 "$work/cno-linux-minimal-x86_64.tar.gz" "$work/out-b" 1700000000
package_a="$work/out-a/cno_1.2.3-${CNO_PACKAGE_RELEASE}_amd64.deb"
package_b="$work/out-b/cno_1.2.3-${CNO_PACKAGE_RELEASE}_amd64.deb"
cmp "$package_a" "$package_b"
[ "$(dpkg-deb -f "$package_a" Package)" = cno ]
[ "$(dpkg-deb -f "$package_a" Architecture)" = amd64 ]
[ "$(dpkg-deb -f "$package_a" Version)" = "1.2.3-${CNO_PACKAGE_RELEASE}" ]
dpkg-deb --ctrl-tarfile "$package_a" | tar -tf - | grep -Fx './md5sums' >/dev/null
dpkg-deb -x "$package_a" "$work/extracted"
[ "$(readlink "$work/extracted/usr/bin/cno")" = ../lib/cno/cno ]
[ -x "$work/extracted/usr/lib/cno/cno" ]
[ -f "$work/extracted/usr/lib/cno/ext/oxc.so" ]
[ -f "$work/extracted/usr/lib/cno/lib/libfixture.so" ]

release_input="$work/release-input"
release_output="$work/release-output"
mkdir -p "$release_input" "$release_output"
awk -F '\t' '!/^#/ && NF { print $2 }' "$CNO_BUILDS_ROOT/config/debian-targets.tsv" \
    | while IFS= read -r arch; do
        touch "$release_input/cno_1.2.3-${CNO_PACKAGE_RELEASE}_${arch}.deb"
    done
awk -F '\t' '!/^#/ && NF { print $2 }' "$CNO_BUILDS_ROOT/config/alpine-targets.tsv" \
    | while IFS= read -r arch; do
        touch "$release_input/cno-1.2.3-r${CNO_PACKAGE_RELEASE}-${arch}.apk"
        touch "$release_input/cno-1.2.3-${arch}.rsa.pub"
    done
awk -F '\t' '!/^#/ && NF { print $1, $2, $3 }' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv" \
    | while read -r formats target subtarget; do
        case "+$formats+" in
            *+ipk+*)
                stable="cno-1.2.3-r${CNO_PACKAGE_RELEASE}-openwrt-24.10.0-${target}-${subtarget}.ipk"
                touch "$release_input/$stable" "$release_input/$stable.buildinfo"
                ;;
        esac
        case "+$formats+" in
            *+apk+*)
                snapshot="cno-1.2.3-r${CNO_PACKAGE_RELEASE}-openwrt-snapshots-${target}-${subtarget}.apk"
                touch "$release_input/$snapshot" "$release_input/$snapshot.buildinfo"
                ;;
        esac
    done
sh "$CNO_BUILDS_ROOT/scripts/collect-release.sh" \
    "$release_input" "$release_output" 1.2.3 \
    1111111111111111111111111111111111111111 \
    https://github.com/imzlh/cno-cli/commit/1111111111111111111111111111111111111111
[ -s "$release_output/SHA256SUMS.txt" ]
[ -s "$release_output/RELEASE-INFO.txt" ]
grep -Fx 'source commit: 1111111111111111111111111111111111111111' \
    "$release_output/RELEASE-INFO.txt" >/dev/null

printf '[check] shell, matrices, reproducible Debian fixture and release set passed\n'

