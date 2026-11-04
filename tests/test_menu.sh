# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# The menu: what an ordinary user gets from `./deploy.sh` without arguments
# in a terminal. Run against the same sandbox and fakes as install,
# upgrade and uninstall (tests/test_install.sh, test_uninstall.sh,
# test_upgrade.sh); the terminal is stood in for by is_interactive.

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# menu_session: deploy.sh's menu as "root" in a "terminal" (the real one
# with pty_menu), against the sandbox. No outside service tells the public
# IPv4 address unless TEST_IPV4_URLS names some; TEST_APT_SECONDS limits
# APT.
menu_session() {
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    load_menu
    # shellcheck disable=SC2317,SC2329 # Called by lib/menu.sh and the commands.
    is_root() { return 0; }
    # shellcheck disable=SC2317,SC2329
    is_interactive() { return 0; }
    SYSROOT=$SB
    ROOT_IDS="$(id -u):$(id -g)"
    INSTALL_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    CHILD_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    OPS_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    INSTALL_SOURCE_DIR=${MENU_TOOL_DIR:-$REPO_ROOT}
    SYSTEM_UID_MAX=$(id -u)
    MOUNTINFO=$TEST_TMP/mountinfo
    TOR_WAIT_SECONDS=3
    NODE_WAIT_SECONDS=3
    NGINX_WAIT_SECONDS=3
    ACME_SH_SHA256=${WQ_ACME_SHA256-$ACME_SH_SHA256}
    read -r -a PUBLIC_IPV4_URLS <<<"${TEST_IPV4_URLS-}"
    APT_SECONDS=${TEST_APT_SECONDS-$APT_SECONDS}
    cmd_menu
  )
}

