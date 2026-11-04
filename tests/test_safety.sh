# shellcheck shell=bash
# Evidence that preflight is side-effect free: no privileged, package,
# service, account, filesystem-mutating, network or cloud command is run, and
# nothing is written.

# Commands preflight must never invoke. Each is replaced by a stub that
# records the call and fails.
FORBIDDEN_COMMANDS=(
  sudo su doas pkexec
  apt apt-get dpkg
  systemctl service journalctl
  useradd usermod userdel groupadd
  rm mkdir cp mv install ln chmod chown touch tee dd
  curl wget nc ncat socat ssh scp rsync git
  tor iptables ip6tables nft ufw
  gcloud aws doctl hcloud cloudflared dig nslookup host
  minotari_node
)

# make_sandbox_path DIR [EXTRA...]: create DIR with bash, a fake `uname -m`
# that reports aarch64, and tracing stubs for every forbidden command plus any
# EXTRA command names. Every stub call is appended to $TRACE_FILE.
make_sandbox_path() {
  local dir=$1 cmd
  mkdir -p "$dir"
  cat >"$dir/uname" <<'STUB'
#!/usr/bin/env bash
printf 'uname %s\n' "$*" >>"$TRACE_FILE"
[[ $1 == -m ]] && echo aarch64
STUB
  cat >"$TEST_TMP/forbidden-stub" <<'STUB'
#!/usr/bin/env bash
printf 'FORBIDDEN %s %s\n' "${0##*/}" "$*" >>"$TRACE_FILE"
exit 99
STUB
  for cmd in "${FORBIDDEN_COMMANDS[@]}" "${@:2}"; do
    cp "$TEST_TMP/forbidden-stub" "$dir/$cmd"
  done
  chmod +x "$dir"/*
  # Added after chmod so the glob above never follows it to the real bash.
  ln -s "$(command -v bash)" "$dir/bash"
}

test_preflight_runs_no_forbidden_commands_and_writes_nothing() {
  make_sandbox_path "$TEST_TMP/sandbox-bin"
  mkdir "$TEST_TMP/workdir"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  (
    cd "$TEST_TMP/workdir" || exit 1
    HOME=$TEST_TMP/workdir run_cli_with_path "$TEST_TMP/sandbox-bin" \
      preflight --os-release "$FIXTURES/os-release/debian-12"
    assert_status 0
    assert_stdout_contains "arch: aarch64"
    assert_stdout_contains "tari_asset_platform: linux-arm64"
  ) || exit 1

  local trace
  trace=$(<"$TRACE_FILE")
  [[ $trace == "uname -m" ]] ||
    fail "unexpected commands invoked: $trace"
  [[ -z $(ls -A "$TEST_TMP/workdir") ]] ||
    fail "preflight wrote files: $(ls -A "$TEST_TMP/workdir")"
}

test_preflight_defaults_to_system_os_release() {
  run_cli preflight --arch aarch64
  local output="${stdout-}${stderr-}"
  [[ $output == *"/etc/os-release"* || $output == *"/usr/lib/os-release"* ]] ||
    fail "default os-release path not used"
}

test_cli_source_contains_no_privileged_or_network_operations() {
  # Static backstop for operations the PATH sandbox cannot intercept
  # (bash /dev/tcp sockets, absolute-path commands, privilege checks).
  local pattern='/dev/(tcp|udp)/|(^|[^A-Za-z_-])(sudo|apt-get|apt|systemctl|useradd|usermod|curl|wget|ssh|iptables|nft|ufw)([^A-Za-z_-]|$)|rm -rf|EUID|id -u'
  local hits
  hits=$(grep -nE "$pattern" <(grep -vE '^[[:space:]]*#' "$CLI")) || true
  [[ -z $hits ]] || fail "forbidden operation in CLI source: $hits"
}
