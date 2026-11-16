#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
    printf '%s\n' \
        'Usage: verify-openwrt-disabled-options.sh CONFIG OPTION [OPTION ...]' >&2
    exit 2
fi

config_file=$1
shift
[ -f "$config_file" ] || {
    printf 'error: OpenWrt config not found: %s\n' "$config_file" >&2
    exit 1
}

for config_name do
    case $config_name in
        ''|*[!A-Z0-9_]*)
            printf 'error: invalid OpenWrt config option name: %s\n' \
                "$config_name" >&2
            exit 1
            ;;
    esac
    # A release may not define every optional feature. Kconfig either emits
    # "# CONFIG_NAME is not set" for a defined disabled symbol or omits an
    # unknown/invisible symbol. Both are safe. Any assignment means the option
    # survived as enabled or otherwise selected and must stop the build.
    if grep -q "^CONFIG_${config_name}=" "$config_file"; then
        printf 'error: SDK defconfig selected disabled CONFIG_%s\n' \
            "$config_name" >&2
        exit 1
    fi
done
