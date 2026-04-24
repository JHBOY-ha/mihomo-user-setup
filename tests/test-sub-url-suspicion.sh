#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_functions="$(mktemp)"
trap 'rm -f "$tmp_functions"' EXIT

awk '
    /^is_suspicious_sub_url\(\) \{/ { in_func = 1 }
    in_func { print }
    in_func && /^}/ { exit }
' "$repo_root/mihomo-user-setup.sh" > "$tmp_functions"

source "$tmp_functions"

assert_suspicious() {
    local url="$1"

    if ! is_suspicious_sub_url "$url"; then
        echo "Expected suspicious URL: $url" >&2
        return 1
    fi
}

assert_not_suspicious() {
    local url="$1"

    if is_suspicious_sub_url "$url"; then
        echo "Expected accepted URL: $url" >&2
        return 1
    fi
}

assert_not_suspicious "https://list.lemonclient.cc/api/v1/client/subscribe?token=289344378eb9ce757c815a1c4be61383"
assert_not_suspicious "https://example.com/subscribe?token=abc123"
assert_not_suspicious "https://example.com/sub?target=clash&insert=true"
assert_not_suspicious "https://example.com/sub?target=clash%26insert=true"

assert_suspicious "https://example.com/sub?target=clash"
assert_suspicious "https://example.com/sub?insert=true"
