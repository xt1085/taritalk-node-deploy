# shellcheck shell=bash
# Tests that need real root (run as root, or via `sudo -n`; see tests/run.sh).

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
test_root_fetch_is_refused_before_any_network_or_write() {
  local mode
  mkdir -p "$TEST_TMP/bin" "$TEST_TMP/dest" "$TEST_TMP/curl-log"
  ln -s "$TESTS_DIR/fakes/curl" "$TEST_TMP/bin/curl"
  for mode in fetch dry-run latest; do
    local -a args=(fetch --destination "$TEST_TMP/dest")
    case "$mode" in
      fetch) args+=(--version 6.0.1-pre.2) ;;
      dry-run) args+=(--version 6.0.1-pre.2 --dry-run) ;;
      latest) args+=(--dry-run) ;;
    esac
    stdout=$(as_root env PATH="$TEST_TMP/bin:$PATH" FAKE_WEB_ROOT="$TEST_TMP/web" \
      FAKE_CURL_LOG_DIR="$TEST_TMP/curl-log" "$CLI" "${args[@]}" 2>"$TEST_TMP/err")
    status=$?
    stderr=$(<"$TEST_TMP/err")
    [[ $status == 1 ]] || fail "$mode: expected exit 1 as root, got $status"
    assert_stdout_empty
    assert_stderr_contains "fetch must not run as root"
  done
  [[ ! -e $TEST_TMP/curl-log/1 ]] || fail "root fetch made a network request"
  [[ -z $(ls -A "$TEST_TMP/dest") ]] || fail "root fetch wrote to the destination"

  # --help needs no privileges and is not refused.
  stdout=$(as_root "$CLI" fetch --help) || fail "fetch --help failed as root"
  assert_stdout_contains "Usage: ./deploy.sh fetch"
}

# The runner, started as root from a checkout the unprivileged test user
# cannot read (e.g. under /root), stops with one clear error instead of
# failing every ordinary test with "Permission denied".
test_root_runner_reports_an_unreadable_checkout_once() {
  local private=$TEST_TMP/private suites=$TEST_TMP/suites out
  mkdir -p "$private/repo" "$suites"
  cp -a "$REPO_ROOT/deploy.sh" "$REPO_ROOT/lib" "$REPO_ROOT/tests" "$private/repo/"
  chmod 755 "$suites"
  chmod 700 "$private"
  out=$(as_root env TARITALK_TEST_ROOT="$suites" \
    bash "$private/repo/tests/run.sh" test_version_prints_stable_version_and_exits_zero 2>&1)
  status=$?
  [[ $status == 1 ]] || fail "expected exit 1, got $status: $out"
  [[ $out == "error: unprivileged test user (uid "*") cannot traverse or read the repository at $private/repo; copy the checkout to a path that user can read (for example under /home) or set TARITALK_TEST_UID and TARITALK_TEST_GID to a user that can" ]] ||
    fail "expected exactly one clear error, got: $out"

  # Control: the same copy, once readable, runs normally.
  chmod 755 "$private"
  out=$(as_root env TARITALK_TEST_ROOT="$suites" \
    bash "$private/repo/tests/run.sh" test_version_prints_stable_version_and_exits_zero 2>&1)
  status=$?
  [[ $status == 0 && $out == *"1 tests, 1 passed, 0 failed, 0 skipped"* ]] ||
    fail "readable checkout: expected a passing run, got $status: $out"
  [[ -z $(ls -A "$suites") ]] || fail "suite directories left behind: $(ls -A "$suites")"
}
