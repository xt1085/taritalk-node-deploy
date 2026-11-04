# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# logs: the node's base_layer.log, read with tail. Uses the sandbox of
# tests/test_status.sh (setup_status, run_ops); the log has 150 lines.

readonly LOG_PATH_IN_SB=var/log/tari/log/base_node/base_layer.log

# use_tail_recorder: a tail that records its argv (NUL-separated) in
# $TEST_TMP/tail-args and then runs the real tail without -F, so that
# --follow returns.
use_tail_recorder() {
  cat >"$TEST_TMP/fakebin/tail" <<REC
#!/usr/bin/env bash
printf '%s\0' "\$@" >'$TEST_TMP/tail-args'
args=()
for a in "\$@"; do [[ \$a == -F ]] || args+=("\$a"); done
exec '$(command -v tail)' "\${args[@]}"
REC
  chmod +x "$TEST_TMP/fakebin/tail"
}

# assert_tail_args ARG...: the recorded tail argv is exactly ARG...
assert_tail_args() {
  local -a got
  mapfile -d '' -t got <"$TEST_TMP/tail-args" || fail "tail was not run"
  [[ ${got[*]@Q} == "${*@Q}" ]] || fail "tail argv: ${got[*]@Q}"
}

test_logs_shows_the_last_100_lines_by_default() {
  setup_status
  use_tail_recorder
  run_ops logs
  assert_status 0
  assert_stderr_empty
  assert_stdout_equals "$(seq 51 150 | sed 's/^/log line /')"
  assert_tail_args -n 100 -- "$SB/$LOG_PATH_IN_SB"
}

test_logs_accepts_lines_from_1_to_1000() {
  setup_status
  use_tail_recorder
  run_ops logs --lines 1
  assert_status 0
  assert_stdout_equals "log line 150"
  assert_tail_args -n 1 -- "$SB/$LOG_PATH_IN_SB"
  seq 1 1200 | sed 's/^/log line /' >"$SB/$LOG_PATH_IN_SB"
  run_ops logs --lines 1000
  assert_status 0
  assert_stdout_equals "$(seq 201 1200 | sed 's/^/log line /')"
  assert_tail_args -n 1000 -- "$SB/$LOG_PATH_IN_SB"
}

test_logs_follow_uses_tail_F_in_either_order() {
  setup_status
  use_tail_recorder
  run_ops logs --follow
  assert_status 0
  assert_tail_args -n 100 -F -- "$SB/$LOG_PATH_IN_SB"
  run_ops logs --lines 7 --follow
  assert_status 0
  assert_tail_args -n 7 -F -- "$SB/$LOG_PATH_IN_SB"
  run_ops logs --follow --lines 7
  assert_status 0
  assert_tail_args -n 7 -F -- "$SB/$LOG_PATH_IN_SB"
  assert_stdout_equals "$(seq 144 150 | sed 's/^/log line /')"
}

test_logs_follow_keeps_reading_new_lines() {
  setup_status
  # The real tail -F, in a separate process stopped by a time limit, as a
  # user would stop it with Ctrl+C.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$REPO_ROOT/deploy.sh" "$REPO_ROOT/lib/fetch.sh" \
      "$REPO_ROOT/lib/install.sh" "$REPO_ROOT/lib/status.sh"
    printf 'is_root() { return 0; }\nSYSROOT=%q\nROOT_IDS=%q\nOPS_PATH=%q\n' "$SB" \
      "$(id -u):$(id -g)" "$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin"
    printf 'cmd_logs "$@"\n'
  } >"$TEST_TMP/logs.sh"
  (
    sleep 1
    echo "appended line" >>"$SB/$LOG_PATH_IN_SB"
  ) &
  timeout -s INT 3 bash "$TEST_TMP/logs.sh" --lines 2 --follow >"$TEST_TMP/follow.out" 2>&1
  status=$?
  wait
  [[ $status == 124 ]] || fail "expected to follow until stopped, got exit $status"
  [[ $(<"$TEST_TMP/follow.out") == $'log line 149\nlog line 150\nappended line' ]] ||
    fail "follow output: $(<"$TEST_TMP/follow.out")"
}

