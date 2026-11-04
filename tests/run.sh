#!/usr/bin/env bash
# Behavioral test runner.
#
# Usage: tests/run.sh [PATTERN]
#   Runs every test_* function defined in tests/test_*.sh whose name matches
#   the optional glob PATTERN (default: all). Each test runs in a fresh shell
#   with a private temporary directory under a suite directory this runner
#   creates in ${TARITALK_TEST_ROOT:-/tmp} and removes afterwards.
#
#   When run as root, ordinary tests run as an unprivileged user
#   (TARITALK_TEST_UID/GID, default 65534) because fetch refuses root.
#   test_root_* tests need real root: they run as root, or with `sudo -n`
#   when available; otherwise they are reported as SKIP, or fail when
#   TARITALK_REQUIRE_ROOT_TESTS=1 (as in CI).
set -uo pipefail
umask 022

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "$TESTS_DIR")
CLI="$REPO_ROOT/deploy.sh"
FIXTURES="$TESTS_DIR/fixtures"
export TESTS_DIR REPO_ROOT CLI FIXTURES

# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"
for test_file in "$TESTS_DIR"/test_*.sh; do
  # shellcheck source=/dev/null # Test files are discovered at run time.
  source "$test_file"
done

# Choose the suite root explicitly rather than trusting an inherited TMPDIR,
# and refuse locations fetch itself would refuse as a destination.
parent=$(realpath -e -- "${TARITALK_TEST_ROOT:-/tmp}") || {
  echo "error: test root ${TARITALK_TEST_ROOT:-/tmp} does not exist" >&2
  exit 1
}
case "$parent" in
  / | /etc | /etc/* | /opt | /opt/* | /usr | /usr/* | /var | /var/* | /bin | /bin/* | \
    /sbin | /sbin/* | /boot | /boot/* | /root | /root/* | /proc | /proc/* | /sys | \
    /sys/* | /dev | /dev/* | /run | /run/* | /lib | /lib/* | /lib64 | /lib64/*)
    echo "error: test root '$parent' is a system location; set TARITALK_TEST_ROOT" >&2
    exit 1
    ;;
esac
SUITE_TMP=$(mktemp -d "$parent/taritalk-tests.XXXXXXXX") || exit 1
chmod 755 "$SUITE_TMP"
cleanup_suite() {
  chmod -R u+rwX -- "$SUITE_TMP" 2>/dev/null
  rm -rf -- "$SUITE_TMP"
}
trap cleanup_suite EXIT
export TMPDIR=$SUITE_TMP

TEST_UID=${TARITALK_TEST_UID:-65534}
TEST_GID=${TARITALK_TEST_GID:-65534}
can_be_root=0
if ((EUID == 0)) || sudo -n true 2>/dev/null; then
  can_be_root=1
fi

pattern=${1:-*}
selected=()
while read -r _ _ name; do
  [[ $name == test_* ]] || continue
  # shellcheck disable=SC2053 # PATTERN is intentionally a glob.
  [[ $name == $pattern ]] && selected+=("$name")
done < <(declare -F)

# As root, ordinary tests run as TEST_UID from this checkout; if that user
# cannot reach it (e.g. a checkout under /root), every one of them would
# fail with "Permission denied". Say so once instead.
unprivileged=0
for name in "${selected[@]}"; do
  [[ $name == test_root_* ]] || unprivileged=1
done
if ((EUID == 0 && unprivileged)); then
  command -v setpriv >/dev/null || {
    echo "error: running the tests as root needs setpriv (util-linux)" >&2
    exit 1
  }
  # shellcheck disable=SC2016 # Expanded by the unprivileged bash.
  if ! setpriv --reuid="$TEST_UID" --regid="$TEST_GID" --clear-groups bash -c '
    cd -- "$1" && [[ -r deploy.sh && -x deploy.sh && -r lib/fetch.sh ]] &&
      cd tests && [[ -r run-one.sh && -r lib.sh && -x fakes/curl && -x guard/curl ]] &&
      cd fixtures' check "$REPO_ROOT" 2>/dev/null; then
    printf '%s\n' "error: unprivileged test user (uid $TEST_UID) cannot traverse or read the repository at $REPO_ROOT; copy the checkout to a path that user can read (for example under /home) or set TARITALK_TEST_UID and TARITALK_TEST_GID to a user that can" >&2
    exit 1
  fi
fi

passed=0
failed=0
skipped=0
failed_names=()

for name in "${selected[@]}"; do
  TEST_TMP=$(mktemp -d "$SUITE_TMP/t.XXXXXXXX") || exit 1
  chmod 755 "$TEST_TMP"
  runner=()
  if [[ $name == test_root_* ]]; then
    if ((!can_be_root)); then
      if [[ ${TARITALK_REQUIRE_ROOT_TESTS-} == 1 ]]; then
        printf 'FAIL %s (needs root or passwordless sudo)\n' "$name"
        failed=$((failed + 1))
        failed_names+=("$name")
      else
        printf 'SKIP %s (needs root or passwordless sudo)\n' "$name"
        skipped=$((skipped + 1))
      fi
      continue
    fi
  elif ((EUID == 0)); then
    chown "$TEST_UID:$TEST_GID" "$TEST_TMP"
    runner=(setpriv --reuid="$TEST_UID" --regid="$TEST_GID" --clear-groups
      env HOME="$TEST_TMP")
  fi
  if TEST_TMP=$TEST_TMP "${runner[@]}" bash "$TESTS_DIR/run-one.sh" "$name"; then
    printf 'ok   %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$name"
    failed=$((failed + 1))
    failed_names+=("$name")
  fi
done

total=$((passed + failed + skipped))
printf '\n%d tests, %d passed, %d failed, %d skipped\n' \
  "$total" "$passed" "$failed" "$skipped"
if ((total == 0)); then
  printf 'error: no tests matched pattern %s\n' "$pattern" >&2
  exit 1
fi
if ((failed > 0)); then
  printf 'failed: %s\n' "${failed_names[*]}" >&2
  exit 1
fi
