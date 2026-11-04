# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# install: a fresh node install on a clean Debian host. Never touches the real
# system: every system command (apt-get, dpkg-query, getent, account tools,
# systemctl, runuser, tor) is the fake tests/fakes/sys, anything else that
# reaches the system is stopped by tests/guard, and all paths live in a
# sandbox root ($SB) that lib/install.sh is pointed at when sourced. The
# release download is the real Phase 2 fetch against the fake curl.

readonly INSTALL_IP=1.2.3.4
readonly SYS_FAKES=(apt-get dpkg-query getent groupadd useradd userdel groupdel systemctl runuser tor)
readonly DEBIAN_TORRC=$'## default Debian torrc (everything commented out)\n#SocksPort 9050'

# setup_install: the fake release, the fake system and the sandbox root.
setup_install() {
  build_release
  use_fake_curl
  SB=$TEST_TMP/sysroot
  local d
  for d in etc etc/systemd etc/systemd/system opt var var/lib var/log usr usr/lib run proc proc/net; do
    mkdir -p "$SB/$d"
    chmod 755 "$SB/$d"
  done
  chmod 755 "$SB"
  mkdir -p "$SB/tmp"
  chmod 1777 "$SB/tmp"
  cp "$FIXTURES/os-release/debian-12" "$SB/etc/os-release"
  FAKE_SYS=$TEST_TMP/fakesys
  mkdir -p "$FAKE_SYS"
  : >"$FAKE_SYS/pkgs"
  : >"$FAKE_SYS/listeners"
  : >"$FAKE_SYS/calls"
  printf 'root:x:0:0:root:/root:/bin/bash\n' >"$FAKE_SYS/passwd"
  printf 'root:x:0:\n' >"$FAKE_SYS/group"
  printf '  sl  local_address rem_address   st\n' >"$SB/proc/net/tcp"
  for d in "${SYS_FAKES[@]}"; do
    ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/$d"
  done
  export FAKE_SYS FAKE_SYSROOT=$SB FAKE_TEST_UID FAKE_TEST_GID SB
  FAKE_TEST_UID=$(id -u)
  FAKE_TEST_GID=$(id -g)
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_install ARGS...: lib/install.sh's cmd_install, run as "root" against
# the sandbox, with $INSTALL_INPUT on stdin. Sets status/stdout/stderr.
run_install() {
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    is_root() { return 0; }
    is_interactive() { [[ -n ${FAKE_TTY-} ]]; }
    SYSROOT=$SB
    ROOT_IDS="$(id -u):$(id -g)"
    INSTALL_PATH=$TEST_TMP/fakebin:$PATH
    CHILD_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    INSTALL_SOURCE_DIR=$REPO_ROOT
    TOR_WAIT_SECONDS=${INSTALL_WAIT-3}
    NODE_WAIT_SECONDS=${INSTALL_WAIT-3}
    cmd_install "$@"
  ) <<<"${INSTALL_INPUT-}" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# call_no GLOB: line number of the first fake system call matching GLOB
# (0 if none).
call_no() {
  local n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    # shellcheck disable=SC2053 # GLOB is a pattern on purpose.
    [[ $line == $1 ]] && {
      echo "$n"
      return 0
    }
  done <"$FAKE_SYS/calls"
  echo 0
}

called() { [[ $(call_no "$1") != 0 ]]; }

# assert_order GLOB...: each GLOB matches a call, in this order.
assert_order() {
  local prev=0 n g
  for g in "$@"; do
    n=$(call_no "$g")
    ((n > prev)) || fail "call order: '$g' not after the previous step (calls: $(<"$FAKE_SYS/calls"))"
    prev=$n
  done
}

# assert_no_changes: only read-only system calls were made.
assert_no_changes() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "dpkg-query "* | "getent "*) ;;
      *) fail "unexpected system call: $line" ;;
    esac
  done <"$FAKE_SYS/calls"
  [[ -z $(ls -A "$TEST_TMP/curl-log") ]] || fail "network requests were made"
}

# assert_rolled_back: nothing created by the run is left (Debian package
# files aside), and Tor is back to the package's configuration, stopped.
assert_rolled_back() {
  [[ -z $(ls -A "$SB/opt") ]] || fail "left in /opt: $(ls -A "$SB/opt")"
  [[ -z $(ls -A "$SB/etc/systemd/system") ]] || fail "unit left: $(ls -A "$SB/etc/systemd/system")"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  [[ $(ls -A "$SB/var/lib") == "" || $(ls -A "$SB/var/lib") == tor ]] ||
    fail "left in /var/lib: $(ls -A "$SB/var/lib")"
  [[ $(ls -A "$SB/var/log") == "" || $(ls -A "$SB/var/log") == tor ]] ||
    fail "left in /var/log: $(ls -A "$SB/var/log")"
  ! grep -q '^tari:' "$FAKE_SYS/passwd" || fail "user tari left"
  ! grep -q '^tari:' "$FAKE_SYS/group" || fail "group tari left"
  [[ ! -e $FAKE_SYS/active.minotari-mainnet.service && ! -e $FAKE_SYS/enabled.minotari-mainnet.service ]] ||
    fail "minotari-mainnet.service left active or enabled"
  [[ ! -e $FAKE_SYS/active.tor@default.service ]] || fail "Tor left running"
  [[ -z $(<"$FAKE_SYS/listeners") ]] || fail "listeners left: $(<"$FAKE_SYS/listeners")"
  if [[ -e $SB/etc/tor/torrc ]]; then
    [[ $(<"$SB/etc/tor/torrc") == "$DEBIAN_TORRC" ]] || fail "torrc not restored"
  fi
  ! called "GUARD *" || fail "a real system command was reached: $(grep GUARD "$FAKE_SYS/calls")"
}

# expect_install_failure MESSAGE: exit 1 with MESSAGE, rolled back.
expect_install_failure() {
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stderr_contains "$1"
  assert_stderr_contains "undoing the changes made by this run"
  assert_rolled_back
}

release_id() {
  local sum
  sum=$(sha256_of "$TEST_TMP/zipsrc/minotari_node")
  echo "minotari-$FIXTURE_VERSION-linux-arm64-${sum:0:16}"
}

# --- command line ---------------------------------------------------------------

test_install_help_works_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" install --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh install [--version VERSION] [--arch ARCH] [--public-ip IPV4] [--yes]"
  assert_stdout_contains "Must be run as root; this tool itself"
  assert_stdout_contains "never escalates privileges (no sudo, su, doas or pkexec)."
  run_cli_with_path "$TEST_TMP/bare-bin" install --yes --help
  assert_status 0
  run_cli_with_path "$TEST_TMP/bare-bin" --help
  assert_status 0
  assert_stdout_contains "install     Install and start a Minotari Mainnet node"
  [[ -z $(<"$TRACE_FILE") ]] || fail "help ran commands: $(<"$TRACE_FILE")"
}

test_install_usage_errors_exit_2_before_root_and_dependency_checks() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  local -a cases=(
    "--bogus"
    "--version"
    "--version --yes"
    "--version 1.2"
    "--version v1.2.3/../x"
    "--arch mips --public-ip $INSTALL_IP"
    "--arch"
    "--public-ip"
    "--public-ip 10.0.0.1"
    "--public-ip example.com"
    "--yes"
  )
  local c
  for c in "${cases[@]}"; do
    # shellcheck disable=SC2086 # Split each case into arguments.
    run_cli_with_path "$TEST_TMP/bare-bin" install $c </dev/null
    [[ $status == 2 ]] || fail "[$c]: expected exit 2, got $status"
    assert_stdout_empty
    [[ $stderr != *"Please run as root"* && $stderr != *"missing required command"* ]] ||
      fail "[$c]: checked root or dependencies before the arguments"
  done
  run_cli install --yes </dev/null
  assert_status 2
  assert_stderr_contains "install needs --public-ip IPV4 when not run interactively"
}

test_install_as_non_root_says_please_run_as_root() {
  local args
  for args in "--public-ip $INSTALL_IP" "--public-ip $INSTALL_IP --yes" \
    "--public-ip $INSTALL_IP --version 6.0.1 --arch amd64"; do
    # shellcheck disable=SC2086 # Split into arguments.
    run_cli install $args </dev/null
    assert_status 1
    assert_stdout_empty
    [[ $stderr == "Please run as root." ]] || fail "unexpected stderr: $stderr"
  done
}

