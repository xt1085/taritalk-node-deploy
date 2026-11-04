# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# wallet-query: Wallet Query over HTTPS for a node installed by this tool.
# Never touches the real system: the node is installed into the sandbox
# ($SB) as for upgrade (tests/test_upgrade.sh setup_upgrade), Nginx, systemd
# and DNS are tests/fakes/sys, and the acme.sh that the fake curl serves is
# a stand-in written here (pinned by its own SHA-256 for the test) that
# issues a self-signed certificate with openssl instead of asking ZeroSSL.

readonly WQ_DOMAIN=wallet.example.com
readonly WQ_EMAIL=node@example.com
readonly WQ_ACME_URL_PATH=raw.githubusercontent.com/acmesh-official/acme.sh/3.1.1/acme.sh

# write_fake_acme [FAIL_AT]: the acme.sh the fake curl serves. It records
# its arguments in $TEST_TMP/acme-calls and fails at the subcommand
# FAIL_AT (register, issue or install), if given; with issue-once, only the
# first issue fails (as when DNS or port 80 was fixed in between).
write_fake_acme() {
  local file=$TEST_TMP/web/$WQ_ACME_URL_PATH
  mkdir -p "${file%/*}"
  cat >"$file" <<EOF
#!/usr/bin/env bash
# Stand-in for acme.sh 3.1.1 (tests only).
set -u
printf '%s\n' "\$*" >>'$TEST_TMP/acme-calls'
home='' cfg='' server='' domain='' key='' chain='' webroot='' sub=''
while ((\$# > 0)); do
  case "\$1" in
    --home) home=\$2; shift ;;
    --config-home) cfg=\$2; shift ;;
    --server) server=\$2; shift ;;
    -d) domain=\$2; shift ;;
    --webroot) webroot=\$2; shift ;;
    --key-file) key=\$2; shift ;;
    --fullchain-file) chain=\$2; shift ;;
    -m | --keylength | --reloadcmd) shift ;;
    --register-account) sub=register ;;
    --issue) sub=issue ;;
    --install-cert) sub=install ;;
    --cron) sub=cron ;;
  esac
  shift
done
[[ -d \$home && \$cfg == "\$home" && \$server == zerossl ]] || exit 64
[[ \$sub != '${1-}' ]] || { echo "acme.sh: simulated \$sub failure" >&2; exit 1; }
if [[ \$sub == issue && '${1-}' == issue-once && ! -e '$TEST_TMP/acme-failed-once' ]]; then
  touch '$TEST_TMP/acme-failed-once'
  echo "acme.sh: simulated issue failure" >&2
  exit 1
fi
case "\$sub" in
  register) touch "\$home/account.conf" ;;
  issue)
    [[ -d \$webroot/.well-known/acme-challenge && -n \$domain ]] || exit 65
    mkdir -p "\$home/\${domain}_ecc"
    ;;
  install)
    [[ -d \$home/\${domain}_ecc ]] || exit 66
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \\
      -keyout "\$key" -out "\$chain" -days 90 -subj "/O=Fake ZeroSSL/CN=\$domain" \\
      -addext "subjectAltName=DNS:\$domain" >/dev/null 2>&1 || exit 67
    ;;
esac
EOF
  WQ_ACME_SHA256=$(sha256_of "$file")
}

