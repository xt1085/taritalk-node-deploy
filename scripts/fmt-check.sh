#!/usr/bin/env bash
# Check shell formatting with shfmt (diff mode; changes nothing).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/shell-files.sh
source scripts/shell-files.sh
mapfile -t files < <(shell_files)
printf 'shfmt %s\n' "$(shfmt --version)"
shfmt --diff --indent 2 --case-indent "${files[@]}"