test_logs_rejects_bad_options_with_exit_2_before_root_checks() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  local -a cases=(
    "--lines|--lines requires a value"
    "--lines --follow|--lines requires a value"
    "--lines -5|--lines requires a value"
    "--follow --lines|--lines requires a value"
    "--lines 0|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 1001|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 10000|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines +5|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 05|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 0x10|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 1e2|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 10.0|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines ١٠|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines ５|invalid --lines value (expected a whole number from 1 to 1000)"
    "--lines 5 --lines 6|--lines given more than once"
    "--follow --follow|--follow given more than once"
    "--lines 5 --follow --follow|--follow given more than once"
    "-n 5|unknown logs option '-n'"
    "-f|unknown logs option '-f'"
    "--lines=5|unknown logs option '--lines=5'"
    "/etc/shadow|unknown logs option '/etc/shadow'"
    "--bogus|unknown logs option '--bogus'"
  )
  local c args message
  for c in "${cases[@]}"; do
    IFS='|' read -r args message <<<"$c"
    # shellcheck disable=SC2086 # Split each case into arguments.
    run_cli_with_path "$TEST_TMP/bare-bin" logs $args
    [[ $status == 2 ]] || fail "[$args]: expected exit 2, got $status"
    assert_stdout_empty
    assert_stderr_contains "error: $message"
    # shellcheck disable=SC2154 # Set by run_cli_with_path (tests/lib.sh).
    [[ $stderr != *"Please run as root"* ]] || fail "[$args]: checked root before the arguments"
  done
  # Empty and blank values.
  local v
  for v in "" " " " 5" "5 " $'5\n'; do
    run_cli_with_path "$TEST_TMP/bare-bin" logs --lines "$v"
    [[ $status == 2 ]] || fail "[$v]: expected exit 2, got $status"
    [[ $stderr == *"--lines requires a value"* || $stderr == *"invalid --lines value"* ]] ||
      fail "[$v]: $stderr"
  done
  [[ -z $(<"$TRACE_FILE") ]] || fail "usage errors ran commands: $(<"$TRACE_FILE")"
}

test_logs_refuses_a_missing_or_unsafe_log_file() {
  local -a cases=(
    "rm -- \$LOG|'/var/log/tari/log/base_node/base_layer.log' does not exist"
    "rm -- \$LOG && ln -s /etc/passwd \$LOG|'/var/log/tari/log/base_node/base_layer.log' is not a regular file"
    "mv -- \$LOG \$LOG.real && ln -s base_layer.log.real \$LOG|'/var/log/tari/log/base_node/base_layer.log' is not a regular file"
    "rm -- \$LOG && mkdir \$LOG|'/var/log/tari/log/base_node/base_layer.log' is not a regular file"
    "rm -- \$LOG && mkfifo \$LOG|'/var/log/tari/log/base_node/base_layer.log' is not a regular file"
    "mv -- \$SB/var/log/tari/log/base_node \$SB/var/log/tari/log/real && ln -s real \$SB/var/log/tari/log/base_node|'/var/log/tari/log/base_node' is not a directory"
    "mv -- \$SB/var/log/tari \$SB/var/log/real && ln -s real \$SB/var/log/tari|'/var/log/tari' is not a directory"
    "rm -rf -- \$SB/var/log/tari|'/var/log/tari' is not a directory"
  )
  local c action message
  for c in "${cases[@]}"; do
    IFS='|' read -r action message <<<"$c"
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/curl-log" "$TEST_TMP/tail-args"
    setup_status
    use_tail_recorder
    # shellcheck disable=SC2034 # Used by the eval'd actions.
    local LOG=$SB/$LOG_PATH_IN_SB
    eval "$action" || fail "[$action]: setup failed"
    run_ops logs --follow
    [[ $status == 1 ]] || fail "[$action]: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "$message"
    [[ ! -e $TEST_TMP/tail-args ]] || fail "[$action]: tail was run"
  done
}

test_logs_reads_only_base_layer_log_without_journal_or_writes() {
  setup_status
  make_ops_sandbox "$TEST_TMP/ops-bin"
  export TRACE_FILE=$TEST_TMP/trace OPS_TEST_PATH=$TEST_TMP/ops-bin
  : >"$TRACE_FILE"
  local d=$SB/var/log/tari/log/base_node
  echo "network" >"$d/network.log"
  echo "rotated" >"$d/base_layer.1.log"
  local before after
  before=$(snapshot "$SB" "$TMPDIR")
  run_ops logs --lines 1000
  assert_status 0
  after=$(snapshot "$SB" "$TMPDIR")
  assert_stdout_equals "$(seq 1 150 | sed 's/^/log line /')"
  [[ $before == "$after" ]] || fail "files changed: $(diff <(echo "$before") <(echo "$after"))"
  [[ -z $(<"$TRACE_FILE") ]] || fail "forbidden commands invoked: $(<"$TRACE_FILE")"
  ! grep -qvE '^$' "$FAKE_SYS/calls" || fail "system calls: $(<"$FAKE_SYS/calls")"
}
