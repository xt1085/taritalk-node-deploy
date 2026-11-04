# shellcheck shell=bash
# Assertion helpers for tests/run.sh. Every assertion exits the current test
# subshell with status 1 on failure.

# run_cli ARGS...: run the CLI, capturing $status, $stdout and $stderr.
# A hung invocation is killed after RUN_CLI_TIMEOUT seconds (status 124).
run_cli() {
  timeout "${RUN_CLI_TIMEOUT:-10}" "$CLI" "$@" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

fail() {
  printf '  assertion failed: %s\n' "$1" >&2
  printf '  status: %s\n  stdout:\n%s\n  stderr:\n%s\n' \
    "${status-}" "${stdout-}" "${stderr-}" >&2
  exit 1
}

assert_status() {
  [[ ${status-} == "$1" ]] || fail "expected exit status $1, got ${status-unset}"
}

assert_stdout_contains() {
  [[ ${stdout-} == *"$1"* ]] || fail "stdout does not contain: $1"
}

assert_stderr_contains() {
  [[ ${stderr-} == *"$1"* ]] || fail "stderr does not contain: $1"
}

assert_stdout_equals() {
  [[ ${stdout-} == "$1" ]] || fail "stdout is not exactly: $1"
}

assert_stdout_empty() {
  [[ -z ${stdout-} ]] || fail "expected empty stdout"
}

assert_stderr_empty() {
  [[ -z ${stderr-} ]] || fail "expected empty stderr"
}

# run_cli_with_path PATH ARGS...: like run_cli, but the CLI (and the bash
# that runs it) sees only the given PATH.
run_cli_with_path() {
  local path=$1
  shift
  timeout "${RUN_CLI_TIMEOUT:-10}" env PATH="$path" "$CLI" "$@" \
    >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# assert_stdout_has_line LINE: stdout contains LINE as a complete line.
assert_stdout_has_line() {
  [[ $'\n'"${stdout-}"$'\n' == *$'\n'"$1"$'\n'* ]] ||
    fail "stdout has no line: $1"
}

# as_root CMD...: run CMD as root (directly when already root, else via
# passwordless sudo). Only test_root_* tests use this; the runner guarantees
# one of the two is available before running them.
as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    # The real sudo, not tests/guard/sudo (which fails any product use).
    "$(type -aP sudo | grep -v '/guard/' | head -n 1)" -n "$@"
  fi
}
