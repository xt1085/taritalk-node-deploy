# shellcheck shell=bash
# install as real root (run as root, or via `sudo -n`; see tests/run.sh), in
# the same sandbox as tests/test_install.sh: every system command is faked,
# every path is under $SB. Real root makes owners real: the fake runuser
# drops to UID 65534 (standing in for the new user tari) with setpriv.

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_root_install SOURCE_DIR [ENV=VALUE...]: the install harness for
# SOURCE_DIR run as root, with the FAKE_* settings and any extra ENV.
run_root_install() {
  local source=$1
  shift
  write_install_harness "$TEST_TMP/harness.sh" 0:0 "$source"
  local -a vars=()
  local v
  for v in $(compgen -e); do
    [[ $v == FAKE_* ]] && vars+=("$v=${!v}")
  done
  as_root env "${vars[@]}" FAKE_TEST_UID=65534 FAKE_TEST_GID=65534 "$@" \
    bash "$TEST_TMP/harness.sh" --public-ip "$INSTALL_IP" --arch aarch64 --yes \
    </dev/null >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# setup_root_install: setup_install, owned by root as on a real host, with
# the fake curl's log and the fake node's trace writable by UID 65534.
setup_root_install() {
  setup_install
  # UID 65534 may not be able to reach the checkout (e.g. under /home):
  # give it copies of the fakes and guards, so that a command it runs can
  # never fall through to a real curl.
  local f
  for f in "$TEST_TMP"/fakebin/*; do
    cp --remove-destination -- "$(realpath "$f")" "$f"
  done
  cp -a -- "$TESTS_DIR/guard" "$TEST_TMP/guard"
  chmod -R a+rX "$TEST_TMP/fakebin" "$TEST_TMP/guard"
  [[ -z $(find "$TEST_TMP/fakebin" -type l) ]] || fail "fakebin still links into the checkout"
  HARNESS_GUARD=$TEST_TMP/guard
  : >"$TEST_TMP/node-trace"
  chmod 666 "$TEST_TMP/node-trace"
  chmod 777 "$TEST_TMP/curl-log"
  as_root chown -R 0:0 "$SB" "$FAKE_SYS" || fail "cannot prepare the sandbox"
  # The runner (maybe not root) removes the suite later; root-owned and
  # 65534-owned files go now.
  trap 'as_root rm -rf --one-file-system -- "$SB" "$FAKE_SYS"' EXIT
}

test_root_install_fetches_as_the_service_user_from_an_unreadable_checkout() {
  setup_root_install
  # A checkout that UID 65534 cannot read, like one under /root.
  local private=$TEST_TMP/private
  mkdir -p "$private/repo"
  cp -a "$REPO_ROOT/deploy.sh" "$REPO_ROOT/lib" "$REPO_ROOT/templates" "$private/repo/"
  chmod 700 "$private"
  install_post_fetch_hook "stat -c '%u %a %n' ../../tool ../../tool/deploy.sh ../../tool/lib ../../tool/lib/fetch.sh ../../dl >'$TEST_TMP/tool-stat'"
  run_root_install "$private/repo" FAKE_RUNUSER_SETPRIV=1
  [[ $status == 0 ]] || fail "install failed: $stderr"
  # fetch ran as UID 65534 (it refuses root), from a root-owned copy.
  [[ $(stat -c %u "$TEST_TMP/curl-log/1") == 65534 ]] || fail "fetch did not run as the service user"
  [[ $(<"$TEST_TMP/tool-stat") == "0 755 ../../tool"$'\n'"0 755 ../../tool/deploy.sh"$'\n'"0 755 ../../tool/lib"$'\n'"0 644 ../../tool/lib/fetch.sh"$'\n'"65534 700 ../../dl" ]] ||
    fail "unexpected tool copy or download directory: $(<"$TEST_TMP/tool-stat")"
  [[ $(<"$TEST_TMP/node-trace") == "--version" ]] || fail "the version probe did not run once"
  local id
  id=$(release_id)
  [[ $(stat -c '%u:%g %a' "$SB/opt/tari/releases/$id/minotari_node") == "0:0 755" ]] ||
    fail "the installed binary is not root's"
  # Under /var/lib/tari (root:65534 0750), which only root or the service
  # user can traverse: inspect as root (the runner may not be root).
  [[ $(as_root stat -c '%u:%g %a' "$SB/var/lib/tari/mainnet/mainnet/config/config.toml") == "65534:65534 600" ]] ||
    fail "the configuration is not the service user's"
  [[ $(stat -c '%u:%g %a' "$SB/var/lib/tari") == "0:65534 750" ]] || fail "/var/lib/tari ownership"
  [[ $(as_root stat -c '%u:%g %a' "$SB/var/lib/tari/taritalk-install-state") == "0:0 600" ]] || fail "state ownership"
  [[ -z $(as_root ls -A "$SB/tmp") ]] || fail "temporary files left"
}

test_root_install_fails_closed_when_fetch_would_run_as_root() {
  setup_root_install
  # Without the privilege drop, the real Phase 2 fetch refuses root.
  run_root_install "$REPO_ROOT"
  assert_status 1
  assert_stderr_contains "fetch must not run as root"
  assert_stderr_contains "error: fetch failed"
  assert_rolled_back
}

test_root_install_refuses_fetch_output_with_another_owner() {
  local action
  for action in "chown 65533 verification.txt" "chown 65533 minotari_node" "chown 65533:65533 ." \
    "chgrp 0 $ASSET_ARM64"; do
    rm -rf -- "${TEST_TMP:?}/fakebin/realpath"
    as_root rm -rf --one-file-system -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys"
    rm -rf -- "$TEST_TMP/web" "$TEST_TMP/zipsrc" "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" \
      "$TEST_TMP/node-trace" "$TEST_TMP/hook.done"
    setup_root_install
    install_post_fetch_hook "$action"
    run_root_install "$REPO_ROOT" FAKE_RUNUSER_SETPRIV=1
    [[ -e $TEST_TMP/hook.done ]] || fail "[$action]: the hook did not run"
    [[ $status == 1 ]] || fail "[$action]: expected exit 1, got $status"
    [[ $stderr == *"is not a private regular file of tari"* || $stderr == *"the fetch output directory is not private to tari"* ]] ||
      fail "[$action]: $stderr"
    [[ ! -s $TEST_TMP/node-trace ]] || fail "[$action]: the binary was executed"
    assert_rolled_back
  done
}

# run_root_uninstall INPUT [ENV=VALUE...]: lib/uninstall.sh's cmd_uninstall
# as real root against the sandbox root-installed by run_root_install, with
# INPUT on stdin. The sandbox's tari is UID 65534. With BIND_FROM and
# BIND_TO set, it runs in a private mount namespace in which BIND_FROM is
# bind-mounted on BIND_TO (the host's mounts never change).
run_root_uninstall() {
  local input=$1 f
  shift
  # Copies (not links into the checkout), as setup_root_install made.
  for f in dpkg systemd-analyze; do
    cp -- "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/$f"
    chmod a+rx "$TEST_TMP/fakebin/$f"
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$REPO_ROOT/deploy.sh" "$REPO_ROOT/lib/fetch.sh" "$REPO_ROOT/lib/install.sh" \
      "$REPO_ROOT/lib/uninstall.sh"
    printf 'is_root() { return 0; }\nSYSROOT=%q\nROOT_IDS=0:0\nSYSTEM_UID_MAX=65534\n' "$SB"
    printf 'INSTALL_PATH=%q\n' "$TEST_TMP/fakebin:$HARNESS_GUARD:/usr/sbin:/usr/bin:/sbin:/bin"
    printf 'INSTALL_SOURCE_DIR=%q\ncmd_uninstall\n' "$REPO_ROOT"
  } >"$TEST_TMP/uninstall-harness.sh"
  local -a vars=()
  local v
  for v in $(compgen -e); do
    [[ $v == FAKE_* ]] && vars+=("$v=${!v}")
  done
  printf '%s\n' "$input" >"$TEST_TMP/uninstall-input"
  local -a run=(bash "$TEST_TMP/uninstall-harness.sh")
  if [[ -n ${BIND_TO-} ]]; then
    # shellcheck disable=SC2016 # Expanded by the inner bash.
    run=(unshare -m --propagation private bash -c 'mount --bind -- "$1" "$2" && exec bash "$3"'
      bind "$BIND_FROM" "$BIND_TO" "$TEST_TMP/uninstall-harness.sh")
  fi
  as_root env "${vars[@]}" "$@" "${run[@]}" \
    <"$TEST_TMP/uninstall-input" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

test_root_uninstall_checks_real_owners_and_removes_the_node() {
  setup_root_install
  run_root_install "$REPO_ROOT" FAKE_RUNUSER_SETPRIV=1
  [[ $status == 0 ]] || fail "install failed: $stderr"
  as_root mkdir -m 755 "$SB/run/tor"
  # A data directory owned by root instead of tari is not what install left.
  as_root chown 0:0 "$SB/var/lib/tari/mainnet"
  run_root_uninstall y
  assert_status 1
  assert_stderr_contains "'/var/lib/tari/mainnet' has an unexpected owner or mode (0:0 700, expected 65534:65534 700)"
  [[ -e $SB/opt/tari/current ]] || fail "refused, but changed the node"
  as_root chown 65534:65534 "$SB/var/lib/tari/mainnet"
  run_root_uninstall y
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  assert_stdout_contains "Uninstalled: Minotari node"
  local path
  for path in /opt/tari /var/lib/tari /var/log/tari /etc/systemd/system/minotari-mainnet.service /etc/tor; do
    [[ ! -e $SB$path ]] || fail "$path is left"
  done
}

test_root_uninstall_refuses_a_real_same_device_bind_mount() {
  if ! as_root unshare -m --propagation private true 2>/dev/null; then
    printf 'note: %s: mount namespaces are not available here; the real bind-mount regression did not run (the mountinfo fixture tests still did)\n' \
      "${FUNCNAME[0]}" >&2
    return 0
  fi
  setup_root_install
  run_root_install "$REPO_ROOT" FAKE_RUNUSER_SETPRIV=1
  [[ $status == 0 ]] || fail "install failed: $stderr"
  as_root mkdir -m 755 "$SB/run/tor"
  # Elsewhere on the same file system: data that is not the node's.
  mkdir "$TEST_TMP/bind-source"
  echo keep >"$TEST_TMP/bind-source/file"
  as_root mkdir "$SB/var/lib/tari/mainnet/mainnet/bound"
  [[ $(stat -c %d "$TEST_TMP/bind-source") == $(as_root stat -c %d "$SB/var/lib/tari/mainnet") ]] ||
    fail "the bind source is not on the sandbox's file system"
  BIND_FROM=$TEST_TMP/bind-source BIND_TO=$SB/var/lib/tari/mainnet/mainnet/bound run_root_uninstall y
  [[ -e $TEST_TMP/bind-source/file ]] || fail "removed the contents of the bind mount's source"
  assert_status 1
  assert_stderr_contains "'/var/lib/tari' is or contains a mount point (/var/lib/tari/mainnet/mainnet/bound)"
  [[ -e $SB/opt/tari/current ]] || fail "refused, but changed the node"
  ! grep -q " $SB/" /proc/self/mountinfo || fail "a mount leaked out of the private namespace"
}

# setup_root_upgrade: a node root-installed by run_root_install whose
# identity exists (UID 65534's, as tari's), with Minotari 6.0.1 published.
setup_root_upgrade() {
  setup_root_install
  run_root_install "$REPO_ROOT" FAKE_RUNUSER_SETPRIV=1
  [[ $status == 0 ]] || fail "install failed: $stderr"
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config f
  for f in base_node_id.json base_node_tor_id.json; do
    as_root sh -c "echo identity >'$cfg/$f' && chown 65534:65534 '$cfg/$f' && chmod 600 '$cfg/$f'"
  done
  # The fake curl runs as UID 65534 during fetch; let it read the new release.
  publish_release_fixture 6.0.1
  tip_info '{"metadata":{"best_block_height":5},"is_synced":false}'
  chmod -R a+rX "$TEST_TMP/web"
  for f in dpkg systemd-analyze; do
    cp -- "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/$f"
    chmod a+rx "$TEST_TMP/fakebin/$f"
  done
}

# run_root_upgrade: lib/upgrade.sh's cmd_upgrade --yes as real root against
# the sandbox of setup_root_upgrade, reading the real mount table. With
# BIND_FROM and BIND_TO set, as run_root_uninstall.
run_root_upgrade() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$REPO_ROOT/deploy.sh"
    printf 'load_upgrade\nis_root() { return 0; }\n'
    printf 'SYSROOT=%q\nROOT_IDS=0:0\nSYSTEM_UID_MAX=65534\nNODE_WAIT_SECONDS=3\n' "$SB"
    printf 'INSTALL_PATH=%q\n' "$TEST_TMP/fakebin:$HARNESS_GUARD:/usr/sbin:/usr/bin:/sbin:/bin"
    printf 'CHILD_PATH=%q\n' "$TEST_TMP/fakebin:$HARNESS_GUARD:/usr/bin:/bin"
    printf 'INSTALL_SOURCE_DIR=%q\ncmd_upgrade --yes --arch aarch64\n' "$REPO_ROOT"
  } >"$TEST_TMP/upgrade-harness.sh"
  local -a vars=()
  local v
  for v in $(compgen -e); do
    [[ $v == FAKE_* ]] && vars+=("$v=${!v}")
  done
  local -a run=(bash "$TEST_TMP/upgrade-harness.sh")
  if [[ -n ${BIND_TO-} ]]; then
    # shellcheck disable=SC2016 # Expanded by the inner bash.
    run=(unshare -m --propagation private bash -c 'mount --bind -- "$1" "$2" && exec bash "$3"'
      bind "$BIND_FROM" "$BIND_TO" "$TEST_TMP/upgrade-harness.sh")
  fi
  as_root env "${vars[@]}" FAKE_RUNUSER_SETPRIV=1 "${run[@]}" \
    </dev/null >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

test_root_upgrade_checks_real_owners_and_switches_the_release() {
  setup_root_upgrade
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config
  run_root_upgrade
  [[ $status == 0 ]] || fail "upgrade failed: $stderr"
  assert_stdout_contains "Upgraded: Minotari $FIXTURE_VERSION -> 6.0.1. The node is running."
  local cur
  cur=$(readlink "$SB/opt/tari/current")
  [[ $(stat -c '%u:%g %a' "$SB/opt/tari/$cur/minotari_node") == "0:0 755" ]] || fail "new binary not root's"
  [[ $(as_root stat -c '%u:%g %a' "$SB/var/lib/tari/taritalk-install-state") == "0:0 600" ]] || fail "record owner"
  [[ $(as_root stat -c '%u:%g %a' "$cfg/base_node_id.json") == "65534:65534 600" ]] || fail "identity file changed"
  [[ $(stat -c %u "$TEST_TMP/curl-log/1") == 65534 ]] || fail "fetch did not run as the service user"
}

test_root_upgrade_refuses_a_real_same_device_bind_mount() {
  if ! as_root unshare -m --propagation private true 2>/dev/null; then
    printf 'note: %s: mount namespaces are not available here; the real bind-mount regression did not run (the mountinfo fixture tests still did)\n' \
      "${FUNCNAME[0]}" >&2
    return 0
  fi
  setup_root_upgrade
  # Elsewhere on the same file system: data that is not the node's, bound
  # over the installed release.
  mkdir "$TEST_TMP/bind-source"
  echo keep >"$TEST_TMP/bind-source/file"
  local release
  release=$(as_root sed -n 's/^release_dir=//p' "$SB/var/lib/tari/taritalk-install-state")
  [[ $(stat -c %d "$TEST_TMP/bind-source") == $(as_root stat -c %d "$SB$release") ]] ||
    fail "the bind source is not on the sandbox's file system"
  BIND_FROM=$TEST_TMP/bind-source BIND_TO=$SB$release run_root_upgrade
  [[ $(<"$TEST_TMP/bind-source/file") == keep ]] || fail "changed the contents of the bind mount's source"
  assert_status 1
  assert_stderr_contains "'/opt/tari' is or contains a mount point ($release)"
  assert_stderr_contains "upgrade refused; nothing was changed."
  [[ $(as_root readlink "$SB/opt/tari/current") == "releases/${release##*/}" ]] || fail "refused, but switched"
  [[ -e $FAKE_SYS/active.minotari-mainnet.service ]] || fail "refused, but stopped the node"
  ! grep -q " $SB/" /proc/self/mountinfo || fail "a mount leaked out of the private namespace"
}

