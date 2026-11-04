# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# uninstall: removes a node installed by lib/install.sh. Never touches the
# real system: the node is first installed into the sandbox ($SB) by the
# real cmd_install against tests/fakes/sys, then lib/uninstall.sh is pointed
# at the same sandbox; every system command is that fake, anything else that
# reaches the system is stopped by tests/guard.

# setup_uninstall: a node installed into the sandbox by the real
# cmd_install (see tests/test_install.sh), with Tor's runtime directory as
# the running tor@default.service would have it. The fake system's call log
# starts empty.
setup_uninstall() {
  setup_install
  # As on the real test nodes: jq, unzip and tor installed by this tool.
  printf 'ca-certificates\ncurl\n' >"$FAKE_SYS/pkgs"
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  [[ $status == 0 ]] || fail "setting up an installed node failed: $stderr"
  mkdir -m 755 "$SB/run/tor"
  # The mount table uninstall reads (as /proc/self/mountinfo): the usual
  # mounts, none below the node's or Tor's paths.
  printf '%s\n' '22 1 254:1 / / rw,relatime shared:1 - ext4 /dev/vda1 rw' \
    '23 22 0:21 / /proc rw,nosuid shared:2 - proc proc rw' \
    '24 22 0:23 / /run rw,nosuid shared:3 - tmpfs tmpfs rw' \
    "25 22 254:1 /srv $SB/srv rw,relatime shared:1 - ext4 /dev/vda1 rw" >"$TEST_TMP/mountinfo"
  local f
  for f in dpkg systemd-analyze; do
    ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/$f"
  done
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/*
}

# save_installed / restore_installed: keep a copy of the installed sandbox
# and fake system, and go back to it (cheaper than installing again).
save_installed() {
  cp -a -- "$SB" "$TEST_TMP/sysroot.saved"
  cp -a -- "$FAKE_SYS" "$TEST_TMP/fakesys.saved"
}
restore_installed() {
  rm -rf -- "$SB" "$FAKE_SYS" "${TEST_TMP:?}/fakebin/stat" "$TEST_TMP/pwned"
  cp -a -- "$TEST_TMP/sysroot.saved" "$SB"
  cp -a -- "$TEST_TMP/fakesys.saved" "$FAKE_SYS"
}

# expect_refusal NAME MESSAGE [UNINSTALL_ENV...]: uninstall, even confirmed,
# exits 1 with MESSAGE before the confirmation and changes nothing.
expect_refusal() {
  local name=$1 message=$2 before
  shift 2
  before=$(system_snapshot)
  : >"$FAKE_SYS/calls"
  (
    # shellcheck disable=SC2163 # Exports the NAME=VALUE arguments.
    [[ $# == 0 ]] || export "$@"
    UNINSTALL_INPUT=y run_uninstall
    [[ $status == 1 ]] || fail "[$name]: expected exit 1, got $status"
    assert_stderr_contains "$message"
    assert_stderr_contains "uninstall refused; nothing was changed. It removes only what this tool installed (the node, Wallet Query and Base Node gRPC) and only while all of it is still as this tool left it; check this host and handle it by hand."
    [[ $stdout != *"[y/N]"* ]] || fail "[$name]: asked for confirmation"
    assert_only_reads
    [[ $(system_snapshot) == "$before" ]] || fail "[$name]: the system changed"
    [[ ! -e $TEST_TMP/pwned ]] || fail "[$name]: the install record was executed"
  ) || exit 1
}

# fake_mount PATH: `stat -c %d -- PATH` (and only that) reports another
# device, as for a separate mount point.
fake_mount() {
  fake_stat_field "$1" %d 4242
}

# fake_stat_field PATH FORMAT VALUE: `stat -c FORMAT -- PATH` prints VALUE
# (for a FORMAT like %u|%F, VALUE replaces only the owner).
fake_stat_field() {
  local real
  real=$(type -aP stat | grep -v "$TEST_TMP" | head -n 1)
  cat >"$TEST_TMP/fakebin/stat" <<STAT
#!/usr/bin/env bash
if [[ \$# == 4 && \$1 == -c && \$2 == '$2'* && \$3 == -- && \$4 == '$SB$1' ]]; then
  if [[ '$2' == %u?* ]]; then
    out=\$('$real' "\$@") || exit 1
    echo "$3|\${out#*|}"
  else
    echo '$3'
  fi
  exit 0
fi
exec '$real' "\$@"
STAT
  chmod +x "$TEST_TMP/fakebin/stat"
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_uninstall: lib/uninstall.sh's cmd_uninstall, run as "root" against the
# sandbox, with $UNINSTALL_INPUT on stdin (no stdin at all when
# UNINSTALL_EOF=1). Sets status/stdout/stderr.
run_uninstall() {
  local input=/dev/null
  if [[ -z ${UNINSTALL_EOF-} ]]; then
    printf '%s\n' "${UNINSTALL_INPUT-}" >"$TEST_TMP/.stdin"
    input=$TEST_TMP/.stdin
  fi
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # The real load chain: install, status, wallet-query, grpc, uninstall.
    load_uninstall
    # shellcheck disable=SC2317,SC2329 # Called by lib/uninstall.sh.
    is_root() { return 0; }
    SYSROOT=$SB
    ROOT_IDS=${UNINSTALL_ROOT_IDS:-"$(id -u):$(id -g)"}
    INSTALL_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    INSTALL_SOURCE_DIR=${UNINSTALL_SOURCE_DIR:-$REPO_ROOT}
    # The sandbox's tari is the test user, whatever its UID.
    SYSTEM_UID_MAX=${UNINSTALL_SYSTEM_UID_MAX:-$(id -u)}
    MOUNTINFO=$TEST_TMP/mountinfo
    cmd_uninstall "$@"
  ) <"$input" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# system_snapshot: everything uninstall could change (files under the
# sandbox root with their identity, accounts, packages, unit states).
system_snapshot() {
  (cd "$SB" && find . -printf '%p %y %m %u %i %s\n' | sort)
  local f
  for f in passwd group pkgs loaded "$FAKE_SYS"/active.* "$FAKE_SYS"/enabled.*; do
    f=${f##*/}
    printf '== %s\n' "$f"
    cat -- "$FAKE_SYS/$f" 2>/dev/null
  done
}

# assert_only_reads: the fake system saw only read-only queries and no
# request left the host.
assert_only_reads() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "dpkg-query -W -f=\${Status} "* | "getent "* | "systemctl show "* | "systemctl is-active "* | "systemd-analyze unit-paths" | \
        "dpkg --no-act --purge -- tor") ;;
      *) fail "unexpected system call: $line" ;;
    esac
  done <"$FAKE_SYS/calls"
  [[ -z $(ls -A "$TEST_TMP/curl-log") ]] || fail "network requests were made"
}

# --- command line ---------------------------------------------------------------