test_install_source_never_escalates_privileges() {
  local code hits
  code=$(cat "$REPO_ROOT/deploy.sh" "$REPO_ROOT/lib/install.sh" | grep -vE '^[[:space:]]*#')
  # A privilege tool in command position (start, after ; & | ( or $( ).
  hits=$(grep -nE '(^|[;&|(]|\$\(|then|do|else)[[:space:]]*(sudo|su|doas|pkexec)([[:space:]]|$)' <<<"$code") || true
  [[ -z $hits ]] || fail "privilege escalation in the source: $hits"
  hits=$(grep -nE 'curl[^|]*\|[[:space:]]*(ba)?sh|--insecure|-k[[:space:]]|apt-key|add-apt-repository|sources\.list|dist-upgrade|full-upgrade|apt-get[^\n]*upgrade|--allow-unauthenticated|/dev/(tcp|udp)/|(^|[^A-Za-z_-])eval([^A-Za-z_-]|$)' <<<"$code") || true
  [[ -z $hits ]] || fail "forbidden operation in the source: $hits"
}

test_install_validates_public_ipv4() {
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    local ip
    for ip in 1.2.3.4 8.8.8.8 1.1.1.1 172.15.255.255 172.32.0.1 \
      100.63.255.255 100.128.0.1 169.253.1.1 192.0.1.1 223.255.255.254; do
      check_public_ipv4 "$ip" || fail "rejected public address $ip: $IPV4_ERROR"
    done
    # shellcheck disable=SC2016 # Literal shell syntax must be rejected.
    for ip in "" " 8.8.8.8" "8.8.8.8 " $'8.8.8.8\n' "example.com" "::1" "2001:db8::1" \
      "8.8.8.8:18189" "8.8.8.8/32" "8.8.8.08" "08.8.8.8" "256.1.1.1" "1.2.3" "1.2.3.4.5" \
      "1.2.3.4." "8.8.8.8;id" '$(id)' $'8.8.8.\x01' $'\uff11.2.3.4' \
      0.0.0.0 0.1.2.3 10.1.2.3 172.16.0.1 172.31.255.255 192.168.1.1 127.0.0.1 \
      127.255.255.254 169.254.1.1 100.64.0.1 100.127.255.255 192.0.0.1 198.18.0.1 \
      198.19.255.255 224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255; do
      ! check_public_ipv4 "$ip" || fail "accepted '$ip'"
      [[ -n $IPV4_ERROR ]] || fail "no reason for '$ip'"
    done
    check_public_ipv4 10.0.0.1
    [[ $IPV4_ERROR == "10.0.0.1 is a private address, not a public IPv4 address" ]] || fail "$IPV4_ERROR"
    check_public_ipv4 127.0.0.1
    [[ $IPV4_ERROR == *"loopback"* ]] || fail "$IPV4_ERROR"
  ) || exit 1
}

test_install_ip_cannot_inject_into_config_or_shell() {
  local bad
  # shellcheck disable=SC2016 # Literal shell syntax must be rejected.
  for bad in '1.2.3.4"]' $'1.2.3.4\n[base_node]' '$(touch /tmp/x)' '1.2.3.4`id`' '1.2.3.4&' $'1.2.3.4\\'; do
    run_cli install --public-ip "$bad" </dev/null
    [[ $status == 2 ]] || fail "[$bad]: expected exit 2, got $status"
  done
  # The renderer itself only substitutes known placeholders, literally, with
  # safe values, and leaves none behind.
  mkdir -p "$TEST_TMP/src/templates"
  printf 'a = "@PUBLIC_IPV4@"\nb = "@OTHER@"\n' >"$TEST_TMP/src/templates/t"
  printf 'x = "@PUBLIC_IPV4@" & \\\\1\n' >"$TEST_TMP/src/templates/u"
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    INSTALL_SOURCE_DIR=$TEST_TMP/src
    out=$(render_template u PUBLIC_IPV4 203.0.113.10) || fail "render failed"
    [[ $out == 'x = "203.0.113.10" & \\1' ]] || fail "not literal: $out"
    (render_template t PUBLIC_IPV4 203.0.113.10) 2>"$TEST_TMP/err" && fail "left a placeholder"
    [[ $(<"$TEST_TMP/err") == *"unreplaced placeholder @OTHER@"* ]] || fail "$(<"$TEST_TMP/err")"
    (render_template u PUBLIC_IPV4 '1.2.3.4&') 2>/dev/null && fail "accepted '&'"
    (render_template u PUBLIC_IPV4 '1.2.3.4"') 2>/dev/null && fail "accepted a quote"
    (render_template u PUBLIC_IPV4 $'1\n2') 2>/dev/null && fail "accepted a newline"
    exit 0
  ) || exit 1
}

test_no_arguments_still_prints_real_help_and_no_menu() {
  run_cli </dev/null
  assert_status 2
  assert_stderr_contains "Usage: ./deploy.sh <command> [options]"
  assert_stderr_contains "install     Install and start"
  assert_stderr_contains "Run without arguments in a terminal for a simple menu."
  [[ $stderr != *"Select"* && $stderr != *"1)"* && $stderr != *"[1]"* ]] ||
    fail "looks like a menu"
}

# --- confirmation and checks -------------------------------------------------------

test_install_cancel_changes_nothing() {
  setup_install
  local before answer
  before=$(cd "$SB" && find . -printf '%p %y %m\n' | sort)
  for answer in "" n N no yes x " y" "Y " YES; do
    : >"$FAKE_SYS/calls"
    INSTALL_INPUT=$answer run_install --public-ip "$INSTALL_IP" --arch aarch64
    [[ $status == 0 ]] || fail "[$answer]: expected exit 0, got $status: $stderr"
    assert_stdout_contains "Minotari node installation plan"
    assert_stdout_contains "Install the Minotari node? [y/N]: "
    assert_stdout_contains "Installation cancelled; nothing was changed."
    assert_no_changes
    [[ $(cd "$SB" && find . -printf '%p %y %m\n' | sort) == "$before" ]] ||
      fail "[$answer]: the sandbox changed"
  done
}

test_install_plan_describes_what_will_change() {
  setup_install
  INSTALL_INPUT=n run_install --public-ip "$INSTALL_IP" --arch aarch64
  assert_status 0
  assert_stdout_contains "Host:           Debian 12, linux-arm64 (aarch64)"
  assert_stdout_contains "Release:        GitHub's latest full release"
  assert_stdout_contains "Public P2P:     $INSTALL_IP:18189"
  assert_stdout_contains "Service user:   tari"
  assert_stdout_contains "Services:       minotari-mainnet.service, tor@default.service"
  assert_stdout_contains "Wallet Query:   127.0.0.1:9000 only; gRPC disabled"
  assert_stdout_contains "Not changed:    DNS, Nginx, TLS, Cloudflare, firewalls, cloud security groups"
  INSTALL_INPUT=n run_install --public-ip "$INSTALL_IP" --arch aarch64 --version 6.0.1-pre.2
  assert_stdout_contains "Release:        v6.0.1-pre.2 (explicit)"
}

test_install_asks_for_the_public_ip_only_when_interactive() {
  setup_install
  FAKE_TTY=1 INSTALL_INPUT=$'1.2.3.77\nn' run_install --arch aarch64
  assert_status 0
  assert_stdout_contains "Public IPv4 address: "
  assert_stdout_contains "Public P2P:     1.2.3.77:18189"
  assert_no_changes
  FAKE_TTY=1 INSTALL_INPUT=$'192.168.1.10\n' run_install --arch aarch64
  assert_status 2
  assert_stderr_contains "192.168.1.10 is a private address"
  assert_no_changes
  INSTALL_INPUT=y run_install --arch aarch64
  assert_status 2
  assert_stderr_contains "install needs --public-ip IPV4 when not run interactively"
}

