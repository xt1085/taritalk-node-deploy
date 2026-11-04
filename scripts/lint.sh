#!/usr/bin/env bash
# Run ShellCheck on every shell source in the repository.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/shell-files.sh
source scripts/shell-files.sh
mapfile -t files < <(shell_files)
shellcheck --version | sed -n 2p
shellcheck --external-sources "${files[@]}"
