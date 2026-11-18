#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if (( $# > 1 )) || [[ "${1:-}" != "" && "${1:-}" != --test-only ]]; then
    echo "Usage: $0 [--test-only]" >&2
    exit 2
fi
ast_grep="${SPOTTY_AST_GREP:-ast-grep}"
expected_version="$(cat Scripts/ast-grep/version)"
if ! command -v "$ast_grep" >/dev/null 2>&1; then
    echo "Install ast-grep $expected_version (see docs/development/verification.md)." >&2
    exit 1
fi
if [[ "$("$ast_grep" --version)" != "ast-grep $expected_version" ]]; then
    echo "Source policies require ast-grep $expected_version; set SPOTTY_AST_GREP to that executable." >&2
    exit 1
fi
export SPOTTY_AST_GREP="$ast_grep"

# Required policy owners must exist and contain content, even when compiler jobs are skipped.
while IFS= read -r owner; do
    [[ -f "$owner" && -s "$owner" ]] || { echo "Missing or empty policy owner: $owner" >&2; exit 1; }
done < Scripts/ast-grep/required-files.txt

python3 -B Scripts/documentation_policy.py
ruby Scripts/check-ci-workflow.rb .github/workflows/ci.yml

if grep -nE "MockCatalog|PlaybackController|demo catalog" \
    "README.md" >&2; then
    echo "Mock catalog references remain" >&2
    exit 1
fi

if grep -nE 'security@example\.com|replace this placeholder' \
    "README.md" \
    "SECURITY.md" \
    "CONTRIBUTING.md" >&2; then
    echo "A public-facing security-contact placeholder remains" >&2
    exit 1
fi

rules='^(workflow-action-pins|workflow-checkout-credentials|workflow-explicit-permissions|workflow-shell-interpolation|ci-fail-closed|ci-read-permissions|script-no-xtrace|development-signing-input|source-gate-tests)$'
"$ast_grep" test --filter "$rules" --skip-snapshot-tests
python3 -B Scripts/test_source_policy.py
python3 -B Scripts/test_rune_workflow_policy.py
python3 -B -m unittest discover -s Scripts -p test_source_gate_policy.py
python3 -B Scripts/test_notices_policy.py
python3 -B Scripts/test_verify.py
python3 -B Scripts/test_harness_ui_smoke.py
python3 -B Scripts/test_report_size.py
python3 -B Scripts/test_ci_timings.py
npm test --prefix Scripts/agent-review-tests
if [[ "${1:-}" != --test-only ]]; then
    "$ast_grep" scan --filter "$rules" .github/workflows Scripts script Rune
fi