test_root_upgrade_puts_back_the_identity_with_its_owner() {
  setup_root_upgrade
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config before
  before=$(as_root stat -c '%n %u:%g %a %s' "$cfg/base_node_id.json" "$cfg/config.toml")
  # The new release replaces the identity with a file of another owner, then fails.
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Expanded by the hook.
    printf '[[ $(realpath %q) == */minotari-6.0.1-linux-* ]] || exit 0\n' "$SB/opt/tari/current"
    printf 'rm -f %q && echo changed >%q && chmod 644 %q\n' "$cfg/base_node_id.json" \
      "$cfg/base_node_id.json" "$cfg/base_node_id.json"
    printf 'echo changed >>%q\n' "$cfg/config.toml"
  } >"$TEST_TMP/change-hook"
  chmod a+rx "$TEST_TMP/change-hook"
  FAKE_SYS_HOOK_ON="systemctl start minotari-mainnet.service" FAKE_SYS_HOOK=$TEST_TMP/change-hook \
    FAKE_NODE_BROKEN="*/minotari-6.0.1-linux-*" run_root_upgrade
  assert_status 1
  assert_stderr_contains "was put back and is running again"
  [[ $(as_root stat -c '%n %u:%g %a %s' "$cfg/base_node_id.json" "$cfg/config.toml") == "$before" ]] ||
    fail "identity or configuration not put back: $(as_root stat -c '%n %u:%g %a %s' "$cfg/base_node_id.json" "$cfg/config.toml")"
  [[ $(as_root cat "$cfg/base_node_id.json") == identity ]] || fail "identity contents not put back"
}