# setup_wallet_query: a running node (setup_upgrade) whose public IPv4
# address the domain points to, the stand-in acme.sh, and the Wallet Query
# answer that Nginx would pass on over HTTPS.
setup_wallet_query() {
  setup_upgrade
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/nginx"
  mkdir -p "$SB/etc/ssl"
  chmod 755 "$SB/etc/ssl"
  printf '%s %s\n' "$WQ_DOMAIN" "$INSTALL_IP" >"$FAKE_SYS/dns"
  write_fake_acme
  # The challenge URL is served from the webroot, as Nginx's alias does.
  mkdir -p "$TEST_TMP/web/$WQ_DOMAIN"
  ln -s "$SB/var/lib/taritalk-wallet-query/webroot/.well-known" "$TEST_TMP/web/$WQ_DOMAIN/.well-known"
  printf '%s' '{"metadata":{"best_block_height":172497},"is_synced":false}' \
    >"$TEST_TMP/web/$WQ_DOMAIN/get_tip_info"
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/*
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_wallet_query ARGS...: lib/wallet-query.sh's cmd_wallet_query as
# "root" against the sandbox, with $WQ_INPUT on stdin (a "terminal" when
# FAKE_TTY is set). Sets status/stdout/stderr.
run_wallet_query() {
  printf '%s\n' "${WQ_INPUT-}" >"$TEST_TMP/.stdin"
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    # shellcheck source=lib/install.sh
    source "$REPO_ROOT/lib/install.sh"
    # shellcheck source=lib/status.sh
    source "$REPO_ROOT/lib/status.sh"
    # shellcheck source=lib/wallet-query.sh
    source "$REPO_ROOT/lib/wallet-query.sh"
    # shellcheck disable=SC2317,SC2329 # Called by lib/wallet-query.sh.
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
    cmd_wallet_query "$@"
  ) <"$TEST_TMP/.stdin" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# node_snapshot: everything of the node: its files and its services.
node_snapshot() {
  (cd "$SB" && find ./opt/tari ./var/lib/tari ./var/log/tari ./etc/tor ./etc/systemd/system/minotari-mainnet.service \
    -printf '%p %y %m %u %i %s %T@\n' | sort)
  local f
  for f in passwd group "$FAKE_SYS"/active.minotari* "$FAKE_SYS"/enabled.minotari* "$FAKE_SYS"/active.tor* "$FAKE_SYS"/enabled.tor*; do
    printf '== %s\n' "${f##*/}"
    cat -- "$FAKE_SYS/${f##*/}" 2>/dev/null
  done
  grep -E '^(node|tor) ' "$FAKE_SYS/listeners"
}

# assert_wallet_query_absent: nothing of Wallet Query is on the host, Nginx
# (if its package is there) is stopped and disabled with its default site
# back, and no temporary files are left.
assert_wallet_query_absent() {
  local path
  for path in var/lib/taritalk-wallet-query opt/taritalk-wallet-query etc/ssl/taritalk-wallet-query \
    etc/nginx/conf.d/taritalk-wallet-query.conf etc/systemd/system/taritalk-wallet-query-renew.service \
    etc/systemd/system/taritalk-wallet-query-renew.timer; do
    [[ ! -e $SB/$path && ! -L $SB/$path ]] || fail "left behind: /$path"
  done
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  [[ -z $(ls -A "$SB/etc/nginx/conf.d" 2>/dev/null) ]] || fail "Nginx configuration left"
  if [[ -d $SB/etc/nginx ]]; then
    [[ $(readlink "$SB/etc/nginx/sites-enabled/default") == /etc/nginx/sites-available/default ]] ||
      fail "Nginx's default site was not restored"
    # What lets the next run reuse this Nginx.
    [[ $(stat -c '%a %h' "$SB/var/lib/taritalk-wallet-query-retry" 2>/dev/null) == "600 1" ]] ||
      fail "no private retry record for the kept Nginx"
  fi
  [[ ! -e $FAKE_SYS/active.nginx.service && ! -e $FAKE_SYS/enabled.nginx.service ]] ||
    fail "Nginx left running or enabled"
  [[ ! -e $FAKE_SYS/active.taritalk-wallet-query-renew.timer && ! -e $FAKE_SYS/enabled.taritalk-wallet-query-renew.timer ]] ||
    fail "renewal timer left active or enabled"
  ! grep -q '^nginx ' "$FAKE_SYS/listeners" || fail "Nginx still listens"
  ! called "GUARD *" || fail "a real system command was reached: $(grep GUARD "$FAKE_SYS/calls")"
}

