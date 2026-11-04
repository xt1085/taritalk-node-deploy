# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# status: a read-only view of a node installed by lib/install.sh. Never
# touches the real system: systemctl and runuser are tests/fakes/sys, curl is
# tests/fakes/curl (the Wallet Query answer is a file), anything else that
# reaches the system is stopped by tests/guard, and every path lives in a
# sandbox root ($SB) that lib/status.sh is pointed at when sourced.

readonly STATUS_RELEASE=minotari-6.0.0-linux-arm64-0123456789abcdef
readonly TIP_URL=http://127.0.0.1:9000/get_tip_info
readonly TIP_SYNCING='{"metadata":{"best_block_height":172497},"is_synced":false}'
readonly HEALTHY_LISTENERS="0.0.0.0:18189 127.0.0.1:9000 127.0.0.1:9050 127.0.0.1:9051 127.0.0.1:40123"

# set_listeners ADDRESS:PORT...: the sandbox's /proc/net/tcp and tcp6 list
# exactly these listening sockets (IPv6: only [::] and [::1]).
set_listeners() {
  local entry ip port a b c d n=0 m=0
  local tcp tcp6
  tcp='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'$'\n'
  tcp6=$tcp
  for entry in "$@"; do
    ip=${entry%:*} port=${entry##*:}
    case "$ip" in
      '[::]')
        printf -v tcp6 '%s%4d: %s:%04X 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1\n' \
          "$tcp6" "$m" 00000000000000000000000000000000 "$port" "$((2000 + m))"
        m=$((m + 1))
        ;;
      '[::1]')
        printf -v tcp6 '%s%4d: %s:%04X 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1\n' \
          "$tcp6" "$m" 00000000000000000000000001000000 "$port" "$((2000 + m))"
        m=$((m + 1))
        ;;
      *)
        IFS=. read -r a b c d <<<"$ip"
        printf -v tcp '%s%4d: %02X%02X%02X%02X:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1\n' \
          "$tcp" "$n" "$d" "$c" "$b" "$a" "$port" "$((1000 + n))"
        n=$((n + 1))
        ;;
    esac
  done
  # An established connection on 9000 is not a listener.
  printf -v tcp '%s%4d: 0100007F:2328 0100007F:9C40 01 00000000:00000000 00:00000000 00000000     0        0 %d 1\n' \
    "$tcp" "$n" 3999
  printf '%s' "$tcp" >"$SB/proc/net/tcp"
  printf '%s' "$tcp6" >"$SB/proc/net/tcp6"
}

# tip_info BODY: what the fake Wallet Query answers.
tip_info() {
  mkdir -p "$TEST_TMP/web/127.0.0.1:9000"
  printf '%s' "$1" >"$TEST_TMP/web/127.0.0.1:9000/get_tip_info"
}

