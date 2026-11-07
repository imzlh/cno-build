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
need_command tar

find "$CNO_BUILDS_ROOT/scripts" -type f -name '*.sh' -print | sort \
    | while IFS= read -r script; do sh -n "$script"; done
# common.sh is a sourced library and intentionally has no shebang invocation.
shellcheck -x -s sh \
    -P "$CNO_BUILDS_ROOT" \
    -P "$CNO_BUILDS_ROOT/scripts" \
    -P "$CNO_BUILDS_ROOT/scripts/lib" \
    "$CNO_BUILDS_ROOT"/scripts/*.sh "$CNO_BUILDS_ROOT"/scripts/lib/*.sh

for table in \
    "$CNO_BUILDS_ROOT/config/debian-targets.tsv" \
    "$CNO_BUILDS_ROOT/config/alpine-targets.tsv" \
    "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv"
do
    awk -F '\t' '
        /^#/ || NF == 0 { next }
        NF < 3 { print FILENAME ":" FNR ": expected at least three TSV columns" > "/dev/stderr"; bad=1 }
        { for (i=1; i<=NF; i++) if ($i == "") { print FILENAME ":" FNR ": empty field" > "/dev/stderr"; bad=1 } }
        END { exit bad }
    ' "$table"
done

debian_matrix=$(sh "$CNO_BUILDS_ROOT/scripts/config-matrix.sh" debian)
alpine_matrix=$(sh "$CNO_BUILDS_ROOT/scripts/config-matrix.sh" alpine)
openwrt_matrix=$(sh "$CNO_BUILDS_ROOT/scripts/config-matrix.sh" openwrt)
[ "$(printf '%s' "$debian_matrix" | jq 'length')" -gt 0 ]
[ "$(printf '%s' "$alpine_matrix" | jq 'length')" -gt 0 ]
[ "$(printf '%s' "$openwrt_matrix" | jq 'length')" -gt 0 ]
printf '%s' "$debian_matrix" | jq -e 'all(.[]; has("deb_arch") and has("image"))' >/dev/null
printf '%s' "$alpine_matrix" | jq -e 'all(.[]; has("alpine_arch") and has("platform"))' >/dev/null
printf '%s' "$openwrt_matrix" | jq -e \
    'all(.[]; (.format == "ipk" or .format == "apk") and has("subtarget"))' >/dev/null

if rg -n '@[A-Z_]+@' "$CNO_BUILDS_ROOT/packaging" \
    --glob '!APKBUILD.in' >/dev/null; then
    die "unexpected unresolved template placeholder"
fi

work=$(make_temp_dir)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
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
package_a="$work/out-a/cno_1.2.3-1_amd64.deb"
package_b="$work/out-b/cno_1.2.3-1_amd64.deb"
cmp "$package_a" "$package_b"
[ "$(dpkg-deb -f "$package_a" Package)" = cno ]
[ "$(dpkg-deb -f "$package_a" Architecture)" = amd64 ]
[ "$(dpkg-deb -f "$package_a" Version)" = 1.2.3-1 ]
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
awk -F '\t' '!/^#/ && NF { print $1, $2 }' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv" \
    | while read -r target subtarget; do
        stable="cno-1.2.3-r${CNO_PACKAGE_RELEASE}-openwrt-24.10.0-${target}-${subtarget}.ipk"
        snapshot="cno-1.2.3-r${CNO_PACKAGE_RELEASE}-openwrt-snapshots-${target}-${subtarget}.apk"
        touch "$release_input/$stable" "$release_input/$stable.buildinfo"
        touch "$release_input/$snapshot" "$release_input/$snapshot.buildinfo"
    done
sh "$CNO_BUILDS_ROOT/scripts/collect-release.sh" \
    "$release_input" "$release_output" 1.2.3
[ -s "$release_output/SHA256SUMS.txt" ]
[ -s "$release_output/RELEASE-INFO.txt" ]

printf '[check] shell, matrices, reproducible Debian fixture and release set passed\n'

