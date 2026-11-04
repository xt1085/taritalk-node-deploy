# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# upgrade: replaces the release of a node installed by lib/install.sh. Never
# touches the real system: the node is installed into the sandbox ($SB) by
# the real cmd_install (tests/test_uninstall.sh setup_uninstall), newer
# releases are served by the fake curl, and every system command is
# tests/fakes/sys.

# publish_release_fixture VERSION [latest|tag-only] [NODE_VERSION_LINE]: a
# fake GitHub release VERSION whose Mainnet Linux ZIPs hold a minotari_node
# answering NODE_VERSION_LINE (default "minotari_node VERSION"); with
# "latest" (the default) it also becomes GitHub's latest full release.
publish_release_fixture() {
  local v=$1 mode=${2:-latest} line=${3:-minotari_node $1}
  local rel=$TEST_TMP/web/github.com/tari-project/tari/releases/download/v$v
  local src=$TEST_TMP/zipsrc-$v manifest="tari_suite-$v.sha256-unsigned.txt"
  local url=https://github.com/tari-project/tari/releases/download/v$v
  local platform asset assets='[]' f name pre=false
  mkdir -p "$rel" "$src"
  write_fake_node "$src/minotari_node" "$line"
  printf 'readme\n' >"$src/README.md"
  : >"$rel/$manifest"
  for platform in linux-arm64 linux-x86_64; do
    asset=tari_suite-$v-mainnet-abc1234-$platform.zip
    rm -f -- "$rel/$asset"
    (cd "$src" && zip -q -X "$rel/$asset" minotari_node README.md) || fail "zip failed"
    printf '%s  %s\n' "$(sha256_of "$rel/$asset")" "$asset" >"$rel/$asset.sha256"
    printf '%s  %s\n' "$(sha256_of "$rel/$asset")" "$asset" >>"$rel/$manifest"
  done
  for f in "$rel"/*; do
    name=${f##*/}
    assets=$(jq -c --arg n "$name" --argjson s "$(stat -c %s "$f")" \
      --arg d "sha256:$(sha256_of "$f")" --arg u "$url/$name" \
      '. + [{name: $n, size: $s, digest: $d, state: "uploaded",
        browser_download_url: $u}]' <<<"$assets") || fail "jq failed"
  done
  [[ $v == *-* ]] && pre=true
  mkdir -p "$TEST_TMP/$API_SUBDIR/tags"
  jq -n --arg tag "v$v" --argjson pre "$pre" --argjson assets "$assets" \
    '{tag_name: $tag, name: $tag, draft: false, prerelease: $pre, assets: $assets}' \
    >"$TEST_TMP/$API_SUBDIR/tags/v$v" || fail "jq failed"
  if [[ $mode == latest ]]; then
    jq '.prerelease = false' "$TEST_TMP/$API_SUBDIR/tags/v$v" >"$TEST_TMP/$API_SUBDIR/latest" ||
      fail "jq failed"
  fi
}

# fake_host_arch: `uname -m` (as the tool runs it) reports aarch64, the
# architecture the sandbox node was installed for, whatever the test host.
fake_host_arch() {
  printf '#!/bin/sh\nif [ "$*" = -m ]; then echo aarch64; else exec /usr/bin/uname "$@"; fi\n' \
    >"$TEST_TMP/fakebin/uname"
  chmod 755 "$TEST_TMP/fakebin/uname"
}