# setup_status: a healthy, syncing node as lib/install.sh leaves it.
setup_status() {
  SB=$TEST_TMP/sysroot
  local d
  for d in etc etc/systemd etc/systemd/system opt opt/tari opt/tari/releases \
    "opt/tari/releases/$STATUS_RELEASE" var var/lib var/lib/tari var/log var/log/tari \
    var/log/tari/log var/log/tari/log/base_node proc proc/net; do
    mkdir -p "$SB/$d"
    chmod 755 "$SB/$d"
  done
  write_fake_node "$SB/opt/tari/releases/$STATUS_RELEASE/minotari_node" "minotari_node 6.0.0"
  ln -s "releases/$STATUS_RELEASE" "$SB/opt/tari/current"
  cp "$REPO_ROOT/templates/minotari-mainnet.service" "$SB/etc/systemd/system/"
  printf '%s=%s\n' format 1 tool_version 0.1.0 tag v6.0.0 version 6.0.0 \
    platform linux-arm64 release_dir "/opt/tari/releases/$STATUS_RELEASE" \
    public_ip 1.2.3.4 >"$SB/var/lib/tari/taritalk-install-state"
  chmod 600 "$SB/var/lib/tari/taritalk-install-state"
  seq 1 150 | sed 's/^/log line /' >"$SB/var/log/tari/log/base_node/base_layer.log"

  FAKE_SYS=$TEST_TMP/fakesys
  mkdir -p "$FAKE_SYS" "$TEST_TMP/fakebin"
  : >"$FAKE_SYS/calls"
  : >"$FAKE_SYS/listeners"
  touch "$FAKE_SYS/active.minotari-mainnet.service" "$FAKE_SYS/enabled.minotari-mainnet.service" \
    "$FAKE_SYS/active.tor@default.service" "$FAKE_SYS/enabled.tor.service"
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/systemctl"
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/runuser"
  use_fake_curl
  # shellcheck disable=SC2086 # Space-separated address list.
  set_listeners $HEALTHY_LISTENERS
  tip_info "$TIP_SYNCING"
  export FAKE_SYS FAKE_SYSROOT=$SB SB
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_ops COMMAND ARGS...: lib/status.sh's cmd_COMMAND, run as "root"
# against the sandbox. Sets status/stdout/stderr.
run_ops() {
  local cmd=$1
  shift
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    # shellcheck source=lib/status.sh
    source "$REPO_ROOT/lib/status.sh"
    # shellcheck disable=SC2317,SC2329 # Called by lib/status.sh.
    is_root() { return 0; }
    SYSROOT=$SB
    ROOT_IDS=${OPS_ROOT_IDS:-"$(id -u):$(id -g)"}
    OPS_PATH=${OPS_TEST_PATH:-$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin}
    CHILD_PATH=${OPS_TEST_PATH:-$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin}
    STATUS_PROBE_SECONDS=${OPS_WAIT-10}
    STATUS_QUERY_SECONDS=${OPS_WAIT-10}
    "cmd_$cmd" "$@"
  ) </dev/null >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# assert_status_lines LINE...: stdout is exactly the status block.
assert_status_lines() {
  local want
  printf -v want '%s\n' "$@"
  [[ $stdout == "${want%$'\n'}" ]] || fail "status block differs; expected:
${want%$'\n'}"
}

healthy_block() {
  assert_status_lines "Minotari node status" \
    "Version: minotari_node 6.0.0" \
    "Node service: active (enabled)" \
    "Tor service: active (enabled)" \
    "Restarts: 0" \
    "Sync: $1" \
    "Block height: $2" \
    "P2P listener: ready (18189)" \
    "Wallet Query: ready (127.0.0.1:9000)"
}

# --- command line --------------------------------------------------------------

test_status_and_logs_help_work_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" status --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh status"
  assert_stdout_contains "Must be run as root"
  assert_stdout_contains "http://127.0.0.1:9000/get_tip_info"
  run_cli_with_path "$TEST_TMP/bare-bin" logs --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh logs [--lines N] [--follow]"
  assert_stdout_contains "/var/log/tari/log/base_node/base_layer.log"
  assert_stdout_contains "Must be run as root"
  run_cli_with_path "$TEST_TMP/bare-bin" logs --lines 5 --follow --help
  assert_status 0
  [[ -z $(<"$TRACE_FILE") ]] || fail "help ran commands: $(<"$TRACE_FILE")"
}

test_status_usage_errors_exit_2_before_root_checks() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  local c
  for c in "--bogus" "extra" "--lines 5" "--follow" "-v" "--help=x"; do
    # shellcheck disable=SC2086 # Split each case into arguments.
    run_cli_with_path "$TEST_TMP/bare-bin" status $c
    [[ $status == 2 ]] || fail "[$c]: expected exit 2, got $status"
    assert_stdout_empty
    [[ $stderr == *"unknown status option '${c%% *}'"* ]] || fail "[$c]: $stderr"
    [[ $stderr != *"Please run as root"* ]] || fail "[$c]: checked root before the arguments"
  done
  [[ -z $(<"$TRACE_FILE") ]] || fail "usage errors ran commands: $(<"$TRACE_FILE")"
}

test_status_and_logs_as_non_root_say_please_run_as_root() {
  local c
  for c in "status" "logs" "logs --lines 1" "logs --follow" "logs --lines 1000 --follow"; do
    # shellcheck disable=SC2086 # Split into arguments.
    run_cli $c </dev/null
    [[ $status == 1 ]] || fail "[$c]: expected exit 1, got $status"
    assert_stdout_empty
    [[ $stderr == "Please run as root." ]] || fail "[$c]: unexpected stderr: $stderr"
  done
}

# --- healthy node ----------------------------------------------------------------