# run_menu LINE...: the menu (menu_session), answering with LINE... (then
# end of input). Sets status/stdout/stderr.
run_menu() {
  printf '%s\n' "$@" >"$TEST_TMP/.stdin"
  menu_session <"$TEST_TMP/.stdin" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# pty_menu STEP...: the menu (menu_session) in a real terminal, as
# ./deploy.sh over SSH: tests/pty-session with STEP... (--expect TEXT,
# --send TEXT, --pause SECONDS). Sets status (pty-session's: 0, or 3 when
# the menu stopped answering, 4 when a process was stopped, 5 when the
# terminal settings changed), stdout (what the terminal showed, without
# carriage returns) and stderr (pty-session's reason).
pty_menu() {
  local var
  {
    printf 'set -u\n'
    for var in REPO_ROOT TESTS_DIR TEST_TMP SB WQ_ACME_SHA256 TEST_IPV4_URLS TEST_APT_SECONDS MENU_TOOL_DIR; do
      [[ -z ${!var+set} ]] || declare -p "$var"
    done
    declare -f menu_session
    printf 'menu_session\n'
  } >"$TEST_TMP/menu-driver"
  timeout 120 "$TESTS_DIR/pty-session" "$TEST_TMP/.transcript" "$@" -- \
    bash "$TEST_TMP/menu-driver" >/dev/null 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(tr -d '\r' <"$TEST_TMP/.transcript")
  stderr=$(<"$TEST_TMP/.stderr")
}

# menu_count TEXT: how often TEXT occurs in stdout.
menu_count() {
  local rest=$stdout n=0
  while [[ $rest == *"$1"* ]]; do
    rest=${rest#*"$1"}
    n=$((n + 1))
  done
  echo "$n"
}

test_menu_shows_one_short_list_and_reasks_on_invalid_input() {
  setup_install
  run_menu "" 9 abc 1x 0
  assert_status 0
  local menu
  printf -v menu '%s\n' "TariTalk Node Tool" \
    "==============================================================" \
    "System Required: Debian 12/13, Ubuntu 24.04/26.04" \
    "Architecture: AMD64 / ARM64" \
    "Version: v0.1.0" \
    "Description: Install and manage a Minotari Mainnet full node" \
    "GitHub: https://github.com/xt1085/taritalk-node-deploy" \
    "==============================================================" \
    "Node: not installed" "" "1. Install node" "2. Node status" "3. Node logs" \
    "4. Upgrade node" "5. Install Wallet Query" "6. Install Base Node gRPC" \
    "7. Submit node to TariTalk Nodes" "8. Uninstall all" "0. Exit" ""
  [[ $stdout == "$menu"* ]] || fail "menu differs"
  [[ $(menu_count "Please choose: ") == 5 ]] || fail "did not ask again after invalid input"
  [[ $(menu_count "Please enter a number from 0 to 8.") == 4 ]] || fail "no hint for invalid input"
  assert_stderr_empty
  assert_no_changes
  # End of input at the menu also ends it, without changing anything.
  run_menu
  assert_status 0
  assert_no_changes
}

# The menu header's one link, to the tool's own page.
readonly MENU_GITHUB_LINE="GitHub: https://github.com/xt1085/taritalk-node-deploy"

# assert_plain_language: what the menu showed (stdout and stderr) has no internals: paths,
# hashes, URLs (but the header's link to the tool), service or unit names,
# loopback ports, symlinks.
assert_plain_language() {
  local bad
  bad=$(grep -vxF "$MENU_GITHUB_LINE" <<<"$stdout$stderr" |
    grep -nE '/(opt|var|etc|run|usr|tmp)/|[0-9a-f]{16,}|https?://|\.service|systemd|127\.0\.0\.1|:9000|9050|9051|symlink|releases/') || true
  [[ -z $bad ]] || fail "the menu showed internals: $bad"
}

test_menu_installs_a_node_in_plain_language() {
  setup_install
  run_menu 1 "$INSTALL_IP" y "" 0
  assert_status 0
  assert_stdout_contains "Public IPv4 address: "
  assert_stdout_contains "Install the Minotari node? [y/N]: "
  assert_stdout_contains "Installed: Minotari $FIXTURE_VERSION. The node is running and has started its first sync."
  assert_stdout_contains "allow inbound TCP port 18189"
  assert_stdout_contains "Node: Minotari $FIXTURE_VERSION, running"
  assert_plain_language
  [[ -e $FAKE_SYS/active.minotari-mainnet.service ]] || fail "not installed"
}

test_menu_explains_plainly_when_no_node_is_installed() {
  setup_install
  run_menu 2 "" 3 "" 4 "" 7 "" 8 "" 0
  assert_status 0
  [[ $(menu_count "No node installed by this tool was found on this server.") == 5 ]] ||
    fail "not every choice explained that no node is installed"
  [[ $(menu_count "Press Enter to return to the menu.") == 5 ]] || fail "did not return to the menu"
  assert_plain_language
  assert_no_changes
}

test_menu_runs_status_logs_upgrade_and_uninstall_in_plain_language() {
  setup_upgrade
  mkdir -p "$SB/var/log/tari/log/base_node"
  seq 1 80 | sed 's/^/log line /' >"$SB/var/log/tari/log/base_node/base_layer.log"
  publish_release_fixture 6.0.1
  run_menu 2 "" 3 "" 4 y "" 8 y "" 0
  assert_status 0
  local line
  for line in "Node status" "  Minotari:    6.0.1-pre.2" "  Node:        running" "  Tor:         running" \
    "  Sync:        syncing, block 172497" "  Restarts:    0" "  Peers:       accepting connections" \
    "  Wallet service (local): answering"; do
    assert_stdout_has_line "$line"
  done
  assert_stdout_has_line "log line 80"
  assert_stdout_has_line "log line 31"
  [[ $stdout != *"log line 30"$'\n'* ]] || fail "showed more than 50 log lines"
  assert_stdout_contains "Upgraded: Minotari 6.0.1-pre.2 -> 6.0.1. The node is running."
  assert_stdout_contains "Node: Minotari 6.0.1, running"
  assert_stdout_contains "Uninstall the node, Wallet Query and Base Node gRPC? [y/N]: "
  assert_stdout_contains "Uninstalled: Minotari node"
  [[ ${stdout##*TariTalk Node Tool} == *"Node: not installed"* ]] || fail "the last menu does not show the node gone"
  assert_plain_language
}

# --- failures, in plain language ---------------------------------------------------

# line_no TEXT: the number of the first stdout line containing TEXT, or 0.
line_no() {
  local n
  n=$(grep -nF -- "$1" <<<"$stdout" | head -n 1 | cut -d: -f1)
  echo "${n:-0}"
}

test_menu_log_before_the_node_has_logged_is_explained_plainly() {
  setup_upgrade
  rm -rf -- "$SB/var/log/tari/log"
  run_menu 3 "" 0
  assert_status 0
  assert_stdout_contains "The node has not written a log yet; it usually does within a minute of starting. Try again in a minute."
  assert_stdout_contains "Press Enter to return to the menu"
  assert_stderr_empty
  assert_plain_language
}

test_menu_status_says_when_the_node_will_not_start_after_a_restart() {
  setup_upgrade
  "$TEST_TMP/fakebin/systemctl" disable minotari-mainnet.service
  run_menu 2 "" 0
  assert_status 0
  assert_stdout_has_line "  Node:        running, but it will not start again after a server restart (!)"
  assert_stdout_contains "Something needs attention (marked with !)."
  assert_stderr_empty
  assert_plain_language
}

test_menu_install_on_an_installed_node_points_to_upgrade() {
  setup_upgrade
  local before
  before=$(system_snapshot)
  run_menu 1 "" 0
  assert_status 0
  assert_stdout_contains "A node installed by this tool is already on this server. To move to a newer Minotari release, choose 4) Upgrade node."
  [[ $stdout$stderr != *future* ]] || fail "still calls upgrade a future command"
  assert_stderr_empty
  assert_plain_language
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
}

test_menu_upgrade_failure_says_first_what_became_of_the_node() {
  local mode outcome reason
  for mode in download start; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/zipsrc-6.0.1" "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_upgrade
    publish_release_fixture 6.0.1
    (
      if [[ $mode == download ]]; then
        export FAKE_CURL_FAIL_NAME=tari_suite-6.0.1-mainnet-abc1234-linux-arm64.zip
        outcome="The upgrade did not go ahead. Your node was not changed and keeps running Minotari 6.0.1-pre.2."
        reason="Reason: it stopped while downloading and verifying the release"
      else
        export FAKE_NODE_BROKEN="*/minotari-6.0.1-linux-*"
        outcome="Minotari 6.0.1 did not start correctly, so the previous release (Minotari 6.0.1-pre.2) was put back and is running again."
        reason="Reason: cannot start the node."
      fi
      run_menu 4 y "" 0
      assert_status 0
      assert_stdout_contains "$outcome"
      assert_stdout_contains "$reason"
      assert_stdout_contains "type d and press Enter to see the technical details"
      ((0 < $(line_no "$outcome") && $(line_no "$outcome") < $(line_no "$reason"))) ||
        fail "[$mode]: the node's state is not said first: $stdout"
      [[ $stdout != *"Upgraded:"* ]] || fail "[$mode]: claimed success"
      assert_stderr_empty
      assert_plain_language
      # The technical details are there on request.
      run_menu 4 y d "" 0
      [[ $stdout == *"error:"* ]] || fail "[$mode]: no technical details on request"
    ) || exit 1
  done
}

test_menu_upgrade_failure_says_to_check_status_and_logs_when_recovery_is_uncertain() {
  setup_upgrade
  publish_release_fixture 6.0.1
  FAKE_NODE_BROKEN="*" run_menu 4 y "" 0
  assert_status 0
  assert_stdout_contains "Check the node with 2) Node status and 3) Node logs."
  [[ $stdout != *"Recent log"* ]] || fail "used the old menu label"
  assert_stderr_empty
  assert_plain_language
}

test_menu_install_plan_names_ubuntu_and_apt_packages() {
  setup_install
  fake_host_arch
  cp "$FIXTURES/os-release/ubuntu-24.04" "$SB/etc/os-release"
  run_menu 1 "$INSTALL_IP" n "" 0
  assert_status 0
  assert_stdout_contains "This server:   Ubuntu 24.04, linux-arm64"
  assert_stdout_contains "It installs Tor and a few standard APT packages"
  assert_stdout_contains "Installation cancelled; nothing was changed."
  assert_plain_language
  assert_no_changes
}

# --- the real entry -----------------------------------------------------------------

test_menu_real_entry_needs_a_terminal_and_root() {
  command -v script >/dev/null || fail "the 'script' test tool (util-linux) is required"
  # In a terminal (a pseudo-terminal from script), ./deploy.sh is the menu,
  # which, like every command that manages the node, needs root.
  timeout 10 script -qec "$CLI" /dev/null </dev/null >"$TEST_TMP/out" 2>&1
  status=$?
  stdout=$(tr -d '\r' <"$TEST_TMP/out")
  assert_status 1
  [[ $stdout == "Please run as root." ]] || fail "unexpected output: $stdout"
  # Not in a terminal (a pipe, cron, CI): the help, exit 2, no waiting.
  run_cli </dev/null
  assert_status 2
  assert_stderr_contains "Run without arguments in a terminal for a simple menu."
  [[ $(printf '1\n' | timeout 5 "$CLI" 2>&1) == *"Usage: ./deploy.sh"* ]] || fail "a pipe did not get the help"
}

# --- the public IPv4 address, found out for the menu --------------------------------

# serve_ipv4 NAME TEXT: the fake service https://NAME/ipv4 answers TEXT.
serve_ipv4() {
  mkdir -p "$FAKE_WEB_ROOT/$1"
  printf '%s\n' "$2" >"$FAKE_WEB_ROOT/$1/ipv4"
}

# recorded_ip: the public IPv4 address the installed node records.
recorded_ip() {
  sed -n 's/^public_ip=//p' "$SB/var/lib/tari/taritalk-install-state"
}

test_menu_install_offers_the_detected_public_ipv4() {
  setup_install
  # The first service fails, the second answers.
  serve_ipv4 ip-b.test 5.6.7.8
  TEST_IPV4_URLS="https://ip-a.test/ipv4 https://ip-b.test/ipv4" run_menu 1 "" y "" 0
  assert_status 0
  assert_stdout_has_line "Detected public IPv4 address: 5.6.7.8"
  assert_stdout_contains "Public IPv4 address [5.6.7.8]: "
  assert_stdout_contains "Installed: Minotari $FIXTURE_VERSION."
  assert_plain_language
  [[ $(recorded_ip) == 5.6.7.8 ]] || fail "Enter did not take the detected address"
  local log args
  for log in "$TEST_TMP"/curl-log/[0-9]*; do
    args=$(tr '\0' ' ' <"$log")
    [[ $args != *ip-[ab].test* ]] && continue
    [[ $args == *" --ipv4 "* && $args == *" --proto =https "* && $args == *" --max-time "* ]] ||
      fail "the address was asked for without IPv4, HTTPS or a time limit: $args"
  done
}

test_menu_install_takes_a_typed_ipv4_over_the_detected_one() {
  setup_install
  serve_ipv4 ip.test 5.6.7.8
  TEST_IPV4_URLS=https://ip.test/ipv4 run_menu 1 "$INSTALL_IP" y "" 0
  assert_status 0
  assert_stdout_contains "Public IPv4 address [5.6.7.8]: "
  [[ $(recorded_ip) == "$INSTALL_IP" ]] || fail "the typed address was not used"
}

test_menu_install_checks_a_typed_ipv4_as_before() {
  setup_install
  serve_ipv4 ip.test 5.6.7.8
  TEST_IPV4_URLS=https://ip.test/ipv4 run_menu 1 10.1.2.3 "" 0
  assert_status 0
  assert_stdout_contains "Public IPv4 address [5.6.7.8]: "
  assert_stdout_contains "Reason: 10.1.2.3 is a private address, not a public IPv4 address."
  [[ ! -e $SB/var/lib/tari/taritalk-install-state ]] || fail "installed anyway"
}

test_menu_install_asks_as_before_when_detection_fails() {
  setup_install
  # Neither a private address nor anything else invalid is offered; a
  # missing service is no answer either.
  serve_ipv4 ip-a.test 192.168.1.5
  serve_ipv4 ip-b.test "not an address"
  TEST_IPV4_URLS="https://ip-a.test/ipv4 https://ip-b.test/ipv4 https://ip-c.test/ipv4" \
    run_menu 1 "" "" 0
  assert_status 0
  [[ $stdout != *Detected* && $stdout != *"address ["* ]] || fail "offered an address"
  assert_stdout_contains "Public IPv4 address: "
  assert_stdout_contains "Reason: invalid public IPv4 address (expected four dot-separated decimal numbers)."
  [[ ! -e $SB/var/lib/tari/taritalk-install-state ]] || fail "installed without an address"
  # Without curl (it comes with the installation), nothing is asked.
  rm -f -- "$TEST_TMP/fakebin/curl" "$TEST_TMP"/curl-log/*
  TEST_IPV4_URLS=https://ip-a.test/ipv4 run_menu 1 "$INSTALL_IP" n "" 0
  assert_status 0
  assert_stdout_contains "Public IPv4 address: "
  assert_stdout_contains "Installation cancelled; nothing was changed."
}

test_menu_detection_uses_https_services_by_default() {
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    load_install
    ((${#PUBLIC_IPV4_URLS[@]} > 0)) || fail "no service"
    local url
    for url in "${PUBLIC_IPV4_URLS[@]}"; do
      [[ $url == https://* ]] || fail "not HTTPS: $url"
    done
  ) || exit 1
}

# --- the real terminal --------------------------------------------------------------

# The control sequence that clears the screen.
readonly CLEAR_SCREEN=$'\e[H\e[2J'

test_menu_clears_the_screen_once_and_only_in_a_terminal() {
  setup_install
  # A usual terminal type, whatever the caller's.
  TERM=xterm pty_menu --expect "Please choose: " --send '2\r' --expect "Press Enter to return to the menu." \
    --send '\r' --expect "Please choose: " --send '0\r'
  assert_status 0
  local rest=${stdout#*"$CLEAR_SCREEN"}
  [[ $rest != "$stdout" ]] || fail "did not clear the screen"
  [[ $rest != *"$CLEAR_SCREEN"* ]] || fail "cleared the screen more than once"
  [[ $rest == "TariTalk Node Tool"* ]] || fail "the menu does not start the clear screen"
  [[ $rest == *"No node installed by this tool was found on this server."*"TariTalk Node Tool"* ]] ||
    fail "the result was not kept above the next menu"
  # Not in a terminal (and in a dumb one): no control sequences.
  run_menu 2 "" 0
  [[ $stdout != *$'\e'* ]] || fail "control sequence without a terminal"
  TERM=dumb pty_menu --expect "Please choose: " --send '0\r'
  assert_status 0
  [[ $stdout != *$'\e'* ]] || fail "control sequence in a dumb terminal"
}

# apt_touches_terminal: from now on, apt-get uses the terminal as apt-get
# 3.0 does (tests/fakes/apt-tty) while it does what the fake apt-get does,
# after FAKE_APT_SLEEP seconds (default 0).
apt_touches_terminal() {
  mkdir -p "$TEST_TMP/sysfakes"
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/sysfakes/apt-get"
  rm -f -- "$TEST_TMP/fakebin/apt-get"
  # shellcheck disable=SC2016 # Expanded by the wrapper.
  printf '#!/usr/bin/env bash\nexec %q bash -c %q %q "$@"\n' "$TESTS_DIR/fakes/apt-tty" \
    'sleep "${FAKE_APT_SLEEP:-0}"; exec "$0" "$@"' "$TEST_TMP/sysfakes/apt-get" \
    >"$TEST_TMP/fakebin/apt-get"
  chmod +x "$TEST_TMP/fakebin/apt-get"
}

# wq_to_apt: STEPS for pty_menu: Wallet Query from the menu, up to its APT
# step.
wq_to_apt() {
  STEPS=(--expect "Please choose: " --send '5\r' --expect "Domain name"
    --send "$WQ_DOMAIN"'\r' --expect "Email address" --send "$WQ_EMAIL"'\r'
    --expect "[y/N]: " --send 'y\r' --expect "installing APT packages: nginx")
}

test_menu_apt_leaves_the_terminal_alone() {
  setup_wallet_query
  apt_touches_terminal
  wq_to_apt
  pty_menu "${STEPS[@]}" --expect "Wallet Query is ready" \
    --expect "Press Enter to return to the menu" --send '\r' --expect "Please choose: " --send '0\r'
  assert_status 0
  [[ -e $FAKE_SYS/active.nginx.service ]] || fail "not set up"
}

test_menu_apt_interrupted_rolls_back_and_leaves_the_terminal_working() {
  setup_wallet_query
  apt_touches_terminal
  export FAKE_APT_SLEEP=5
  wq_to_apt
  pty_menu "${STEPS[@]}" --pause 1 --send '\003' \
    --expect "Wallet Query was not set up; the changes made were undone." \
    --expect "Press Enter to return to the menu" --send '\r' --expect "Please choose: " --send '0\r'
  assert_status 0
  assert_wallet_query_absent
}

test_menu_apt_timeout_rolls_back_and_leaves_the_terminal_working() {
  setup_wallet_query
  apt_touches_terminal
  export FAKE_APT_SLEEP=10
  wq_to_apt
  TEST_APT_SECONDS=1 pty_menu "${STEPS[@]}" \
    --expect "Wallet Query was not set up; the changes made were undone." \
    --expect "Press Enter to return to the menu" --send '\r' --expect "Please choose: " --send '0\r'
  assert_status 0
  assert_wallet_query_absent
}

# real_apt_runs_first: from now on, apt-get install first runs the real
# apt-get, confined to a private root under $TEST_TMP/apt (its own
# configuration, package lists and status; a dpkg that only notes how it
# was run, in $TEST_TMP/apt/dpkg-ran), on an empty package; then the fake
# apt-get does the rest. The real apt-get's own terminal handling is what
# is tested.
real_apt_runs_first() {
  local apt_get dpkg_deb a=$TEST_TMP/apt d
  apt_get=$(type -aP apt-get | grep -v '/guard/' | head -n 1)
  dpkg_deb=$(type -aP dpkg-deb | grep -v '/guard/' | head -n 1)
  [[ -n $apt_get && -n $dpkg_deb ]] || fail "the real apt-get and dpkg-deb test tools are required"
  for d in root/etc/apt/apt.conf.d root/etc/apt/preferences.d root/etc/apt/sources.list.d \
    root/var/lib/dpkg root/var/lib/apt/lists/partial root/var/cache/apt/archives/partial \
    root/var/log/apt pkg/DEBIAN; do
    mkdir -p "$a/$d"
  done
  : >"$a/root/var/lib/dpkg/status"
  : >"$a/root/etc/apt/sources.list"
  printf '%s\n' "Package: taritalk-tty-probe" "Version: 1.0" "Architecture: all" \
    "Maintainer: test <test@example.invalid>" "Description: empty test package" \
    >"$a/pkg/DEBIAN/control"
  "$dpkg_deb" --build --root-owner-group "$a/pkg" "$a/probe.deb" >/dev/null || fail "cannot build the test package"
  # shellcheck disable=SC2016 # Expanded by the fake dpkg.
  printf '%s\n' '#!/bin/sh' 'case "$*" in' '  *--print-foreign-architectures*|*--assert*) exit 0 ;;' \
    '  *--print-architecture*) echo all; exit 0 ;;' 'esac' \
    'r=no-terminal; [ -t 1 ] && r=terminal' "echo \$r >>'$a/dpkg-ran'" 'sleep 1' >"$a/dpkg"
  chmod +x "$a/dpkg"
  printf '%s\n' "Dir \"$a/root/\";" "Dir::State::status \"$a/root/var/lib/dpkg/status\";" \
    "Dir::Bin::dpkg \"$a/dpkg\";" 'Debug::NoLocking "true";' >"$a/apt.conf"
  mkdir -p "$TEST_TMP/sysfakes"
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/sysfakes/apt-get"
  rm -f -- "$TEST_TMP/fakebin/apt-get"
  printf '%s\n' '#!/usr/bin/env bash' 'if [[ " $* " == *" install "* ]]; then' \
    "  APT_CONFIG=$(printf %q "$a/apt.conf") $(printf %q "$apt_get") -q -y install $(printf %q "$a/probe.deb") || true" \
    'fi' "exec $(printf %q "$TEST_TMP/sysfakes/apt-get") \"\$@\"" >"$TEST_TMP/fakebin/apt-get"
  chmod +x "$TEST_TMP/fakebin/apt-get"
}

test_menu_real_apt_leaves_the_terminal_alone() {
  setup_wallet_query
  real_apt_runs_first
  wq_to_apt
  pty_menu "${STEPS[@]}" --expect "Wallet Query is ready" \
    --expect "Press Enter to return to the menu" --send '\r' --expect "Please choose: " --send '0\r'
  assert_status 0
  [[ -e $FAKE_SYS/active.nginx.service ]] || fail "not set up"
  # The real apt-get got as far as running dpkg in its own terminal.
  grep -qx terminal "$TEST_TMP/apt/dpkg-ran" 2>/dev/null ||
    fail "the real apt-get did not run dpkg in a terminal: $(cat -- "$TEST_TMP/apt/dpkg-ran" 2>&1)"
}