test_install_command_line_never_detects_the_public_ip() {
  setup_install
  # Even with the services the menu asks answering, the command line asks
  # for the address (interactively) or needs --public-ip; it asks nothing
  # outside.
  local url
  while IFS= read -r url; do
    mkdir -p "$(dirname -- "$FAKE_WEB_ROOT/${url#https://}")"
    printf '5.6.7.8\n' >"$FAKE_WEB_ROOT/${url#https://}"
  done < <(
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    load_install
    printf '%s\n' "${PUBLIC_IPV4_URLS[@]}"
  )
  FAKE_TTY=1 INSTALL_INPUT=$'1.2.3.77\nn' run_install --arch aarch64
  assert_status 0
  assert_stdout_contains "Public IPv4 address: "
  [[ $stdout != *Detected* && $stdout != *5.6.7.8* ]] || fail "offered a detected address"
  assert_no_changes
  INSTALL_INPUT=y run_install --arch aarch64
  assert_status 2
  assert_stderr_contains "install needs --public-ip IPV4 when not run interactively"
  assert_no_changes
}

test_install_yes_skips_only_the_confirmation() {
  setup_install
  mkdir "$SB/opt/tari"
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 1
  assert_stderr_contains "conflict: '/opt/tari' already exists"
  assert_no_changes
  rmdir "$SB/opt/tari"
  : >"$FAKE_SYS/calls"
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  [[ $stdout != *"[y/N]"* ]] || fail "asked for confirmation despite --yes"
}

test_install_refuses_a_host_that_is_not_clean() {
  local -a cases=(
    "unit@@touch \$SB/etc/systemd/system/minotari-mainnet.service@@'/etc/systemd/system/minotari-mainnet.service' already exists"
    "dropin@@mkdir \$SB/etc/systemd/system/minotari-mainnet.service.d@@minotari-mainnet.service.d' already exists"
    "lib-unit@@mkdir -p \$SB/lib/systemd/system && touch \$SB/lib/systemd/system/minotari-mainnet.service@@already exists"
    "opt@@mkdir \$SB/opt/tari@@'/opt/tari' already exists"
    "current@@mkdir \$SB/opt/tari && ln -s /nowhere \$SB/opt/tari/current@@'/opt/tari' already exists"
    "data@@mkdir \$SB/var/lib/tari@@'/var/lib/tari' already exists"
    "logs@@ln -s /tmp \$SB/var/log/tari@@'/var/log/tari' already exists"
    "user@@echo tari:x:999:999::/home/tari:/bin/sh >>\$FAKE_SYS/passwd@@user 'tari' already exists"
    "group@@echo tari:x:999: >>\$FAKE_SYS/group@@group 'tari' already exists"
    "tor-pkg@@echo tor >>\$FAKE_SYS/pkgs@@the tor package is already installed"
    "tor-etc@@mkdir \$SB/etc/tor@@'/etc/tor' exists"
    "tor-id@@mkdir \$SB/var/lib/tor@@'/var/lib/tor' exists"
    "tor-run@@mkdir \$SB/run/tor@@'/run/tor' exists"
    "tor-proc@@mkdir \$SB/proc/77 && echo tor >\$SB/proc/77/comm@@a Tor process is running"
    "p2p-port@@echo 'x 0.0.0.0:18189' >>\$FAKE_SYS/listeners@@TCP port 18189 is already in use"
    "wq-port@@echo 'x 127.0.0.1:9000' >>\$FAKE_SYS/listeners@@TCP port 9000 is already in use"
    "socks-port@@echo 'x 127.0.0.1:9050' >>\$FAKE_SYS/listeners@@TCP port 9050 is already in use"
    "control-port@@echo 'x 127.0.0.1:9051' >>\$FAKE_SYS/listeners@@TCP port 9051 is already in use"
    "grpc-port@@echo 'x 127.0.0.1:18142' >>\$FAKE_SYS/listeners@@TCP port 18142 is already in use"
    "opt-link@@rmdir \$SB/opt && ln -s \$TEST_TMP \$SB/opt@@'/opt' is not a directory"
    "varlib-writable@@chmod 777 \$SB/var/lib@@'/var/lib' is group- or world-writable"
    "tmp-mode@@chmod 755 \$SB/tmp@@/tmp is not mode 1777"
  )
  local c name action message
  for c in "${cases[@]}"; do
    name=${c%%@@*}
    action=${c#*@@}
    message=${action#*@@}
    action=${action%%@@*}
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" "$TEST_TMP/fakebin"
    setup_install
    eval "$action" || fail "[$name]: setup failed"
    if [[ -s $FAKE_SYS/listeners ]]; then
      # Rebuild /proc/net/tcp from the listener list (via the fake).
      "$TEST_TMP/fakebin/systemctl" stop minotari-mainnet.service
      : >"$FAKE_SYS/calls"
    fi
    local before
    before=$(cd "$SB" && find . -printf '%p %y %m %s\n' | sort)
    run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
    [[ $status == 1 ]] || fail "[$name]: expected exit 1, got $status"
    assert_stderr_contains "$message"
    assert_no_changes
    [[ $(cd "$SB" && find . -printf '%p %y %m %s\n' | sort) == "$before" ]] ||
      fail "[$name]: the existing setup was changed"
  done
}

test_install_refuses_unsupported_platforms() {
  setup_install
  local c
  # FIXTURE @@ message
  for c in "ubuntu-25.10@@unsupported Ubuntu version '25.10' (install supports Debian 12 and 13 and Ubuntu 24.04 and 26.04)" \
    "fedora-42@@unsupported Linux distribution 'fedora' (install supports Debian 12 and 13 and Ubuntu 24.04 and 26.04)" \
    "debian-11@@unsupported Debian version '11'"; do
    cp "$FIXTURES/os-release/${c%%@@*}" "$SB/etc/os-release"
    run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
    [[ $status == 1 ]] || fail "[${c%%@@*}]: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "${c#*@@}"
    assert_no_changes
  done
}

# ubuntu_host VERSION: the sandbox is an Ubuntu host, with its standard /var/log
# (root, group syslog, 0775; on real hosts syslog is GID 101, here the
# sandbox root's group, as only real root may give away a directory).
ubuntu_host() {
  cp "$FIXTURES/os-release/ubuntu-${1:-26.04}" "$SB/etc/os-release"
  printf 'syslog:x:%s:\n' "$(id -g)" >>"$FAKE_SYS/group"
  chmod 775 "$SB/var/log"
}

test_install_on_supported_ubuntu_releases_plans_and_installs_on_both_architectures() {
  local version pair before unit
  for version in 24.04 26.04; do
    for pair in aarch64:linux-arm64 x86_64:linux-x86_64; do
      rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/curl-log"
      setup_install
      ubuntu_host "$version"
      before=$(cd "$SB" && find . -printf '%p %y %m\n' | sort)
      # The plan, then cancelling changes nothing.
      INSTALL_INPUT=n run_install --public-ip "$INSTALL_IP" --arch "${pair%%:*}"
      [[ $status == 0 ]] || fail "[$version/$pair]: expected exit 0, got $status: $stderr"
      assert_stdout_contains "Host:           Ubuntu $version, ${pair#*:} (${pair%%:*})"
      assert_stdout_contains "Packages:       ca-certificates curl jq unzip tor (only missing ones; no system upgrade)"
      assert_stdout_contains "Installation cancelled; nothing was changed."
      assert_no_changes
      [[ $(cd "$SB" && find . -printf '%p %y %m\n' | sort) == "$before" ]] || fail "[$version/$pair]: cancelling changed the sandbox"
      # The normal path.
      : >"$FAKE_SYS/calls"
      run_install --public-ip "$INSTALL_IP" --arch "${pair%%:*}" --yes
      [[ $status == 0 ]] || fail "[$version/$pair]: install failed: $stderr"
      assert_stderr_contains "==> installing APT packages: ca-certificates curl jq unzip tor"
      [[ $stdout$stderr != *"Debian packages"* ]] || fail "[$version/$pair]: told an Ubuntu user about Debian packages"
      [[ $(readlink "$SB/opt/tari/current") == "releases/minotari-$FIXTURE_VERSION-${pair#*:}-"* ]] ||
        fail "[$version/$pair]: current: $(readlink "$SB/opt/tari/current")"
      grep -qx "platform=${pair#*:}" "$SB/var/lib/tari/taritalk-install-state" || fail "[$version/$pair]: record platform"
      for unit in minotari-mainnet.service tor@default.service; do
        [[ -e $FAKE_SYS/active.$unit ]] || fail "[$version/$pair]: $unit not active"
      done
      ! called "GUARD *" || fail "[$version/$pair]: a real system command was reached"
    done
  done
}

test_install_accepts_only_ubuntus_own_writable_var_log() {
  local c
  # SETUP @@ refused directory; each starts from an Ubuntu 26.04 host whose
  # /var/log is root:syslog 0775.
  for c in "cp \$FIXTURES/os-release/debian-13 \$SB/etc/os-release@@/var/log" \
    "chmod 777 \$SB/var/log@@/var/log" \
    "chmod 2775 \$SB/var/log@@/var/log" \
    "chmod 757 \$SB/var/log@@/var/log" \
    "sed -i /^syslog:/d \$FAKE_SYS/group@@/var/log" \
    "sed -i 's/^syslog:x:[0-9]*:/syslog:x:4242:/' \$FAKE_SYS/group@@/var/log" \
    "chmod 775 \$SB/var/lib@@/var/lib" \
    "chmod 775 \$SB/etc@@/etc"; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys"
    setup_install
    ubuntu_host
    eval "${c%%@@*}" || fail "[${c%%@@*}]: setup failed"
    : >"$FAKE_SYS/calls"
    run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
    [[ $status == 1 ]] || fail "[${c%%@@*}]: expected exit 1, got $status"
    assert_stderr_contains "unexpected host layout: '${c#*@@}' is group- or world-writable"
    assert_no_changes
  done
}

test_install_refuses_to_run_twice() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  : >"$FAKE_SYS/calls"
  rm -f "$TEST_TMP"/curl-log/*
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 1
  assert_stderr_contains "a Minotari node installed by taritalk-node-deploy already exists; reinstalling is not supported; to move to a newer release run './deploy.sh upgrade'"
  assert_no_changes
  [[ -e $FAKE_SYS/active.minotari-mainnet.service ]] || fail "the installed node was touched"
}

# --- the installation -----------------------------------------------------------

test_install_installs_and_starts_a_node() {
  setup_install
  INSTALL_INPUT=y run_install --public-ip "$INSTALL_IP" --arch aarch64
  [[ $status == 0 ]] || fail "install failed: $stderr"
  local id
  id=$(release_id)
  [[ $(readlink "$SB/opt/tari/current") == "releases/$id" ]] || fail "current: $(readlink "$SB/opt/tari/current")"
  local me
  me="$(id -u):$(id -g)"
  local -a expect=(
    "opt/tari|directory|755"
    "opt/tari/releases|directory|755"
    "opt/tari/releases/$id|directory|755"
    "opt/tari/releases/$id/minotari_node|regular file|755"
    "opt/tari/releases/$id/verification.txt|regular file|644"
    "var/lib/tari|directory|750"
    "var/lib/tari/mainnet|directory|700"
    "var/lib/tari/mainnet/mainnet/config|directory|700"
    "var/lib/tari/mainnet/mainnet/config/config.toml|regular file|600"
    "var/lib/tari/mainnet/mainnet/config/base_node/log4rs.yml|regular file|600"
    "var/lib/tari/taritalk-install-state|regular file|600"
    "var/log/tari|directory|700"
    "var/log/tari/log/base_node|directory|700"
    "etc/systemd/system/minotari-mainnet.service|regular file|644"
    "etc/tor/torrc|regular file|644"
  )
  local e path
  for e in "${expect[@]}"; do
    path=${e%%|*}
    [[ $(stat -c '%F|%a' "$SB/$path") == "${e#*|}" ]] ||
      fail "$path: $(stat -c '%F|%a' "$SB/$path"), expected ${e#*|}"
    [[ $(stat -c '%u:%g' "$SB/$path") == "$me" ]] || fail "$path: owner"
  done
  [[ $(sha256_of "$SB/opt/tari/releases/$id/minotari_node") == $(sha256_of "$TEST_TMP/zipsrc/minotari_node") ]] ||
    fail "installed binary differs from the release"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  grep -q '^tari:x:[0-9]*:[0-9]*::/var/lib/tari:/usr/sbin/nologin$' "$FAKE_SYS/passwd" || fail "user tari"
  grep -q '^debian-tor:x:4100:tari$' "$FAKE_SYS/group" || fail "tari not in debian-tor"
  local unit
  for unit in minotari-mainnet.service tor@default.service; do
    [[ -e $FAKE_SYS/active.$unit ]] || fail "$unit not active"
  done
  [[ -e $FAKE_SYS/enabled.minotari-mainnet.service && -e $FAKE_SYS/enabled.tor.service ]] ||
    fail "services not enabled"
  assert_order "groupadd --system tari" \
    "useradd --system --gid tari --groups debian-tor --home-dir /var/lib/tari --no-create-home --shell /usr/sbin/nologin tari"
  ! called "GUARD *" || fail "a real system command was reached"
}

test_install_runs_only_fixed_apt_commands() {
  setup_install
  printf 'ca-certificates\ncurl\n' >"$FAKE_SYS/pkgs"
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  local apt
  apt=$(grep '^apt-get' "$FAKE_SYS/calls")
  [[ $apt == "apt-get -q update"$'\n'"apt-get -q -y --no-install-recommends -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef install -- jq unzip tor" ]] ||
    fail "unexpected apt-get calls: $apt"
  grep -q '^packages_installed=jq,unzip,tor$' "$SB/var/lib/tari/taritalk-install-state" ||
    fail "state does not record the packages installed"
}

test_install_runs_fetch_as_the_service_user() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  local fetch_call work
  fetch_call=$(grep '^runuser -u tari -- env -i .* fetch ' "$FAKE_SYS/calls") || fail "fetch did not run as tari"
  work=${fetch_call#*TMPDIR=}
  work=${work%%/dltmp *}
  [[ $work == "$SB/tmp/taritalk-install."* ]] || fail "unexpected work dir: $work"
  [[ $fetch_call == "runuser -u tari -- env -i PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin HOME=/var/lib/tari LC_ALL=C TMPDIR=$work/dltmp $work/tool/deploy.sh fetch --destination $work/dl --arch aarch64" ]] ||
    fail "unexpected fetch call: $fetch_call"
  [[ $(curl_call_count) == 4 ]] || fail "fetch made $(curl_call_count) requests"
  # The explicit version is passed through.
  rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/curl-log"
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch arm64 --version v6.0.1-pre.2 --yes
  assert_status 0
  grep -q -- ' fetch --destination .*/dl --arch arm64 --version v6.0.1-pre.2$' "$FAKE_SYS/calls" ||
    fail "version not passed to fetch"
  grep -q '^tag=v6.0.1-pre.2$' "$SB/var/lib/tari/taritalk-install-state" || fail "state tag"
}

test_install_executes_the_binary_only_after_installing_and_reverifying_it() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  [[ $(<"$TEST_TMP/node-trace") == "--version" ]] || fail "node runs: $(<"$TEST_TMP/node-trace")"
  local id
  id=$(release_id)
  assert_order "runuser -u tari -- env -i * fetch *" \
    "runuser -u tari -- env -i PATH=* HOME=/var/lib/tari LC_ALL=C $SB/opt/tari/releases/$id/minotari_node --version" \
    "runuser -u debian-tor -- tor --verify-config -f $SB/etc/tor/torrc" \
    "systemctl daemon-reload" "systemctl start tor@default.service" \
    "systemctl start minotari-mainnet.service"
}

test_install_stops_on_a_wrong_binary_version() {
  setup_install
  write_fake_node "$TEST_TMP/zipsrc/minotari_node" "minotari_node 9.9.9"
  rezip minotari_node README.md
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  expect_install_failure "'minotari_node --version' does not report version $FIXTURE_VERSION"
  ! called "runuser -u debian-tor -- tor *" || fail "continued to Tor"
  ! called "systemctl start minotari-mainnet.service" || fail "started the node"
}

test_install_writes_the_audited_node_configuration() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  local config=$SB/var/lib/tari/mainnet/mainnet/config/config.toml expected
  expected=$(sed 's/@PUBLIC_IPV4@/1.2.3.4/' "$REPO_ROOT/templates/config.toml.in")
  [[ $(<"$config") == "$expected" ]] || fail "config differs from the template"
  local line
  for line in "grpc_enabled = false" "grpc_readiness_enabled = false" "use_libtor = false" \
    "pruning_horizon = 0" "track_reorgs = true" \
    'public_addresses = ["/ip4/1.2.3.4/tcp/18189"]' \
    'auxiliary_tcp_listener_address = "/ip4/0.0.0.0/tcp/18189"' 'type = "tcp_tor"' \
    'tcp.listener_address = "/ip4/0.0.0.0/tcp/18189"' \
    'tor.control_address = "/ip4/127.0.0.1/tcp/9051"' 'listen_ip = "127.0.0.1"'; do
    grep -qxF "$line" "$config" || fail "config lacks: $line"
  done
  if command -v python3 >/dev/null && python3 -c 'import tomllib' 2>/dev/null; then
    python3 - "$config" <<'PY' || fail "config does not parse as the expected TOML"
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))["base_node"]
assert c["grpc_enabled"] is False and c["grpc_readiness_enabled"] is False
assert c["use_libtor"] is False
assert c["storage"] == {"pruning_horizon": 0, "track_reorgs": True}
p = c["p2p"]
assert p["public_addresses"] == ["/ip4/1.2.3.4/tcp/18189"]
assert p["auxiliary_tcp_listener_address"] == "/ip4/0.0.0.0/tcp/18189"
assert p["transport"] == {"type": "tcp_tor", "tcp": {"listener_address": "/ip4/0.0.0.0/tcp/18189"},
                          "tor": {"control_address": "/ip4/127.0.0.1/tcp/9051"}}