test_status_reports_a_healthy_syncing_node() {
  setup_status
  run_ops status
  assert_status 0
  assert_stderr_empty
  healthy_block syncing 172497
}

test_status_reports_a_synced_node() {
  setup_status
  tip_info '{"metadata":{"best_block_height":172600,"other":"x"},"is_synced":true,"extra":[1]}'
  run_ops status
  assert_status 0
  assert_stderr_empty
  healthy_block synced 172600
}

test_status_accepts_block_height_zero() {
  setup_status
  tip_info '{"metadata":{"best_block_height":0},"is_synced":false}'
  run_ops status
  assert_status 0
  healthy_block syncing 0
}

test_status_accepts_p2p_on_ipv6_any_and_restarts_above_zero() {
  setup_status
  set_listeners '[::]:18189' 127.0.0.1:9000
  FAKE_NRESTARTS=3 run_ops status
  assert_status 0
  assert_stderr_empty
  assert_stdout_has_line "P2P listener: ready (18189)"
  assert_stdout_has_line "Restarts: 3"
}

# --- unhealthy node: every field is still printed, exit 1 ------------------------

test_status_reports_inactive_or_disabled_services() {
  local -a cases=(
    "active.minotari-mainnet.service|Node service: inactive (enabled)|minotari-mainnet.service is not active (inactive)"
    "enabled.minotari-mainnet.service|Node service: active (disabled)|minotari-mainnet.service is not enabled (disabled)"
    "active.tor@default.service|Tor service: inactive (enabled)|tor@default.service is not active (inactive)"
    "enabled.tor.service|Tor service: active (disabled)|tor.service is not enabled (disabled)"
  )
  local c file line problem
  for c in "${cases[@]}"; do
    IFS='|' read -r file line problem <<<"$c"
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web"
    setup_status
    rm -- "$FAKE_SYS/$file"
    run_ops status
    [[ $status == 1 ]] || fail "[$file]: expected exit 1, got $status"
    assert_stdout_has_line "$line"
    assert_stderr_contains "error: $problem"
    # The other fields are still there.
    assert_stdout_has_line "Version: minotari_node 6.0.0"
    assert_stdout_has_line "Sync: syncing"
    assert_stdout_has_line "Block height: 172497"
    assert_stdout_has_line "Wallet Query: ready (127.0.0.1:9000)"
  done
}

test_status_reports_wallet_query_failures() {
  local -a cases=(
    "FAKE_CURL_FAIL_NAME=get_tip_info FAKE_CURL_FAIL_CODE=28|timed out"
    "FAKE_CURL_FAIL_NAME=get_tip_info FAKE_CURL_FAIL_CODE=7|failed (curl exit 7)"
    "FAKE_CURL_FAIL_NAME=get_tip_info FAKE_CURL_FAIL_CODE=22|failed (curl exit 22)"
    "OPS_WAIT=1 FAKE_CURL_SLEEP_NAME=get_tip_info|timed out"
  )
  local c settings reason
  for c in "${cases[@]}"; do
    IFS='|' read -r settings reason <<<"$c"
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/curl-log"
    setup_status
    (
      # shellcheck disable=SC2086,SC2163 # Space-separated settings.
      export $settings
      run_ops status
      [[ $status == 1 ]] || fail "[$settings]: expected exit 1, got $status"
      assert_stdout_has_line "Sync: unknown"
      assert_stdout_has_line "Block height: unknown"
      assert_stdout_has_line "Wallet Query: no valid answer (127.0.0.1:9000)"
      assert_stdout_has_line "Node service: active (enabled)"
      assert_stdout_has_line "P2P listener: ready (18189)"
      assert_stderr_contains "error: Wallet Query request to $TIP_URL $reason"
    ) || exit 1
  done
}