# setup_upgrade: a running node installed (from the fixture release
# 6.0.1-pre.2) into the sandbox, whose identity files exist and whose
# Wallet Query answers, as after its first start.
setup_upgrade() {
  setup_uninstall
  fake_host_arch
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config
  echo '{"node":"identity"}' >"$cfg/base_node_id.json"
  echo '{"tor":"identity"}' >"$cfg/base_node_tor_id.json"
  chmod 600 "$cfg/base_node_id.json" "$cfg/base_node_tor_id.json"
  tip_info '{"metadata":{"best_block_height":172497},"is_synced":false}'
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/*
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_upgrade ARGS...: lib/upgrade.sh's cmd_upgrade, run as "root" against
# the sandbox, with $UPGRADE_INPUT on stdin. Sets status/stdout/stderr.
run_upgrade() {
  printf '%s\n' "${UPGRADE_INPUT-}" >"$TEST_TMP/.stdin"
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    # shellcheck source=lib/status.sh
    source "$REPO_ROOT/lib/status.sh"
    # shellcheck source=lib/uninstall.sh
    source "$REPO_ROOT/lib/uninstall.sh"
    # shellcheck source=lib/upgrade.sh
    source "$REPO_ROOT/lib/upgrade.sh"
    # shellcheck disable=SC2317 # Called by lib/upgrade.sh.
    is_root() { return 0; }
    SYSROOT=$SB
    ROOT_IDS="$(id -u):$(id -g)"
    INSTALL_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    CHILD_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    INSTALL_SOURCE_DIR=$REPO_ROOT
    SYSTEM_UID_MAX=$(id -u)
    MOUNTINFO=$TEST_TMP/mountinfo
    NODE_WAIT_SECONDS=${UPGRADE_WAIT-3}
    cmd_upgrade "$@"
  ) <"$TEST_TMP/.stdin" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# --- command line ---------------------------------------------------------------

test_upgrade_help_works_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" upgrade --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh upgrade [--version VERSION] [--arch ARCH] [--yes]"
  assert_stdout_contains "Must be run as root"
  run_cli_with_path "$TEST_TMP/bare-bin" --help
  assert_status 0
  assert_stdout_contains "upgrade     Upgrade the installed node to a newer Minotari release"
  [[ -z $(<"$TRACE_FILE") ]] || fail "help ran commands: $(<"$TRACE_FILE")"
}

test_upgrade_usage_errors_exit_2_before_root_and_dependency_checks() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  local -a cases=("--bogus" "--version" "--version 1.2" "--version v1.2.3/../x" "--arch"
    "--arch mips" "--yes --force" "extra" "--version 6.0.2 --version 6.0.3")
  local c
  for c in "${cases[@]}"; do
    # shellcheck disable=SC2086 # Split each case into arguments.
    run_cli_with_path "$TEST_TMP/bare-bin" upgrade $c </dev/null
    [[ $status == 2 ]] || fail "[$c]: expected exit 2, got $status"
    assert_stdout_empty
    [[ $stderr != *"Please run as root"* && $stderr != *"missing required command"* ]] ||
      fail "[$c]: checked root or dependencies before the arguments"
  done
}

test_upgrade_as_non_root_says_please_run_as_root() {
  local args
  for args in "" "--yes" "--version 6.0.2 --arch amd64"; do
    # shellcheck disable=SC2086 # Split into arguments.
    run_cli upgrade $args </dev/null
    assert_status 1
    assert_stdout_empty
    [[ $stderr == "Please run as root." ]] || fail "[$args]: unexpected stderr: $stderr"
  done
}

# --- versions ------------------------------------------------------------------------

test_upgrade_compares_versions_like_semver() {
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    load_upgrade
    local pair
    for pair in "6.0.0 6.0.1" "6.0.1 6.1.0" "6.9.9 7.0.0" "6.0.1-pre.1 6.0.1-pre.2" \
      "6.0.1-pre.2 6.0.1" "6.0.1-pre.2 6.0.1-pre.10" "6.0.1-alpha 6.0.1-beta" \
      "6.0.1-pre 6.0.1-pre.1" "6.0.1-1 6.0.1-pre" "6.0.9 6.0.10" "v6.0.0 6.0.1"; do
      # shellcheck disable=SC2086 # Two versions.
      version_newer ${pair#* } ${pair% *} || fail "${pair#* } should be newer than ${pair% *}"
      # shellcheck disable=SC2086 # Two versions.
      ! version_newer ${pair% *} ${pair#* } || fail "${pair% *} should not be newer than ${pair#* }"
    done
    ! version_newer 6.0.1 6.0.1 || fail "equal versions are not newer"
    ! version_newer 6.0.1 v6.0.1 || fail "equal versions are not newer"
    exit 0
  ) || exit 1
}

test_upgrade_changes_nothing_when_already_up_to_date_or_older() {
  setup_upgrade
  local before
  before=$(system_snapshot)
  run_upgrade
  assert_status 0
  assert_stdout_contains "Minotari 6.0.1-pre.2 is already the latest release; nothing was changed."
  run_upgrade --version 6.0.1-pre.2
  assert_status 0
  assert_stdout_contains "Minotari 6.0.1-pre.2 is already installed; nothing was changed."
  local v
  for v in 6.0.0 6.0.1-pre.1 v5.9.9; do
    run_upgrade --version "$v"
    assert_status 1
    assert_stderr_contains "is older than the installed Minotari 6.0.1-pre.2; downgrades are not supported"
  done
  # GitHub's latest full release may be older than an installed pre-release.
  publish_release_fixture 6.0.0
  run_upgrade
  assert_status 1
  assert_stderr_contains "GitHub's latest full release (Minotari 6.0.0) is older than the installed Minotari 6.0.1-pre.2; downgrades are not supported"
  assert_stderr_contains "upgrade refused; nothing was changed."
  [[ $stdout != *"already the latest"* && $stdout != *"[y/N]"* ]] || fail "an older latest release was not refused: $stdout"
  ! grep -qE '^systemctl (stop|start|restart|disable|enable)|^(apt-get|dpkg|userdel|groupdel) ' "$FAKE_SYS/calls" ||
    fail "changed services or packages: $(<"$FAKE_SYS/calls")"
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
  [[ -e $FAKE_SYS/active.minotari-mainnet.service ]] || fail "the node was stopped"
}

# protected_snapshot: SHA-256 of what an upgrade must never change: the two
# identity files, the configuration, and the node's whole data tree and logs.
protected_snapshot() {
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config
  sha256sum "$cfg/base_node_id.json" "$cfg/base_node_tor_id.json" "$cfg/config.toml" \
    "$cfg/base_node/log4rs.yml"
  (cd "$SB/var/lib/tari/mainnet" && find . -printf '%p %y %m %s\n' | sort)
  (cd "$SB/var/log/tari" && find . -printf '%p %y %m %s\n' | sort)
  grep -E '^(public_ip|installed_at|packages_installed)=' "$SB/var/lib/tari/taritalk-install-state"
}

# record_value KEY: KEY's value in the sandbox install record.
record_value() {
  sed -n "s/^$1=//p" "$SB/var/lib/tari/taritalk-install-state"
}

# --- the upgrade -----------------------------------------------------------------------

test_upgrade_installs_and_starts_a_newer_release() {
  setup_upgrade
  publish_release_fixture 6.0.1
  local old_dir old_sum before
  old_dir=$(record_value release_dir)
  old_sum=$(record_value binary_sha256)
  before=$(protected_snapshot)
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "upgrade failed: $stderr"
  assert_stdout_contains "Upgrade Minotari 6.0.1-pre.2 to 6.0.1? [y/N]: "
  assert_stdout_has_line "Upgraded: Minotari 6.0.1-pre.2 -> 6.0.1. The node is running."
  local new_sum new_id
  new_sum=$(sha256_of "$TEST_TMP/zipsrc-6.0.1/minotari_node")
  new_id=minotari-6.0.1-linux-arm64-${new_sum:0:16}
  [[ $(readlink "$SB/opt/tari/current") == "releases/$new_id" ]] || fail "current: $(readlink "$SB/opt/tari/current")"
  [[ $(stat -c '%F|%a' "$SB/opt/tari/releases/$new_id/minotari_node") == "regular file|755" ]] ||
    fail "new binary not installed"
  [[ $(sha256_of "$SB/opt/tari/releases/$new_id/minotari_node") == "$new_sum" ]] || fail "wrong binary"
  [[ -d $SB$old_dir ]] || fail "the previous release was removed"
  local kv
  for kv in "version=6.0.1" "tag=v6.0.1" "release_dir=/opt/tari/releases/$new_id" "binary_sha256=$new_sum" \
    "previous_version=6.0.1-pre.2" "previous_release_dir=$old_dir" "previous_binary_sha256=$old_sum"; do
    grep -qxF "$kv" "$SB/var/lib/tari/taritalk-install-state" || fail "record lacks $kv"
  done
  [[ $(protected_snapshot) == "$before" ]] || fail "data, identity, configuration or logs changed"
  # The old node ran until the new release was downloaded and checked.
  assert_order "runuser -u tari -- env -i * fetch --destination *" \
    "runuser -u tari -- env -i * $SB/opt/tari/releases/$new_id/minotari_node --version" \
    "systemctl stop minotari-mainnet.service" "systemctl start minotari-mainnet.service"
  [[ $(readlink "$SB/proc/4242/exe") == "$SB/opt/tari/releases/$new_id/minotari_node" ]] ||
    fail "the node does not run the new release"
  ! grep -qE '^systemctl (stop|start|restart|disable|enable|daemon-reload)( |$).*tor|^systemctl daemon-reload' "$FAKE_SYS/calls" ||
    fail "Tor or units were touched: $(grep '^systemctl' "$FAKE_SYS/calls")"
  ! grep -qE '^(apt-get|dpkg|useradd|userdel|groupadd|groupdel) ' "$FAKE_SYS/calls" || fail "packages or accounts touched"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  ! called "GUARD *" || fail "a real system command was reached: $(grep GUARD "$FAKE_SYS/calls")"
  run_ops status
  assert_status 0
  assert_stdout_contains "Version: minotari_node 6.0.1"
}

test_upgrade_failures_before_the_switch_leave_the_node_running() {
  # SETTING @@ message
  local -a cases=(
    "FAKE_CURL_FAIL_NAME=tari_suite-6.0.1-mainnet-abc1234-linux-arm64.zip@@fetch failed"
    "WRONG_VERSION@@does not report version 6.0.1"
    "FAKE_SYS_FAIL=runuser -u tari -- env -i * --version@@'minotari_node --version' failed"
  )
  local c setting message before record_before
  setup_upgrade
  save_installed
  for c in "${cases[@]}"; do
    setting=${c%%@@*}
    message=${c#*@@}
    restore_installed
    rm -rf -- "${TEST_TMP:?}/web/github.com" "$TEST_TMP/zipsrc-6.0.1"
    if [[ $setting == WRONG_VERSION ]]; then
      publish_release_fixture 6.0.1 latest "minotari_node 6.0.0"
    else
      publish_release_fixture 6.0.1
    fi
    before=$(system_snapshot)
    record_before=$(<"$SB/var/lib/tari/taritalk-install-state")
    (
      [[ $setting == WRONG_VERSION ]] || export "${setting%%=*}=${setting#*=}"
      UPGRADE_INPUT=y run_upgrade
      [[ $status == 1 ]] || fail "[$setting]: expected exit 1, got $status"
      assert_stderr_contains "$message"
      assert_stderr_contains "Upgrade failed before the node was touched: it keeps running Minotari 6.0.1-pre.2."
      [[ $stdout != *"Upgraded:"* ]] || fail "[$setting]: claimed success"
      ! called "systemctl stop *" || fail "[$setting]: the node was stopped"
      [[ -e $FAKE_SYS/active.minotari-mainnet.service ]] || fail "[$setting]: the node is not running"
      [[ $(<"$SB/var/lib/tari/taritalk-install-state") == "$record_before" ]] || fail "[$setting]: record changed"
      [[ $(system_snapshot) == "$before" ]] || fail "[$setting]: files were left or changed"
    ) || exit 1
  done
}

test_upgrade_cancel_changes_nothing() {
  setup_upgrade
  publish_release_fixture 6.0.1
  local before answer
  before=$(system_snapshot)
  for answer in "" n N no yes x; do
    : >"$FAKE_SYS/calls"
    UPGRADE_INPUT=$answer run_upgrade
    [[ $status == 0 ]] || fail "[$answer]: expected exit 0, got $status: $stderr"
    assert_stdout_contains "Upgrade to:  Minotari 6.0.1 (GitHub's latest full release)"
    assert_stdout_contains "Upgrade cancelled; nothing was changed."
    ! grep -qE '^systemctl (stop|start)|fetch --destination' "$FAKE_SYS/calls" ||
      fail "[$answer]: downloaded or touched the node: $(<"$FAKE_SYS/calls")"
    [[ $(system_snapshot) == "$before" ]] || fail "[$answer]: the system changed"
  done
  run_upgrade --yes
  assert_status 0
  [[ $stdout != *"[y/N]"* ]] || fail "asked for confirmation despite --yes"
  assert_stdout_contains "Upgraded: Minotari 6.0.1-pre.2 -> 6.0.1."
}

test_upgrade_restores_the_previous_release_when_the_new_one_fails() {
  local mode
  for mode in start listen; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/zipsrc-6.0.1" "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_upgrade
    publish_release_fixture 6.0.1
    local old_link old_record before
    old_link=$(readlink "$SB/opt/tari/current")
    old_record=$(<"$SB/var/lib/tari/taritalk-install-state")
    before=$(protected_snapshot)
    (
      export FAKE_NODE_BROKEN="*/minotari-6.0.1-linux-*" FAKE_NODE_BROKEN_MODE=$mode
      UPGRADE_INPUT=y run_upgrade
      [[ $status == 1 ]] || fail "[$mode]: expected exit 1, got $status"
      assert_stderr_contains "Upgrade failed: Minotari 6.0.1 did not start correctly. The previous release (Minotari 6.0.1-pre.2) was put back and is running again."
      [[ $stdout != *"Upgraded:"* ]] || fail "[$mode]: claimed success"
      [[ $(readlink "$SB/opt/tari/current") == "$old_link" ]] || fail "[$mode]: current not restored"
      [[ $(<"$SB/var/lib/tari/taritalk-install-state") == "$old_record" ]] || fail "[$mode]: record not restored"
      [[ $(readlink "$SB/proc/4242/exe") == $(realpath "$SB/opt/tari/current/minotari_node") ]] ||
        fail "[$mode]: the old release is not running"
      [[ -z $(find "$SB/opt/tari/releases" -maxdepth 1 -name 'minotari-6.0.1-linux-*') ]] ||
        fail "[$mode]: the failed release was left behind"
      [[ $(protected_snapshot) == "$before" ]] || fail "[$mode]: data, identity or configuration changed"
      [[ -z $(ls -A "$SB/tmp") ]] || fail "[$mode]: temporary files left"
      ! grep -qE '^systemctl (stop|start|restart|disable|enable) tor' "$FAKE_SYS/calls" || fail "[$mode]: Tor touched"
      run_ops status
      assert_status 0
      assert_stdout_contains "Version: minotari_node 6.0.1-pre.2"
    ) || exit 1
  done
}