test_uninstall_help_works_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" uninstall --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh uninstall"
  assert_stdout_contains "Must be run as root"
  local line
  for line in "Uninstall all: remove everything this tool installed" \
    "/etc/systemd/system/minotari-mainnet.service, /opt/tari, /var/lib/tari" \
    "permanently deleted" "node identity" "only if its" \
    "ca-certificates, curl, jq, openssl and unzip are kept" "dpkg --purge -- tor" \
    "purge removes /var/lib/tor, /var/log/tor and /run/tor" "other Tor instance" \
    "mount point" "Wallet Query, if this tool set it up" "Base Node gRPC, if this tool set it up" \
    "/var/lib/taritalk-wallet-query" "/var/lib/taritalk-grpc" "/etc/nginx/conf.d/taritalk-wallet-query.conf" \
    "the nginx package (with nginx-common)" "purge
    removes /etc/nginx, /var/log/nginx and /var/lib/nginx" "An Nginx this tool did not install
is never touched" "no way to remove only some of the components" \
    "shows this tool installed tor" "may be left partially removed" "no --yes or --force"; do
    assert_stdout_contains "$line"
  done
  run_cli_with_path "$TEST_TMP/bare-bin" --help
  assert_status 0
  assert_stdout_contains "uninstall   Uninstall all: remove the node installed by this tool"
  assert_stdout_contains "Run without arguments in a terminal for a simple menu."
  [[ $stdout != *"/var/log/tor is kept"* ]] || fail "help claims /var/log/tor is kept"
  [[ -z $(<"$TRACE_FILE") ]] || fail "help ran commands: $(<"$TRACE_FILE")"
}

test_uninstall_usage_errors_exit_2_before_root_and_dependency_checks() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  local -a cases=("--yes" "--force" "-y" "--keep-data" "extra" "--help extra" "extra --help"
    "--help --help" "-- " "--version")
  local c
  for c in "${cases[@]}"; do
    # shellcheck disable=SC2086 # Split each case into arguments.
    run_cli_with_path "$TEST_TMP/bare-bin" uninstall $c </dev/null
    [[ $status == 2 ]] || fail "[$c]: expected exit 2, got $status"
    assert_stdout_empty
    assert_stderr_contains "Try './deploy.sh --help' for more information."
    [[ $stderr != *"Please run as root"* && $stderr != *"missing required command"* ]] ||
      fail "[$c]: checked root or dependencies before the arguments"
  done
  run_cli_with_path "$TEST_TMP/bare-bin" uninstall "" </dev/null
  assert_status 2
  [[ -z $(<"$TRACE_FILE") ]] || fail "usage errors ran commands: $(<"$TRACE_FILE")"
}

test_uninstall_as_non_root_says_please_run_as_root() {
  run_cli uninstall </dev/null
  assert_status 1
  assert_stdout_empty
  [[ $stderr == "Please run as root." ]] || fail "unexpected stderr: $stderr"
}

# --- confirmation ---------------------------------------------------------------

test_uninstall_cancel_changes_nothing() {
  setup_uninstall
  local before answer
  before=$(system_snapshot)
  for answer in "" EOF n N no yes YES x " y" "Y " yy "y y"; do
    : >"$FAKE_SYS/calls"
    if [[ $answer == EOF ]]; then
      UNINSTALL_EOF=1 run_uninstall
    else
      UNINSTALL_INPUT=$answer run_uninstall
    fi
    [[ $status == 0 ]] || fail "[$answer]: expected exit 0, got $status: $stderr"
    assert_stdout_contains "Uninstall all plan"
    assert_stdout_contains "Not changed:    DNS, Nginx, TLS, Cloudflare, firewalls, cloud security groups"
    [[ $stdout == *$'\n'"Uninstall the node, Wallet Query and Base Node gRPC? [y/N]: "$'\n'"Uninstall cancelled; nothing was changed." ]] ||
      fail "[$answer]: prompt or cancel message differs"
    assert_only_reads
    [[ $(system_snapshot) == "$before" ]] || fail "[$answer]: the system changed"
  done
}

# --- the uninstall ----------------------------------------------------------------

test_uninstall_stops_and_disables_the_services() {
  local answer
  for answer in y Y; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_uninstall
    UNINSTALL_INPUT=$answer run_uninstall
    [[ $status == 0 ]] || fail "[$answer]: uninstall failed: $stderr"
    assert_order "systemctl stop minotari-mainnet.service" "systemctl disable minotari-mainnet.service" \
      "systemctl stop tor@default.service" "systemctl disable tor.service"
    local unit
    for unit in minotari-mainnet.service tor@default.service tor.service; do
      [[ ! -e $FAKE_SYS/active.$unit && ! -e $FAKE_SYS/enabled.$unit ]] || fail "[$answer]: $unit left active or enabled"
    done
    ! grep -E '^systemctl ' "$FAKE_SYS/calls" | grep -vE '^systemctl (daemon-reload$|(show|stop|disable) )' ||
      fail "[$answer]: unexpected systemctl call"
  done
}

test_uninstall_purges_only_tor_with_a_fixed_dpkg_command() {
  setup_uninstall
  grep -qx 'packages_installed=jq,unzip,tor' "$SB/var/lib/tari/taritalk-install-state" ||
    fail "unexpected install record"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  local pkg_calls
  pkg_calls=$(grep -E '^(apt|apt-get|dpkg) ' "$FAKE_SYS/calls" | grep -v '^dpkg --no-act ')
  [[ $pkg_calls == "dpkg --purge -- tor" ]] || fail "unexpected package commands: $pkg_calls"
  [[ $(sort "$FAKE_SYS/pkgs" | tr '\n' ' ') == "ca-certificates curl jq unzip " ]] ||
    fail "packages after uninstall: $(<"$FAKE_SYS/pkgs")"
  assert_order "systemctl disable tor.service" "dpkg --purge -- tor"
  [[ $(grep -cx 'dpkg --no-act --purge -- tor' "$FAKE_SYS/calls") == 2 ]] ||
    fail "dpkg's dry run did not run before the confirmation and again before the purge"
}

test_uninstall_removes_the_node_its_account_and_tor() {
  setup_uninstall
  mkdir -p "$SB/var/lib/tari/mainnet/mainnet/data/base_node/db" "$SB/var/log/tari/log/base_node"
  echo db >"$SB/var/lib/tari/mainnet/mainnet/data/base_node/db/data.mdb"
  echo id >"$SB/var/lib/tari/mainnet/mainnet/config/base_node_id.json"
  echo log >"$SB/var/log/tari/log/base_node/base_layer.log"
  echo state >"$SB/var/lib/tor/cached-certs"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  local path
  # (The tor package's own purge removes /var/lib/tor, /var/log/tor and
  # /run/tor; /etc/tor goes with its conffile.)
  for path in /etc/systemd/system/minotari-mainnet.service /opt/tari /var/lib/tari /var/log/tari \
    /etc/tor /var/lib/tor /var/log/tor /run/tor; do
    [[ ! -e $SB$path && ! -L $SB$path ]] || fail "$path is left"
  done
  ! grep -q '^tari:' "$FAKE_SYS/passwd" || fail "user tari left"
  ! grep -q '^tari:' "$FAKE_SYS/group" || fail "group tari left"
  grep -qx 'debian-tor:x:4100:' "$FAKE_SYS/group" || fail "tari still in debian-tor"
  [[ -z $(<"$FAKE_SYS/loaded") ]] || fail "units still loaded: $(<"$FAKE_SYS/loaded")"
  assert_order "systemctl stop minotari-mainnet.service" "dpkg --purge -- tor" \
    "systemctl daemon-reload" "userdel tari" "groupdel tari"
  ! called "GUARD *" || fail "a real system command was reached: $(grep GUARD "$FAKE_SYS/calls")"
  # Nothing else in the sandbox went away.
  for path in /etc /etc/systemd/system /opt /var/lib /var/log /run /tmp /etc/os-release; do
    [[ -e $SB$path ]] || fail "$path was removed"
  done
}