# expect_wq_refusal NAME MESSAGE [ARGS...]: wallet-query, confirmed, exits 1
# with MESSAGE before asking and changes nothing (only reads; no request).
expect_wq_refusal() {
  local name=$1 message=$2 before
  shift 2
  before=$(system_snapshot)
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/*
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes "$@"
  [[ $status == 1 ]] || fail "[$name]: expected exit 1, got $status"
  assert_stderr_contains "$message"
  [[ $stdout != *"Set up Wallet Query"* ]] || fail "[$name]: asked for confirmation"
  assert_only_reads
  [[ $(system_snapshot) == "$before" ]] || fail "[$name]: the system changed"
}

# --- command line ---------------------------------------------------------------

test_wallet_query_help_works_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" wallet-query --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh wallet-query [--domain DOMAIN] [--email EMAIL] [--yes]"
  assert_stdout_contains "ZeroSSL"
  assert_stdout_contains "127.0.0.1:9000 only"
  assert_stdout_contains "nodes.taritalk.xyz"
  run_cli --help
  assert_stdout_contains "wallet-query"
}

test_wallet_query_usage_errors_exit_2_before_any_check() {
  setup_install
  local -a args
  local bad
  for bad in "--domain" "--domain localhost" "--domain 1.2.3.4" "--domain -x.example.com" \
    "--domain a..example.com" "--domain wallet_query.example.com" "--domain wallet.example.c0m" \
    "--email" "--email nobody" "--email a@b@example.com" "--email user@localhost" "--bogus"; do
    read -r -a args <<<"$bad"
    run_wallet_query "${args[@]}"
    [[ $status == 2 ]] || fail "[$bad]: expected exit 2, got $status"
  done
  # Not in a terminal, both values are required.
  run_wallet_query --email "$WQ_EMAIL"
  assert_status 2
  assert_stderr_contains "wallet-query needs --domain DOMAIN when not run interactively"
  run_wallet_query --domain "$WQ_DOMAIN"
  assert_status 2
  assert_stderr_contains "wallet-query needs --email EMAIL when not run interactively"
  assert_no_changes
}

test_wallet_query_accepts_domains_as_people_type_them() {
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/wallet-query.sh
    source "$REPO_ROOT/lib/wallet-query.sh"
    [[ $(normalize_domain "  Wallet.Example.COM.  ") == wallet.example.com ]] || fail "not normalized"
    check_domain wallet-query-01.nodes.taritalk.xyz || fail "a community subdomain was refused"
    check_domain xn--80ak6aa92e.xn--p1ai || fail "an IDN domain was refused"
    check_domain "$(printf 'a%.0s' {1..64}).example.com" && fail "a 64-character label was accepted"
    check_email First.Last+tari@Example.org || fail "a plain address was refused"
    exit 0
  ) || exit 1
}

# --- refusals ---------------------------------------------------------------------

test_wallet_query_needs_a_node_installed_by_this_tool() {
  setup_install
  ln -sf "$TESTS_DIR/fakes/sys" "$TEST_TMP/fakebin/nginx"
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 1
  assert_stderr_contains "no node installed by taritalk-node-deploy was found"
  assert_no_changes
}

test_wallet_query_refuses_hosts_it_could_disturb() {
  setup_wallet_query
  printf '%s 5.6.7.8\n' "$WQ_DOMAIN" >"$FAKE_SYS/dns"
  expect_wq_refusal dns-elsewhere "$WQ_DOMAIN points to 5.6.7.8, not to this server ($INSTALL_IP)"
  printf '%s 5.6.7.8\n%s %s\n' "$WQ_DOMAIN" "$WQ_DOMAIN" "$INSTALL_IP" >"$FAKE_SYS/dns"
  expect_wq_refusal dns-two "points to $INSTALL_IP 5.6.7.8, not to this server"
  : >"$FAKE_SYS/dns"
  expect_wq_refusal dns-none "$WQ_DOMAIN does not point to this server yet (no DNS A record found)"
  printf '%s %s\n' "$WQ_DOMAIN" "$INSTALL_IP" >"$FAKE_SYS/dns"

  echo nginx-common >>"$FAKE_SYS/pkgs"
  expect_wq_refusal nginx "a web server (nginx-common) is already installed on this server"
  sed -i '/^nginx-common$/d' "$FAKE_SYS/pkgs"
  echo apache2 >>"$FAKE_SYS/pkgs"
  expect_wq_refusal apache "a web server (apache2) is already installed on this server"
  sed -i '/^apache2$/d' "$FAKE_SYS/pkgs"

  # Something already listens on 0.0.0.0:443.
  cp "$SB/proc/net/tcp" "$TEST_TMP/tcp.saved"
  printf '  99: 00000000:01BB 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 999 1\n' \
    >>"$SB/proc/net/tcp"
  expect_wq_refusal port-443 "TCP port 443 is already in use on this server"
  cp "$TEST_TMP/tcp.saved" "$SB/proc/net/tcp"

  mkdir -p "$SB/etc/nginx"
  expect_wq_refusal etc-nginx "conflict: '/etc/nginx' already exists"
  rmdir "$SB/etc/nginx"

  # The node's Wallet Query must be up, on loopback only.
  "$TEST_TMP/fakebin/systemctl" stop minotari-mainnet.service
  expect_wq_refusal node-down "the node's local Wallet Query is not running, or not private to this server"
}

# --- setting it up --------------------------------------------------------------------

test_wallet_query_sets_up_https_in_front_of_the_loopback_wallet_query() {
  setup_wallet_query
  local node_before
  node_before=$(node_snapshot)
  echo openssl >>"$FAKE_SYS/pkgs"
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 0
  assert_stdout_contains "Wallet Query: https://$WQ_DOMAIN (CORS: any origin)"
  assert_stdout_contains "Backend: 127.0.0.1:9000 (loopback only; answered at block 172497)"
  assert_stdout_contains "Certificate: O=Fake ZeroSSL, CN=$WQ_DOMAIN, valid until"
  assert_stdout_contains "Renewal: taritalk-wallet-query-renew.timer (active)"
  [[ $stderr != *error:* && $stderr != *warning:* ]] || fail "errors or warnings: $stderr"

  # Only the missing package; Nginx runs on 80 and 443, enabled; renewal on.
  called "apt-get -q -y --no-install-recommends * install -- nginx" || fail "nginx was not installed"
  grep -qx nginx "$FAKE_SYS/pkgs" || fail "nginx missing"
  [[ -e $FAKE_SYS/active.nginx.service && -e $FAKE_SYS/enabled.nginx.service ]] || fail "Nginx not running and enabled"
  grep -qx 'nginx 0.0.0.0:443' "$FAKE_SYS/listeners" || fail "Nginx does not listen on 443"
  [[ -e $FAKE_SYS/active.taritalk-wallet-query-renew.timer && -e $FAKE_SYS/enabled.taritalk-wallet-query-renew.timer ]] ||
    fail "renewal timer not active and enabled"
  # The node is untouched, and its Wallet Query still loopback only.
  [[ $(node_snapshot) == "$node_before" ]] || fail "the node changed"
  [[ $(grep ':9000$' "$FAKE_SYS/listeners") == "node 127.0.0.1:9000" ]] || fail "9000 is not loopback only"

  # Nginx: the package's default site out, the Wallet Query site in, as the
  # public TariTalk nodes have it (Nginx 1.22: the http2 listen parameter).
  [[ ! -e $SB/etc/nginx/sites-enabled/default && ! -L $SB/etc/nginx/sites-enabled/default ]] ||
    fail "the default site is still enabled"
  local conf=$SB/etc/nginx/conf.d/taritalk-wallet-query.conf line
  [[ $(stat -c '%a %h' "$conf") == "644 1" ]] || fail "unexpected mode of the Nginx configuration"
  for line in "    server_name $WQ_DOMAIN;" "    listen 443 ssl http2;" "    listen 443 ssl http2 default_server;" \
    "    ssl_certificate /etc/ssl/taritalk-wallet-query/fullchain.pem;" \
    "    ssl_certificate_key /etc/ssl/taritalk-wallet-query/privkey.pem;" \
    "    if (\$host != $WQ_DOMAIN) { return 444; }" \
    "    location / { return 308 https://$WQ_DOMAIN\$request_uri; }" \
    "        alias /var/lib/taritalk-wallet-query/webroot/.well-known/acme-challenge/;" \
    "        proxy_pass http://127.0.0.1:9000\$uri\$is_args\$args;" \
    "        proxy_pass http://127.0.0.1:9000/json_rpc;" \
    '        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;'; do
    grep -qxF -- "$line" "$conf" || fail "Nginx configuration lacks: $line"
  done
  ! grep -q 'http2 on;' "$conf" || fail "http2 on; is not for Nginx 1.22"
  # Certificate: private key for root only, where Nginx expects it.
  [[ $(stat -c '%a' "$SB/etc/ssl/taritalk-wallet-query") == 700 &&
  $(stat -c '%a' "$SB/etc/ssl/taritalk-wallet-query/privkey.pem") == 600 &&
  $(stat -c '%a' "$SB/etc/ssl/taritalk-wallet-query/fullchain.pem") == 644 ]] ||
    fail "unexpected modes of the certificate files"
  [[ $(stat -c '%a' "$SB/var/lib/taritalk-wallet-query/acme") == 700 ]] || fail "the acme.sh home is not private"
  # The pinned acme.sh, used with ZeroSSL, in this order.
  [[ $(sha256_of "$SB/opt/taritalk-wallet-query/acme.sh") == "$WQ_ACME_SHA256" ]] || fail "acme.sh is not the pinned one"
  local -a acme
  mapfile -t acme <"$TEST_TMP/acme-calls"
  ((${#acme[@]} == 3)) || fail "unexpected acme.sh calls: ${acme[*]}"
  [[ ${acme[0]} == *"--server zerossl --no-color --register-account -m $WQ_EMAIL" ]] || fail "register: ${acme[0]}"
  [[ ${acme[1]} == *"--server zerossl --no-color --issue -d $WQ_DOMAIN --webroot $SB/var/lib/taritalk-wallet-query/webroot --keylength ec-256" ]] ||
    fail "issue: ${acme[1]}"
  [[ ${acme[2]} == *"--install-cert -d $WQ_DOMAIN --ecc "*"--reloadcmd systemctl reload nginx.service" ]] || fail "install-cert: ${acme[2]}"
  # The renewal unit runs the installed acme.sh with its home.
  grep -qxF 'ExecStart=/opt/taritalk-wallet-query/acme.sh --cron --home /var/lib/taritalk-wallet-query/acme --config-home /var/lib/taritalk-wallet-query/acme' \
    "$SB/etc/systemd/system/taritalk-wallet-query-renew.service" || fail "renewal unit"
  grep -qxF 'OnCalendar=daily' "$SB/etc/systemd/system/taritalk-wallet-query-renew.timer" || fail "renewal timer"
  # Requests: acme.sh from GitHub, the local challenge check, the HTTPS check.
  curl_requested "https://$WQ_ACME_URL_PATH" || fail "acme.sh was not downloaded"
  curl_requested "http://$WQ_DOMAIN/.well-known/acme-challenge/taritalk-check" || fail "no challenge check"
  curl_requested "https://$WQ_DOMAIN/get_tip_info" || fail "no HTTPS check"
  [[ ! -e $SB/var/lib/taritalk-wallet-query/webroot/.well-known/acme-challenge/taritalk-check ]] ||
    fail "the challenge check file was left"
  # The record, private to root; no temporary files.
  [[ $(stat -c '%a' "$SB/var/lib/taritalk-wallet-query/state") == 600 ]] || fail "state not private"
  grep -qx "domain=$WQ_DOMAIN" "$SB/var/lib/taritalk-wallet-query/state" || fail "state lacks the domain"
  grep -qx "packages_installed=nginx" "$SB/var/lib/taritalk-wallet-query/state" || fail "state lacks the packages"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  ! called "GUARD *" || fail "a real system command was reached"

  # Once set up, again is refused, without any change.
  expect_wq_refusal again "Wallet Query is already set up on this server"
}

test_wallet_query_uses_http2_on_for_newer_nginx() {
  setup_wallet_query
  FAKE_NGINX_VERSION=1.26.3 run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 0
  local conf=$SB/etc/nginx/conf.d/taritalk-wallet-query.conf
  ! grep -q 'ssl http2' "$conf" || fail "the http2 listen parameter is deprecated in Nginx 1.26"
  [[ $(grep -c '^    http2 on;$' "$conf") == 2 ]] || fail "expected http2 on; in both TLS servers"
  grep -qxF '    listen 443 ssl;' "$conf" || fail "no plain listen 443 ssl"
}

test_wallet_query_node_status_and_uninstall_all_still_work_afterwards() {
  setup_wallet_query
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 0
  (
    run_cli_status() {
      (
        # shellcheck source=deploy.sh
        source "$REPO_ROOT/deploy.sh"
        load_status
        # shellcheck disable=SC2317,SC2329
        is_root() { return 0; }
        SYSROOT=$SB
        ROOT_IDS="$(id -u):$(id -g)"
        OPS_PATH=$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin
        CHILD_PATH=$OPS_PATH
        cmd_status
      ) >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
      status=$?
      stdout=$(<"$TEST_TMP/.stdout")
      stderr=$(<"$TEST_TMP/.stderr")
    }
    run_cli_status
    assert_status 0
    assert_stdout_has_line "Wallet Query: ready (127.0.0.1:9000)"
  ) || exit 1
  UNINSTALL_INPUT=y run_uninstall
  assert_status 0
  assert_stdout_contains "Uninstalled: Minotari node, Wallet Query"
  # Uninstall all takes Wallet Query and its Nginx with the node.
  [[ ! -e $SB/var/lib/taritalk-wallet-query && ! -e $SB/etc/nginx ]] ||
    fail "uninstall left Wallet Query files"
}

# --- failures roll back ------------------------------------------------------------

test_wallet_query_failures_roll_back_everything_but_packages() {
  local at message
  for at in register issue install checksum challenge https nginx-t; do
    rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/acme-calls" "$TEST_TMP/node-trace"
    setup_wallet_query
    local node_before
    node_before=$(node_snapshot)
    (
      case "$at" in
        register | issue | install) write_fake_acme "$at" ;;
        checksum) WQ_ACME_SHA256=$(printf '0%.0s' {1..64}) ;;
        challenge) rm -f -- "$TEST_TMP/web/$WQ_DOMAIN/.well-known" ;;
        https) rm -f -- "$TEST_TMP/web/$WQ_DOMAIN/get_tip_info" ;;
        nginx-t) export FAKE_SYS_FAIL='nginx -t -q' ;;
      esac
      case "$at" in
        register) message="ZeroSSL did not accept the account for $WQ_EMAIL" ;;
        issue) message="ZeroSSL did not issue a certificate for $WQ_DOMAIN; check that it points to this server and that inbound TCP port 80 is open" ;;
        install) message="acme.sh could not install the certificate" ;;
        checksum) message="the downloaded acme.sh does not match its pinned SHA-256" ;;
        challenge) message="Nginx does not serve the certificate check for $WQ_DOMAIN on this server" ;;
        https) message="Wallet Query does not answer at https://$WQ_DOMAIN on this server" ;;
        nginx-t) message="nginx -t rejected the configuration" ;;
      esac
      run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
      [[ $status == 1 ]] || fail "[$at]: expected exit 1, got $status"
      assert_stderr_contains "$message"
      assert_stderr_contains "Wallet Query setup failed; undoing the changes made by this run"
      assert_stderr_contains "note: APT packages installed by this run are kept"
      [[ $stderr != *"rollback was incomplete"* ]] || fail "[$at]: incomplete rollback: $stderr"
      assert_wallet_query_absent
      [[ $(node_snapshot) == "$node_before" ]] || fail "[$at]: the node changed"
    ) || exit 1
  done
}

# --- trying again after a failure ---------------------------------------------------

# apt_installs PACKAGE: how often apt-get installed PACKAGE.
apt_installs() {
  grep -c "^apt-get .* install -- .*\b$1\b" "$FAKE_SYS/calls"
}

test_wallet_query_can_be_run_again_after_a_failure_once_fixed() {
  setup_wallet_query
  local node_before
  node_before=$(node_snapshot)
  # ZeroSSL cannot reach the server yet: the rollback keeps Nginx, stopped.
  write_fake_acme issue
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 1
  assert_stderr_contains "ZeroSSL did not issue a certificate for $WQ_DOMAIN"
  assert_stderr_contains "note: Nginx is kept, stopped; once the problem is fixed, run the Wallet Query setup again: it reuses this Nginx"
  assert_wallet_query_absent
  grep -qx 'packages_installed=nginx,openssl' "$SB/var/lib/taritalk-wallet-query-retry" || fail "retry record lacks the packages"
  # Still not fixed: a second failure, reusing that Nginx, rolls back the same way.
  write_fake_acme register
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 1
  assert_stderr_contains "ZeroSSL did not accept the account for $WQ_EMAIL"
  [[ $stderr != *"rollback was incomplete"* ]] || fail "incomplete rollback: $stderr"
  assert_wallet_query_absent
  grep -qx 'packages_installed=nginx,openssl' "$SB/var/lib/taritalk-wallet-query-retry" || fail "retry record lost the packages"
  # Fixed: the same command now sets it up, without installing Nginx again.
  write_fake_acme
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 0
  assert_stdout_contains "Wallet Query: https://$WQ_DOMAIN (CORS: any origin)"
  [[ $stderr != *error:* && $stderr != *warning:* ]] || fail "errors or warnings: $stderr"
  [[ $(apt_installs nginx) == 1 ]] || fail "nginx was installed more than once"
  [[ -e $FAKE_SYS/active.nginx.service && -e $FAKE_SYS/enabled.nginx.service ]] || fail "Nginx not running and enabled"
  grep -qx 'nginx 0.0.0.0:443' "$FAKE_SYS/listeners" || fail "Nginx does not listen on 443"
  [[ ! -e $SB/etc/nginx/sites-enabled/default && ! -L $SB/etc/nginx/sites-enabled/default ]] ||
    fail "the default site is still enabled"
  grep -qx 'packages_installed=nginx,openssl' "$SB/var/lib/taritalk-wallet-query/state" ||
    fail "the record does not name the packages the first run installed"
  [[ ! -e $SB/var/lib/taritalk-wallet-query-retry ]] || fail "the retry record was left"
  [[ $(node_snapshot) == "$node_before" ]] || fail "the node changed"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  expect_wq_refusal again "Wallet Query is already set up on this server"
}

test_wallet_query_does_not_take_over_an_nginx_changed_after_a_failure() {
  setup_wallet_query
  write_fake_acme issue
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 1
  local record=$SB/var/lib/taritalk-wallet-query-retry
  [[ -f $record ]] || fail "no retry record"
  write_fake_acme
  local changed="Nginx was changed after the last failed Wallet Query setup, so this tool does not take it over"
  # Someone else's site, a changed file, a changed mode: refused.
  printf 'server { listen 8080; }\n' >"$SB/etc/nginx/conf.d/other.conf"
  expect_wq_refusal other-site "$changed"
  rm -- "$SB/etc/nginx/conf.d/other.conf"
  printf '# edited\n' >>"$SB/etc/nginx/nginx.conf"
  expect_wq_refusal edited "$changed"
  sed -i '$d' "$SB/etc/nginx/nginx.conf"
  chmod 600 "$SB/etc/nginx/sites-available/default"
  expect_wq_refusal mode "$changed"
  chmod 644 "$SB/etc/nginx/sites-available/default"
  rm -- "$SB/etc/nginx/sites-enabled/default"
  expect_wq_refusal default-site "$changed"
  ln -s /etc/nginx/sites-available/default "$SB/etc/nginx/sites-enabled/default"
  # Nginx started by someone else (running, or just its service active).
  "$TEST_TMP/fakebin/systemctl" start nginx.service
  expect_wq_refusal started "Nginx was started after the last failed Wallet Query setup"
  "$TEST_TMP/fakebin/systemctl" stop nginx.service
  touch "$FAKE_SYS/active.nginx.service"
  expect_wq_refusal active "Nginx was started after the last failed Wallet Query setup"
  rm -f -- "$FAKE_SYS/active.nginx.service"
  # Something else on port 443 meanwhile.
  cp "$SB/proc/net/tcp" "$TEST_TMP/tcp.saved"
  printf '  99: 00000000:01BB 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 999 1\n' \
    >>"$SB/proc/net/tcp"
  expect_wq_refusal port-443 "TCP port 443 is already in use on this server"
  cp "$TEST_TMP/tcp.saved" "$SB/proc/net/tcp"
  # Another web server beside it, or a record that is not the tool's.
  echo apache2 >>"$FAKE_SYS/pkgs"
  expect_wq_refusal apache "a web server (apache2) is already installed on this server"
  sed -i '/^apache2$/d' "$FAKE_SYS/pkgs"
  chmod 644 "$record"
  expect_wq_refusal record-mode "is not a private file of root"
  chmod 600 "$record"
  cp "$record" "$TEST_TMP/record.saved"
  printf 'command=rm -rf /\n' >>"$record"
  expect_wq_refusal record-content "is not a record of taritalk-node-deploy"
  cp "$TEST_TMP/record.saved" "$record"
  # Put back exactly as the tool left it: the setup goes ahead.
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  assert_status 0
  [[ ! -e $record ]] || fail "the retry record was left"
}

# --- the menu -----------------------------------------------------------------------

test_menu_wallet_query_without_a_node_says_to_install_one() {
  setup_install
  run_menu 5 "" 0
  assert_status 0
  assert_stdout_contains "5. Install Wallet Query"
  assert_stdout_contains "No node installed by this tool was found on this server."
  assert_stdout_contains "Wallet Query needs the node: choose 1) Install node first."
  assert_no_changes
}

test_menu_wallet_query_asks_for_a_domain_and_can_be_cancelled() {
  setup_wallet_query
  local before
  before=$(system_snapshot)
  # Cancel at the domain (after one invalid try), at the email, and at
  # the confirmation: nothing is changed and nothing requested.
  run_menu 5 "not a domain" "" "" 5 "$WQ_DOMAIN" "" "" 5 "$WQ_DOMAIN" "$WQ_EMAIL" n "" 0
  assert_status 0
  assert_stdout_contains "It needs a domain name whose DNS A record points to this
  server ($INSTALL_IP)."
  assert_stdout_contains "No domain name? You can ask TariTalk for a free community subdomain (see
  nodes.taritalk.xyz)."
  assert_stdout_contains "Domain name (press Enter without typing anything to cancel): "
  assert_stdout_contains "'not a domain' is not a valid domain name (expected something like wallet.example.com)."
  assert_stdout_contains "Email address for the free ZeroSSL account"
  assert_stdout_contains "Domain:        $WQ_DOMAIN (points to this server, $INSTALL_IP)"
  assert_stdout_contains "inbound TCP ports 80 and 443 must be open"
  assert_stdout_contains "Set up Wallet Query over HTTPS? [y/N]: "
  [[ $(menu_count "Cancelled; nothing was changed.") == 3 ]] || fail "not cancelled three times"
  assert_stderr_empty
  assert_plain_language
  assert_only_reads
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
}

test_menu_sets_up_wallet_query_in_plain_language() {
  setup_wallet_query
  run_menu 5 "$WQ_DOMAIN" "$WQ_EMAIL" y "" 5 "" 0
  assert_status 0
  assert_stdout_contains "Wallet Query is ready at $WQ_DOMAIN over HTTPS (free ZeroSSL certificate,
renewed automatically). Your node answered through it at block 172497."
  assert_stdout_contains "Wallet Query is already set up on this server."
  assert_stdout_contains "Node: Minotari 6.0.1-pre.2, running"
  assert_plain_language
  [[ -e $FAKE_SYS/active.nginx.service ]] || fail "not set up"
}

test_menu_wallet_query_can_be_chosen_again_after_a_failure() {
  setup_wallet_query
  write_fake_acme issue-once
  run_menu 5 "$WQ_DOMAIN" "$WQ_EMAIL" y "" 5 "$WQ_DOMAIN" "$WQ_EMAIL" y "" 0
  assert_status 0
  assert_stdout_contains "Wallet Query was not set up; the changes made were undone. The node was not changed. Once the problem is fixed, you can choose 5 again."
  assert_stdout_contains "Wallet Query is ready at $WQ_DOMAIN over HTTPS"
  [[ $stdout != *"a web server (nginx) is already installed"* ]] || fail "the second try was refused"
  assert_stderr_empty
  assert_plain_language
  [[ -e $FAKE_SYS/active.nginx.service && ! -e $SB/var/lib/taritalk-wallet-query-retry ]] || fail "not set up"
}

test_menu_wallet_query_failure_says_first_that_nothing_stayed() {
  setup_wallet_query
  write_fake_acme issue
  run_menu 5 "$WQ_DOMAIN" "$WQ_EMAIL" y "" 0
  assert_status 0
  local outcome="Wallet Query was not set up; the changes made were undone. The node was not changed. Once the problem is fixed, you can choose 5 again."
  local reason="Reason: ZeroSSL did not issue a certificate for $WQ_DOMAIN; check that it points to this server and that inbound TCP port 80 is open, then try again."
  assert_stdout_contains "$outcome"
  assert_stdout_contains "$reason"
  ((0 < $(line_no "$outcome") && $(line_no "$outcome") < $(line_no "$reason"))) ||
    fail "the outcome is not said first: $stdout"
  [[ $stdout != *"Wallet Query is ready"* ]] || fail "claimed success"
  assert_stderr_empty
  assert_plain_language
  assert_wallet_query_absent
}