# changing_release_hook: a FAKE_SYS hook that, when Minotari 6.0.1 is
# started, changes the node's identity and configuration (as a faulty new
# release might) before it runs.
changing_release_hook() {
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Expanded by the hook.
    printf '[[ $(realpath %q) == */minotari-6.0.1-linux-* ]] || exit 0\n' "$SB/opt/tari/current"
    printf 'echo changed >%q\n' "$cfg/base_node_id.json"
    printf 'echo changed >>%q\n' "$cfg/config.toml"
    printf 'chmod 644 %q\n' "$cfg/base_node_tor_id.json"
  } >"$TEST_TMP/change-hook"
  chmod +x "$TEST_TMP/change-hook"
}

test_upgrade_puts_back_identity_and_configuration_the_new_release_changed() {
  local mode
  for mode in fails starts; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/zipsrc-6.0.1" "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/node-trace"
    setup_upgrade
    publish_release_fixture 6.0.1
    changing_release_hook
    local old_link before
    old_link=$(readlink "$SB/opt/tari/current")
    before=$(protected_snapshot)
    (
      export FAKE_SYS_HOOK_ON="systemctl start minotari-mainnet.service" FAKE_SYS_HOOK=$TEST_TMP/change-hook
      [[ $mode == starts ]] || export FAKE_NODE_BROKEN="*/minotari-6.0.1-linux-*"
      UPGRADE_INPUT=y run_upgrade
      [[ $status == 1 ]] || fail "[$mode]: expected exit 1, got $status"
      [[ $mode == fails ]] ||
        assert_stderr_contains "the node's identity or configuration changed during the upgrade"
      assert_stderr_contains "The previous release (Minotari 6.0.1-pre.2) was put back and is running again."
      [[ $(readlink "$SB/opt/tari/current") == "$old_link" ]] || fail "[$mode]: current not restored"
      [[ $(protected_snapshot) == "$before" ]] ||
        fail "[$mode]: identity or configuration not put back: $(diff <(echo "$before") <(protected_snapshot))"
      [[ $(stat -c '%u:%g %a' "$SB/var/lib/tari/mainnet/mainnet/config/base_node_id.json") == "$(id -u):$(id -g) 600" ]] ||
        fail "[$mode]: identity file owner or mode not put back"
      [[ $(readlink "$SB/proc/4242/exe") == $(realpath "$SB/opt/tari/current/minotari_node") ]] ||
        fail "[$mode]: the old release is not running"
      [[ -z $(ls -A "$SB/tmp") ]] || fail "[$mode]: temporary files (copies of the identity?) left"
      [[ -z $(find "$SB/var/lib/tari" -name '.restore.*') ]] || fail "[$mode]: leftovers next to the identity"
    ) || exit 1
  done
}