test_status_rejects_invalid_tip_info() {
  local -a bodies=(
    'not json'
    ''
    '[]'
    'null'
    '{"metadata":{"best_block_height":"172497"},"is_synced":false}'
    '{"metadata":{"best_block_height":-1},"is_synced":false}'
    '{"metadata":{"best_block_height":1.5},"is_synced":false}'
    '{"metadata":{"best_block_height":1e30},"is_synced":false}'
    '{"metadata":{"best_block_height":null},"is_synced":false}'
    '{"metadata":{},"is_synced":false}'
    '{"metadata":[],"is_synced":false}'
    '{"best_block_height":1,"is_synced":false}'
    '{"metadata":{"best_block_height":1}}'
    '{"metadata":{"best_block_height":1},"is_synced":"false"}'
    '{"metadata":{"best_block_height":1},"is_synced":0}'
    '{"metadata":{"best_block_height":1},"is_synced":null}'
    '{"metadata":{"best_block_height":1},"is_synced":false} {"metadata":{"best_block_height":2},"is_synced":true}'
    '{"metadata":{"best_block_height":1},"is_synced":false'
  )
  local body
  setup_status
  for body in "${bodies[@]}"; do
    tip_info "$body"
    run_ops status
    [[ $status == 1 ]] || fail "[$body]: expected exit 1, got $status"
    assert_stdout_has_line "Sync: unknown"
    assert_stdout_has_line "Block height: unknown"
    assert_stdout_has_line "Wallet Query: no valid answer (127.0.0.1:9000)"
    assert_stderr_contains "error: Wallet Query request to $TIP_URL returned an invalid answer"
  done
  # Oversized answers are not parsed.
  tip_info "{\"metadata\":{\"best_block_height\":1},\"is_synced\":false,\"pad\":\"$(head -c 70000 /dev/zero | tr '\0' x)\"}"
  run_ops status
  assert_status 1
  assert_stderr_contains "returned an invalid answer"
}

test_status_reports_listener_problems() {
  local -a cases=(
    "127.0.0.1:9000|P2P listener: not listening (18189)|nothing listens on TCP 18189 on 0.0.0.0 or [::]"
    "127.0.0.1:18189 127.0.0.1:9000|P2P listener: not listening (18189)|nothing listens on TCP 18189 on 0.0.0.0 or [::]"
    "0.0.0.0:18189|Wallet Query: not listening (127.0.0.1:9000)|nothing listens on 127.0.0.1:9000"
    "0.0.0.0:18189 0.0.0.0:9000|Wallet Query: unexpected listener (0.0.0.0:9000)|TCP 9000 listens on addresses other than 127.0.0.1: 0.0.0.0:9000"
    "0.0.0.0:18189 127.0.0.1:9000 [::]:9000|Wallet Query: unexpected listener ([::]:9000)|TCP 9000 listens on addresses other than 127.0.0.1: [::]:9000"
    "0.0.0.0:18189 127.0.0.1:9000 10.0.0.5:9000|Wallet Query: unexpected listener (10.0.0.5:9000)|TCP 9000 listens on addresses other than 127.0.0.1: 10.0.0.5:9000"
  )
  local c listeners line problem
  for c in "${cases[@]}"; do
    IFS='|' read -r listeners line problem <<<"$c"
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/curl-log"
    setup_status
    # shellcheck disable=SC2086 # Space-separated address list.
    set_listeners $listeners
    run_ops status
    [[ $status == 1 ]] || fail "[$listeners]: expected exit 1, got $status"
    assert_stdout_has_line "$line"
    assert_stderr_contains "error: $problem"
    assert_stdout_has_line "Node service: active (enabled)"
    assert_stdout_has_line "Version: minotari_node 6.0.0"
    # Without a 127.0.0.1:9000 listener there is nothing to ask.
    if [[ " $listeners " == *" 127.0.0.1:9000 "* ]]; then
      [[ $(curl_call_count) == 1 ]] || fail "[$listeners]: expected one request"
    else
      [[ $(curl_call_count) == 0 ]] || fail "[$listeners]: requested the Wallet Query without a listener"
    fi
  done
}

test_status_reports_version_probe_failures() {
  local -a cases=(
    "garbage"
    "minotari_node"
    "minotari_node 6.0"
    "minotari_node v6.0.0"
    "minotari_node 6.0.0 extra"
    $'minotari_node 6.0.0\nminotari_node 6.0.0'
    "EXIT1"
    "HANG"
  )
  local c bin
  for c in "${cases[@]}"; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/curl-log"
    setup_status
    bin=$SB/opt/tari/releases/$STATUS_RELEASE/minotari_node
    case "$c" in
      EXIT1) printf '#!/bin/sh\necho "minotari_node 6.0.0"\nexit 1\n' >"$bin" ;;
      HANG) printf '#!/bin/sh\nexec sleep 30\n' >"$bin" ;;
      *) printf '#!/bin/sh\nprintf "%%b\\n" "%s"\n' "${c//$'\n'/\\n}" >"$bin" ;;
    esac
    OPS_WAIT=1 run_ops status
    [[ $status == 1 ]] || fail "[$c]: expected exit 1, got $status"
    assert_stdout_has_line "Version: unknown"
    assert_stderr_contains "error: 'minotari_node --version' failed or printed an unexpected version"
    assert_stdout_has_line "Node service: active (enabled)"
    assert_stdout_has_line "Block height: 172497"
  done
}

