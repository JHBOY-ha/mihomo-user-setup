#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
tmp_functions="$(mktemp)"
trap 'rm -rf "$tmp_home" "$tmp_functions"' EXIT

awk '{ if ($0 == "main \"$@\"") print ":"; else print }' \
    "$repo_root/mihomo-user-setup.sh" > "$tmp_functions"

HOME="$tmp_home"
export HOME
SHELL=/bin/bash
export SHELL

source "$tmp_functions"

printf 'existing_func() {\n    true\n}' > "$HOME/.bashrc"

setup_shell_aliases >/dev/null

if grep -q '}# >>> mihomo user proxy >>>' "$HOME/.bashrc"; then
    echo "Alias block marker was appended without a leading newline" >&2
    exit 1
fi

if ! grep -qx '# >>> mihomo user proxy >>>' "$HOME/.bashrc"; then
    echo "Alias block start marker is not on its own line" >&2
    exit 1
fi

cat > "$HOME/.bashrc" <<'RC_EOF'
existing_func() {
    true
}# >>> mihomo user proxy >>>
proxy1_on() {
    :
}
# <<< mihomo user proxy <<<
RC_EOF

remove_mihomo_shell_aliases "$HOME/.bashrc"

if ! grep -qx '}' "$HOME/.bashrc"; then
    echo "Cleanup did not preserve content before an embedded start marker" >&2
    exit 1
fi

if grep -q 'mihomo user proxy' "$HOME/.bashrc"; then
    echo "Cleanup did not remove the mihomo alias block" >&2
    exit 1
fi