assert c["http_wallet_query_service"] == {"listen_ip": "127.0.0.1"}
assert set(c) == {"grpc_enabled", "grpc_readiness_enabled", "use_libtor", "storage", "p2p", "http_wallet_query_service"}
PY
  fi
  [[ $(<"$SB/var/lib/tari/mainnet/mainnet/config/base_node/log4rs.yml") == "$(<"$REPO_ROOT/templates/log4rs.yml")" ]] ||
    fail "log4rs.yml differs from the template"
}

test_log_template_is_minimal_and_private() {
  local t=$REPO_ROOT/templates/log4rs.yml
  grep -q 'level: warn' "$t" || fail "console threshold"
  [[ $(grep -c 'limit: 10mb' "$t") == 5 && $(grep -c 'count: 5' "$t") == 5 ]] || fail "rotation"
  ! grep -vE '^[[:space:]]*#' "$t" | grep -E 'path: ' | grep -v '"/var/log/tari/log/base_node/' ||
    fail "log path outside /var/log/tari/log/base_node"
  ! grep -qiE 'X\(|env|token|cookie|secret|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$t" || fail "sensitive or host-specific content"
  local f
  for f in "$REPO_ROOT"/templates/*; do
    ! grep -qE '(^|[^0-9.])(10|192\.168|203\.0\.113)\.[0-9]+\.[0-9]+' "$f" || fail "$f has an address"
    ! grep -qiE 'taritalk\.|hermes|/root/|/home/' "$f" || fail "$f has a private name or path"
  done
}

test_install_configures_tor_for_loopback_and_verifies_before_start() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  [[ $(<"$SB/etc/tor/torrc") == "$(<"$REPO_ROOT/templates/torrc")" ]] || fail "torrc differs from the template"
  local expected=$'SocksPort 127.0.0.1:9050\nControlPort 127.0.0.1:9051\nCookieAuthentication 1\nCookieAuthFileGroupReadable 1\nDataDirectory /var/lib/tor\nLog notice syslog'
  [[ $(grep -vE '^#' "$SB/etc/tor/torrc") == "$expected" ]] || fail "torrc settings"
  ! grep -qiE 'ORPort|DirPort|ExitRelay|0\.0\.0\.0' "$SB/etc/tor/torrc" || fail "torrc opens Tor beyond loopback"
  [[ $(<"$FAKE_SYS/verified-torrc") == "$(<"$SB/etc/tor/torrc")" ]] || fail "verified another torrc"
  # The package's Tor is stopped before anything is configured, and Tor is
  # only started again after tor --verify-config accepted the new file.
  assert_order "apt-get * install -- *tor" "systemctl stop tor@default.service" \
    "systemctl stop tor.service" "runuser -u debian-tor -- tor --verify-config -f *" \
    "systemctl enable tor.service" "systemctl start tor@default.service"
  [[ $(grep -c 'start tor@default.service' "$FAKE_SYS/calls") == 1 ]] || fail "Tor started more than once"
}

test_install_writes_the_hardened_service_unit() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  local unit=$SB/etc/systemd/system/minotari-mainnet.service line
  [[ $(<"$unit") == "$(<"$REPO_ROOT/templates/minotari-mainnet.service")" ]] || fail "unit differs from the template"
  for line in "User=tari" "Group=tari" "UMask=0077" "Type=simple" \
    "ExecStart=/opt/tari/current/minotari_node --base-path /var/lib/tari/mainnet --network mainnet --non-interactive-mode --disable-splash-screen" \
    "Wants=network-online.target tor@default.service" "After=network-online.target tor@default.service" \
    "Restart=on-failure" "NoNewPrivileges=true" "PrivateTmp=true" "PrivateDevices=true" \
    "ProtectSystem=strict" "ProtectHome=true" "ReadWritePaths=/var/lib/tari /var/log/tari" \
    "ProtectKernelTunables=true" "ProtectKernelModules=true" "ProtectKernelLogs=true" \
    "ProtectControlGroups=true" "RestrictSUIDSGID=true" "LockPersonality=true" \
    "RestrictRealtime=true" "SystemCallArchitectures=native" "WantedBy=multi-user.target"; do
    grep -qxF "$line" "$unit" || fail "unit lacks: $line"
  done
  ! grep -qE 'grpc|--enable|MINOTARI_NODE_ENABLE|Environment' "$unit" || fail "unit enables something"
  # Nothing is reloaded, enabled or started before every file is in place
  # and verified.
  local reload
  reload=$(call_no "systemctl daemon-reload")
  ((reload > $(call_no "runuser -u debian-tor -- tor --verify-config *"))) || fail "reload before Tor was verified"
  ((reload < $(call_no "systemctl enable *"))) || fail "enabled before reload"
}

test_install_success_writes_state_without_secrets() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  local state=$SB/var/lib/tari/taritalk-install-state keys
  keys=$(cut -d= -f1 "$state" | tr '\n' ' ')
  [[ $keys == "format tool_version tag version platform asset archive_sha256 binary_sha256 release_dir public_ip installed_at packages_installed " ]] ||
    fail "state keys: $keys"
  grep -qE '^[a-z_0-9]+=[A-Za-z0-9.:/_,+-]*$' "$state" || fail "state value format"
  ! grep -qvE '^[a-z_0-9]+=[A-Za-z0-9.:/_,+-]*$' "$state" || fail "unexpected state line"
  local line
  for line in "tool_version=0.1.0" "version=$FIXTURE_VERSION" "platform=linux-arm64" \
    "asset=$ASSET_ARM64" "archive_sha256=$(sha256_of "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64")" \
    "binary_sha256=$(sha256_of "$TEST_TMP/zipsrc/minotari_node")" \
    "release_dir=/opt/tari/releases/$(release_id)" "public_ip=$INSTALL_IP"; do
    grep -qxF "$line" "$state" || fail "state lacks: $line"
  done
  grep -qE '^installed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$state" || fail "state time"
  ! grep -qiE 'key|secret|cookie|token|private|identity' "$state" || fail "state looks sensitive"
  ! grep -qE 'source|\. ' <(grep -vE '^[[:space:]]*#' "$REPO_ROOT/lib/install.sh" | grep -i 'state') ||
    fail "the state record is sourced somewhere"
}

test_install_success_output_is_honest() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  assert_stdout_has_line "Installed: Minotari $FIXTURE_VERSION (linux-arm64)"
  assert_stdout_has_line "Release directory: /opt/tari/releases/$(release_id)"
  assert_stdout_has_line "Service: minotari-mainnet.service (active)"
  assert_stdout_has_line "Public P2P address: $INSTALL_IP:18189"
  assert_stdout_has_line "Wallet Query: 127.0.0.1:9000 (local only)"
  assert_stdout_has_line "gRPC: disabled"
  assert_stdout_has_line "Data directory: /var/lib/tari/mainnet"
  assert_stdout_has_line "The node has started its initial sync; it is not yet synced."
  assert_stdout_contains "tool did not change any firewall and has not tested reachability from outside."
  [[ $stdout != *"fully synced"* && $stdout != *"is reachable"* && $stdout != *"cookie"* ]] ||
    fail "output overclaims or leaks"
}

# --- failures and rollback --------------------------------------------------------

test_install_rolls_back_at_every_failure_point() {
  local -a cases=(
    "FAKE_SYS_FAIL=apt-get -q update@@apt-get update failed@@apt-get * install *"
    "FAKE_SYS_FAIL=apt-get * install *@@apt-get install failed@@groupadd *"
    "FAKE_SYS_FAIL=systemctl stop tor.service@@cannot stop tor.service@@groupadd *"
    "FAKE_SYS_FAIL=groupadd *@@cannot create group tari@@useradd *"
    "FAKE_SYS_FAIL=useradd *@@cannot create user tari@@runuser *"
    "FAKE_CURL_FAIL_NAME=$ASSET_ARM64@@fetch failed@@runuser -u tari -- env -i * --version"
    "FAKE_SYS_FAIL=runuser -u tari -- env -i * --version@@'minotari_node --version' failed@@runuser -u debian-tor *"
    "FAKE_SYS_FAIL=runuser -u debian-tor -- tor --verify-config *@@tor --verify-config rejected the configuration@@systemctl start tor@default.service"
    "FAKE_SYS_FAIL=systemctl daemon-reload@@systemctl daemon-reload failed@@systemctl start tor@default.service"
    "FAKE_SYS_FAIL=systemctl enable tor.service@@cannot enable tor.service@@systemctl start tor@default.service"
    "FAKE_SYS_FAIL=systemctl start tor@default.service@@cannot start tor@default.service@@systemctl enable minotari-mainnet.service"
    "FAKE_TOR_LISTEN=0.0.0.0:9050 127.0.0.1:9051@@timed out after 3s waiting for Tor@@systemctl enable minotari-mainnet.service"
    "FAKE_SYS_FAIL=systemctl enable minotari-mainnet.service@@cannot enable minotari-mainnet.service@@systemctl start minotari-mainnet.service"
    "FAKE_SYS_FAIL=systemctl start minotari-mainnet.service@@cannot start minotari-mainnet.service@@systemctl is-active *"
    "FAKE_NODE_LISTEN=0.0.0.0:18189@@timed out after 3s waiting for minotari-mainnet.service@@systemctl is-enabled *"
    "FAKE_NODE_LISTEN=0.0.0.0:18189 0.0.0.0:9000@@timed out after 3s waiting for minotari-mainnet.service@@systemctl is-enabled *"
    "FAKE_NODE_ACTIVE=activating@@timed out after 3s waiting for minotari-mainnet.service@@systemctl is-enabled *"
    "FAKE_NODE_LISTEN=0.0.0.0:18189 127.0.0.1:9000 127.0.0.1:18142@@something listens on the gRPC port 18142@@NONE"
    "FAKE_NRESTARTS=1@@minotari-mainnet.service has restarted@@NONE"
    "FAKE_NODE_EXE=/usr/bin/other@@does not run /opt/tari/releases/@@NONE"
  )
  local c setting message later var value
  for c in "${cases[@]}"; do
    setting=${c%%@@*}
    message=${c#*@@}
    later=${message#*@@}
    message=${message%%@@*}
    var=${setting%%=*}
    value=${setting#*=}
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_install
    (
      export "$var=$value"
      run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
      [[ $status == 1 ]] || fail "[$setting]: expected exit 1, got $status: $stderr"
      assert_stderr_contains "$message"
      assert_stderr_contains "undoing the changes made by this run"
      assert_rolled_back
      [[ $later == NONE ]] || ! called "$later" || fail "[$setting]: continued with '$later'"
      [[ ! -e $SB/var/lib/tari/taritalk-install-state ]] || fail "[$setting]: state written"
      if grep -qx tor "$FAKE_SYS/pkgs"; then
        assert_stderr_contains "APT packages installed by this run are kept (removing packages could break the system): ca-certificates curl jq unzip tor"
      fi
    ) || fail "case [$setting] failed"
  done
}

test_install_refuses_tampered_fetch_output() {
  local ZEROS
  ZEROS=$(printf '0%.0s' {1..64})
  local -a cases=(
    "binary-symlink@@cp minotari_node ../copy && rm minotari_node && ln -s ../copy minotari_node@@is not a private regular file"
    "binary-hardlink@@ln minotari_node ../hardlink@@is not a private regular file"
    "binary-fifo@@rm minotari_node && mkfifo -m 700 minotari_node@@is not a private regular file"
    "binary-mode@@chmod 755 minotari_node@@is not a private regular file"
    "binary-modified@@printf x >>minotari_node@@the copied binary does not match its verified SHA-256"
    "archive-modified@@printf x >>$ASSET_ARM64@@$ASSET_ARM64 does not match its verified SHA-256"
    "sidecar-modified@@sed -i 's/^[0-9a-f]\\{64\\}/$ZEROS/' $ASSET_ARM64.sha256@@$ASSET_ARM64.sha256 does not match the verified archive"
    "manifest-modified@@sed -i 's/^[0-9a-f]\\{64\\}  $ASSET_ARM64\$/$ZEROS  $ASSET_ARM64/' $MANIFEST_NAME@@the release manifest does not match the verified archive"
    "record-modified@@printf 'x\\n' >>verification.txt@@verification.txt does not match the verified release"
    "record-symlink@@cp verification.txt ../rec && rm verification.txt && ln -s ../rec verification.txt@@is not a private regular file"
    "extra-file@@: >extra@@unexpected files in the fetch output"
    "dir-mode@@chmod 750 .@@the fetch output directory is not private"
  )
  local c name action message
  for c in "${cases[@]}"; do
    name=${c%%@@*}
    action=${c#*@@}
    message=${action#*@@}
    action=${action%%@@*}
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace" "$TEST_TMP/hook.done"
    setup_install
    install_post_fetch_hook "$action"
    run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
    [[ -e $TEST_TMP/hook.done ]] || fail "[$name]: the hook did not run"
    rm -f "$TEST_TMP/hook.done"
    [[ $status == 1 ]] || fail "[$name]: expected exit 1, got $status"
    assert_stderr_contains "$message"
    assert_rolled_back
    [[ ! -e $TEST_TMP/node-trace ]] || fail "[$name]: the binary was executed"
    ! called "runuser -u tari -- env -i * --version" || fail "[$name]: continued to the version check"
  done
}

# install_post_fetch_hook ACTION: a realpath wrapper that, the first time the
# installer resolves the download directory after fetch finished, runs
# ACTION inside the fetch output directory.
install_post_fetch_hook() {
  local real
  real=$(type -aP realpath | grep -v "$TEST_TMP" | head -n 1)
  cat >"$TEST_TMP/fakebin/realpath" <<HOOK
#!/usr/bin/env bash
if [[ \$1 == -e && \$3 == */dl && -d \$3/minotari-$FIXTURE_VERSION-linux-arm64 && ! -e '$TEST_TMP/hook.done' ]]; then
  touch '$TEST_TMP/hook.done'
  (cd "\$3/minotari-$FIXTURE_VERSION-linux-arm64" && $1) || exit 99