test_status_reports_invalid_restart_counts() {
  local n
  setup_status
  for n in abc -1 1.5 " 1" 99999999999 "[not set]"; do
    FAKE_NRESTARTS=$n run_ops status
    [[ $status == 1 ]] || fail "[$n]: expected exit 1, got $status"
    assert_stdout_has_line "Restarts: unknown"
    assert_stderr_contains "error: cannot read the restart count of minotari-mainnet.service"
    assert_stdout_has_line "Wallet Query: ready (127.0.0.1:9000)"
  done
}

test_status_runs_the_version_probe_as_the_service_user() {
  setup_status
  run_ops status
  assert_status 0
  grep -qxF "runuser -u tari -- env -i PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin HOME=/var/lib/tari LC_ALL=C $SB/opt/tari/current/minotari_node --version" \
    "$FAKE_SYS/calls" || fail "unexpected probe: $(<"$FAKE_SYS/calls")"
  [[ $(<"$TEST_TMP/node-trace") == "--version" ]] || fail "binary run otherwise: $(<"$TEST_TMP/node-trace")"
}

# --- the installation must be ours ------------------------------------------------

test_status_and_logs_refuse_a_missing_or_unsafe_install_state() {
  local -a cases=(
    "rm -- \$STATE|is missing; no node installed by taritalk-node-deploy was found"
    "mv -- \$STATE \$STATE.real && ln -s taritalk-install-state.real \$STATE|is not a regular file"
    "rm -- \$STATE && mkdir \$STATE|is not a regular file"
    "chmod 644 \$STATE|is not a private file of root (owner, mode, links:"
    "chmod 400 \$STATE|is not a private file of root (owner, mode, links:"
    "ln \$STATE \$STATE.hard|is not a private file of root (owner, mode, links:"
    "OWNER|is not a private file of root (owner, mode, links:"
    "printf 'format=2\\n' >\$STATE|is not an install record of taritalk-node-deploy"
    "printf 'garbage\\n' >\$STATE|is not an install record of taritalk-node-deploy"
    "sed -i '/^release_dir=/d' \$STATE|is not an install record of taritalk-node-deploy"
    "printf 'release_dir=/opt/tari/releases/x\\n' >>\$STATE|is not an install record of taritalk-node-deploy"
    "sed -i 's#^release_dir=.*#release_dir=/opt/tari/releases/../x#' \$STATE|is not an install record of taritalk-node-deploy"
  )
  local c action message cmd
  for c in "${cases[@]}"; do
    IFS='|' read -r action message <<<"$c"
    for cmd in status logs; do
      rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/curl-log"
      setup_status
      ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/tail"
      # shellcheck disable=SC2034 # Used by the eval'd actions.
      local STATE=$SB/var/lib/tari/taritalk-install-state
      (
        if [[ $action == OWNER ]]; then
          # Owned by someone other than root (as the harness sees root).
          export OPS_ROOT_IDS=$(($(id -u) + 1)):0
        else
          eval "$action" || fail "[$action]: setup failed"
        fi
        run_ops "$cmd"
        [[ $status == 1 ]] || fail "[$cmd $action]: expected exit 1, got $status"
        assert_stdout_empty
        assert_stderr_contains "/var/lib/tari/taritalk-install-state"
        assert_stderr_contains "$message"
      ) || exit 1
      ! grep -qvE '^$' "$FAKE_SYS/calls" || fail "[$cmd $action]: system calls: $(<"$FAKE_SYS/calls")"
      [[ $(curl_call_count) == 0 ]] || fail "[$cmd $action]: made a request"
    done
  done
}

