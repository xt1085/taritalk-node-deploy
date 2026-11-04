#!/usr/bin/env bash
# Run the behavioral test suite. Optional argument: test-name glob.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
exec tests/run.sh "$@"
