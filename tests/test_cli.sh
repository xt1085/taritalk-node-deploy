# shellcheck shell=bash
# Top-level CLI behavior: --help and --version.

test_help_prints_usage_and_exits_zero() {
  run_cli --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh"
  assert_stdout_contains "preflight"
  assert_stdout_contains "--version"
  assert_stdout_contains "Unofficial TariTalk community tool"
  assert_stdout_contains "install     Install and start a Minotari Mainnet node"
  assert_stdout_contains "status      Show the state of the installed node; read-only, run as root"
  assert_stdout_contains "logs        Show the node's base_layer.log; read-only, run as root"
  assert_stdout_contains "uninstall   Uninstall all: remove the node installed by this tool"
  assert_stdout_contains "Run without arguments in a terminal for a simple menu."
  [[ $stdout != *"status, logs"* && $stdout != *"menu  "* ]] || fail "help lists status/logs as missing or a menu"
}

test_version_prints_stable_version_and_exits_zero() {
  run_cli --version
  assert_status 0
  assert_stderr_empty
  assert_stdout_equals "taritalk-node-deploy 0.1.0"
}

test_no_arguments_prints_usage_to_stderr_and_exits_two() {
  run_cli
  assert_status 2
  assert_stdout_empty
  assert_stderr_contains "Usage: ./deploy.sh"
}

test_unknown_command_is_rejected_with_exit_two() {
  local cmd
  for cmd in Upgrade rollback verify Uninstall menu bogus Status LOGS log; do
    run_cli "$cmd"
    assert_status 2
    assert_stdout_empty
    assert_stderr_contains "unknown command '$cmd'"
  done
}

test_preflight_rejects_bad_options_with_exit_two() {
  run_cli preflight --bogus
  assert_status 2
  assert_stderr_contains "unknown preflight option '--bogus'"

  run_cli preflight --arch
  assert_status 2
  assert_stderr_contains "--arch requires a value"

  run_cli preflight --os-release
  assert_status 2
  assert_stderr_contains "--os-release requires a value"
}

test_preflight_help_exits_zero() {
  run_cli preflight --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh preflight"
  assert_stdout_contains "--os-release FILE"
  assert_stdout_contains "--arch ARCH"
}

test_preflight_rejects_option_as_option_value_with_exit_two() {
  local opt next
  for opt in --arch --os-release; do
    for next in --help --bogus; do
      run_cli preflight "$opt" "$next"
      assert_status 2
      assert_stdout_empty
      assert_stderr_contains "$opt requires a value"
    done
  done
}

test_deploy_sh_is_the_only_entry_point_and_describes_network_use_accurately() {
  [[ -x $REPO_ROOT/deploy.sh ]] || fail "deploy.sh missing or not executable"
  [[ ! -e $REPO_ROOT/bin ]] || fail "bin/ must not remain as an entry point"
  # Works from any working directory.
  stdout=$(cd / && "$REPO_ROOT/deploy.sh" --help) || fail "deploy.sh --help failed from /"
  assert_stdout_contains "preflight   Read-only platform check; makes no network requests"
  assert_stdout_contains "fetch       Download and verify a Minotari release from Tari's"
  [[ $stdout != *"Phase 1"* && $stdout != *"never makes network requests"* ]] ||
    fail "help still describes the whole tool as Phase 1 / network-free"
  local header
  header=$(sed -n '1,12p' "$REPO_ROOT/deploy.sh")
  [[ $header != *"Phase 1"* && $header != *"makes network requests"*"never"* &&
    $header != *"never installs, writes system files, invokes systemd, or makes network requests"* ]] ||
    fail "deploy.sh header comment is out of date"
}
