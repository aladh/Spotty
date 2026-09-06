#!/usr/bin/env bash
set -euo pipefail

# The composite action changes PATH; BASH_ENV keeps this adapter ahead of its installer.
cli="$RUNNER_TEMP/thermos-cli/node_modules/.bin/opencode"
if [[ "$#" == 2 && "$1" == github && "$2" == run ]]; then
    cd "$GITHUB_WORKSPACE/source"
    unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
    exec > "$RUNNER_TEMP/thermos-review.log" 2>&1
    exec "$cli" --pure github run
fi
exec "$cli" "$@"