fi
exec '$real' "\$@"
HOOK
  chmod +x "$TEST_TMP/fakebin/realpath"
}

test_install_never_overwrites_a_release_directory() {
  setup_install
  local id real
  id=$(release_id)
  real=$(type -aP sha256sum | grep -v "$TEST_TMP" | head -n 1)
  # Someone creates the release directory just before it is published.
  cat >"$TEST_TMP/fakebin/sha256sum" <<HOOK
#!/usr/bin/env bash
if [[ \$2 == */.stage.*/minotari_node && ! -e '$TEST_TMP/hook.done' ]]; then
  touch '$TEST_TMP/hook.done'
  mkdir '$SB/opt/tari/releases/$id' && echo foreign >'$SB/opt/tari/releases/$id/file'
fi
exec '$real' "\$@"
HOOK
  chmod +x "$TEST_TMP/fakebin/sha256sum"
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  [[ -e $TEST_TMP/hook.done ]] || fail "hook did not run"
  assert_status 1
  assert_stderr_contains "'/opt/tari/releases/$id' already exists; refusing to overwrite"
  [[ $(<"$SB/opt/tari/releases/$id/file") == foreign && $(ls -A "$SB/opt/tari/releases/$id") == file ]] ||
    fail "the existing release directory was changed"
  [[ ! -e $SB/opt/tari/current && ! -L $SB/opt/tari/current ]] || fail "current was published"
  ! called "runuser -u tari -- env -i * --version" || fail "continued after the conflict"
}