test_root_upgrade_puts_back_an_owner_the_new_release_changed_without_changing_contents() {
  setup_root_upgrade
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config before
  before=$(as_root stat -c '%n %u:%g %a %s' "$cfg/base_node_id.json" "$cfg/config.toml")
  # The new release starts correctly, but the identity's owner changes; its
  # contents and mode stay the same.
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Expanded by the hook.
    printf '[[ $(realpath %q) == */minotari-6.0.1-linux-* ]] || exit 0\n' "$SB/opt/tari/current"
    printf 'chown 0:0 %q\n' "$cfg/base_node_id.json"
  } >"$TEST_TMP/owner-hook"
  chmod a+rx "$TEST_TMP/owner-hook"
  FAKE_SYS_HOOK_ON="systemctl start minotari-mainnet.service" FAKE_SYS_HOOK=$TEST_TMP/owner-hook run_root_upgrade
  assert_status 1
  [[ $stdout != *"Upgraded:"* ]] || fail "claimed success with a changed owner"
  assert_stderr_contains "the node's identity or configuration changed during the upgrade"
  assert_stderr_contains "was put back and is running again"
  [[ $(as_root stat -c '%n %u:%g %a %s' "$cfg/base_node_id.json" "$cfg/config.toml") == "$before" ]] ||
    fail "owner not put back: $(as_root stat -c '%n %u:%g %a %s' "$cfg/base_node_id.json")"
}

