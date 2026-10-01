#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
source "$project_root/Scripts/swiftpm-env.sh"
exec python3 "$project_root/Scripts/gui_regression.py" "$@"