test_install_cleanup_never_follows_swapped_paths() {
  setup_install
  mkdir -p "$TEST_TMP/victim"
  echo keep >"$TEST_TMP/victim/file"
  # Just before the node is started (and fails to start), the paths the
  # install created are replaced.
  cat >"$TEST_TMP/swap" <<SWAP
#!/usr/bin/env bash
set -e
mv '$SB/var/log/tari' '$TEST_TMP/moved-logs'
ln -s '$TEST_TMP/victim' '$SB/var/log/tari'
rm '$SB/opt/tari/current'
ln -s '$TEST_TMP/victim' '$SB/opt/tari/current'
mv '$SB/var/lib/tari/mainnet' '$TEST_TMP/moved-data'
mkdir '$SB/var/lib/tari/mainnet'
echo keep >'$SB/var/lib/tari/mainnet/file'
SWAP
  chmod +x "$TEST_TMP/swap"
  FAKE_SYS_HOOK_ON="systemctl start minotari-mainnet.service" FAKE_SYS_HOOK=$TEST_TMP/swap \
    FAKE_SYS_FAIL="systemctl start minotari-mainnet.service" \
    run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 1
  assert_stderr_contains "$SB/var/log/tari was replaced; leaving it untouched"
  assert_stderr_contains "$SB/opt/tari/current was replaced; leaving it untouched"
  assert_stderr_contains "$SB/var/lib/tari/mainnet was replaced; leaving it untouched"
  assert_stderr_contains "rollback was incomplete"
  [[ $(<"$TEST_TMP/victim/file") == keep && $(ls -A "$TEST_TMP/victim") == file ]] ||
    fail "cleanup followed a swapped path into the victim"
  [[ -L $SB/var/log/tari && $(readlink "$SB/var/log/tari") == "$TEST_TMP/victim" ]] || fail "swapped log path touched"
  [[ -L $SB/opt/tari/current && $(readlink "$SB/opt/tari/current") == "$TEST_TMP/victim" ]] || fail "swapped current touched"
  [[ $(<"$SB/var/lib/tari/mainnet/file") == keep ]] || fail "swapped data directory touched"
  grep -q '^tari:' "$FAKE_SYS/passwd" || fail "removed the user although files may remain"
  # What cleanup could verify is still undone.
  [[ ! -e $SB/etc/systemd/system/minotari-mainnet.service ]] || fail "unit left"
  [[ $(<"$SB/etc/tor/torrc") == "$DEBIAN_TORRC" ]] || fail "torrc not restored"
}

# --- signals ------------------------------------------------------------------------

