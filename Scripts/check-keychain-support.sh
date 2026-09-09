#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
    print -u2 "Keychain support checks require the Xcode command-line tools (xcrun clang)."
    exit 1
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/spotty-keychain-check.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
# Link fake Security operations: this executable never accesses any Keychain.
xcrun clang -Wall -Wextra -Werror \
    -I "$project_root/Sources/SpottyKeychainSupport/include" \
    "$project_root/Sources/SpottyKeychainSupport/SpottyKeychainSupport.c" \
    "$project_root/Tests/KeychainSupport/check.c" -o "$work_dir/check"
"$work_dir/check"
