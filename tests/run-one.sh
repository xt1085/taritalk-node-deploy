#!/usr/bin/env bash
# Run a single test function in a fresh shell: tests/run-one.sh NAME.
# Invoked by tests/run.sh (possibly as an unprivileged user) with TESTS_DIR,
# REPO_ROOT, CLI, FIXTURES and TEST_TMP exported.
set -uo pipefail
umask 022
# Any accidental real network use fails loudly (see tests/guard/curl).
export PATH="$TESTS_DIR/guard:$PATH"
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
for test_file in "$TESTS_DIR"/test_*.sh; do
  # shellcheck source=/dev/null # Test files are discovered at run time.
  source "$test_file"
done
cd -- "$TEST_TMP" || exit 1
# A private TMPDIR per test, so leftovers are detectable.
export TMPDIR=$TEST_TMP/tmp
mkdir -p -- "$TMPDIR" || exit 1
"$1"