# write_install_harness FILE ROOT_IDS SOURCE_DIR: a script that runs
# cmd_install (from SOURCE_DIR) as "root" against the sandbox, with its
# arguments; the same set-up as run_install, as a separate process.
write_install_harness() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\nsource %q\nsource %q\n' "$3/deploy.sh" "$3/lib/fetch.sh" "$3/lib/install.sh"
    printf 'is_root() { return 0; }\nis_interactive() { return 1; }\n'
    printf 'SYSROOT=%q\nROOT_IDS=%q\n' "$SB" "$2"
    printf 'INSTALL_PATH=%q\n' "$TEST_TMP/fakebin:${HARNESS_GUARD:-$TESTS_DIR/guard}:/usr/sbin:/usr/bin:/sbin:/bin"
    printf 'CHILD_PATH=%q\n' "$TEST_TMP/fakebin:${HARNESS_GUARD:-$TESTS_DIR/guard}:/usr/bin:/bin"
    printf 'INSTALL_SOURCE_DIR=%q\nTOR_WAIT_SECONDS=3\nNODE_WAIT_SECONDS=3\n' "$3"
    printf 'cmd_install "$@"\n'
  } >"$1"
  chmod 755 "$1"
}

# start_install_in_background: the harness as a background job whose INT is
# not ignored (a plain `&` job of a non-interactive shell ignores SIGINT,
# unlike an install started from a terminal); sets INSTALL_PID.
start_install_in_background() {
  write_install_harness "$TEST_TMP/harness.sh" "$(id -u):$(id -g)" "$REPO_ROOT"
  env --default-signal=INT,QUIT bash "$TEST_TMP/harness.sh" --public-ip "$INSTALL_IP" \
    --arch aarch64 --yes </dev/null >"$TEST_TMP/out" 2>&1 &
  INSTALL_PID=$!
}

# no_process_with_pid_file FILE: the process recorded in FILE is gone.
assert_process_gone() {
  local pid i
  pid=$(<"$1")
  for ((i = 0; i < 50; i++)); do
    process_running "$pid" || return 0
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null
  fail "process $pid ($1) kept running"
}