test_root_install_accepts_ubuntus_standard_var_log() {
  setup_root_install
  # Exactly the metadata of a fresh Ubuntu 26.04 host: /var/log is
  # root:syslog (GID 101) 0775.
  as_root sh -c "cp '$FIXTURES/os-release/ubuntu-26.04' '$SB/etc/os-release' &&
    echo 'syslog:x:101:' >>'$FAKE_SYS/group' && chown 0:101 '$SB/var/log' && chmod 775 '$SB/var/log'"
  [[ $(as_root stat -c '%U:%g %a' "$SB/var/log") == *":101 775" ]] || fail "not the Ubuntu layout"
  run_root_install "$REPO_ROOT" FAKE_RUNUSER_SETPRIV=1
  [[ $status == 0 ]] || fail "install failed on Ubuntu's /var/log: $stderr"
  [[ $(as_root stat -c '%u:%g %a' "$SB/var/log") == "0:101 775" ]] || fail "/var/log was changed"
  [[ $(as_root stat -c '%u %a' "$SB/var/log/tari") == "65534 700" ]] || fail "/var/log/tari"
  # The same directory on Debian 13 is still refused.
  as_root rm -rf --one-file-system -- "$SB" "$FAKE_SYS" || fail "cannot reset the sandbox"
  setup_root_install
  as_root sh -c "cp '$FIXTURES/os-release/debian-13' '$SB/etc/os-release' &&
    echo 'syslog:x:101:' >>'$FAKE_SYS/group' && chown 0:101 '$SB/var/log' && chmod 775 '$SB/var/log'"
  run_root_install "$REPO_ROOT" FAKE_RUNUSER_SETPRIV=1
  assert_status 1
  assert_stderr_contains "unexpected host layout: '/var/log' is group- or world-writable"
  [[ ! -e $SB/var/log/tari ]] || fail "refused, but changed the host"
}
