#!/bin/sh
set -eu

runtime=${1:?Usage: smoke-openwrt.sh RUNTIME_ARCHIVE SDK VERSION EMULATOR}
sdk=${2:?Missing extracted OpenWrt SDK}
version=${3:?Missing expected version}
emulator=${4:?Missing QEMU user emulator}
[ -f "$runtime" ] || { printf 'runtime archive not found: %s\n' "$runtime" >&2; exit 1; }
[ -d "$sdk" ] || { printf 'SDK directory not found: %s\n' "$sdk" >&2; exit 1; }
command -v "$emulator" >/dev/null 2>&1 || { printf 'emulator not found: %s\n' "$emulator" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { printf 'timeout is required\n' >&2; exit 1; }

work=$(mktemp -d /tmp/cno-openwrt-smoke.XXXXXX)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
mkdir -p "$work/root" "$work/root/tmp"
tar -xzf "$runtime" -C "$work/root"
binary="$work/root/usr/lib/cno/cno"
[ -x "$binary" ]
[ -f "$work/root/usr/lib/cno/ext/oxc.so" ]
[ "$(readlink "$work/root/usr/bin/cno")" = ../lib/cno/cno ]

headers=$(LC_ALL=C readelf -lW "$binary")
interpreter=$(printf '%s\n' "$headers" | sed -n \
    's/.*Requesting program interpreter: \([^]]*\)\].*/\1/p')
case $interpreter in
    /lib/ld-musl-*.so.1) ;;
    *) printf 'unexpected musl interpreter: %s\n' "$interpreter" >&2; exit 1 ;;
esac

needed_sonames() {
    readelf -dW "$1" | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p'
}
find_target_library() {
    wanted_soname=$1
    for target_root in "$sdk"/staging_dir/target-* "$sdk"/staging_dir/toolchain-*; do
        [ -d "$target_root" ] || continue
        candidate=$(find "$target_root" \( -type f -o -type l \) \
            -name "$wanted_soname" -print -quit)
        if [ -n "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
pending="$work/pending-libraries"
seen="$work/seen-libraries"
: > "$pending"
: > "$seen"
needed_sonames "$binary" >> "$pending"
needed_sonames "$work/root/usr/lib/cno/ext/oxc.so" >> "$pending"

# Populate a private target root with the SDK's runtime libraries. This lets
# QEMU exercise exactly the same shared objects declared as package
# dependencies, without borrowing the host distribution's ABI.
mkdir -p "$work/root/lib" "$work/root/usr/lib"
find "$sdk/staging_dir" -mindepth 1 -maxdepth 1 -type d -name 'toolchain-*' -print \
    | while IFS= read -r toolchain; do
        [ ! -d "$toolchain/lib" ] || cp -aL "$toolchain/lib/." "$work/root/lib/"
        [ ! -d "$toolchain/usr/lib" ] || cp -aL "$toolchain/usr/lib/." "$work/root/usr/lib/"
    done
find "$sdk/staging_dir" -mindepth 1 -maxdepth 1 -type d -name 'target-*' -print \
    | while IFS= read -r staging; do
        [ ! -d "$staging/lib" ] || cp -aL "$staging/lib/." "$work/root/lib/"
        [ ! -d "$staging/usr/lib" ] || cp -aL "$staging/usr/lib/." "$work/root/usr/lib/"
    done
[ -f "$work/root$interpreter" ] || {
    printf 'target loader not found in SDK runtime root: %s\n' "$interpreter" >&2
    exit 1
}

# Resolve the complete DT_NEEDED closure from SDK staging. Most dependencies
# are already in the target sysroot; package-only DSOs can live deeper under
# staging_dir, so copy those by SONAME on demand.
queue_index=1
while :; do
    soname=$(sed -n "${queue_index}p" "$pending")
    [ -n "$soname" ] || break
    queue_index=$((queue_index + 1))
    grep -Fx "$soname" "$seen" >/dev/null 2>&1 && continue
    printf '%s\n' "$soname" >> "$seen"
    case $soname in libc.so|libc.musl-*.so.1|ld-musl-*.so.1) continue ;; esac
    library=$(find "$work/root/lib" "$work/root/usr/lib" \
        \( -type f -o -type l \) -name "$soname" -print | head -n 1)
    if [ -z "$library" ]; then
        # Do not accidentally copy an x86 host/hostpkg DSO into an ARM/MIPS
        # QEMU root merely because it has the requested SONAME.
        library=$(find_target_library "$soname" || true)
        [ -n "$library" ] || {
            printf 'cannot stage target library required for smoke test: %s\n' "$soname" >&2
            exit 1
        }
        cp -L "$library" "$work/root/usr/lib/$soname"
        library="$work/root/usr/lib/$soname"
    fi
    needed_sonames "$library" >> "$pending"
done

printf '%s\n' \
    'const answer: number = 6 * 7; console.log(`CNO_OPENWRT_OK=${answer}`);' \
    > "$work/root/tmp/smoke.ts"
version_output=$(timeout --signal=KILL 180 \
    "$emulator" -L "$work/root" "$binary" --version)
printf '%s\n' "$version_output" | grep -Eq "^cno ${version}([[:space:]]|$)" || {
    printf 'unexpected cno version output: %s\n' "$version_output" >&2
    exit 1
}
DEBUG=transformer CTS_CACHE_DIR="$work/cache" \
    timeout --signal=KILL 180 \
    "$emulator" -L "$work/root" "$binary" run --disable-cache \
    "$work/root/tmp/smoke.ts" \
    > "$work/output.log" 2>&1
grep -Fx 'CNO_OPENWRT_OK=42' "$work/output.log"
grep -Eiq 'oxc( bytes)?:' "$work/output.log"
printf '[smoke-openwrt] dynamic runtime and OXC passed with %s\n' "$emulator"