test_upgrade_says_so_when_even_the_previous_release_does_not_come_back() {
  setup_upgrade
  publish_release_fixture 6.0.1
  FAKE_NODE_BROKEN="*" UPGRADE_INPUT=y run_upgrade
  assert_status 1
  assert_stderr_contains "Upgrade failed: Minotari 6.0.1 did not start correctly, and the previous release (Minotari 6.0.1-pre.2) could not be confirmed running either."
  assert_stderr_contains "Check the node with './deploy.sh status' and './deploy.sh logs'"
  [[ $stderr != *"is running again"* && $stdout != *"Upgraded:"* ]] || fail "claimed a recovery or success"
}

test_upgrade_twice_keeps_only_the_current_and_previous_release() {
  setup_upgrade
  local first_dir
  first_dir=$(record_value release_dir)
  publish_release_fixture 6.0.1
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "first upgrade failed: $stderr"
  local second_dir
  second_dir=$(record_value release_dir)
  publish_release_fixture 6.0.2
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "second upgrade failed: $stderr"
  assert_stdout_has_line "Upgraded: Minotari 6.0.1 -> 6.0.2. The node is running."
  local third_dir
  third_dir=$(record_value release_dir)
  local kept want
  kept=$(find "$SB/opt/tari/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  want=$(printf '%s\n' "${second_dir##*/}" "${third_dir##*/}" | sort)
  [[ $kept == "$want" ]] || fail "releases kept: $kept"
  [[ ! -e $SB$first_dir ]] || fail "the oldest release was kept"
  [[ $(record_value previous_release_dir) == "$second_dir" && $(record_value previous_version) == 6.0.1 ]] ||
    fail "previous release not recorded"
  run_ops status
  assert_status 0
  assert_stdout_contains "Version: minotari_node 6.0.2"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall after upgrades failed: $stderr"
  [[ ! -e $SB/opt/tari ]] || fail "releases left after uninstall"
}

test_upgraded_node_refuses_unrecorded_or_changed_releases() {
  setup_upgrade
  publish_release_fixture 6.0.1
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "upgrade failed: $stderr"
  rm -f -- "$TEST_TMP"/curl-log/*
  save_installed
  local prev
  prev=$SB$(record_value previous_release_dir)
  # shellcheck disable=SC2034 # Used by the eval'd actions.
  local PREV=$prev STATE=$SB/var/lib/tari/taritalk-install-state
  local -a cases=(
    "mkdir \$SB/opt/tari/releases/minotari-9.9.9-linux-arm64-0000000000000000@@'/opt/tari/releases' contains unexpected entries"
    "echo x >>\$PREV/minotari_node@@does not match the recorded SHA-256"
    "touch \$PREV/extra@@contains unexpected entries"
    "sed -i '/^previous_binary_sha256=/d' \$STATE@@is not a valid install record"
    "sed -i 's#^previous_release_dir=.*#previous_release_dir=/opt/tari/releases/../x#' \$STATE@@is not a valid install record"
    "sed -i 's#^previous_release_dir=.*#previous_release_dir=/opt/tari/current#' \$STATE@@is not a valid install record"
  )
  local c action message
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    eval "$action" || fail "[$action]: setup failed"
    expect_refusal "$action" "$message"
    : >"$FAKE_SYS/calls"
    UPGRADE_INPUT=y run_upgrade --version 6.0.2
    [[ $status == 1 ]] || fail "[$action]: upgrade did not refuse"
    assert_stderr_contains "$message"
    assert_stderr_contains "upgrade refused; nothing was changed"
    ! called "systemctl stop *" || fail "[$action]: upgrade stopped the node"
  done
}

# --- mounts ---------------------------------------------------------------------------

test_upgrade_refuses_any_mount_in_the_release_tree() {
  setup_upgrade
  publish_release_fixture 6.0.1
  cp "$TEST_TMP/mountinfo" "$TEST_TMP/mountinfo.saved"
  local before path
  before=$(system_snapshot)
  for path in /opt/tari /opt/tari/releases "$(record_value release_dir)" "$(record_value release_dir)/x"; do
    cp "$TEST_TMP/mountinfo.saved" "$TEST_TMP/mountinfo"
    mount_at "$path"
    : >"$FAKE_SYS/calls"
    UPGRADE_INPUT=y run_upgrade
    [[ $status == 1 ]] || fail "[$path]: expected exit 1, got $status"
    assert_stderr_contains "'/opt/tari' is or contains a mount point ($path)"
    assert_stderr_contains "upgrade refused; nothing was changed."
    [[ $stdout != *"[y/N]"* ]] || fail "[$path]: asked before checking"
    ! called "systemctl stop *" || fail "[$path]: the node was stopped"
    [[ $(system_snapshot) == "$before" ]] || fail "[$path]: the system changed"
  done
}

test_upgrade_keeps_the_oldest_release_when_a_mount_appears_in_it() {
  setup_upgrade
  local first_dir
  first_dir=$(record_value release_dir)
  publish_release_fixture 6.0.1
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "first upgrade failed: $stderr"
  publish_release_fixture 6.0.2
  # Something mounts into the oldest release after the checks.
  printf '#!/usr/bin/env bash\nprintf %q >>%q\n' \
    "41 22 254:1 /srv/x $SB$first_dir/sub rw,relatime shared:1 - ext4 /dev/vda1 rw"$'\n' \
    "$TEST_TMP/mountinfo" >"$TEST_TMP/mount-hook"
  chmod +x "$TEST_TMP/mount-hook"
  FAKE_SYS_HOOK_ON="systemctl start minotari-mainnet.service" FAKE_SYS_HOOK=$TEST_TMP/mount-hook \
    UPGRADE_INPUT=y run_upgrade
  assert_status 1
  assert_stdout_has_line "Upgraded: Minotari 6.0.1 -> 6.0.2. The node is running."
  assert_stderr_contains "'/opt/tari' is or contains a mount point ($first_dir/sub)"
  assert_stderr_contains "the oldest release (Minotari 6.0.1-pre.2) was not removed; remove it by hand"
  [[ $stderr != *"warning:"* ]] || fail "reported only as a warning: $stderr"
  [[ -d $SB$first_dir ]] || fail "removed the oldest release despite the mount"
}

# --- boundaries ----------------------------------------------------------------------

test_upgrade_requests_only_the_release_and_the_local_wallet_query() {
  setup_upgrade
  publish_release_fixture 6.0.1
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "upgrade failed: $stderr"
  local i n url
  n=$(curl_call_count)
  ((n > 0)) || fail "no requests at all"
  for ((i = 1; i <= n; i++)); do
    load_curl_call "$i"
    url=${CALL[-1]}
    case "$url" in
      https://api.github.com/repos/tari-project/tari/releases/latest | \
        https://api.github.com/repos/tari-project/tari/releases/tags/v6.0.1 | \
        https://github.com/tari-project/tari/releases/download/v6.0.1/* | \
        http://127.0.0.1:9000/get_tip_info) ;;
      *) fail "unexpected request: $url" ;;
    esac
  done
}

test_upgrade_source_stays_within_its_bounds() {
  local lib=$REPO_ROOT/lib/upgrade.sh code hits
  # Comments and the list of commands that must exist are not calls.
  code=$(grep -vE '^[[:space:]]*#' "$lib" | sed '/^readonly UPGRADE_DEPENDENCIES=/,/)$/d')
  hits=$(grep -nE '(^|[;&|(]|\$\(|then|do|else)[[:space:]]*(sudo|su|doas|pkexec|curl|wget|ssh|nc)([[:space:]]|$)' <<<"$code") || true
  [[ -z $hits ]] || fail "privileges or direct network use in lib/upgrade.sh: $hits"
  hits=$(grep -nE '(^|[^A-Za-z_-])(eval|source|apt|apt-get|dpkg|useradd|usermod|userdel|groupadd|groupdel)([^A-Za-z_.-]|$)|rm -rf|systemctl[^|;]*(enable|disable|restart|daemon-reload|mask)' <<<"$code") || true
  [[ -z $hits ]] || fail "forbidden operation in lib/upgrade.sh: $hits"
  # Tor is only ever asked whether it runs.
  hits=$(grep -nE 'TOR_(MASTER_)?SERVICE' <<<"$code" | grep -v 'is-active') || true
  [[ -z $hits ]] || fail "lib/upgrade.sh does more with Tor than check it: $hits"
  # The node service is only stopped, started and queried.
  hits=$(grep -nE 'systemctl (stop|start)' <<<"$code" | grep -v 'NODE_SERVICE') || true
  [[ -z $hits ]] || fail "lib/upgrade.sh stops or starts something else: $hits"
}

test_upgrade_interrupted_while_downloading_leaves_the_node_running() {
  setup_upgrade
  publish_release_fixture 6.0.1
  local record_before before
  record_before=$(<"$SB/var/lib/tari/taritalk-install-state")
  before=$(system_snapshot)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$REPO_ROOT/deploy.sh"
    printf 'load_upgrade\nis_root() { return 0; }\n'
    printf 'SYSROOT=%q\nROOT_IDS=%q\nSYSTEM_UID_MAX=%q\nMOUNTINFO=%q\n' "$SB" "$(id -u):$(id -g)" \
      "$(id -u)" "$TEST_TMP/mountinfo"
    printf 'INSTALL_PATH=%q\nCHILD_PATH=%q\n' "$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin" \
      "$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin"
    printf 'cmd_upgrade --yes\n'
  } >"$TEST_TMP/upgrade-harness.sh"
  FAKE_CURL_SLEEP_NAME=tari_suite-6.0.1-mainnet-abc1234-linux-arm64.zip \
    env --default-signal=INT,QUIT bash "$TEST_TMP/upgrade-harness.sh" </dev/null >"$TEST_TMP/out" 2>&1 &
  local pid=$!
  wait_for_file "$TEST_TMP/curl-log/sleep.pid"
  kill -s TERM "$pid"
  wait "$pid"
  status=$?
  stderr=$(<"$TEST_TMP/out")
  [[ $status == 143 ]] || fail "expected 143, got $status: $stderr"
  assert_process_gone "$TEST_TMP/curl-log/sleep.pid"
  assert_stderr_contains "Upgrade failed before the node was touched: it keeps running Minotari 6.0.1-pre.2."
  ! called "systemctl stop *" || fail "the node was stopped"
  [[ $(<"$SB/var/lib/tari/taritalk-install-state") == "$record_before" ]] || fail "record changed"
  [[ $(system_snapshot) == "$before" ]] || fail "files were left or changed"
}

test_upgrade_refuses_a_node_that_is_not_running() {
  setup_upgrade
  publish_release_fixture 6.0.1
  "$TEST_TMP/fakebin/systemctl" stop minotari-mainnet.service
  : >"$FAKE_SYS/calls"
  local before
  before=$(system_snapshot)
  UPGRADE_INPUT=y run_upgrade
  assert_status 1
  assert_stderr_contains "the node is not running; check it with './deploy.sh status' first"
  assert_stderr_contains "upgrade refused; nothing was changed"
  assert_only_reads
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
}

test_upgrade_refuses_a_node_without_its_identity_yet() {
  setup_upgrade
  publish_release_fixture 6.0.1
  rm "$SB/var/lib/tari/mainnet/mainnet/config/base_node_tor_id.json"
  local before
  before=$(system_snapshot)
  UPGRADE_INPUT=y run_upgrade
  assert_status 1
  assert_stderr_contains "the node has not created its identity yet; let it run first"
  [[ $stdout != *"[y/N]"* ]] || fail "asked before checking"
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
}

test_upgrade_stops_if_the_running_release_changed_meanwhile() {
  setup_upgrade
  publish_release_fixture 6.0.1
  local old
  old=$(readlink "$SB/opt/tari/current")
  printf '#!/usr/bin/env bash\nln -sfn releases/elsewhere %q\n' "$SB/opt/tari/current" >"$TEST_TMP/hook"
  chmod +x "$TEST_TMP/hook"
  FAKE_CURL_HOOK_NAME=tari_suite-6.0.1-mainnet-abc1234-linux-arm64.zip FAKE_CURL_HOOK=$TEST_TMP/hook \
    UPGRADE_INPUT=y run_upgrade
  assert_status 1
  assert_stderr_contains "the installed node changed during the upgrade"
  assert_stderr_contains "Upgrade failed before the node was touched"
  ! called "systemctl stop *" || fail "the node was stopped"
  [[ $(readlink "$SB/opt/tari/current") == releases/elsewhere ]] || fail "the changed link was touched"
  : "$old"
}

test_upgrade_puts_back_a_mode_the_new_release_changed_without_changing_contents() {
  setup_upgrade
  publish_release_fixture 6.0.1
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config old_link before
  old_link=$(readlink "$SB/opt/tari/current")
  before=$(stat -c '%n %u:%g %a' "$cfg"/base_node_id.json "$cfg"/base_node_tor_id.json "$cfg"/config.toml \
    "$cfg"/base_node/log4rs.yml)
  # The new release starts correctly, but makes the Tor identity readable by
  # everyone; its contents stay the same.
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Expanded by the hook.
    printf '[[ $(realpath %q) == */minotari-6.0.1-linux-* ]] || exit 0\n' "$SB/opt/tari/current"
    printf 'chmod 644 %q\n' "$cfg/base_node_tor_id.json"
  } >"$TEST_TMP/mode-hook"
  chmod +x "$TEST_TMP/mode-hook"
  FAKE_SYS_HOOK_ON="systemctl start minotari-mainnet.service" FAKE_SYS_HOOK=$TEST_TMP/mode-hook \
    UPGRADE_INPUT=y run_upgrade
  assert_status 1
  [[ $stdout != *"Upgraded:"* ]] || fail "claimed success with a changed mode"
  assert_stderr_contains "the node's identity or configuration changed during the upgrade"
  assert_stderr_contains "The previous release (Minotari 6.0.1-pre.2) was put back and is running again."
  [[ $(readlink "$SB/opt/tari/current") == "$old_link" ]] || fail "current not restored"
  [[ $(stat -c '%n %u:%g %a' "$cfg"/base_node_id.json "$cfg"/base_node_tor_id.json "$cfg"/config.toml \
    "$cfg"/base_node/log4rs.yml) == "$before" ]] || fail "mode not put back: $(stat -c '%n %a' "$cfg/base_node_tor_id.json")"
  [[ $(readlink "$SB/proc/4242/exe") == $(realpath "$SB/opt/tari/current/minotari_node") ]] ||
    fail "the old release is not running"
}