test_install_signals_stop_children_and_roll_back() {
  local -a cases=(
    "TERM 143 FAKE_SYS_HANG=apt-get * install * hang.pid"
    "INT 130 FAKE_CURL_SLEEP_NAME=$ASSET_ARM64 sleep.pid"
    "HUP 129 FAKE_SYS_HANG=runuser -u debian-tor -- tor --verify-config * hang.pid"
    "TERM 143 FAKE_SYS_HANG=systemctl start minotari-mainnet.service hang.pid"
  )
  local c sig code setting pidfile var value
  for c in "${cases[@]}"; do
    read -r sig code setting <<<"$c"
    pidfile=${setting##* }
    setting=${setting% *}
    var=${setting%%=*}
    value=${setting#*=}
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_install
    local dir=$FAKE_SYS
    [[ $pidfile == sleep.pid ]] && dir=$TEST_TMP/curl-log
    (
      export "$var=$value"
      start_install_in_background
      wait_for_file "$dir/$pidfile"
      kill -s "$sig" "$INSTALL_PID"
      wait "$INSTALL_PID"
      status=$?
      [[ $status == "$code" ]] || fail "[$sig during $value]: expected $code, got $status: $(<"$TEST_TMP/out")"
      assert_process_gone "$dir/$pidfile"
      stderr=$(<"$TEST_TMP/out")
      assert_stderr_contains "undoing the changes made by this run"
      assert_rolled_back
    ) || fail "case [$sig during $value] failed"
  done
}

# INT or HUP during the download (fetch, nested, as tari) still stops it and
# rolls back where `timeout` kills its group on INT and HUP instead of passing
# them on, as uutils timeout 0.10 (Ubuntu 26.04) does.
test_install_int_or_hup_stops_the_download_with_a_timeout_that_kills_on_them() {
  local c sig code
  for c in "INT 130" "HUP 129"; do
    read -r sig code <<<"$c"
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_install
    ln -sf "$TESTS_DIR/fakes/timeout-kill-on-int" "$TEST_TMP/fakebin/timeout"
    (
      export FAKE_CURL_SLEEP_NAME=$ASSET_ARM64
      start_install_in_background
      wait_for_file "$TEST_TMP/curl-log/sleep.pid"
      kill -s "$sig" "$INSTALL_PID"
      wait "$INSTALL_PID"
      status=$?
      [[ $status == "$code" ]] || fail "[$sig]: expected $code, got $status: $(<"$TEST_TMP/out")"
      assert_process_gone "$TEST_TMP/curl-log/sleep.pid"
      stderr=$(<"$TEST_TMP/out")
      assert_stderr_contains "undoing the changes made by this run"
      assert_rolled_back
    ) || fail "case [$sig during the download] failed"
  done
}

test_install_publishes_current_by_atomic_rename() {
  setup_install
  local tool real
  # Record every ln and mv the installer runs (fetch runs neither).
  for tool in ln mv; do
    real=$(type -aP "$tool" | grep -v "$TEST_TMP" | head -n 1)
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>%q\nexec %q "$@"\n' "$tool" \
      "$TEST_TMP/fs-calls" "$real" >"$TEST_TMP/fakebin/$tool"
    chmod +x "$TEST_TMP/fakebin/$tool"
  done
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  local calls
  calls=$(grep -E 'opt/tari/(current|\.current)' "$TEST_TMP/fs-calls")
  [[ $calls =~ ^"ln -s -- releases/$(release_id) $SB/opt/tari/.current."[0-9]+$'\n'"mv --no-target-directory -- $SB/opt/tari/.current."[0-9]+" $SB/opt/tari/current"$ ]] ||
    fail "current was not published by renaming a new symlink: $calls"
  [[ -L $SB/opt/tari/current && -z $(find "$SB/opt/tari" -maxdepth 1 -name '.current.*') ]] ||
    fail "temporary link left"
}

test_install_accepts_tor_enabled_runtime_and_rejects_disabled() {
  local state
  for state in enabled-runtime disabled; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_install
    # systemctl answers STATE for `is-enabled tor@default.service`; every
    # other call goes to the unchanged fake (which dispatches on its name).
    mkdir -p "$TEST_TMP/realsys"
    ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/realsys/systemctl"
    rm "$TEST_TMP/fakebin/systemctl"
    cat >"$TEST_TMP/fakebin/systemctl" <<WRAP
#!/usr/bin/env bash
if [[ \$* == "is-enabled tor@default.service" ]]; then
  echo $state
  exit 0
fi
exec '$TEST_TMP/realsys/systemctl' "\$@"
WRAP
    chmod +x "$TEST_TMP/fakebin/systemctl"
    run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
    if [[ $state == enabled-runtime ]]; then
      [[ $status == 0 ]] || fail "enabled-runtime: expected exit 0, got $status: $stderr"
    else
      expect_install_failure "tor@default.service is not started at boot (disabled)"
    fi
  done
}

test_install_rejects_unicode_digits_and_documentation_addresses() {
  local ip loc
  # Rejected as invalid usage before any root, package, account or network
  # step, whatever the locale.
  for loc in C C.UTF-8 en_US.UTF-8; do
    for ip in $'\uff11.2.3.4' $'1.\uff12.3.4' $'1.2.3.\u0664' 192.0.2.1 198.51.100.7 203.0.113.10; do
      LC_ALL=$loc run_cli install --public-ip "$ip" --yes </dev/null 2>/dev/null
      [[ $status == 2 ]] || fail "[$loc $ip]: expected exit 2, got $status: $stderr"
      [[ $stderr != *"Please run as root"* ]] || fail "[$loc $ip]: checked root first"
    done
  done
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    for ip in 192.0.2.0 192.0.2.255 198.51.100.0 198.51.100.255 203.0.113.0 203.0.113.255; do
      ! check_public_ipv4 "$ip" || fail "accepted documentation address $ip"
      [[ $IPV4_ERROR == "$ip is a documentation (RFC 5737) address, not a public IPv4 address" ]] ||
        fail "$ip: $IPV4_ERROR"
    done
    for ip in 192.0.1.255 192.0.3.0 198.51.99.255 198.51.101.0 203.0.112.255 203.0.114.0; do
      check_public_ipv4 "$ip" || fail "rejected public address $ip: $IPV4_ERROR"
    done
  ) || exit 1
}

test_install_writes_the_official_mainnet_seeds() {
  setup_install
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  assert_status 0
  python3 -c 'import tomllib' 2>/dev/null || fail "python3 with tomllib is required for this test"
  # Tari's official Mainnet seeds (tari-project/tari v6.0.0,
  # common/config/presets/b_peer_seeds.toml, [mainnet.p2p.seeds]): the whole
  # table must match exactly, in order, with nothing missing or added.
  python3 - "$SB/var/lib/tari/mainnet/mainnet/config/config.toml" <<'PY' ||
import sys, tomllib
config = tomllib.load(open(sys.argv[1], "rb"))
seeds = config["mainnet"]["p2p"]["seeds"]
expected_peers = [
    "44c1ebed4ec5a6b3b325601e83ff3924f89e8943e15c5e82dfffe83754482b26::/ip4/54.36.113.0/tcp/18189",
    "c00684151e75650c63a5d3e4fd4221ce19c4fbffd1a921caaecf06f8a4a65f0f::/ip4/15.235.48.4/tcp/18189",
    "02577fd02c9f1fdef52c8de153c17c1af4f29ede2495ee008b334479456e1a5c::/ip4/54.36.117.26/tcp/18189",
    "8cc21698e3930da90fd8a9663fedf9d4d56d6ecd7dedec07f8b3590e82061503::/ip4/54.36.112.71/tcp/18189",
    "94a4b29148621479b1c1dffb1a2f5680dcf2c0cfb901152e245d6ec299821f61::/ip4/91.134.83.67/tcp/18189",
    "1850155828616111f97cc739bf5f3d433d7f07edd477cbf5a3eec0dfe7547c61::/ip4/54.36.117.109/tcp/18189",
    "5819ba1c9ddc57d8c82d60b6b3e8c1d8dd369c3336c47112b7483f4ca5fef315::/ip4/15.235.44.167/tcp/18189",
    "d6a0d9c3f75ae3cb4d06e314a5f5dceb9cc7ad34f7e8be4126ee25253b039726::/ip4/15.235.44.135/tcp/18189",
    "de568a57a62bff39322fff935523c5f670e379783293c88b1c525b776b568d41::/ip4/15.235.49.151/tcp/18189",
    "fabf65440daa00a8033a7d0c966d68815f17feb6a25bc60c75bc5d4a84c41123::/ip4/15.235.49.169/tcp/18189",
    "7c8e6530294e8bb7ff45b0f39e8bf8ea4e461b3df15a2df1ba3fa3a9bcc9ef71::/ip4/15.235.224.202/tcp/18189",
    "ecf3f88c40d0b299cf0d0ff30e7ce8dd5a021c0806b8487426f0de89e4766177::/ip4/141.95.111.150/tcp/18189",
    "54e491e0d88633170a98898f5d89ccc6b4f7ec22252afc23fe645d5bab453734::/ip4/198.244.203.249/tcp/18189",
    "54e491e0d88633170a98898f5d89ccc6b4f7ec22252afc23fe645d5bab453734::/ip6/2001:41d0:803:f900::/tcp/18189",
    "94a4b29148621479b1c1dffb1a2f5680dcf2c0cfb901152e245d6ec299821f61::/ip6/2001:41d0:40d:4300::/tcp/18189",
    "7c8e6530294e8bb7ff45b0f39e8bf8ea4e461b3df15a2df1ba3fa3a9bcc9ef71::/ip6/2402:1f00:8005:ca00::/tcp/18189",
    "c00684151e75650c63a5d3e4fd4221ce19c4fbffd1a921caaecf06f8a4a65f0f::/ip6/2607:5300:205:300::d28/tcp/18189",
    "d6a0d9c3f75ae3cb4d06e314a5f5dceb9cc7ad34f7e8be4126ee25253b039726::/ip6/2607:5300:205:300::afc/tcp/18189",
    "fabf65440daa00a8033a7d0c966d68815f17feb6a25bc60c75bc5d4a84c41123::/ip6/2607:5300:205:300::5f4/tcp/18189",
    "02577fd02c9f1fdef52c8de153c17c1af4f29ede2495ee008b334479456e1a5c::/ip6/2001:41d0:701:1000::5bf/tcp/18189",
    "1850155828616111f97cc739bf5f3d433d7f07edd477cbf5a3eec0dfe7547c61::/ip6/2001:41d0:701:1000::f36/tcp/18189",
    "5819ba1c9ddc57d8c82d60b6b3e8c1d8dd369c3336c47112b7483f4ca5fef315::/ip6/2607:5300:205:300::196b/tcp/18189",
    "de568a57a62bff39322fff935523c5f670e379783293c88b1c525b776b568d41::/ip6/2607:5300:205:300::2396/tcp/18189",
    "ecf3f88c40d0b299cf0d0ff30e7ce8dd5a021c0806b8487426f0de89e4766177::/ip6/2001:41d0:701:1000::3dd/tcp/18189",
    "44c1ebed4ec5a6b3b325601e83ff3924f89e8943e15c5e82dfffe83754482b26::/ip6/2001:41d0:701:1000::43ca/tcp/18189",
    "8cc21698e3930da90fd8a9663fedf9d4d56d6ecd7dedec07f8b3590e82061503::/ip6/2001:41d0:701:1000::3e6d/tcp/18189",
    "02577fd02c9f1fdef52c8de153c17c1af4f29ede2495ee008b334479456e1a5c::/onion3/bukg4svrs4r3hdtx4s2vle6ekipi4v7bshenfwjalymvax7akivyhkyd:18141",
    "1850155828616111f97cc739bf5f3d433d7f07edd477cbf5a3eec0dfe7547c61::/onion3/miubwm3dbl5uh4ci7jgvq5jeyhr6sora4fivjm5fkjflyt543cqx2kqd:18141",
    "44c1ebed4ec5a6b3b325601e83ff3924f89e8943e15c5e82dfffe83754482b26::/onion3/kimfu5ch2lwo4wm4y6xgi5kvuqnrobdgiyis2okcc27alf3qavuruxqd:18141",
    "54e491e0d88633170a98898f5d89ccc6b4f7ec22252afc23fe645d5bab453734::/onion3/b5zgqd6emm6p2zmj7gdniysbxvmtvltrwshsyfxjoq26xqfjoicge5id:18141",
    "5819ba1c9ddc57d8c82d60b6b3e8c1d8dd369c3336c47112b7483f4ca5fef315::/onion3/f4n5yh62a3aml5y4lrf7xhqjzgqen2r75ubze2aritezw73qk2uzirad:18141",
    "7c8e6530294e8bb7ff45b0f39e8bf8ea4e461b3df15a2df1ba3fa3a9bcc9ef71::/onion3/5husjyv2zskwjh2wzbuirbq4gk5uiyx4gnn277r3yoxv4oucn72tmeyd:18141",
    "8cc21698e3930da90fd8a9663fedf9d4d56d6ecd7dedec07f8b3590e82061503::/onion3/yur5nsnkbpfvs4f5h65y652igcqjfv35okchify44kr77evkyfpnleqd:18141",
    "94a4b29148621479b1c1dffb1a2f5680dcf2c0cfb901152e245d6ec299821f61::/onion3/x4cc7t4z5bhzz2qoj5qkfje6jnisz5gvzixeygvzwgi6sg3rhpo5rlqd:18141",
    "c00684151e75650c63a5d3e4fd4221ce19c4fbffd1a921caaecf06f8a4a65f0f::/onion3/xfa5ijw7747cmjwkbjx6fhobgy4rgx5uozc3dnp7lif7gw7c3dzg6kad:18141",
    "d6a0d9c3f75ae3cb4d06e314a5f5dceb9cc7ad34f7e8be4126ee25253b039726::/onion3/kuibpj4742riknkddi4vlrdgklipf6uf5f6b4vdwsklr4iigxrm367qd:18141",
    "de568a57a62bff39322fff935523c5f670e379783293c88b1c525b776b568d41::/onion3/xwsoa6q4ijugfar22uoggu22wt6ttmtg2egkyo4fs6ptfjtq3kbrulid:18141",
    "ecf3f88c40d0b299cf0d0ff30e7ce8dd5a021c0806b8487426f0de89e4766177::/onion3/3dcfberbstruf3g2g5slacw2ls3nj6qmad2fxumqop3m65llagnhj6yd:18141",
    "fabf65440daa00a8033a7d0c966d68815f17feb6a25bc60c75bc5d4a84c41123::/onion3/k7egeg7alhhgr5vbjgatdd6g2rlvy3l6pd3kxvget2q437jqh7q6cuid:18141",
]
assert seeds == {"dns_seeds": ["seeds.tari.com"], "peer_seeds": expected_peers}, seeds
assert len(seeds["peer_seeds"]) == 39 and len(set(seeds["peer_seeds"])) == 39
kinds = [p.split("::/", 1)[1].split("/", 1)[0] for p in seeds["peer_seeds"]]
assert (kinds.count("ip4"), kinds.count("ip6"), kinds.count("onion3")) == (13, 13, 13), kinds
assert set(config) == {"base_node", "mainnet"} and set(config["mainnet"]) == {"p2p"}
assert set(config["mainnet"]["p2p"]) == {"seeds"}
PY
    fail "config.toml does not carry exactly the official Mainnet seeds"
}
