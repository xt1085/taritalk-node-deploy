# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# grpc: the node's read-only Base Node gRPC over HTTPS for a node installed
# by this tool, alone or next to its Wallet Query. Never touches the real
# system: as tests/test_wallet_query.sh (the node in the sandbox, Nginx,
# systemd and DNS in tests/fakes/sys, the stand-in acme.sh), with gRPC
# calls answered by tests/fakes/curl from the sandbox's node configuration
# and Nginx configuration, as the node and Nginx would.

readonly GRPC_DOMAIN=grpc.example.com
readonly GRPC_ALLOWED=(get_version get_sync_info get_sync_progress get_tip_info identify
  get_network_status get_network_state list_headers)

# setup_grpc: setup_wallet_query, plus the gRPC domain pointing to this
# server and its certificate check served from its webroot.
setup_grpc() {
  setup_wallet_query
  printf '%s %s\n%s %s\n' "$WQ_DOMAIN" "$INSTALL_IP" "$GRPC_DOMAIN" "$INSTALL_IP" >"$FAKE_SYS/dns"
  mkdir -p "$TEST_TMP/web/$GRPC_DOMAIN"
  ln -s "$SB/var/lib/taritalk-grpc/webroot/.well-known" "$TEST_TMP/web/$GRPC_DOMAIN/.well-known"
  NODE_CONFIG_BEFORE=$(sha256_of "$SB/var/lib/tari/mainnet/mainnet/config/config.toml")
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_grpc ARGS...: lib/grpc.sh's cmd_grpc as "root" against the sandbox,
# with $GRPC_INPUT on stdin (a "terminal" when FAKE_TTY is set).
run_grpc() {
  printf '%s\n' "${GRPC_INPUT-}" >"$TEST_TMP/.stdin"
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    load_grpc
    # shellcheck disable=SC2317,SC2329 # Called by lib/grpc.sh.
    is_root() { return 0; }
    # shellcheck disable=SC2317,SC2329
    is_interactive() { [[ -n ${FAKE_TTY-} ]]; }
    SYSROOT=$SB
    ROOT_IDS="$(id -u):$(id -g)"
    INSTALL_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    CHILD_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
    INSTALL_SOURCE_DIR=$REPO_ROOT
    ACME_SH_SHA256=${WQ_ACME_SHA256-}
    NGINX_WAIT_SECONDS=3
    NODE_WAIT_SECONDS=3
    GRPC_CHALLENGE_SECONDS=${GRPC_CHALLENGE_WAIT-3}
    cmd_grpc "$@"
  ) <"$TEST_TMP/.stdin" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

grpc_ok() { run_grpc --domain "$GRPC_DOMAIN" --email "$WQ_EMAIL" --yes "$@"; }

# with_wallet_query: Wallet Query set up by this tool, as the starting point.
with_wallet_query() {
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  [[ $status == 0 ]] || fail "Wallet Query setup failed: $stderr"
  WQ_CONF_BEFORE=$(sha256_of "$SB/etc/nginx/conf.d/taritalk-wallet-query.conf")
  WQ_STATE_BEFORE=$(sha256_of "$SB/var/lib/taritalk-wallet-query/state")
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/* "$TEST_TMP/acme-calls"
}

# client_call METHOD: a gRPC client calling METHOD at the public endpoint
# (through the fakes, as the tool calls it); prints the gRPC status.
client_call() {
  local dir=$TEST_TMP/client
  mkdir -p "$dir"
  rm -f -- "$dir"/*
  printf '\0\0\0\0\0' >"$dir/req"
  mkdir -p "$dir/log"
  FAKE_CURL_LOG_DIR=$dir/log PATH=$TEST_TMP/fakebin:$PATH curl --http2 --resolve "$GRPC_DOMAIN:443:127.0.0.1" \
    -H 'content-type: application/grpc' --data-binary "@$dir/req" --dump-header "$dir/h" \
    --output "$dir/b" --write-out '%{http_version} %{http_code}' \
    -- "https://$GRPC_DOMAIN/tari.rpc.BaseNode/$1" >/dev/null 2>&1 || {
    echo none
    return 0
  }
  sed -n 's/^grpc-status: \([0-9]*\)\r$/\1/p' "$dir/h"
}

# node_config_value KEY: KEY's line in the node configuration.
node_config() { cat -- "$SB/var/lib/tari/mainnet/mainnet/config/config.toml"; }

# assert_node_as_before: the node configuration is back to what install
# wrote (contents, owner, mode), and the node runs without gRPC.
assert_node_as_before() {
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config/config.toml
  [[ $(sha256_of "$cfg") == "$NODE_CONFIG_BEFORE" ]] || fail "node configuration not restored"
  [[ $(stat -c '%a %h' "$cfg") == "600 1" ]] || fail "node configuration mode changed"
  ! grep -q '18142' "$FAKE_SYS/listeners" || fail "gRPC still listens"
  { grep -qx 'node 0.0.0.0:18189' "$FAKE_SYS/listeners" && grep -qx 'node 127.0.0.1:9000' "$FAKE_SYS/listeners"; } ||
    fail "the node does not run as before"
  [[ -e $FAKE_SYS/active.minotari-mainnet.service ]] || fail "the node is not running"
  [[ -z $(find "$SB/var/lib/tari/mainnet/mainnet/config" -name '.taritalk-grpc.*') ]] ||
    fail "temporary node configuration left"
}

# assert_grpc_absent: nothing of the gRPC setup is on the host, and no
# temporary files are left.
assert_grpc_absent() {
  local path
  for path in var/lib/taritalk-grpc opt/taritalk-grpc etc/ssl/taritalk-grpc \
    etc/nginx/conf.d/taritalk-grpc.conf etc/systemd/system/taritalk-grpc-renew.service \
    etc/systemd/system/taritalk-grpc-renew.timer; do
    [[ ! -e $SB/$path && ! -L $SB/$path ]] || fail "left behind: /$path"
  done
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  [[ ! -e $FAKE_SYS/active.taritalk-grpc-renew.timer && ! -e $FAKE_SYS/enabled.taritalk-grpc-renew.timer ]] ||
    fail "renewal timer left active or enabled"
  ! called "GUARD *" || fail "a real system command was reached: $(grep GUARD "$FAKE_SYS/calls")"
}

# assert_grpc_reads_only: the fake system saw only read-only queries and no
# request left the host.
assert_grpc_reads_only() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "dpkg-query -W -f=\${Status} "* | "getent "* | "systemctl show "* | "systemctl is-active "* | "nginx -v") ;;
      *) fail "unexpected system call: $line" ;;
    esac
  done <"$FAKE_SYS/calls"
  [[ -z $(ls -A "$TEST_TMP/curl-log") ]] || fail "network requests were made"
}

# expect_grpc_refusal NAME MESSAGE [ARGS...]: grpc, confirmed, exits 1 with
# MESSAGE before asking and changes nothing (only reads; no request).
expect_grpc_refusal() {
  local name=$1 message=$2 before
  shift 2
  before=$(system_snapshot)
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/*
  grpc_ok "$@"
  [[ $status == 1 ]] || fail "[$name]: expected exit 1, got $status: $stdout"
  [[ $stderr == *"$message"* ]] || fail "[$name]: stderr lacks '$message': $stderr"
  [[ $stdout != *"Set up Base Node gRPC"* ]] || fail "[$name]: asked for confirmation"
  assert_grpc_reads_only
  [[ $(system_snapshot) == "$before" ]] || fail "[$name]: the system changed"
}

# --- command line ---------------------------------------------------------------

test_grpc_help_works_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" grpc --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh grpc [--domain DOMAIN] [--email EMAIL] [--yes]"
  assert_stdout_contains "Not a website, and not the
Wallet Query."
  assert_stdout_contains "127.0.0.1:18142 only"
  assert_stdout_contains "get_version get_sync_info get_sync_progress get_tip_info identify get_network_status get_network_state list_headers"
  assert_stdout_contains "ZeroSSL"
  run_cli --help
  assert_stdout_contains "  grpc        Make the node's read-only Base Node gRPC reachable over HTTPS"
}

test_grpc_usage_errors_exit_2_before_any_check() {
  setup_install
  local -a args
  local bad
  for bad in "--domain" "--domain localhost" "--domain 1.2.3.4" "--email" "--email nobody" "--bogus"; do
    read -r -a args <<<"$bad"
    run_grpc "${args[@]}"
    [[ $status == 2 ]] || fail "[$bad]: expected exit 2, got $status"
  done
  run_grpc --email "$WQ_EMAIL"
  assert_status 2
  assert_stderr_contains "grpc needs --domain DOMAIN when not run interactively"
  run_grpc --domain "$GRPC_DOMAIN"
  assert_status 2
  assert_stderr_contains "grpc needs --email EMAIL when not run interactively"
  assert_no_changes
}

test_grpc_needs_a_node_installed_by_this_tool() {
  setup_install
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/nginx"
  run_grpc --domain "$GRPC_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 1
  assert_stderr_contains "no node installed by taritalk-node-deploy was found"
  assert_no_changes
}

test_grpc_asks_for_a_domain_and_email_and_can_be_cancelled() {
  setup_grpc
  local before
  before=$(system_snapshot)
  : >"$FAKE_SYS/calls"
  FAKE_TTY=1 GRPC_INPUT="not a domain"$'\n' run_grpc
  assert_status 0
  assert_stdout_contains "Base Node gRPC over HTTPS"
  assert_stdout_contains "it is not a website"
  assert_stdout_contains "'not a domain' is not a valid domain name"
  assert_stdout_contains "Cancelled; nothing was changed."
  FAKE_TTY=1 GRPC_INPUT="$GRPC_DOMAIN"$'\n' run_grpc
  assert_status 0
  assert_stdout_contains "Email address for the free ZeroSSL account"
  assert_stdout_contains "Cancelled; nothing was changed."
  FAKE_TTY=1 GRPC_INPUT="$GRPC_DOMAIN"$'\n'"$WQ_EMAIL"$'\n'"n" run_grpc
  assert_status 0
  assert_stdout_contains "Set up Base Node gRPC over HTTPS? [y/N]: "
  assert_stdout_contains "allowed: get_version get_sync_info"
  assert_stdout_contains "Cancelled; nothing was changed."
  assert_grpc_reads_only
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
}

# --- setting it up --------------------------------------------------------------

test_grpc_turns_on_read_only_grpc_and_publishes_it_over_https() {
  setup_grpc
  local original expected_block method
  original=$(node_config)
  echo openssl >>"$FAKE_SYS/pkgs"
  grpc_ok
  assert_status 0
  assert_stdout_contains "Base Node gRPC: $GRPC_DOMAIN:443 (TLS, HTTP/2; service tari.rpc.BaseNode)"
  assert_stdout_contains "Allowed methods: ${GRPC_ALLOWED[*]}"
  assert_stdout_contains "Backend: 127.0.0.1:18142 (loopback only; get_version answered, get_peers refused)"
  assert_stdout_contains "Certificate: O=Fake ZeroSSL, CN=$GRPC_DOMAIN, valid until"
  assert_stdout_contains "Renewal: taritalk-grpc-renew.timer (active)"
  [[ $stderr != *error:* && $stderr != *warning:* ]] || fail "errors or warnings: $stderr"

  # The node configuration: exactly install's, with this block instead of
  # "grpc_enabled = false" (and the header saying so).
  expected_block='# Base Node gRPC, turned on by the grpc command of taritalk-node-deploy:
# loopback only, read-only methods only (Nginx publishes it over HTTPS).
grpc_enabled = true
grpc_address = "/ip4/127.0.0.1/tcp/18142"
grpc_tls_enabled = false
second_layer_grpc_enabled = false
mining_enabled = false
grpc_server_allow_methods = [
    "get_version",
    "get_sync_info",
    "get_sync_progress",
    "get_tip_info",
    "identify",
    "get_network_status",
    "get_network_state",
    "list_headers",
]'
  local expected=${original/$'[base_node]\ngrpc_enabled = false\n'/$'[base_node]\n'"$expected_block"$'\n'}
  expected=${expected/"# not a seed node, miner or public RPC service. gRPC is disabled, the"/"# not a seed node or miner. Base Node gRPC is read-only on loopback, the"}
  [[ $expected != "$original" && $(node_config) == "$expected" ]] ||
    fail "unexpected node configuration: $(diff <(printf '%s\n' "$expected") <(node_config))"
  [[ $(grep -c '^grpc_enabled' <<<"$(node_config)") == 1 ]] || fail "grpc_enabled twice"
  ! grep -q 'grpc_authentication' <<<"$(node_config)" || fail "authentication configured"
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config/config.toml
  [[ $(stat -c '%a %h %u' "$cfg") == "600 1 $(id -u)" ]] || fail "node configuration mode changed"

  # The node restarted once, its gRPC on loopback only; P2P and Wallet
  # Query as before.
  [[ $(grep -c '^systemctl restart minotari-mainnet.service$' "$FAKE_SYS/calls") == 1 ]] ||
    fail "the node was not restarted exactly once"
  [[ $(grep '18142' "$FAKE_SYS/listeners") == "node 127.0.0.1:18142" ]] || fail "gRPC is not loopback only"
  { grep -qx 'node 0.0.0.0:18189' "$FAKE_SYS/listeners" && grep -qx 'node 127.0.0.1:9000' "$FAKE_SYS/listeners"; } ||
    fail "P2P or Wallet Query changed"
  ! grep -q '0.0.0.0:9000' "$FAKE_SYS/listeners" || fail "Wallet Query became public"

  # Nginx: the gRPC host over TLS with HTTP/2, proxying only to the node's
  # loopback gRPC; default servers for other names.
  local conf=$SB/etc/nginx/conf.d/taritalk-grpc.conf
  [[ $(stat -c '%a' "$conf") == 644 ]] || fail "conf mode"
  grep -qxF '    listen 443 ssl http2;' "$conf" || fail "no HTTP/2 on 443"
  grep -qxF '    listen 443 ssl http2 default_server;' "$conf" || fail "no default TLS server"
  grep -qxF '    listen 80 default_server;' "$conf" || fail "no default HTTP server"
  grep -qxF "    server_name $GRPC_DOMAIN;" "$conf" || fail "no server_name"
  { [[ $(grep -c 'grpc_pass' "$conf") == 1 ]] && grep -qxF '        grpc_pass grpc://127.0.0.1:18142;' "$conf"; } ||
    fail "not exactly one grpc_pass to the loopback gRPC"
  ! grep -qE 'proxy_pass|grpcs://|:9000|0\.0\.0\.0' "$conf" || fail "Nginx passes on elsewhere"
  grep -qxF '    location /tari.rpc.BaseNode/ {' "$conf" || fail "not limited to the BaseNode service"
  grep -qxF "    ssl_certificate /etc/ssl/taritalk-grpc/fullchain.pem;" "$conf" || fail "certificate path"
  ! grep -q '@[A-Z_]*@' "$conf" || fail "placeholder left"
  [[ ! -e $SB/etc/nginx/sites-enabled/default ]] || fail "default site still enabled"
  [[ -e $FAKE_SYS/active.nginx.service && -e $FAKE_SYS/enabled.nginx.service ]] || fail "Nginx not running"

  # Through the public endpoint: every allowed method answers, others are
  # refused by the node (PERMISSION_DENIED).
  for method in GetVersion GetSyncInfo GetSyncProgress GetTipInfo Identify GetNetworkStatus GetNetworkState ListHeaders; do
    [[ $(client_call "$method") == 0 ]] || fail "$method is not answered"
  done
  for method in GetPeers GetMempoolTransactions SubmitBlock GetNewBlockTemplate GetBlocks GetActiveValidatorNodes; do
    [[ $(client_call "$method") == 7 ]] || fail "$method is not refused with PERMISSION_DENIED"
  done
  # The tool itself checked both, on loopback and through Nginx over HTTP/2.
  local log calls_text=''
  for log in "$TEST_TMP"/curl-log/[0-9]*; do calls_text+=$(tr '\0' ' ' <"$log")$'\n'; done
  grep -q -- "--http2-prior-knowledge .*-- http://127.0.0.1:18142/tari.rpc.BaseNode/GetPeers" <<<"$calls_text" ||
    fail "no loopback check"
  grep -q -- "--http2 --resolve $GRPC_DOMAIN:443:127.0.0.1 -- https://$GRPC_DOMAIN/tari.rpc.BaseNode/GetVersion" <<<"$calls_text" ||
    fail "no public check"

  # Certificate, renewal and record.
  [[ $(stat -c '%a' "$SB/etc/ssl/taritalk-grpc/privkey.pem") == 600 ]] || fail "key mode"
  grep -qxF 'ExecStart=/opt/taritalk-grpc/acme.sh --cron --home /var/lib/taritalk-grpc/acme --config-home /var/lib/taritalk-grpc/acme' \
    "$SB/etc/systemd/system/taritalk-grpc-renew.service" || fail "renewal unit"
  [[ -e $FAKE_SYS/active.taritalk-grpc-renew.timer && -e $FAKE_SYS/enabled.taritalk-grpc-renew.timer ]] ||
    fail "renewal timer not on"
  grep -q -- "--install-cert -d $GRPC_DOMAIN --ecc .* --reloadcmd systemctl reload nginx.service" "$TEST_TMP/acme-calls" ||
    fail "certificate installed without reloading Nginx"
  local state=$SB/var/lib/taritalk-grpc/state
  [[ $(stat -c '%a' "$state") == 600 ]] || fail "state mode"
  {
    grep -qx "domain=$GRPC_DOMAIN" "$state" && grep -qx 'with_wallet_query=0' "$state" &&
      grep -qx "allowed_methods=$(
        IFS=,
        printf '%s' "${GRPC_ALLOWED[*]}"
      )" "$state" && grep -qx 'packages_installed=nginx' "$state" &&
      grep -qx "node_config_sha256=$(sha256_of "$cfg")" "$state"
  } || fail "state: $(<"$state")"
  ! grep -q '@' "$state" || fail "the email address is in the state record"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left"
  ! called "GUARD *" || fail "a real system command was reached"

  # Once set up, running it again is refused, and changes nothing.
  expect_grpc_refusal again "Base Node gRPC is already set up on this server"
}

test_grpc_uses_http2_on_for_newer_nginx() {
  setup_grpc
  FAKE_NGINX_VERSION=1.26.3 grpc_ok
  assert_status 0
  local conf=$SB/etc/nginx/conf.d/taritalk-grpc.conf
  ! grep -q 'ssl http2' "$conf" || fail "the http2 listen parameter is deprecated in Nginx 1.26"
  [[ $(grep -c '^    http2 on;$' "$conf") == 2 ]] || fail "expected http2 on; in both TLS servers"
  [[ $(client_call GetTipInfo) == 0 ]] || fail "not answered"
}

test_grpc_sits_next_to_the_wallet_query_of_this_tool() {
  setup_grpc
  with_wallet_query
  grpc_ok
  assert_status 0
  assert_stdout_contains "Nginx: /etc/nginx/conf.d/taritalk-grpc.conf (Wallet Query at $WQ_DOMAIN unchanged)"
  [[ $stderr != *error:* && $stderr != *warning:* ]] || fail "errors or warnings: $stderr"
  # Wallet Query untouched, Nginx reloaded (never stopped or reinstalled).
  [[ $(sha256_of "$SB/etc/nginx/conf.d/taritalk-wallet-query.conf") == "$WQ_CONF_BEFORE" &&
  $(sha256_of "$SB/var/lib/taritalk-wallet-query/state") == "$WQ_STATE_BEFORE" ]] ||
    fail "Wallet Query changed"
  ! called "apt-get *" || fail "packages were installed"
  { ! called "systemctl stop nginx.service" && ! called "systemctl restart nginx.service"; } ||
    fail "the Wallet Query's Nginx was stopped"
  called "systemctl reload nginx.service" || fail "Nginx not reloaded"
  local conf=$SB/etc/nginx/conf.d/taritalk-grpc.conf
  ! grep -q 'default_server' "$conf" || fail "a second default server"
  grep -qxF "    server_name $GRPC_DOMAIN;" "$conf" || fail "no own host name"
  "$TEST_TMP/fakebin/nginx" -t -q || fail "nginx -t fails with both"
  # Both endpoints answer; the tool checked Wallet Query too.
  [[ $(client_call GetVersion) == 0 && $(client_call GetPeers) == 7 ]] || fail "gRPC"
  local log calls_text=''
  for log in "$TEST_TMP"/curl-log/[0-9]*; do calls_text+=$(tr '\0' ' ' <"$log")$'\n'; done
  grep -q -- "-- https://$WQ_DOMAIN/get_tip_info" <<<"$calls_text" || fail "Wallet Query not checked"
  { grep -qx 'with_wallet_query=1' "$SB/var/lib/taritalk-grpc/state" &&
    grep -qx 'packages_installed=' "$SB/var/lib/taritalk-grpc/state"; } || fail "state"
  [[ ! -e $SB/var/lib/taritalk-grpc-retry ]] || fail "retry record"
}

test_grpc_node_status_upgrade_and_uninstall_all_still_work_afterwards() {
  setup_grpc
  grpc_ok
  assert_status 0
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config/config.toml sum
  sum=$(sha256_of "$cfg")
  run_ops status
  assert_status 0
  assert_stdout_has_line "Wallet Query: ready (127.0.0.1:9000)"
  # An upgrade keeps the configuration, so the node comes back with gRPC.
  publish_release_fixture 6.0.1
  UPGRADE_INPUT=y run_upgrade
  [[ $status == 0 ]] || fail "upgrade failed: $stderr"
  assert_stdout_has_line "Upgraded: Minotari 6.0.1-pre.2 -> 6.0.1. The node is running."
  [[ $(sha256_of "$cfg") == "$sum" ]] || fail "the upgrade changed the node configuration"
  [[ $(grep '18142' "$FAKE_SYS/listeners") == "node 127.0.0.1:18142" ]] || fail "gRPC not back on loopback"
  [[ $(client_call GetTipInfo) == 0 && $(client_call GetPeers) == 7 ]] || fail "gRPC after the upgrade"
  UNINSTALL_INPUT=y run_uninstall
  assert_status 0
  assert_stdout_contains "Uninstalled: Minotari node, Base Node gRPC"
  # Uninstall all takes gRPC and its Nginx with the node.
  [[ ! -e $SB/var/lib/taritalk-grpc && ! -e $SB/etc/nginx ]] ||
    fail "uninstall left gRPC files"
}

# --- refusals ---------------------------------------------------------------------

test_grpc_refuses_hosts_it_could_disturb() {
  setup_grpc
  local cfg=$SB/var/lib/tari/mainnet/mainnet/config/config.toml
  printf '%s 5.6.7.8\n' "$GRPC_DOMAIN" >"$FAKE_SYS/dns"
  expect_grpc_refusal dns "$GRPC_DOMAIN points to 5.6.7.8, not to this server ($INSTALL_IP)"
  printf '%s %s\n' "$GRPC_DOMAIN" "$INSTALL_IP" >"$FAKE_SYS/dns"

  # A changed node configuration (contents or mode) is not taken over.
  cp -p "$cfg" "$TEST_TMP/config.saved"
  printf '# my change\n' >>"$cfg"
  expect_grpc_refusal config "the node configuration '/var/lib/tari/mainnet/mainnet/config/config.toml' was changed after the installation"
  cp -p "$TEST_TMP/config.saved" "$cfg"
  sed -i 's/^grpc_enabled = false$/grpc_enabled = true/' "$cfg"
  expect_grpc_refusal config-grpc "was changed after the installation"
  cp -p "$TEST_TMP/config.saved" "$cfg"
  chmod 640 "$cfg"
  expect_grpc_refusal config-mode "is not the private file of the node that install wrote"
  chmod 600 "$cfg"

  # Something on the gRPC port, or the node not running.
  printf '  98: 0100007F:46DE 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 998 1\n' \
    >>"$SB/proc/net/tcp"
  expect_grpc_refusal port-18142 "something already listens on the gRPC port 18142"
  sed -i '/ 0100007F:46DE /d' "$SB/proc/net/tcp"
  "$TEST_TMP/fakebin/systemctl" stop minotari-mainnet.service
  expect_grpc_refusal node-down "the node is not running with its local Wallet Query private to this server"
  "$TEST_TMP/fakebin/systemctl" start minotari-mainnet.service

  # Web servers and Nginx that are not this tool's.
  echo nginx >>"$FAKE_SYS/pkgs"
  expect_grpc_refusal nginx "a web server (nginx) is already installed on this server"
  sed -i '/^nginx$/d' "$FAKE_SYS/pkgs"
  echo apache2 >>"$FAKE_SYS/pkgs"
  expect_grpc_refusal apache "a web server (apache2) is already installed on this server"
  sed -i '/^apache2$/d' "$FAKE_SYS/pkgs"
  mkdir -p "$SB/etc/nginx"
  expect_grpc_refusal etc-nginx "conflict: '/etc/nginx' already exists"
  rmdir "$SB/etc/nginx"
  printf '  99: 00000000:01BB 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 999 1\n' \
    >>"$SB/proc/net/tcp"
  expect_grpc_refusal port-443 "TCP port 443 is already in use on this server"
  sed -i '/ 00000000:01BB /d' "$SB/proc/net/tcp"
  # A stray ACME or gRPC state.
  mkdir -p "$SB/opt/taritalk-grpc"
  expect_grpc_refusal opt "conflict: '/opt/taritalk-grpc' already exists"
  rmdir "$SB/opt/taritalk-grpc"
  grpc_ok
  assert_status 0
}

test_grpc_next_to_wallet_query_refuses_a_changed_nginx() {
  setup_grpc
  with_wallet_query
  local wq=$SB/etc/nginx/conf.d/taritalk-wallet-query.conf
  expect_grpc_refusal same-domain "$WQ_DOMAIN is the Wallet Query's domain name; the gRPC endpoint needs a domain name of its own" \
    --domain "$WQ_DOMAIN"
  cp -p "$wq" "$TEST_TMP/wq.saved"
  printf '# edited\n' >>"$wq"
  expect_grpc_refusal wq-conf "the Wallet Query's Nginx configuration was changed after it was set up"
  cp -p "$TEST_TMP/wq.saved" "$wq"
  printf 'server { listen 8080; }\n' >"$SB/etc/nginx/conf.d/other.conf"
  expect_grpc_refusal conf-d "Nginx has configuration that Wallet Query did not write ('/etc/nginx/conf.d/other.conf')"
  rm "$SB/etc/nginx/conf.d/other.conf"
  ln -s /etc/nginx/sites-available/default "$SB/etc/nginx/sites-enabled/default"
  expect_grpc_refusal site "Nginx has configuration that Wallet Query did not write ('/etc/nginx/sites-enabled/default')"
  rm "$SB/etc/nginx/sites-enabled/default"
  echo apache2 >>"$FAKE_SYS/pkgs"
  expect_grpc_refusal apache "a web server (apache2) is installed besides the Wallet Query's Nginx"
  sed -i '/^apache2$/d' "$FAKE_SYS/pkgs"
  "$TEST_TMP/fakebin/systemctl" stop nginx.service
  expect_grpc_refusal nginx-down "the Wallet Query's Nginx is not running on TCP 80 and 443"
  "$TEST_TMP/fakebin/systemctl" start nginx.service
  printf 'format=1\nnginx_fingerprint=%064d\npackages_installed=\n' 0 >"$SB/var/lib/taritalk-wallet-query-retry"
  chmod 600 "$SB/var/lib/taritalk-wallet-query-retry"
  expect_grpc_refusal wq-retry "a failed Wallet Query setup is pending on this server"
  rm "$SB/var/lib/taritalk-wallet-query-retry"
  grpc_ok
  assert_status 0
}

# --- failures roll back -------------------------------------------------------------

# fail_once_hook GLOB: the first fake system call matching GLOB fails;
# later ones (as the rollback's) succeed.
fail_once_hook() {
  cat >"$TEST_TMP/fail-once" <<EOF
#!/usr/bin/env bash
[[ -e '$TEST_TMP/failed-once' ]] && exit 0
touch '$TEST_TMP/failed-once'
exit 1
EOF
  chmod 755 "$TEST_TMP/fail-once"
  rm -f -- "$TEST_TMP/failed-once"
  export FAKE_SYS_HOOK_ON=$1 FAKE_SYS_HOOK=$TEST_TMP/fail-once
}

# grpc_failure_case AT: set up the failure AT for the next run; sets
# MESSAGE (what the run must say) and NODE_TOUCHED (the node configuration
# was replaced before it).
grpc_failure_case() {
  NODE_TOUCHED=0
  case "$1" in
    register | issue | install) write_fake_acme "$1" ;;
    checksum) WQ_ACME_SHA256=$(printf '0%.0s' {1..64}) ;;
    challenge) rm -f -- "$TEST_TMP/web/$GRPC_DOMAIN/.well-known" ;;
    nginx-t) fail_once_hook 'nginx -t -q' ;;
    node-restart) fail_once_hook 'systemctl restart minotari-mainnet.service' ;;
    node-public) export FAKE_NODE_GRPC_LISTEN=0.0.0.0:18142 ;;
    node-allows-all) export FAKE_CURL_FAIL_NAME=GetPeers ;;
    https) fail_once_hook 'systemctl reload nginx.service' ;;
    timer) export FAKE_SYS_FAIL='systemctl start taritalk-grpc-renew.timer' ;;
  esac
  case "$1" in
    register) MESSAGE="ZeroSSL did not accept the account for $WQ_EMAIL" ;;
    issue) MESSAGE="ZeroSSL did not issue a certificate for $GRPC_DOMAIN" ;;
    install) MESSAGE="acme.sh could not install the certificate" ;;
    checksum) MESSAGE="the downloaded acme.sh does not match its pinned SHA-256" ;;
    challenge) MESSAGE="Nginx does not serve the certificate check for $GRPC_DOMAIN on this server" ;;
    nginx-t) MESSAGE="nginx -t rejected the configuration" ;;
    node-restart) MESSAGE="cannot restart minotari-mainnet.service" NODE_TOUCHED=1 ;;
    node-public) MESSAGE="timed out after 3s waiting for the node's gRPC on 127.0.0.1:18142" NODE_TOUCHED=1 ;;
    node-allows-all) MESSAGE="the node's gRPC does not refuse methods outside the read-only list" NODE_TOUCHED=1 ;;
    https) MESSAGE="cannot reload nginx.service" NODE_TOUCHED=1 ;;
    timer) MESSAGE="cannot start taritalk-grpc-renew.timer" NODE_TOUCHED=1 ;;
  esac
}

reset_grpc_sandbox() {
  rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
    "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/acme-calls" "$TEST_TMP/node-trace"
}

test_grpc_failures_roll_back_the_node_and_everything_but_packages() {
  local at
  for at in register issue install checksum challenge nginx-t node-restart node-public node-allows-all https timer; do
    reset_grpc_sandbox
    setup_grpc
    (
      grpc_failure_case "$at"
      grpc_ok
      [[ $status == 1 ]] || fail "[$at]: expected exit 1, got $status"
      assert_stderr_contains "$MESSAGE"
      assert_stderr_contains "gRPC setup failed; undoing the changes made by this run"
      [[ $stderr != *"rollback was incomplete"* ]] || fail "[$at]: incomplete rollback: $stderr"
      assert_grpc_absent
      assert_node_as_before
      local restarts
      restarts=$(grep -c '^systemctl restart minotari-mainnet.service$' "$FAKE_SYS/calls")
      ((NODE_TOUCHED ? restarts == 2 : restarts == 0)) || fail "[$at]: node restarted $restarts times"
      # The Nginx this run installed stays, stopped, with what lets the
      # next run reuse it.
      [[ ! -e $FAKE_SYS/active.nginx.service && ! -e $FAKE_SYS/enabled.nginx.service ]] ||
        fail "[$at]: Nginx left running"
      [[ $(readlink "$SB/etc/nginx/sites-enabled/default") == /etc/nginx/sites-available/default ]] ||
        fail "[$at]: default site not restored"
      [[ $(stat -c '%a %h' "$SB/var/lib/taritalk-grpc-retry" 2>/dev/null) == "600 1" ]] ||
        fail "[$at]: no retry record"
      [[ ! -e $SB/var/lib/taritalk-wallet-query-retry ]] || fail "[$at]: wrote the Wallet Query's record"
    ) || exit 1
  done
}

test_grpc_failures_next_to_wallet_query_leave_it_serving() {
  local at
  for at in issue challenge node-restart node-public https timer; do
    reset_grpc_sandbox
    setup_grpc
    with_wallet_query
    (
      grpc_failure_case "$at"
      grpc_ok
      [[ $status == 1 ]] || fail "[$at]: expected exit 1, got $status"
      assert_stderr_contains "$MESSAGE"
      [[ $stderr != *"rollback was incomplete"* ]] || fail "[$at]: incomplete rollback: $stderr"
      assert_grpc_absent
      assert_node_as_before
      # The Wallet Query's Nginx keeps running, reloaded without the gRPC host.
      [[ -e $FAKE_SYS/active.nginx.service && -e $FAKE_SYS/enabled.nginx.service ]] ||
        fail "[$at]: the Wallet Query's Nginx was stopped"
      grep -qx 'nginx 0.0.0.0:443' "$FAKE_SYS/listeners" || fail "[$at]: Nginx no longer on 443"
      [[ $(tail -n 1 <(grep '^systemctl .*nginx' "$FAKE_SYS/calls")) == "systemctl reload nginx.service" ]] ||
        fail "[$at]: Nginx not reloaded last"
      [[ $(sha256_of "$SB/etc/nginx/conf.d/taritalk-wallet-query.conf") == "$WQ_CONF_BEFORE" ]] ||
        fail "[$at]: Wallet Query configuration changed"
      [[ $(ls "$SB/etc/nginx/conf.d") == taritalk-wallet-query.conf ]] || fail "[$at]: conf.d"
      [[ ! -e $SB/var/lib/taritalk-grpc-retry ]] || fail "[$at]: retry record next to Wallet Query"
    ) || exit 1
    # And it can be run again right away once fixed.
    unset FAKE_NODE_GRPC_LISTEN FAKE_SYS_FAIL FAKE_SYS_HOOK_ON FAKE_CURL_FAIL_NAME
    write_fake_acme
    ln -sfn "$SB/var/lib/taritalk-grpc/webroot/.well-known" "$TEST_TMP/web/$GRPC_DOMAIN/.well-known"
    grpc_ok
    [[ $status == 0 ]] || fail "[$at]: second run failed: $stderr"
  done
}

# challenge_hook N: the first N requests for the certificate check fail
# (as an Nginx whose workers do not serve the new host name yet: curl's
# "Empty reply from server"); "always" fails every one.
challenge_hook() {
  cat >"$TEST_TMP/challenge-hook" <<EOF
#!/usr/bin/env bash
n=\$(cat '$TEST_TMP/challenge-tries' 2>/dev/null || echo 0)
echo \$((n + 1)) >'$TEST_TMP/challenge-tries'
[[ $1 == always ]] && { echo "curl: (52) Empty reply from server" >&2; exit 52; }
((n >= $1)) || { echo "curl: (52) Empty reply from server" >&2; exit 52; }
exit 0
EOF
  chmod 755 "$TEST_TMP/challenge-hook"
  rm -f -- "$TEST_TMP/challenge-tries"
  export FAKE_CURL_HOOK_NAME=taritalk-check FAKE_CURL_HOOK=$TEST_TMP/challenge-hook
}

test_grpc_next_to_wallet_query_waits_for_the_reloaded_nginx_to_serve_the_check() {
  setup_grpc
  with_wallet_query
  # Right after the reload, the new host's check gets no answer twice.
  challenge_hook 2
  grpc_ok
  [[ $status == 0 ]] || fail "expected success after the reload settled: $stderr"
  [[ $(<"$TEST_TMP/challenge-tries") == 3 ]] || fail "check tried $(<"$TEST_TMP/challenge-tries") times, expected 3"
  [[ $stderr != *"gRPC setup failed"* ]] || fail "rolled back"
  [[ $(client_call GetVersion) == 0 && $(client_call GetPeers) == 7 ]] || fail "gRPC not published"
  [[ $(sha256_of "$SB/etc/nginx/conf.d/taritalk-wallet-query.conf") == "$WQ_CONF_BEFORE" ]] ||
    fail "Wallet Query configuration changed"
}

test_grpc_next_to_wallet_query_still_fails_when_the_check_is_never_served() {
  setup_grpc
  with_wallet_query
  challenge_hook always
  local start=$SECONDS
  grpc_ok
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stderr_contains "Nginx does not serve the certificate check for $GRPC_DOMAIN on this server"
  assert_stderr_contains "gRPC setup failed; undoing the changes made by this run"
  [[ $stderr != *"rollback was incomplete"* ]] || fail "incomplete rollback: $stderr"
  # Bounded: a few tries within the wait, then the rollback.
  (($(<"$TEST_TMP/challenge-tries") >= 2 && SECONDS - start < 30)) ||
    fail "tries: $(<"$TEST_TMP/challenge-tries"), $((SECONDS - start))s"
  ! grep -q -- '--register-account' "$TEST_TMP/acme-calls" 2>/dev/null || fail "ZeroSSL was asked"
  assert_grpc_absent
  assert_node_as_before
  { [[ -e $FAKE_SYS/active.nginx.service ]] && grep -qx 'nginx 0.0.0.0:443' "$FAKE_SYS/listeners"; } ||
    fail "the Wallet Query's Nginx stopped"
  [[ $(ls "$SB/etc/nginx/conf.d") == taritalk-wallet-query.conf ]] || fail "conf.d"
}

test_grpc_can_be_run_again_after_a_failure_once_fixed() {
  setup_grpc
  # The node refuses to restart once: the rollback keeps Nginx, stopped.
  fail_once_hook 'systemctl restart minotari-mainnet.service'
  grpc_ok
  assert_status 1
  assert_stderr_contains "note: Nginx is kept, stopped; once the problem is fixed, run the gRPC setup again"
  unset FAKE_SYS_HOOK_ON FAKE_SYS_HOOK
  # A changed Nginx is not taken over; put back, it is.
  local nginx_conf=$SB/etc/nginx/nginx.conf
  cp -p "$nginx_conf" "$TEST_TMP/nginx.saved"
  printf '# edited\n' >>"$nginx_conf"
  expect_grpc_refusal changed "Nginx was changed after the last failed gRPC setup"
  cp -p "$TEST_TMP/nginx.saved" "$nginx_conf"
  touch -d @0 "$nginx_conf"
  grpc_ok
  assert_status 0
  [[ $(grep -c "^apt-get .* install -- .*nginx" "$FAKE_SYS/calls") == 0 ]] || fail "Nginx installed again"
  grep -qx 'packages_installed=nginx,openssl' "$SB/var/lib/taritalk-grpc/state" ||
    fail "state: $(<"$SB/var/lib/taritalk-grpc/state")"
  [[ ! -e $SB/var/lib/taritalk-grpc-retry ]] || fail "retry record left"
}

test_grpc_interrupted_while_the_node_restarts_puts_the_node_back() {
  setup_grpc
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$REPO_ROOT/deploy.sh"
    printf 'load_grpc\nis_root() { return 0; }\nis_interactive() { return 1; }\n'
    printf 'SYSROOT=%q\nROOT_IDS=%q\nINSTALL_SOURCE_DIR=%q\nACME_SH_SHA256=%q\n' "$SB" \
      "$(id -u):$(id -g)" "$REPO_ROOT" "$WQ_ACME_SHA256"
    printf 'INSTALL_PATH=%q\nCHILD_PATH=%q\nNGINX_WAIT_SECONDS=3\nNODE_WAIT_SECONDS=3\n' \
      "$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin" "$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin"
    printf 'cmd_grpc --domain %q --email %q --yes\n' "$GRPC_DOMAIN" "$WQ_EMAIL"
  } >"$TEST_TMP/grpc-harness.sh"
  # The node's restart hangs, once (the rollback's own restart does not).
  cat >"$TEST_TMP/hang-once" <<EOF
#!/usr/bin/env bash
[[ -e '$TEST_TMP/hung-once' ]] && exit 0
touch '$TEST_TMP/hung-once'
echo "\$\$" >'$FAKE_SYS/hang.pid'
exec sleep 300
EOF
  chmod 755 "$TEST_TMP/hang-once"
  FAKE_SYS_HOOK_ON='systemctl restart minotari-mainnet.service' FAKE_SYS_HOOK=$TEST_TMP/hang-once \
    env --default-signal=INT,QUIT bash "$TEST_TMP/grpc-harness.sh" </dev/null >"$TEST_TMP/out" 2>&1 &
  local pid=$!
  wait_for_file "$FAKE_SYS/hang.pid"
  kill -s TERM "$pid"
  wait "$pid"
  status=$?
  stderr=$(<"$TEST_TMP/out")
  [[ $status == 143 ]] || fail "expected 143, got $status: $stderr"
  assert_process_gone "$FAKE_SYS/hang.pid"
  assert_stderr_contains "gRPC setup failed; undoing the changes made by this run"
  [[ $stderr != *"rollback was incomplete"* ]] || fail "incomplete rollback: $stderr"
  assert_grpc_absent
  assert_node_as_before
}

test_grpc_renewal_uses_its_own_acme_home_and_timer() {
  setup_grpc
  with_wallet_query
  grpc_ok
  assert_status 0
  local dir=$SB/etc/systemd/system
  grep -qxF 'ExecStart=/opt/taritalk-grpc/acme.sh --cron --home /var/lib/taritalk-grpc/acme --config-home /var/lib/taritalk-grpc/acme' \
    "$dir/taritalk-grpc-renew.service" || fail "renewal command"
  grep -qxF 'Environment=HOME=/var/lib/taritalk-grpc/acme' "$dir/taritalk-grpc-renew.service" || fail "HOME"
  grep -qx 'Description=Renew the Base Node gRPC TLS certificate (TariTalk Node Tool)' \
    "$dir/taritalk-grpc-renew.service" || fail "description"
  grep -qx 'OnCalendar=daily' "$dir/taritalk-grpc-renew.timer" || fail "timer"
  # Both renewals are on, each with its own acme.sh and home; a renewed
  # certificate reloads the shared Nginx.
  [[ -e $FAKE_SYS/enabled.taritalk-grpc-renew.timer && -e $FAKE_SYS/enabled.taritalk-wallet-query-renew.timer ]] ||
    fail "a renewal timer is off"
  [[ -x $SB/opt/taritalk-grpc/acme.sh && $(sha256_of "$SB/opt/taritalk-grpc/acme.sh") == "$WQ_ACME_SHA256" ]] ||
    fail "acme.sh"
  grep -q -- "--home $SB/var/lib/taritalk-grpc/acme .*--install-cert -d $GRPC_DOMAIN .*--reloadcmd systemctl reload nginx.service" \
    "$TEST_TMP/acme-calls" || fail "acme calls: $(<"$TEST_TMP/acme-calls")"
}

test_grpc_writes_no_secrets() {
  setup_grpc
  grpc_ok
  assert_status 0
  local f
  for f in "$SB/var/lib/taritalk-grpc/state" "$SB/etc/nginx/conf.d/taritalk-grpc.conf" \
    "$SB/var/lib/tari/mainnet/mainnet/config/config.toml" "$SB/etc/systemd/system/taritalk-grpc-renew.service"; do
    ! grep -qiE 'PRIVATE KEY|password|secret|\b(eab|hmac)\b|@example\.com' "$f" || fail "secret-like value in $f"
  done
  ! grep -qi 'PRIVATE KEY' <<<"$stdout$stderr" || fail "a key in the output"
  # The plan names the account to confirm; the summary afterwards does not.
  [[ ${stdout#*Base Node gRPC: } != *"$WQ_EMAIL"* ]] || fail "the email address in the summary"
  # The account and key stay in root-only directories.
  [[ $(stat -c '%a' "$SB/var/lib/taritalk-grpc/acme") == 700 && $(stat -c '%a' "$SB/etc/ssl/taritalk-grpc") == 700 ]] ||
    fail "ACME home or TLS directory not private"
}

# --- the menu -----------------------------------------------------------------------

test_menu_grpc_without_a_node_says_to_install_one() {
  setup_install
  run_menu 6 "" 0
  assert_status 0
  assert_stdout_contains "6. Install Base Node gRPC"
  assert_stdout_contains "Base Node gRPC needs the node: choose 1) Install node first."
  assert_no_changes
}

test_menu_sets_up_grpc_in_plain_language() {
  setup_grpc
  run_menu 6 "$GRPC_DOMAIN" "$WQ_EMAIL" y "" 6 "" 0
  assert_status 0
  assert_stdout_contains "Base Node gRPC setup
  Domain:        $GRPC_DOMAIN (points to this server, $INSTALL_IP)"
  assert_stdout_contains "Base Node gRPC is ready at $GRPC_DOMAIN, port 443 (HTTPS, free ZeroSSL
certificate, renewed automatically). Only read-only calls are allowed"
  assert_stdout_contains "Base Node gRPC is already set up on this server."
  [[ $stdout != *Wallet\ Query\ is\ ready* ]] || fail "described as Wallet Query"
  assert_plain_language
}

test_menu_grpc_failure_says_first_that_the_node_runs_as_before() {
  setup_grpc
  write_fake_acme issue
  run_menu 6 "$GRPC_DOMAIN" "$WQ_EMAIL" y "" 0
  assert_status 0
  local outcome="Base Node gRPC was not set up; the changes made were undone and the node runs as before. Once the problem is fixed, you can choose 6 again."
  assert_stdout_contains "$outcome"
  assert_stdout_contains "Reason: ZeroSSL did not issue a certificate for $GRPC_DOMAIN"
  ((0 < $(line_no "$outcome") && $(line_no "$outcome") < $(line_no "Reason: "))) ||
    fail "the outcome is not said first: $stdout"
  assert_stderr_empty
  assert_plain_language
  assert_grpc_absent
}
