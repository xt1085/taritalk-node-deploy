# shellcheck shell=bash
# uninstall as the CLI loads it: deploy.sh's load_uninstall sources
# lib/uninstall.sh from inside a function, so its top-level declarations
# must still be global once load_uninstall has returned.

test_uninstall_state_survives_the_real_cli_loader() {
  local sb=$TEST_TMP/sysroot unit=/etc/systemd/system/minotari-mainnet.service tor=/run/tor
  mkdir -p "$sb/etc/systemd/system"
  echo unit >"$sb/etc/systemd/system/minotari-mainnet.service"
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    load_uninstall
    # Back from load_uninstall: the shared state is still there.
    [[ $(declare -p TARGET_ID 2>&1) == "declare -A TARGET_ID"* ]] ||
      fail "TARGET_ID is not a global associative array: $(declare -p TARGET_ID 2>&1)"
    [[ ${#TOR_DIRS[@]} == 4 && ${DPKG_PURGE_TOR[*]} == "dpkg --purge -- tor" ]] ||
      fail "lib/uninstall.sh constants did not survive load_uninstall"
    # shellcheck disable=SC2034 # Used by lib/install.sh sysroot.
    SYSROOT=$sb
    record_target file "$unit" 2>"$TEST_TMP/err" || fail "record_target failed: $(<"$TEST_TMP/err")"
    record_target tree "$tor" 2>>"$TEST_TMP/err" || fail "record_target failed: $(<"$TEST_TMP/err")"
    [[ ! -s $TEST_TMP/err ]] || fail "record_target reported: $(<"$TEST_TMP/err")"
    [[ ${TARGET_ID[$unit]} == "$(object_id file "$sb$unit")" ]] ||
      fail "wrong identity recorded: $(declare -p TARGET_ID)"
    [[ ${TARGET_ID[$tor]} == absent && ${#TARGET_ID[@]} == 2 ]] ||
      fail "unexpected keys: $(declare -p TARGET_ID)"
    exit 0
  ) || exit 1
}
