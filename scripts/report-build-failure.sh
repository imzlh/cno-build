#!/bin/sh
set -eu

log=${1:?Usage: report-build-failure.sh LOG TITLE}
title=${2:?Missing failure title}

[ -f "$log" ] || {
    printf 'failure log not found: %s\n' "$log" >&2
    exit 2
}

temp_parent=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
mkdir -p "$temp_parent"
work=$(mktemp -d "$temp_parent/cno-build-report.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

# Parallel package builds often keep printing successful dependency output
# after cno itself has failed. Prefer the first fatal compiler/configure
# diagnostic over the final top-level make error, then retain the true end of
# the log too. CMake's `-- Could NOT find ...` status lines are deliberately
# excluded: dependency projects such as nghttp2 print them for optional
# features and continue configuring successfully.
first_diagnostic=$(
    awk '
        {
            text = tolower($0)
            # The OpenWrt downloader logs curl failures while cycling mirrors;
            # a later mirror can and commonly does succeed.
            if (text ~ /^curl: \([0-9]+\).*error:/) next
            if (text ~ /fatal error:|(^|[[:space:]])error:|failed:/ ||
                text ~ /cmake error|configure: error|undefined reference/ ||
                text ~ /collect2: error|ninja:.*build stopped/ ||
                text ~ /cannot find[[:space:]]+-l|unable to select packages/ ||
                text ~ /error relocating|unsupported relocation type/ ||
                text ~ /segmentation fault|illegal instruction|bus error/ ||
                text ~ /exec format error|staged package is missing/ ||
                text ~ /does not export the quickjs api/) {
                print NR
                exit
            }
        }
    ' "$log"
)

if [ -z "$first_diagnostic" ]; then
    first_diagnostic=$(
        awk '
            {
                text = tolower($0)
                if (text ~ /no rule to make target|no such file or directory/ ||
                    text ~ /cannot find|command not found/ ||
                    text ~ /make(\[[0-9]+\])?: \*\*\*.*error [0-9]+/) {
                    print NR
                    exit
                }
            }
        ' "$log"
    )
fi

if [ -n "$first_diagnostic" ]; then
    {
        printf 'First high-signal diagnostic (log line %s):\n' "$first_diagnostic"
        # Put the matched line first so it survives the annotation byte limit.
        # Truncate every line: a FAILED: match is typically followed by one
        # multi-kilobyte compiler command line that would otherwise consume
        # the whole budget before the actual compiler error appears.
        awk -v first="$first_diagnostic" \
            'NR >= first && NR <= first + 18 { print substr($0, 1, 240) }' "$log"
        start=$((first_diagnostic - 5))
        [ "$start" -gt 0 ] || start=1
        if [ "$start" -lt "$first_diagnostic" ]; then
            printf '\nImmediately preceding lines:\n'
            awk -v start="$start" -v first="$first_diagnostic" \
                'NR >= start && NR < first { print substr($0, 1, 240) }' "$log"
        fi
    } > "$work/diagnostic"
else
    printf '%s\n' 'No high-signal diagnostic line was recognized.' > "$work/diagnostic"
fi

{
    printf '%s\n' '=== FIRST DIAGNOSTIC ==='
    head -c 1800 "$work/diagnostic"
    printf '\n%s\n' '=== FINAL LOG BYTES ==='
    tail -c 850 "$log"
} > "$work/annotation"

{
    printf '::group::%s log tail\n' "$title"
    tail -n 200 "$log"
    printf '%s\n' '::endgroup::'
} >&2

encoded_title=$(
    printf '%s' "$title" | awk '
        BEGIN { ORS="" }
        {
            gsub(/%/, "%25")
            gsub(/\r/, "%0D")
            gsub(/:/, "%3A")
            gsub(/,/, "%2C")
            if (NR > 1) printf "%%0A"
            printf "%s", $0
        }
    '
)
annotation=$(
    awk '
        BEGIN { ORS="" }
        {
            gsub(/%/, "%25")
            gsub(/\r/, "%0D")
            if (NR > 1) printf "%%0A"
            printf "%s", $0
        }
    ' "$work/annotation"
)
printf '::error title=%s::%s\n' "$encoded_title" "$annotation" >&2
