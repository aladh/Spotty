#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/spotty-keychain-check.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
# Link fake Security operations: this executable never accesses any Keychain.
xcrun clang -Wall -Wextra -Werror \
    -I "$project_root/Sources/SpottyKeychainSupport/include" \
    "$project_root/Sources/SpottyKeychainSupport/SpottyKeychainSupport.c" \
    "$project_root/Tests/KeychainSupport/check.c" -o "$work_dir/check"
"$work_dir/check"