test_status_refuses_missing_installation_paths() {
  local -a cases=(
    "rm -- \$SB/opt/tari/current|'/opt/tari/current' is missing or not a symlink"
    "rm -- \$SB/opt/tari/current && ln -s releases/other \$SB/opt/tari/current|'/opt/tari/current' does not point to the installed release"
    "rm -- \$SB/opt/tari/current && ln -s /opt/tari/releases/$STATUS_RELEASE \$SB/opt/tari/current|'/opt/tari/current' does not point to the installed release"
    "rm -- \$SB/opt/tari/releases/$STATUS_RELEASE/minotari_node|'/opt/tari/releases/$STATUS_RELEASE/minotari_node' is missing or not an executable file"
    "chmod 644 \$SB/opt/tari/releases/$STATUS_RELEASE/minotari_node|'/opt/tari/releases/$STATUS_RELEASE/minotari_node' is missing or not an executable file"
    "rm -- \$SB/etc/systemd/system/minotari-mainnet.service|'/etc/systemd/system/minotari-mainnet.service' is missing"
  )
  local c action message
  for c in "${cases[@]}"; do
    IFS='|' read -r action message <<<"$c"
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/curl-log"
    setup_status
    eval "$action" || fail "[$action]: setup failed"
    run_ops status
    [[ $status == 1 ]] || fail "[$action]: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "$message"
    ! grep -qvE '^$' "$FAKE_SYS/calls" || fail "[$action]: system calls: $(<"$FAKE_SYS/calls")"
    [[ $(curl_call_count) == 0 ]] || fail "[$action]: made a request"
  done
}

# --- read-only and loopback-only ------------------------------------------------------

# snapshot DIR...: every path below DIR with type, mode, size and mtime.
snapshot() {
  find "$@" -printf '%p %y %m %s %T@ %l\n' | sort
}

test_status_requests_only_the_fixed_loopback_url_with_safe_curl_options() {
  setup_status
  http_proxy=http://proxy.invalid:3128 HTTP_PROXY=http://proxy.invalid:3128 \
    ALL_PROXY=http://proxy.invalid:3128 CURL_HOME=$TEST_TMP run_ops status
  assert_status 0
  [[ $(curl_call_count) == 1 ]] || fail "expected 1 request, got $(curl_call_count)"
  load_curl_call 1
  local -a want=(--disable --silent --fail --noproxy '*' --proto "=http" --max-redirs 0
    --connect-timeout 2 --max-time 5 --max-filesize 65536 -- "$TIP_URL")
  [[ ${CALL[*]@Q} == "${want[*]@Q}" ]] || fail "request argv: ${CALL[*]@Q}"
}

test_status_writes_nothing_and_changes_no_service() {
  setup_status
  local before after
  before=$(snapshot "$SB" "$TMPDIR")
  run_ops status
  assert_status 0
  after=$(snapshot "$SB" "$TMPDIR")
  [[ $before == "$after" ]] || fail "files changed: $(diff <(echo "$before") <(echo "$after"))"
  # A failing run must not change anything either.
  rm -- "$FAKE_SYS/active.minotari-mainnet.service"
  before=$(snapshot "$SB" "$TMPDIR")
  FAKE_CURL_FAIL_NAME=get_tip_info run_ops status
  assert_status 1
  after=$(snapshot "$SB" "$TMPDIR")
  [[ $before == "$after" ]] || fail "files changed: $(diff <(echo "$before") <(echo "$after"))"
  local line
  while IFS= read -r line; do
    case "$line" in
      "systemctl is-active minotari-mainnet.service" | "systemctl is-enabled minotari-mainnet.service" | \
        "systemctl show minotari-mainnet.service -p NRestarts --value" | \
        "systemctl is-active tor@default.service" | "systemctl is-enabled tor.service" | \
        "runuser -u tari -- env -i "*" --version") ;;
      *) fail "unexpected system call: $line" ;;
    esac
  done <"$FAKE_SYS/calls"
  [[ $(grep -c . "$FAKE_SYS/calls") == 12 ]] || fail "calls: $(<"$FAKE_SYS/calls")"
}

