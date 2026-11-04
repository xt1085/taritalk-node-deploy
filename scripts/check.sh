#!/usr/bin/env bash
# Run all quality gates: behavioral tests, ShellCheck, and shfmt check.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
scripts/test.sh
scripts/lint.sh
scripts/fmt-check.sh
echo "all quality gates passed"
