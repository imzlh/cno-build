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

# Alpine's abuild invokes apk again to install the generated .makedepends
# package. A no-cache bootstrap discards the repository indexes before that
# second invocation, making even ordinary runtime dependencies unresolvable.
grep -Fq 'apk add --update-cache alpine-sdk openssl coreutils' \
    "$CNO_BUILDS_ROOT/.github/workflows/packages.yml" \
    || die 'Alpine bootstrap must preserve apk indexes for abuild dependencies'
if grep -Fq 'apk add --no-cache alpine-sdk openssl coreutils' \
    "$CNO_BUILDS_ROOT/.github/workflows/packages.yml"; then
    die 'Alpine bootstrap must not discard indexes before abuild runs'
fi
grep -Fq 'ABUILD_APK_INDEX_OPTS="--keys-dir $trusted_keys_dir"' \
    "$CNO_BUILDS_ROOT/scripts/build-alpine.sh" \
    || die 'Alpine repository indexing must trust the package signing public key'
grep -Fq 'cp "$public_key" "$trusted_keys_dir/$public_key_name"' \
    "$CNO_BUILDS_ROOT/scripts/build-alpine.sh" \
    || die 'Alpine index trust directory must contain the matching public key'
if grep -Eq 'ABUILD_APK_INDEX_OPTS=.*--allow-untrusted' \
    "$CNO_BUILDS_ROOT/scripts/build-alpine.sh"; then
    die 'Alpine repository indexing must not disable signature verification'
fi

# Failure annotations must expose the first useful diagnostic as well as the
# final make output. Parallel OpenWrt dependencies commonly finish after cno
# fails and otherwise push the real compiler error out of a tail-only report.
failure_fixture=$(make_temp_dir)
failure_log="$failure_fixture/parallel-failure.log"
cat > "$failure_log" <<'EOF'
[ 41%] Building dependency
-- Could NOT find OpenSSL (missing: OPENSSL_CRYPTO_LIBRARY OPENSSL_INCLUDE_DIR)
-- Could NOT find Libevent (missing: LIBEVENT_CORE_LIBRARY)
(missing: optional dependency)
src/runtime.c:17:9: error: unknown type name 'fixture_type'
make[4]: *** [runtime.o] Error 1
dependency: successful cleanup after unrelated parallel work
time: package/feeds/packages/libffi/compile#3.96#4.85#6.79
make: *** [include/toplevel.mk:226: package/cno/compile] Error 2
EOF
failure_report=$(sh "$CNO_BUILDS_ROOT/scripts/report-build-failure.sh" \
    "$failure_log" 'fixture failed' 2>&1)
printf '%s\n' "$failure_report" | grep -Fq \
    "First high-signal diagnostic (log line 5):%0Asrc/runtime.c:17:9: error: unknown type name 'fixture_type'" \
    || die 'failure reporter did not preserve the first compiler diagnostic'
printf '%s\n' "$failure_report" | grep -Fq \
    'make: *** [include/toplevel.mk:226: package/cno/compile] Error 2' \
    || die 'failure reporter did not preserve the final build error'

failure_log="$failure_fixture/qemu-loader-failure.log"
cat > "$failure_log" <<'EOF'
-- Could NOT find OpenSSL (missing: OPENSSL_CRYPTO_LIBRARY OPENSSL_INCLUDE_DIR)
-- Could NOT find Libngtcp2 (missing: LIBNGTCP2_LIBRARY LIBNGTCP2_INCLUDE_DIR)
Error relocating /sdk/staging_dir/host/lib/runas.so: unsupported relocation type 7
make[4]: *** [build.ninja:802: cno_cli_blob.h] Error 1
make: *** [include/toplevel.mk:226: package/cno/compile] Error 2
EOF
failure_report=$(sh "$CNO_BUILDS_ROOT/scripts/report-build-failure.sh" \
    "$failure_log" 'qemu fixture failed' 2>&1)