# make_ops_sandbox DIR: PATH dir with the fakes, the real tools status and
# logs may use, and tracing stubs for every other forbidden command.
make_ops_sandbox() {
  local dir=$1 cmd tool
  mkdir -p "$dir"
  cat >"$TEST_TMP/forbidden-stub" <<'STUB'
#!/usr/bin/env bash
printf 'FORBIDDEN %s %s\n' "${0##*/}" "$*" >>"$TRACE_FILE"
exit 99
STUB
  chmod +x "$TEST_TMP/forbidden-stub"
  for cmd in "${FORBIDDEN_COMMANDS[@]}" runuser setpriv sleep kill; do
    case "$cmd" in systemctl | curl | runuser) ;; *) cp "$TEST_TMP/forbidden-stub" "$dir/$cmd" ;; esac
  done
  for tool in bash env timeout jq stat readlink tail cat; do
    ln -s "$(command -v "$tool")" "$dir/$tool"
  done
  ln -s "$TESTS_DIR/fakes/sys" "$dir/systemctl"
  ln -s "$TESTS_DIR/fakes/sys" "$dir/runuser"
  ln -s "$TESTS_DIR/fakes/curl" "$dir/curl"
}

test_status_and_logs_run_no_forbidden_commands() {
  setup_status
  make_ops_sandbox "$TEST_TMP/ops-bin"
  export TRACE_FILE=$TEST_TMP/trace OPS_TEST_PATH=$TEST_TMP/ops-bin
  : >"$TRACE_FILE"
  run_ops status
  assert_status 0
  healthy_block syncing 172497
  rm -- "$FAKE_SYS/active.tor@default.service"
  set_listeners
  FAKE_CURL_FAIL_NAME=get_tip_info run_ops status
  assert_status 1
  run_ops logs --lines 2
  assert_status 0
  assert_stdout_equals $'log line 149\nlog line 150'
  [[ -z $(<"$TRACE_FILE") ]] || fail "forbidden commands invoked: $(<"$TRACE_FILE")"
}

test_status_source_is_read_only_and_loopback_only() {
  local lib=$REPO_ROOT/lib/status.sh code hits
  [[ -f $lib ]] || fail "lib/status.sh is missing"
  code=$(grep -vE '^[[:space:]]*#' "$lib")
  # No privilege tools, writing or service-changing commands, journal,
  # eval or sourcing, and no file redirections but /dev/null.
  hits=$(grep -nE '(^|[;&|(]|\$\(|then|do|else)[[:space:]]*(sudo|su|doas|pkexec)([[:space:]]|$)' <<<"$code") || true
  [[ -z $hits ]] || fail "privilege escalation in lib/status.sh: $hits"
  local pattern='/dev/(tcp|udp)/|(^|[^A-Za-z_-])(eval|source|journalctl|apt-get|apt|dpkg|useradd|usermod|userdel|groupadd|groupdel|mkdir|rm|rmdir|mv|cp|ln|chmod|chown|touch|tee|dd|mktemp|wget|ssh|nc)([^A-Za-z_.-]|$)|systemctl[^|;]*[[:space:]](start|stop|restart|reload|enable|disable|mask|unmask|kill|daemon-reload|set-property|edit)([[:space:]]|$)|--insecure|--location|--proxy[[:space:]]|--proxy='
  hits=$(grep -nE "$pattern" <<<"$code") || true
  [[ -z $hits ]] || fail "forbidden operation in lib/status.sh: $hits"
  # (shfmt writes redirections without a space; `(($# > 0))` is arithmetic.)
  hits=$(grep -noE '>>?[^&=[:space:]][^[:space:])]*' <<<"$code" | grep -vE ':>/dev/null$') || true
  [[ -z $hits ]] || fail "file redirection in lib/status.sh: $hits"
  # curl in command position exactly once, with the one fixed URL.
  local curl_lines urls
  # A curl command word anywhere (also after timeout and its arguments).
  curl_lines=$(grep -cE '(^|[[:space:]"(|&;])curl[[:space:]]+-' <<<"$code") || true
  [[ $curl_lines == 1 ]] || fail "curl must be invoked from exactly one place, found $curl_lines"
  urls=$(grep -oE '[A-Za-z]+://[^ "]*' <<<"$code") || true
  [[ $urls == "http://127.0.0.1:9000/get_tip_info" ]] || fail "unexpected URLs in lib/status.sh: $urls"
  grep -qE '^readonly TIP_INFO_URL=http://127\.0\.0\.1:9000/get_tip_info$' "$lib" ||
    fail "TIP_INFO_URL is not the fixed loopback URL"
}