test_uninstall_success_output_is_exact_and_status_finds_no_node() {
  setup_uninstall
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  [[ $stdout == *$'\n'"Uninstalled: Minotari node
Removed: node service, node data, node logs, Tari release, tari account, tor package
Kept APT packages: jq, unzip
DNS, firewall and cloud security settings were not changed." ]] || fail "success output differs"
  local cmd
  for cmd in status logs; do
    run_ops "$cmd"
    assert_status 1
    assert_stderr_contains "'/var/lib/tari/taritalk-install-state' is missing; no node installed by taritalk-node-deploy was found"
  done
}

test_uninstall_reports_none_when_it_installed_no_generic_package() {
  setup_uninstall
  sed -i 's/^packages_installed=.*/packages_installed=tor/' "$SB/var/lib/tari/taritalk-install-state"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  assert_stdout_has_line "Kept APT packages: none"
}

test_uninstall_verifies_that_everything_is_gone() {
  # Each case: a hook run just before the given fake call puts something
  # back (or, for "noop-groupdel", groupdel succeeds without removing the
  # group); the final check must notice it.
  local -a cases=(
    "groupdel tari@@echo 'tari:x:999:999::/var/lib/tari:/usr/sbin/nologin' >>\$FAKE_SYS/passwd@@user tari still exists"
    "noop-groupdel@@@@group tari still exists"
    "groupdel tari@@sed -i 's/^debian-tor:x:4100:\$/debian-tor:x:4100:tari/' \$FAKE_SYS/group@@tari is still a member of group debian-tor"
    "systemctl daemon-reload@@touch \$SB/etc/systemd/system/minotari-mainnet.service@@'/etc/systemd/system/minotari-mainnet.service' still exists"
    "userdel tari@@echo tor >>\$FAKE_SYS/pkgs@@the tor package is still installed"
    "userdel tari@@mkdir \$SB/var/log/tari@@'/var/log/tari' still exists"
  )
  local c on action message
  for c in "${cases[@]}"; do
    on=${c%%@@*}
    action=${c#*@@}
    message=${action#*@@}
    action=${action%%@@*}
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_uninstall
    printf '#!/usr/bin/env bash\n%s\n' "$action" >"$TEST_TMP/hook"
    chmod +x "$TEST_TMP/hook"
    (
      if [[ $on == noop-groupdel ]]; then
        ln -sf "$(type -P true)" "$TEST_TMP/fakebin/groupdel"
      else
        export FAKE_SYS_HOOK_ON=$on FAKE_SYS_HOOK=$TEST_TMP/hook
      fi
      UNINSTALL_INPUT=y run_uninstall
      [[ $status == 1 ]] || fail "[$on]: expected exit 1, got $status"
      assert_stderr_contains "$message"
      [[ $stdout != *"Uninstalled:"* ]] || fail "[$on]: claimed success"
    ) || exit 1
  done
}

# --- ownership checks ------------------------------------------------------------

test_uninstall_refuses_a_missing_unsafe_or_invalid_install_record() {
  local not_record="is not a valid install record of taritalk-node-deploy"
  local not_private="is not a private file of root (owner, mode, links:"
  # shellcheck disable=SC2016 # Literal shell syntax in the record.
  local -a cases=(
    "rm -- \$STATE@@'/var/lib/tari/taritalk-install-state' is missing; no node installed by taritalk-node-deploy was found"
    "mv -- \$STATE \$STATE.real && ln -s taritalk-install-state.real \$STATE@@is not a regular file"
    "rm -- \$STATE && mkdir \$STATE@@is not a regular file"
    "chmod 644 \$STATE@@$not_private"
    "chmod 400 \$STATE@@$not_private"
    "ln \$STATE \$SB/var/lib/tari/mainnet/hard@@$not_private"
    "OWNER@@$not_private"
    "sed -i 's/^format=1\$/format=2/' \$STATE@@$not_record"
    "sed -i '/^format=/d' \$STATE@@$not_record"
    "sed -i '/^release_dir=/d' \$STATE@@$not_record"
    "sed -i '/^binary_sha256=/d' \$STATE@@$not_record"
    "sed -i '/^packages_installed=/d' \$STATE@@$not_record"
    "sed -i '/^tag=/d' \$STATE@@$not_record"
    "echo format=1 >>\$STATE@@$not_record"
    "sed -i /^release_dir=/p \$STATE@@$not_record"
    "sed -i /^binary_sha256=/p \$STATE@@$not_record"
    "sed -i /^packages_installed=/p \$STATE@@$not_record"
    "sed -i /^public_ip=/p \$STATE@@$not_record"
    "echo garbage >>\$STATE@@$not_record"
    "echo >>\$STATE@@$not_record"
    "printf 'x=1\\0y=2\\n' >>\$STATE@@$not_record"
    "echo 'note=\$(touch \$TEST_TMP/pwned)' >>\$STATE@@$not_record"
    "echo '\$(touch \$TEST_TMP/pwned)' >>\$STATE@@$not_record"
    "echo 'note=\`touch \$TEST_TMP/pwned\`' >>\$STATE@@$not_record"
    "sed -i 's#^release_dir=.*#&;touch \$TEST_TMP/pwned#' \$STATE@@$not_record"
    "sed -i 's#^release_dir=.*#release_dir=\$(touch \$TEST_TMP/pwned)#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=tor;touch \$TEST_TMP/pwned#' \$STATE@@$not_record"
    "sed -i 's#^release_dir=.*#release_dir=/opt/tari/releases/../x#' \$STATE@@$not_record"
    "sed -i 's#^release_dir=.*#release_dir=/opt/tari/releases/other-1#' \$STATE@@$not_record"
    "sed -i 's#^release_dir=.*#release_dir=/opt/tari/releases/minotari-a/b#' \$STATE@@$not_record"
    "sed -i 's#^release_dir=.*#release_dir=/opt/tari/current#' \$STATE@@$not_record"
    "sed -i 's#^binary_sha256=.*#binary_sha256=ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789#' \$STATE@@$not_record"
    "sed -i 's#^binary_sha256=\\(.*\\).\$#binary_sha256=\\1#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=jq,unzip#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=tor,tor#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=nginx,tor#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=jq,,tor#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=jq,tor,#' \$STATE@@$not_record"
    "sed -i 's#^packages_installed=.*#packages_installed=jq, tor#' \$STATE@@$not_record"
  )
  setup_uninstall
  save_installed
  # shellcheck disable=SC2034 # Used by the eval'd actions.
  local STATE=$SB/var/lib/tari/taritalk-install-state c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    if [[ $action == OWNER ]]; then
      # Owned by someone other than root (as the harness sees root).
      expect_refusal "$action" "$message" UNINSTALL_ROOT_IDS=$(($(id -u) + 1)):0
    else
      eval "$action" || fail "[$action]: setup failed"
      expect_refusal "$action" "$message"
    fi
  done
}

test_uninstall_refuses_changed_or_unexpected_node_files() {
  local rel
  setup_uninstall
  save_installed
  rel=$SB$(sed -n 's/^release_dir=//p' "$SB/var/lib/tari/taritalk-install-state")
  local unit=$SB/etc/systemd/system/minotari-mainnet.service
  # shellcheck disable=SC2034 # Used by the eval'd actions.
  local REL=$rel UNIT=$unit
  local -a cases=(
    "rm \$SB/opt/tari/current@@'/opt/tari/current' is missing or not a symlink"
    "ln -sfn \$REL \$SB/opt/tari/current@@'/opt/tari/current' does not point to the installed release"
    "ln -sfn releases/minotari-other \$SB/opt/tari/current@@'/opt/tari/current' does not point to the installed release"
    "rm \$SB/opt/tari/current && mkdir \$SB/opt/tari/current@@'/opt/tari/current' is missing or not a symlink"
    "echo x >>\$REL/minotari_node@@does not match the recorded SHA-256"
    "chmod 700 \$REL/minotari_node@@minotari_node' is not a root-owned regular file with mode 755 and one link"
    "ln \$REL/minotari_node \$SB/var/lib/tari/mainnet/hard@@minotari_node' is not a root-owned regular file with mode 755 and one link"
    "mv \$REL/minotari_node \$REL/real && ln -s real \$REL/minotari_node@@minotari_node' is not a root-owned regular file with mode 755 and one link"
    "rm \$REL/minotari_node@@minotari_node' is not a root-owned regular file with mode 755 and one link"
    "echo '# changed' >>\$UNIT@@'/etc/systemd/system/minotari-mainnet.service' differs from this tool's template"
    "sed -i 's/^Restart=.*/Restart=no/' \$UNIT@@'/etc/systemd/system/minotari-mainnet.service' differs from this tool's template"
    "truncate -s -1 \$UNIT@@'/etc/systemd/system/minotari-mainnet.service' differs from this tool's template"
    "chmod 664 \$UNIT@@'/etc/systemd/system/minotari-mainnet.service' is not a root-owned regular file with mode 644 and one link"
    "ln \$UNIT \$SB/etc/systemd/system/copy.service@@'/etc/systemd/system/minotari-mainnet.service' is not a root-owned regular file with mode 644 and one link"
    "mv \$UNIT \$SB/etc/real.service && ln -s ../../real.service \$UNIT@@'/etc/systemd/system/minotari-mainnet.service' is not a root-owned regular file with mode 644 and one link"
    "rm \$UNIT@@'/etc/systemd/system/minotari-mainnet.service' is not a root-owned regular file with mode 644 and one link"
    "mv \$SB/opt/tari \$SB/opt/real && ln -s real \$SB/opt/tari@@'/opt/tari' is not a directory"
    "mv \$SB/var/log/tari \$SB/var/log/real && ln -s real \$SB/var/log/tari@@'/var/log/tari' is not a directory"
    "mv \$SB/var/lib/tari/mainnet \$SB/var/lib/real && ln -s ../real \$SB/var/lib/tari/mainnet@@'/var/lib/tari/mainnet' is not a directory"
    "mv \$SB/opt/tari/releases \$SB/opt/real && ln -s ../real \$SB/opt/tari/releases@@'/opt/tari/releases' is not a directory"
    "mv \$REL \$SB/opt/real && ln -s ../../real \$REL@@is not a directory"
    "mv \$SB/var/log/tari/log \$SB/var/log/real && ln -s ../real \$SB/var/log/tari/log@@'/var/log/tari/log' is not a directory"
    "rm -r \$SB/var/log/tari/log@@'/var/log/tari/log' is not a directory"
    "chmod 775 \$SB/opt/tari@@'/opt/tari' has an unexpected owner or mode"
    "chmod 755 \$SB/var/lib/tari@@'/var/lib/tari' has an unexpected owner or mode"
    "chmod 750 \$SB/var/log/tari@@'/var/log/tari' has an unexpected owner or mode"
    "chmod 755 \$SB/var/lib/tari/mainnet@@'/var/lib/tari/mainnet' has an unexpected owner or mode"
    "MOUNT /opt/tari@@'/opt/tari' is a separate mount point"
    "MOUNT /opt/tari/releases@@'/opt/tari/releases' is a separate mount point"
    "MOUNT /var/lib/tari@@'/var/lib/tari' is a separate mount point"
    "MOUNT /var/lib/tari/mainnet@@'/var/lib/tari/mainnet' is a separate mount point"
    "MOUNT /var/log/tari@@'/var/log/tari' is a separate mount point"
    "MOUNT /var/log/tari/log@@'/var/log/tari/log' is a separate mount point"
    "touch \$SB/opt/tari/extra@@'/opt/tari' contains unexpected entries"
    "touch \$SB/opt/tari/.hidden@@'/opt/tari' contains unexpected entries"
    "mkdir \$SB/opt/tari/releases/minotari-other@@'/opt/tari/releases' contains unexpected entries"
    "touch \$SB/var/lib/tari/notes@@'/var/lib/tari' contains unexpected entries"
    "mkdir \$SB/var/log/tari/old@@'/var/log/tari' contains unexpected entries"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    if [[ $action == MOUNT* ]]; then
      fake_mount "${action#MOUNT }"
    else
      eval "$action" || fail "[$action]: setup failed"
    fi
    expect_refusal "$action" "$message"
  done
  # Free content inside the node's directories is accepted.
  restore_installed
  mkdir -p "$SB/var/lib/tari/mainnet/mainnet/data" "$SB/var/log/tari/log/base_node"
  echo db >"$SB/var/lib/tari/mainnet/mainnet/data/x.mdb"
  echo log >"$SB/var/log/tari/log/base_node/base_layer.log.1"
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
}

test_uninstall_refuses_a_changed_account_unit_or_tor_package() {
  setup_uninstall
  save_installed
  local me
  me=$(id -u)
  local -a cases=(
    "sed -i '/^tari:/d' \$FAKE_SYS/passwd@@user tari does not exist"
    "sed -i 's/^tari:x:[0-9]*:/tari:x:0:/' \$FAKE_SYS/passwd@@user tari is not a system account"
    "SYSUID@@user tari is not a system account"
    "sed -i 's#:/var/lib/tari:#:/home/tari:#' \$FAKE_SYS/passwd@@user tari does not have home /var/lib/tari"
    "sed -i 's#/usr/sbin/nologin\$#/bin/bash#' \$FAKE_SYS/passwd@@user tari does not have shell /usr/sbin/nologin"
    "sed -i '/^tari:/d' \$FAKE_SYS/group@@group tari does not exist"
    "sed -i 's/^tari:x:[0-9]*:/tari:x:4242:/' \$FAKE_SYS/group@@the primary group of user tari is not group tari"
    "sed -i 's/^debian-tor:x:4100:tari\$/debian-tor:x:4100:/' \$FAKE_SYS/group@@user tari is not a member of group debian-tor"
    "sed -i 's/^debian-tor:x:4100:tari\$/debian-tor:x:4100:xtari/' \$FAKE_SYS/group@@user tari is not a member of group debian-tor"
    "FRAGMENT@@minotari-mainnet.service is not loaded from /etc/systemd/system/minotari-mainnet.service"
    "sed -i '/^minotari-mainnet.service\$/d' \$FAKE_SYS/loaded@@minotari-mainnet.service is not loaded from /etc/systemd/system/minotari-mainnet.service"
    "mkdir \$SB/etc/systemd/system/minotari-mainnet.service.d@@'/etc/systemd/system/minotari-mainnet.service.d' holds drop-ins"
    "mkdir -p \$SB/run/systemd/system && touch \$SB/run/systemd/system/minotari-mainnet.service@@'/run/systemd/system/minotari-mainnet.service' also defines"
    "mkdir -p \$SB/usr/lib/systemd/system && touch \$SB/usr/lib/systemd/system/minotari-mainnet.service@@'/usr/lib/systemd/system/minotari-mainnet.service' also defines"
    "sed -i '/^tor\$/d' \$FAKE_SYS/pkgs@@the tor package is not installed"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    case "$action" in
      SYSUID) expect_refusal "$action" "$message" UNINSTALL_SYSTEM_UID_MAX=$((me - 1)) ;;
      FRAGMENT) expect_refusal "$action" "$message" FAKE_FRAGMENT=/run/systemd/transient/minotari-mainnet.service ;;
      *)
        eval "$action" || fail "[$action]: setup failed"
        expect_refusal "$action" "$message"
        ;;
    esac
  done
  # Active or not, enabled or not: all accepted before the confirmation.
  restore_installed
  rm -rf "$FAKE_SYS"/active.* "$FAKE_SYS"/enabled.* "$SB/proc/4242" "$SB/proc/4343"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "a stopped, disabled node was not uninstalled: $stderr"
}

test_uninstall_refuses_a_changed_tor_setup() {
  setup_uninstall
  save_installed
  # shellcheck disable=SC2034 # Used by the eval'd actions.
  local TORRC=$SB/etc/tor/torrc
  local -a cases=(
    "echo 'SocksPort 0.0.0.0:9050' >>\$TORRC@@'/etc/tor/torrc' differs from this tool's template torrc"
    "sed -i 's/9051/9052/' \$TORRC@@'/etc/tor/torrc' differs from this tool's template torrc"
    "chmod 600 \$TORRC@@'/etc/tor/torrc' is not a root-owned regular file with mode 644 and one link"
    "ln \$TORRC \$SB/etc/torrc.hard@@'/etc/tor/torrc' is not a root-owned regular file with mode 644 and one link"
    "mv \$TORRC \$SB/etc/torrc.real && ln -s ../torrc.real \$TORRC@@'/etc/tor/torrc' is not a root-owned regular file with mode 644 and one link"
    "rm \$TORRC@@'/etc/tor/torrc' is not a root-owned regular file with mode 644 and one link"
    "mv \$SB/etc/tor \$SB/etc/tor.real && ln -s tor.real \$SB/etc/tor@@'/etc/tor' is not a directory"
    "mv \$SB/var/lib/tor \$SB/var/lib/tor.real && ln -s tor.real \$SB/var/lib/tor@@'/var/lib/tor' is not a directory"
    "rmdir \$SB/run/tor && ln -s \$TEST_TMP \$SB/run/tor@@'/run/tor' is not a directory"
    "rm -r \$SB/var/lib/tor && touch \$SB/var/lib/tor@@'/var/lib/tor' is not a directory"
    "MOUNT /etc/tor@@'/etc/tor' is a separate mount point"
    "MOUNT /var/lib/tor@@'/var/lib/tor' is a separate mount point"
    "MOUNT /run/tor@@'/run/tor' is a separate mount point"
    "APT@@other packages depend on tor"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    case "$action" in
      MOUNT*)
        fake_mount "${action#MOUNT }"
        expect_refusal "$action" "$message"
        ;;
      APT)
        echo nyx >>"$FAKE_SYS/pkgs"
        echo 'nyx tor' >"$FAKE_SYS/depends"
        expect_refusal "$action" "$message"
        ;;
      *)
        eval "$action" || fail "[$action]: setup failed"
        expect_refusal "$action" "$message"
        ;;
    esac
  done
  # Tor's runtime directory exists only while Tor runs: its absence is fine.
  restore_installed
  rmdir "$SB/run/tor"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed without /run/tor: $stderr"
}

# --- failures -------------------------------------------------------------------

test_uninstall_stops_at_a_failed_step_and_keeps_the_install_record() {
  # FAIL GLOB @@ message @@ a later call that must not happen @@ what must still exist
  local -a cases=(
    "systemctl stop minotari-mainnet.service@@cannot stop minotari-mainnet.service@@systemctl stop tor@default.service@@/opt/tari"
    "systemctl disable minotari-mainnet.service@@cannot disable minotari-mainnet.service@@systemctl stop tor@default.service@@/opt/tari"
    "systemctl stop tor@default.service@@cannot stop tor@default.service@@dpkg --purge -- tor@@/opt/tari"
    "systemctl disable tor.service@@cannot disable tor.service@@dpkg --purge -- tor@@/opt/tari"
    "dpkg --purge -- tor@@dpkg --purge tor failed@@systemctl daemon-reload@@/etc/systemd/system/minotari-mainnet.service"
    "systemctl daemon-reload@@systemctl daemon-reload failed@@userdel *@@/opt/tari"
    "userdel tari@@cannot remove user tari@@groupdel *@@/var/lib/tari/taritalk-install-state"
    "groupdel tari@@cannot remove group tari@@NONE@@/var/lib/tari/taritalk-install-state"
  )
  local c glob message later keep
  setup_uninstall
  save_installed
  for c in "${cases[@]}"; do
    IFS='|' read -r glob message later keep <<<"${c//@@/|}"
    restore_installed
    (
      export FAKE_SYS_FAIL=$glob
      UNINSTALL_INPUT=y run_uninstall
      [[ $status == 1 ]] || fail "[$glob]: expected exit 1, got $status"
      assert_stderr_contains "$message"
      assert_stderr_contains "uninstall stopped; later steps were not run"
      [[ $stdout != *"Uninstalled:"* ]] || fail "[$glob]: claimed success"
      [[ $later == NONE ]] || ! called "$later" || fail "[$glob]: continued with '$later'"
      [[ -e $SB$keep ]] || fail "[$glob]: $keep was removed"
      [[ -e $SB/var/lib/tari/taritalk-install-state ]] || fail "[$glob]: the install record was removed"
    ) || exit 1
  done
}

test_uninstall_keeps_everything_while_tari_processes_run() {
  setup_uninstall
  # A process of tari survives stopping the services.
  cat >"$TEST_TMP/hook" <<HOOK
#!/usr/bin/env bash
mkdir -p '$SB/proc/777'
printf 'Name:\tminotari_node\nUid:\t%s\t%s\t%s\t%s\n' $(id -u) $(id -u) $(id -u) $(id -u) >'$SB/proc/777/status'
HOOK
  chmod +x "$TEST_TMP/hook"
  FAKE_SYS_HOOK_ON="systemctl disable tor.service" FAKE_SYS_HOOK=$TEST_TMP/hook \
    UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "processes of user tari are still running"
  ! called "dpkg --purge *" || fail "continued with the purge"
  ! called "userdel *" || fail "continued with the account"
  local path
  for path in /opt/tari /var/lib/tari/mainnet /var/log/tari /etc/systemd/system/minotari-mainnet.service \
    /var/lib/tari/taritalk-install-state /etc/tor/torrc; do
    [[ -e $SB$path ]] || fail "$path was removed"
  done
  grep -q '^tari:' "$FAKE_SYS/passwd" || fail "user tari was removed"
}

# --- replaced paths ---------------------------------------------------------------

test_uninstall_never_removes_a_path_replaced_after_the_checks() {
  # ON (fake call the hook runs before) @@ hook @@ message @@ a later call
  # that must not happen
  local -a cases=(
    "systemctl stop minotari-mainnet.service@@mv \$SB/var/log/tari \$TEST_TMP/moved && mkdir \$SB/var/log/tari && echo keep >\$SB/var/log/tari/file@@'/var/log/tari' changed after the checks@@dpkg --purge -- tor"
    "systemctl stop tor@default.service@@echo 'SocksPort 0.0.0.0:9050' >>\$SB/etc/tor/torrc@@'/etc/tor/torrc' changed after the checks@@dpkg --purge -- tor"
    "systemctl disable tor.service@@mv \$SB/etc/tor/torrc \$TEST_TMP/moved && cp \$TEST_TMP/moved \$SB/etc/tor/torrc@@'/etc/tor/torrc' changed after the checks@@dpkg --purge -- tor"
    "systemctl disable tor.service@@mv \$SB/etc/systemd/system/minotari-mainnet.service \$TEST_TMP/moved && cp \$TEST_TMP/moved \$SB/etc/systemd/system/minotari-mainnet.service@@'/etc/systemd/system/minotari-mainnet.service' changed after the checks@@dpkg --purge -- tor"
    "dpkg --purge -- tor@@mv \$SB/opt/tari \$TEST_TMP/moved && ln -s \$TEST_TMP/victim \$SB/opt/tari@@'/opt/tari' changed after the checks@@userdel *"
    "systemctl daemon-reload@@mv \$SB/var/lib/tari/mainnet \$TEST_TMP/moved && mkdir \$SB/var/lib/tari/mainnet && echo keep >\$SB/var/lib/tari/mainnet/file@@'/var/lib/tari/mainnet' changed after the checks@@userdel *"
    "userdel tari@@mkdir \$SB/var/lib/tor && echo keep >\$SB/var/lib/tor/file@@'/var/lib/tor' changed after the checks@@NONE"
    "userdel tari@@ln -s \$TEST_TMP/victim \$SB/run/tor@@'/run/tor' changed after the checks@@NONE"
  )
  local c on hook message later before_victim
  setup_uninstall
  mkdir "$TEST_TMP/victim"
  echo keep >"$TEST_TMP/victim/file"
  save_installed
  for c in "${cases[@]}"; do
    IFS='|' read -r on hook message later <<<"${c//@@/|}"
    restore_installed
    rm -rf -- "${TEST_TMP:?}/moved" "$TEST_TMP/hook.ran"
    printf '#!/usr/bin/env bash\nset -e\ntouch %q\n%s\n' "$TEST_TMP/hook.ran" "$hook" >"$TEST_TMP/hook"
    chmod +x "$TEST_TMP/hook"
    before_victim=$(cd "$TEST_TMP/victim" && find . -printf '%p %s\n')
    (
      export FAKE_SYS_HOOK_ON=$on FAKE_SYS_HOOK=$TEST_TMP/hook
      UNINSTALL_INPUT=y run_uninstall
      [[ $status == 1 ]] || fail "[$on]: expected exit 1, got $status"
      assert_stderr_contains "$message"
      [[ $stdout != *"Uninstalled:"* ]] || fail "[$on]: claimed success"
      [[ $later == NONE ]] || ! called "$later" || fail "[$on]: continued with '$later'"
      [[ -e $TEST_TMP/hook.ran ]] || fail "[$on]: the hook did not run"
      [[ $(cd "$TEST_TMP/victim" && find . -printf '%p %s\n') == "$before_victim" ]] ||
        fail "[$on]: followed a replacement into the victim"
      if [[ $hook == *"echo keep >"* ]]; then
        local kept=${hook##*echo keep >}
        kept=${kept//\$SB/$SB}
        [[ $(<"$kept") == keep ]] || fail "[$on]: the replacement was removed"
      fi
      if [[ $hook == *"ln -s "* ]]; then
        local link=${hook##* }
        link=${link//\$SB/$SB}
        [[ -L $link ]] || fail "[$on]: the replacing symlink was removed"
      fi
      # Tor's leftovers are removed last, after the install record (step 11).
      [[ $on == "userdel tari" || -e $SB/var/lib/tari/taritalk-install-state ]] ||
        fail "[$on]: the install record was removed"
    ) || exit 1
  done
}

test_uninstall_never_follows_symlinks_inside_the_node_directories() {
  setup_uninstall
  mkdir "$TEST_TMP/victim"
  echo keep >"$TEST_TMP/victim/file"
  ln -s "$TEST_TMP/victim" "$SB/var/log/tari/log/link"
  ln -s "$TEST_TMP/victim/file" "$SB/var/lib/tari/mainnet/file-link"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  [[ $(<"$TEST_TMP/victim/file") == keep && $(ls -A "$TEST_TMP/victim") == file ]] ||
    fail "removal followed a symlink"
}

test_uninstall_leaves_a_tor_directory_that_appeared_after_the_checks() {
  setup_uninstall
  rmdir "$SB/run/tor"
  printf '#!/usr/bin/env bash\nmkdir %q && echo keep >%q\n' "$SB/run/tor" "$SB/run/tor/file" >"$TEST_TMP/hook"
  chmod +x "$TEST_TMP/hook"
  FAKE_SYS_HOOK_ON="userdel tari" FAKE_SYS_HOOK=$TEST_TMP/hook UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "'/run/tor' appeared after the checks; leaving it untouched"
  [[ $(<"$SB/run/tor/file") == keep ]] || fail "removed a directory it never checked"
  [[ $stdout != *"Uninstalled:"* ]] || fail "claimed success"
}

# --- commands -----------------------------------------------------------------------

test_uninstall_runs_only_the_fixed_commands() {
  setup_uninstall
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  local -a want_calls=(
    "getent passwd tari"
    "getent group tari"
    "getent group tari"
    "getent passwd"
    "getent group debian-tor"
    "systemd-analyze unit-paths"
    "systemctl show -p FragmentPath --value minotari-mainnet.service"
    "systemctl show -p DropInPaths --value minotari-mainnet.service"
    "dpkg-query -W -f=\${Status} tor"
    "systemctl show -p MainPID --value tor@default.service"
    "dpkg --no-act --purge -- tor"
    "systemctl stop minotari-mainnet.service"
    "systemctl disable minotari-mainnet.service"
    "systemctl stop tor@default.service"
    "systemctl disable tor.service"
    "systemctl show -p MainPID --value tor@default.service"
    "dpkg --no-act --purge -- tor"
    "dpkg --purge -- tor"
    "systemctl daemon-reload"
    "userdel tari"
    "getent group tari"
    "groupdel tari"
    "systemctl show -p LoadState --value minotari-mainnet.service"
    "getent passwd tari"
    "getent group tari"
    "getent group debian-tor"
    "dpkg-query -W -f=\${Status} tor"
  )
  local want
  printf -v want '%s\n' "${want_calls[@]}"
  [[ $(<"$FAKE_SYS/calls") == "${want%$'\n'}" ]] || fail "unexpected system calls:
$(<"$FAKE_SYS/calls")"
  [[ -z $(ls -A "$TEST_TMP/curl-log") ]] || fail "network requests were made"
}

test_uninstall_source_never_escalates_or_executes_the_record() {
  local lib=$REPO_ROOT/lib/uninstall.sh code hits
  [[ -f $lib ]] || fail "lib/uninstall.sh is missing"
  code=$(grep -vE '^[[:space:]]*#' "$lib")
  hits=$(grep -nE '(^|[;&|(]|\$\(|then|do|else)[[:space:]]*(sudo|su|doas|pkexec|curl|wget|ssh|nc)([[:space:]]|$)' <<<"$code") || true
  [[ -z $hits ]] || fail "privilege escalation or network use in lib/uninstall.sh: $hits"
  local pattern='/dev/(tcp|udp)/|(^|[^A-Za-z_-])(eval|source|apt|apt-get|usermod|useradd|groupadd|mv|cp|ln|chmod|chown)([^A-Za-z_.-]|$)|autoremove|update|install[[:space:]]+--|dpkg[^#]*--force|rm -r|rm -f[^ ]'
  hits=$(grep -nE "$pattern" <<<"$code") || true
  [[ -z $hits ]] || fail "forbidden operation in lib/uninstall.sh: $hits"
  # The one real purge command, fixed; trees are removed only by
  # lib/install.sh remove_tree (rm -rf --one-file-system, no symlinks).
  # shellcheck disable=SC2016 # Literal source text.
  [[ $(grep -cF '"${DPKG_PURGE_TOR[@]}"' <<<"$code") == 1 &&
  $(grep -cE '^[[:space:]]*dpkg --no-act --purge -- tor ' <<<"$code") == 1 ]] ||
    fail "dpkg must be invoked from exactly two places (dry run and purge)"
  grep -qxF 'readonly -a DPKG_PURGE_TOR=(dpkg --purge -- tor)' "$lib" ||
    fail "the purge command is not the fixed one"
  # shellcheck disable=SC2016 # Literal source text.
  grep -qF 'rm -rf --one-file-system -- "./${1##*/}"' "$REPO_ROOT/lib/install.sh" || fail "remove_tree changed"
}

test_uninstall_accepts_tor_runtime_directory_removed_when_tor_stops() {
  setup_uninstall
  printf '#!/usr/bin/env bash\nrmdir %q\n' "$SB/run/tor" >"$TEST_TMP/hook"
  chmod +x "$TEST_TMP/hook"
  FAKE_SYS_HOOK_ON="systemctl stop tor@default.service" FAKE_SYS_HOOK=$TEST_TMP/hook \
    UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  [[ ! -e $SB/run/tor ]] || fail "/run/tor came back"
}

test_uninstall_refuses_extra_or_changed_files_in_the_release() {
  local rel
  setup_uninstall
  save_installed
  rel=$SB$(sed -n 's/^release_dir=//p' "$SB/var/lib/tari/taritalk-install-state")
  # shellcheck disable=SC2034 # Used by the eval'd actions.
  local REL=$rel
  local extra="contains unexpected entries"
  local not_root_file="verification.txt' is not a root-owned regular file with mode 644 and one link"
  local -a cases=(
    "touch \$REL/extra@@$extra"
    "touch \$REL/.hidden@@$extra"
    "mkdir \$REL/dir@@$extra"
    "ln -s minotari_node \$REL/link@@$extra"
    "rm \$REL/verification.txt@@$not_root_file"
    "mv \$REL/verification.txt \$REL/v && cp \$REL/v \$REL/verification.txt && rm \$REL/v && chmod 600 \$REL/verification.txt@@$not_root_file"
    "mv \$REL/verification.txt \$SB/opt/v && ln -s ../../../v \$REL/verification.txt@@$not_root_file"
    "sed -i 's/^version: .*/version: 9.9.9/' \$REL/verification.txt@@verification.txt' does not match the install record"
    "echo extra >>\$REL/verification.txt@@verification.txt' does not match the install record"
    "truncate -s -1 \$REL/verification.txt@@verification.txt' does not match the install record"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    eval "$action" || fail "[$action]: setup failed"
    expect_refusal "$action" "$message"
  done
}

test_uninstall_refuses_a_tari_group_used_by_other_accounts() {
  setup_uninstall
  save_installed
  local gid
  gid=$(grep '^tari:' "$FAKE_SYS/group" | cut -d: -f3)
  local -a cases=(
    "sed -i 's/^tari:x:\([0-9]*\):\$/tari:x:\1:alice/' \$FAKE_SYS/group@@group tari has other members (alice)"
    "sed -i 's/^tari:x:\([0-9]*\):\$/tari:x:\1:tari,alice/' \$FAKE_SYS/group@@group tari has other members (tari,alice)"
    "echo 'bob:x:12345:$gid::/home/bob:/bin/sh' >>\$FAKE_SYS/passwd@@group tari is the primary group of user bob"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    eval "$action" || fail "[$action]: setup failed"
    expect_refusal "$action" "$message"
  done
}

test_uninstall_refuses_other_copies_or_drop_ins_of_the_unit() {
  setup_uninstall
  save_installed
  local unit=minotari-mainnet.service
  local -a cases=(
    "/usr/lib/systemd/system/$unit.d/override.conf"
    "/lib/systemd/system/$unit.d/override.conf"
    "/usr/local/lib/systemd/system/$unit"
    "/usr/lib/systemd/system/$unit"
    "/etc/systemd/system/minotari-.service.d/override.conf"
    "/etc/systemd/system.control/$unit.d/50-CPUQuota.conf"
    "/run/systemd/transient/$unit.d/50-x.conf"
    "/run/systemd/system.attached/$unit.d/10-x.conf"
    "/run/systemd/generator/$unit"
    "/run/systemd/generator.late/$unit"
  )
  local path
  for path in "${cases[@]}"; do
    restore_installed
    mkdir -p "$SB${path%/*}"
    printf '[Service]\nExecStart=\nExecStart=/bin/true\n' >"$SB$path"
    "$TEST_TMP/fakebin/systemctl" daemon-reload
    # Named in the refusal: the other copy, or the drop-in directory.
    expect_refusal "$path" "'${path%/*}"
  done
  # A drop-in for every service is not this unit's own: accepted.
  restore_installed
  mkdir -p "$SB/usr/lib/systemd/system/service.d"
  printf '[Service]\nTimeoutStopFailureMode=abort\n' >"$SB/usr/lib/systemd/system/service.d/10-timeout-abort.conf"
  "$TEST_TMP/fakebin/systemctl" daemon-reload
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
}

test_uninstall_never_removes_a_package_that_came_to_depend_on_tor() {
  # A package depending on tor is installed after the checks: before the
  # services stop, or (ON "dpkg --purge -- tor") just before the purge.
  local on
  for on in "systemctl disable tor.service" "dpkg --purge -- tor"; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_uninstall
    printf '#!/usr/bin/env bash\necho nyx >>%q\necho "nyx tor" >>%q\n' "$FAKE_SYS/pkgs" "$FAKE_SYS/depends" >"$TEST_TMP/hook"
    chmod +x "$TEST_TMP/hook"
    (
      export FAKE_SYS_HOOK_ON=$on FAKE_SYS_HOOK=$TEST_TMP/hook
      UNINSTALL_INPUT=y run_uninstall
      [[ $status == 1 ]] || fail "[$on]: expected exit 1, got $status"
      grep -qx nyx "$FAKE_SYS/pkgs" || fail "[$on]: nyx was removed"
      grep -qx tor "$FAKE_SYS/pkgs" || fail "[$on]: tor was removed although nyx depends on it"
      [[ $stdout != *"Uninstalled:"* ]] || fail "[$on]: claimed success"
      [[ -e $SB/opt/tari && -e $SB/var/lib/tari/taritalk-install-state ]] || fail "[$on]: node files were removed"
    ) || exit 1
  done
}

test_uninstall_refuses_other_tor_instances_or_unknown_tor_content() {
  setup_uninstall
  echo state >"$SB/var/lib/tor/cached-certs"
  mkdir "$SB/var/lib/tor/keys"
  echo 4343 >"$SB/run/tor/tor.pid"
  save_installed
  local unexpected="is not something the default Tor instance wrote" path uid
  local -a cases=(
    "mkdir -p \$SB/etc/tor/instances/relay && touch \$SB/etc/tor/instances/relay/torrc@@'/etc/tor' contains unexpected entries"
    "mkdir \$SB/etc/tor/torrc.d@@'/etc/tor' contains unexpected entries"
    "touch \$SB/etc/tor/torrc.orig@@'/etc/tor' contains unexpected entries"
    "mkdir -p \$SB/var/lib/tor-instances/relay@@'/var/lib/tor-instances' exists: other Tor instances"
    "mkdir -p \$SB/run/tor-instances@@'/run/tor-instances' exists: other Tor instances"
    "echo log >\$SB/var/log/tor/notices.log@@'/var/log/tor' is not empty"
    "rmdir \$SB/var/log/tor && ln -s \$TEST_TMP \$SB/var/log/tor@@'/var/log/tor' is not a directory"
    "OWNER /var/lib/tor/cached-certs@@'/var/lib/tor/cached-certs' $unexpected"
    "OWNER /var/lib/tor/keys@@'/var/lib/tor/keys' $unexpected"
    "OWNER /run/tor/tor.pid 12345@@'/run/tor/tor.pid' $unexpected"
    "ln -s \$TEST_TMP \$SB/var/lib/tor/link@@'/var/lib/tor/link' $unexpected"
    "mkfifo \$SB/var/lib/tor/fifo@@'/var/lib/tor/fifo' $unexpected"
    "ln -s /etc \$SB/run/tor/link@@'/run/tor/link' $unexpected"
    "MOUNT /var/log/tor@@'/var/log/tor' is a separate mount point"
    "mkdir \$SB/proc/999 && echo tor >\$SB/proc/999/comm@@another Tor process is running (PID 999)"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    case "$action" in
      MOUNT*) fake_mount "${action#MOUNT }" ;;
      OWNER*)
        # OWNER PATH [UID]: PATH owned by UID (default root).
        read -r _ path uid <<<"$action"
        fake_stat_field "$path" %u "${uid:-0}"
        ;;
      *) eval "$action" || fail "[$action]: setup failed" ;;
    esac
    expect_refusal "$action" "$message"
  done
  # What the default instance itself wrote is fine, also what Tor creates
  # as root in its runtime directory before it drops privileges: /run/tor
  # owned by another UID (debian-tor), tor.pid by root.
  restore_installed
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
  fake_stat_field /run/tor %u 12345
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
}

test_uninstall_never_empties_a_tor_directory_the_purge_left() {
  setup_uninstall
  echo state >"$SB/var/lib/tor/cached-certs"
  FAKE_TOR_POSTRM_KEEPS=1 UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "'/var/lib/tor' is left after purging tor and is not empty; leaving it untouched"
  [[ $(<"$SB/var/lib/tor/cached-certs") == state ]] || fail "removed the contents of /var/lib/tor"
  [[ $stdout != *"Uninstalled:"* ]] || fail "claimed success"
}

# mount_at PATH: the test mount table also has a bind mount of the same
# file system (same device numbers as /) at PATH under the sandbox.
mount_at() {
  printf '40 22 254:1 /srv/x %s rw,relatime shared:1 - ext4 /dev/vda1 rw\n' "$SB$1" >>"$TEST_TMP/mountinfo"
}

test_uninstall_refuses_any_mount_at_or_below_what_it_removes() {
  setup_uninstall
  save_installed
  cp "$TEST_TMP/mountinfo" "$TEST_TMP/mountinfo.saved"
  local -a cases=(
    /opt/tari
    /opt/tari/releases
    /var/lib/tari/mainnet/mainnet/data
    /var/log/tari/log/base_node
    /var/lib/tari/taritalk-install-state
    /etc/systemd/system/minotari-mainnet.service
    /etc/tor/torrc
    /var/lib/tor/keys
    /var/log/tor
    /run/tor
    '/var/lib/tari/mainnet/a\040b'
  )
  local path
  for path in "${cases[@]}"; do
    restore_installed
    cp "$TEST_TMP/mountinfo.saved" "$TEST_TMP/mountinfo"
    mount_at "$path"
    expect_refusal "$path" "is or contains a mount point"
  done
  # Mounts beside the removed paths are fine.
  restore_installed
  cp "$TEST_TMP/mountinfo.saved" "$TEST_TMP/mountinfo"
  mount_at /var/lib/tari-other
  mount_at /opt/tarix
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
}

test_uninstall_refuses_a_mount_that_appears_after_the_confirmation() {
  setup_uninstall
  printf '#!/usr/bin/env bash\nprintf "40 22 254:1 /srv/x %%s rw - ext4 /dev/vda1 rw\\n" %q >>%q\n' \
    "$SB/var/log/tari/log" "$TEST_TMP/mountinfo" >"$TEST_TMP/hook"
  chmod +x "$TEST_TMP/hook"
  FAKE_SYS_HOOK_ON="systemctl disable tor.service" FAKE_SYS_HOOK=$TEST_TMP/hook UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "'/var/log/tari' is or contains a mount point"
  ! called "dpkg --purge *" || fail "continued with the purge"
  [[ -e $SB/var/log/tari/log && -e $SB/opt/tari ]] || fail "removed node files"
}