rm -rf -- "$failure_fixture"
printf '%s\n' "$failure_report" | grep -Fq \
    'First high-signal diagnostic (log line 3):%0AError relocating /sdk/staging_dir/host/lib/runas.so: unsupported relocation type 7' \
    || die 'failure reporter did not prioritize the target-loader relocation error'
grep -Fq 'sh scripts/report-build-failure.sh "$log"' \
    "$CNO_BUILDS_ROOT/.github/workflows/packages.yml" \
    || die 'package workflow does not use the structured failure reporter'
grep -Fq '[openwrt-sdk] parallel build failed; retrying package/cno serially' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt failures must be retried serially for deterministic diagnostics'
grep -Fq 'emulator_path=$(command -v "$emulator")' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must resolve the system qemu-user executable before SDK make'
grep -Fq 'CNO_QEMU="$emulator_path"' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt target tools must use the absolute system qemu-user path'
wrapper_unset_count=$(grep -Fc \
    "'unset LD_PRELOAD LD_LIBRARY_PATH RUNAS_ARG0'" \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile")
[ "$wrapper_unset_count" -eq 2 ] \
    || die 'both OpenWrt target-tool wrappers must clear host loader injection'
grep -Fq 'exec "$(CNO_QEMU)" -L' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt target-tool wrappers must quote the absolute qemu-user path'
dynamic_symbol_read_count=$(grep -Fc \
    '$readelf_command --use-dynamic --dyn-syms --wide' \
    "$CNO_BUILDS_ROOT/scripts/verify-openwrt-elf.sh")
[ "$dynamic_symbol_read_count" -eq 2 ] \
    || die 'OpenWrt ELF export checks must read symbols through the dynamic section'
grep -Fq './scripts/feeds update base packages' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must index the SDK-pinned base and packages feeds'
grep -Fq './scripts/feeds install -p base zlib ca-certificates' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must install cno core dependency recipes from the base feed'
grep -Fq './scripts/feeds install -p packages libsqlite3 libffi libexpat libnghttp2' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must install only the active packages-feed dependency recipes'
for direct_recipe in libcurl openssl; do
    if awk -v wanted="$direct_recipe" '
        /\.\/scripts\/feeds install/ {
            for (field = 1; field <= NF; field++) if ($field == wanted) bad=1
        }
        END { exit bad }
    ' "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh"; then
        :
    else
        die "OpenWrt must link $direct_recipe without recursively installing disabled dependencies"
    fi
done
grep -Fq 'scripts/normalize-openwrt-depends.sh' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must normalize curl and OpenSSL package dependencies'
grep -Fq 'ln -s ../../../feeds/packages/net/curl "$curl_recipe"' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must link the SDK-pinned curl source recipe directly'
for openssl_layout in package/libs/openssl libs/openssl; do
    grep -Fq "feeds/base/$openssl_layout" \
        "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
        || die "OpenWrt must accept the base-feed OpenSSL layout $openssl_layout"
done
grep -Fq 'base feed contains ambiguous OpenSSL recipes' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must reject ambiguous base-feed OpenSSL layouts'
grep -Fq 'ln -s "../../../$openssl_source" "$openssl_recipe"' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must link the SDK-pinned OpenSSL source recipe directly'
grep -Fq 'refusing to replace non-symlink curl recipe' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt curl recipe linking must not replace an existing directory'
grep -Fq 'refusing to replace non-symlink OpenSSL recipe' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt OpenSSL recipe linking must not replace an existing directory'
if grep -Fq './scripts/feeds install -a' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh"; then
    die 'OpenWrt must not expose unrelated packages-feed Kconfig entries'
fi
grep -Fq "grep -Fqi 'recursive dependency detected'" \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt defconfig must reject every recursive Kconfig diagnostic'
grep -Fq 'sdk_defconfig curl-openssl' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt curl TLS selection must use checked defconfig output'
initial_defconfig_line=$(grep -n '^sdk_defconfig initial$' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" | cut -d: -f1)
[ -n "$initial_defconfig_line" ] \
    || die 'OpenWrt build must run an initial checked defconfig'
config_touch_line=$(grep -nF 'touch "$sdk_dir/.config"' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" | head -n 1 | cut -d: -f1)
[ -n "$config_touch_line" ] && [ "$config_touch_line" -lt "$initial_defconfig_line" ] \
    || die 'OpenWrt must create .config before editing it'
for buildbot_option in ALL ALL_NONSHARED ALL_KMODS; do
    disabled_line=$(grep -nF "'# CONFIG_${buildbot_option} is not set'" \
        "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" | head -n 1 | cut -d: -f1)
    [ -n "$disabled_line" ] && [ "$disabled_line" -lt "$initial_defconfig_line" ] \
        || die "OpenWrt must disable $buildbot_option before the initial defconfig"
done
grep -Fq '"$sdk_dir/.config" ALL ALL_NONSHARED ALL_KMODS' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must verify buildbot package defaults stayed disabled'
grep -Fq "'CONFIG_LIBCURL_OPENSSL=y'" \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt libcurl must use the explicitly selected OpenSSL backend'
grep -Fq "'CONFIG_LIBCURL_HTTP2=y'" \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt libcurl must explicitly retain HTTP/2 support'
grep -Fq "'CONFIG_LIBCURL_ZLIB=y'" \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt libcurl must explicitly retain zlib support'
grep -Fq "'CONFIG_PACKAGE_libopenssl=m'" \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt configuration must explicitly seed the libopenssl package'
grep -Fq "'CONFIG_PACKAGE_libnghttp2=m'" \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt configuration must explicitly seed the libnghttp2 package'
for disabled_option in \
    LIBCURL_WOLFSSL LIBCURL_GNUTLS LIBCURL_MBEDTLS LIBCURL_NOSSL \
    LIBCURL_ZSTD LIBCURL_THREADED_RESOLVER LIBCURL_LDAP \
    LIBCURL_LIBIDN2 LIBCURL_SSH2 LIBCURL_HTTP3 LIBCURL_KERBEROS_AUTH
do
    grep -Fq "'# CONFIG_${disabled_option} is not set'" \
        "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
        || die "OpenWrt configuration must explicitly disable $disabled_option"
done
for disabled_option in \
    OPENSSL_WITH_COMPRESSION OPENSSL_ENGINE_BUILTIN_AFALG \
    OPENSSL_ENGINE_BUILTIN_DEVCRYPTO OPENSSL_ENGINE_BUILTIN_PADLOCK
do
    grep -Fq "'# CONFIG_${disabled_option} is not set'" \
        "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
        || die "OpenWrt configuration must explicitly disable $disabled_option"
done
for disabled_package in \
    libopenssl-afalg libopenssl-devcrypto libopenssl-padlock
do
    grep -Fq "'# CONFIG_PACKAGE_${disabled_package} is not set'" \
        "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
        || die "OpenWrt configuration must explicitly disable $disabled_package"
done
grep -Fq 'scripts/verify-openwrt-disabled-options.sh' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt must verify that optional config symbols are disabled or absent'

disabled_config_fixture=$(make_temp_dir)
cat > "$disabled_config_fixture/.config" <<'EOF'
# CONFIG_DEFINED_DISABLED is not set
CONFIG_UNRELATED=y
EOF
sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-disabled-options.sh" \
    "$disabled_config_fixture/.config" DEFINED_DISABLED ABSENT_DISABLED \
    PACKAGE_absent-lowercase
printf '%s\n' 'CONFIG_FORBIDDEN=y' >> "$disabled_config_fixture/.config"
printf '%s\n' 'CONFIG_PACKAGE_forbidden-engine=m' \
    >> "$disabled_config_fixture/.config"
if sh "$CNO_BUILDS_ROOT/scripts/verify-openwrt-disabled-options.sh" \
    "$disabled_config_fixture/.config" DEFINED_DISABLED ABSENT_DISABLED \
    FORBIDDEN PACKAGE_forbidden-engine >/dev/null 2>&1; then
    die 'OpenWrt disabled-option verifier accepted an assigned forbidden option'
fi
rm -rf -- "$disabled_config_fixture"

grep -Fq 'name: Upload OpenWrt failure log' \
    "$CNO_BUILDS_ROOT/.github/workflows/packages.yml" \
    || die 'OpenWrt failures must preserve their complete logs'

curl_fixture=$(make_temp_dir)
curl_recipe_fixture="$curl_fixture/Makefile"
openssl_recipe_fixture="$curl_fixture/openssl.Makefile"
cat > "$curl_recipe_fixture" <<'EOF'
define Package/libcurl
  DEPENDS:= +LIBCURL_WOLFSSL:libwolfssl +LIBCURL_OPENSSL:libopenssl +LIBCURL_GNUTLS:libgnutls +LIBCURL_MBEDTLS:libmbedtls
  DEPENDS += +LIBCURL_ZLIB:zlib +LIBCURL_ZSTD:libzstd +LIBCURL_THREADED_RESOLVER:libpthread +LIBCURL_LDAP:libopenldap
  DEPENDS += +LIBCURL_LIBIDN2:libidn2 +LIBCURL_SSH2:libssh2 +LIBCURL_HTTP2:libnghttp2 +LIBCURL_HTTP3:libnghttp3 +LIBCURL_HTTP3:libngtcp2 +ca-bundle
  DEPENDS += +LIBCURL_KERBEROS_AUTH:krb5-libs
endef
EOF
cat > "$openssl_recipe_fixture" <<'EOF'
define Package/libopenssl
  DEPENDS:=+OPENSSL_WITH_COMPRESSION:zlib \
	   +OPENSSL_ENGINE_BUILTIN_AFALG:kmod-crypto-user \
	   +OPENSSL_ENGINE_BUILTIN_DEVCRYPTO:kmod-cryptodev \
	   +OPENSSL_ENGINE_BUILTIN_PADLOCK:kmod-crypto-hw-padlock \
	   $(ATOMIC64_DEPENDS)
endef
EOF
cp "$curl_recipe_fixture" "$curl_fixture/curl-original.Makefile"
cp "$openssl_recipe_fixture" "$curl_fixture/openssl-original.Makefile"
sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_recipe_fixture" "$openssl_recipe_fixture"
for normalized_token in +libopenssl +zlib +libnghttp2 +ca-bundle; do
    [ "$(awk -v wanted="$normalized_token" '
        { for (field = 1; field <= NF; field++) if ($field == wanted) count++ }
        END { print count + 0 }
    ' "$curl_recipe_fixture")" -eq 1 ] \
        || die "normalized curl fixture lost $normalized_token"
done
if rg -n '\+LIBCURL_[A-Z0-9_]+:' "$curl_recipe_fixture" >/dev/null; then
    die 'normalized curl fixture retained a conditional package dependency'
fi
if rg -n '\+OPENSSL_[A-Z0-9_]+:' "$openssl_recipe_fixture" >/dev/null; then
    die 'normalized OpenSSL fixture retained a conditional package dependency'
fi

cp "$curl_fixture/curl-original.Makefile" "$curl_fixture/omitted-curl.Makefile"
cp "$curl_fixture/openssl-original.Makefile" "$curl_fixture/omitted-openssl.Makefile"
sed -i \
    -e 's|+LIBCURL_KERBEROS_AUTH:krb5-libs||' \
    "$curl_fixture/omitted-curl.Makefile"
sed -i \
    -e 's|+OPENSSL_ENGINE_BUILTIN_PADLOCK:kmod-crypto-hw-padlock||' \
    "$curl_fixture/omitted-openssl.Makefile"
sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_fixture/omitted-curl.Makefile" \
    "$curl_fixture/omitted-openssl.Makefile"

cp "$curl_recipe_fixture" "$curl_fixture/drifted.Makefile"
if sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_fixture/drifted.Makefile" "$openssl_recipe_fixture" >/dev/null 2>&1; then
    die 'curl dependency normalizer accepted an already-normalized recipe'
fi

cp "$curl_fixture/curl-original.Makefile" "$curl_fixture/unknown-curl.Makefile"
cp "$curl_fixture/openssl-original.Makefile" "$curl_fixture/unknown-openssl.Makefile"
printf '%s\n' 'FUTURE_DEPENDS:=+LIBCURL_FUTURE_BACKEND:libfuture' \
    >> "$curl_fixture/unknown-curl.Makefile"
if sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_fixture/unknown-curl.Makefile" \
    "$curl_fixture/unknown-openssl.Makefile" >/dev/null 2>&1; then
    die 'dependency normalizer accepted an unknown curl conditional token'
fi

cp "$curl_fixture/curl-original.Makefile" "$curl_fixture/unknown-curl.Makefile"
printf '%s\n' 'FUTURE_DEPENDS:=+OPENSSL_FUTURE_BACKEND:libfuture' \
    >> "$curl_fixture/unknown-openssl.Makefile"
if sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_fixture/unknown-curl.Makefile" \
    "$curl_fixture/unknown-openssl.Makefile" >/dev/null 2>&1; then
    die 'dependency normalizer accepted an unknown OpenSSL conditional token'
fi

cp "$curl_fixture/curl-original.Makefile" "$curl_fixture/duplicate-curl.Makefile"
cp "$curl_fixture/openssl-original.Makefile" "$curl_fixture/duplicate-openssl.Makefile"
printf '%s\n' 'DEPENDS += +LIBCURL_KERBEROS_AUTH:krb5-libs' \
    >> "$curl_fixture/duplicate-curl.Makefile"
if sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_fixture/duplicate-curl.Makefile" \
    "$curl_fixture/duplicate-openssl.Makefile" >/dev/null 2>&1; then
    die 'dependency normalizer accepted a duplicate disabled curl token'
fi

cp "$curl_fixture/curl-original.Makefile" "$curl_fixture/duplicate-curl.Makefile"
printf '%s\n' 'DEPENDS += +OPENSSL_WITH_COMPRESSION:zlib' \
    >> "$curl_fixture/duplicate-openssl.Makefile"
if sh "$CNO_BUILDS_ROOT/scripts/normalize-openwrt-depends.sh" \
    "$curl_fixture/duplicate-curl.Makefile" \
    "$curl_fixture/duplicate-openssl.Makefile" >/dev/null 2>&1; then
    die 'dependency normalizer accepted a duplicate OpenSSL conditional token'
fi
rm -rf -- "$curl_fixture"

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
    {
        count=split($1, formats, "+")
        for (i=1; i<=count; i++) {
            key=formats[i] SUBSEP $2 SUBSEP $3
            if (key in job_seen) {
                print FILENAME ":" FNR ": duplicate OpenWrt job: " formats[i] " " $2 "/" $3 > "/dev/stderr"
                bad=1
            }
            job_seen[key]=1
        }
    }
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
         .rust_features == "aarch64-no-crypto" or
         .rust_features == "arm-soft-nofp" or
         .rust_features == "arm-hard-d16" or
         .rust_features == "arm-hard-neon") and
        (.endian == "little" or .endian == "big") and
        (.float_abi == "hard" or .float_abi == "soft" or .float_abi == "none") and
        (.wasm == "ON" or .wasm == "OFF"))' >/dev/null
printf '%s' "$openwrt_matrix" | jq -e \
    'group_by([.format, .target, .subtarget]) | all(.[]; length == 1)' >/dev/null

# ARCH_PACKAGES is the user-facing OpenWrt compatibility identifier. Keep the
# SDK target/subtarget as a suffix because two SDKs may share that package
# architecture while using different CPU tuning (for example mt7620/mt7621).
grep -Fq 'name: OpenWrt ${{ matrix.format }} ${{ matrix.expected_arch }} (${{ matrix.target }}/${{ matrix.subtarget }})' \
    "$CNO_BUILDS_ROOT/.github/workflows/packages.yml" \
    || die 'OpenWrt job names must lead with the official package architecture'
grep -Fq 'packages-openwrt-${{ matrix.format }}-${{ matrix.expected_arch }}-${{ matrix.target }}-${{ matrix.subtarget }}' \
    "$CNO_BUILDS_ROOT/.github/workflows/packages.yml" \
    || die 'OpenWrt artifacts must include the official package architecture'
grep -Fq 'openwrt-${release}-${expected_arch}-${target}-${subtarget}.${format}' \
    "$CNO_BUILDS_ROOT/scripts/build-openwrt.sh" \
    || die 'OpenWrt release assets must include the official package architecture'
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
        if .rust_features == "aarch64-no-crypto" then
            .rust_target == "aarch64-unknown-linux-musl" and .float_abi == "none"
        elif .rust_features == "arm-soft-nofp" then
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
for compile_call in \
    '$(call Build/Compile/Default,cjsc qjsc)' \
    '$(call Build/Compile/Default,cjsc)' \
    '$(call Build/Compile/Default)'
do
    grep -Fq "$compile_call" "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
        || die "OpenWrt package recipe bypasses the official CMake compile macro: $compile_call"
done
if rg -n '^[[:space:]]*[+]?\$\(NINJA\)' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" >/dev/null; then
    die 'OpenWrt package recipe must not bypass Build/Compile/Default with a direct Ninja call'
fi
grep -Fq '$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/cno' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt package must consume the CMake-installed runtime from PKG_INSTALL_DIR'
grep -Fq '$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/lib/cno/ext/oxc.so' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt package must consume the CMake-installed OXC module from PKG_INSTALL_DIR'
grep -Fq 'CNO_OPENWRT_DEPENDS?=+ca-bundle +libc +libcurl +libopenssl +libsqlite3 +libffi +libexpat +zlib' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile" \
    || die 'OpenWrt dependencies must use logical package names so development files are staged'
if grep -Eq 'CNO_OPENWRT_DEPENDS.*(libcurl4|libopenssl3|libsqlite3-0)' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile"; then
    die 'OpenWrt recipes must not use generated ABI-suffixed repository package names'
fi
if grep -Eq 'cp[[:space:]]+-aL[[:space:]]' \
    "$CNO_BUILDS_ROOT/packaging/openwrt/Makefile"; then
    die 'OpenWrt QEMU sysroot copies must preserve SDK symlinks (x86 lib64 points to .)'
fi
grep -Fq 'patch --dry-run --forward --silent -d "$libuv_root" -p1 < "$libuv_patch"' \
    "$CNO_BUILDS_ROOT/patches/cno-cli-openwrt-cross-abi.patch" \
    || die 'cno source patch must apply the RISC-V libuv fix independently of nested Git metadata'
grep -Fq "grep -Fq '.insn 0x0100000f'" \
    "$CNO_BUILDS_ROOT/patches/cno-cli-openwrt-cross-abi.patch" \
    || die 'cno source patch must reject a silently skipped RISC-V libuv fix'
grep -Fq "grep -Fq '.word 0x0100000f'" \
    "$CNO_BUILDS_ROOT/patches/cno-cli-openwrt-cross-abi.patch" \
    || die 'cno source patch must prove the RISC-V libuv replacement is present'

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
awk -F '\t' '!/^#/ && NF { print $1, $2, $3, $4 }' "$CNO_BUILDS_ROOT/config/openwrt-targets.tsv" \
    | while read -r formats target subtarget expected_arch; do
        case "+$formats+" in
            *+ipk+*)
                stable="cno-1.2.3-r${CNO_PACKAGE_RELEASE}-openwrt-24.10.0-${expected_arch}-${target}-${subtarget}.ipk"
                touch "$release_input/$stable" "$release_input/$stable.buildinfo"
                ;;
        esac
        case "+$formats+" in
            *+apk+*)
                snapshot="cno-1.2.3-r${CNO_PACKAGE_RELEASE}-openwrt-snapshots-${expected_arch}-${target}-${subtarget}.apk"
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

