# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# status/stdout/stderr are set by the run_* helpers of the other test files.
# shellcheck disable=SC2154
# Uninstall all: lib/uninstall.sh removes the node together with the Wallet
# Query and Base Node gRPC this tool set up, and the Nginx it installed for
# them, so that everything can be set up again afterwards. Built on the
# sandboxes of tests/test_uninstall.sh, test_wallet_query.sh and
# test_grpc.sh: the real commands set the components up against
# tests/fakes/sys, and the real uninstall removes them.

# setup_all_components: a node with Wallet Query and Base Node gRPC set up
# by this tool (the real commands against the sandbox). The fake system's
# call log starts empty.
setup_all_components() {
  setup_grpc
  with_wallet_query
  grpc_ok
  [[ $status == 0 ]] || fail "setting up gRPC failed: $stderr"
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/* "$TEST_TMP/acme-calls"
}

# setup_node_and_wallet_query: a node with only Wallet Query set up.
setup_node_and_wallet_query() {
  setup_grpc
  with_wallet_query
}

# reinstall_node: install the node again on the uninstalled sandbox, as the
# user would after Uninstall all.
reinstall_node() {
  run_install --public-ip "$INSTALL_IP" --arch aarch64 --yes
  [[ $status == 0 ]] || fail "installing the node again failed: $stderr"
  : >"$FAKE_SYS/calls"
}

# assert_everything_absent: nothing of the node, Wallet Query, gRPC or the
# tool's Nginx is left: no file, package, account, unit or listener.
assert_everything_absent() {
  local path
  for path in /etc/systemd/system/minotari-mainnet.service /opt/tari /var/lib/tari /var/log/tari \
    /etc/tor /var/lib/tor /var/log/tor /run/tor \
    /var/lib/taritalk-wallet-query /opt/taritalk-wallet-query /etc/ssl/taritalk-wallet-query \
    /etc/nginx/conf.d/taritalk-wallet-query.conf /etc/systemd/system/taritalk-wallet-query-renew.service \
    /etc/systemd/system/taritalk-wallet-query-renew.timer /var/lib/taritalk-wallet-query-retry \
    /var/lib/taritalk-grpc /opt/taritalk-grpc /etc/ssl/taritalk-grpc /etc/nginx/conf.d/taritalk-grpc.conf \
    /etc/systemd/system/taritalk-grpc-renew.service /etc/systemd/system/taritalk-grpc-renew.timer \
    /var/lib/taritalk-grpc-retry /etc/nginx /var/log/nginx /var/lib/nginx; do
    [[ ! -e $SB$path && ! -L $SB$path ]] || fail "$path is left"
  done
  ! grep -q '^tari:' "$FAKE_SYS/passwd" || fail "user tari left"
  ! grep -q '^tari:' "$FAKE_SYS/group" || fail "group tari left"
  ! grep -qxE 'tor|nginx|nginx-common' "$FAKE_SYS/pkgs" || fail "packages left: $(<"$FAKE_SYS/pkgs")"
  [[ -z $(<"$FAKE_SYS/loaded") ]] || fail "units still loaded: $(<"$FAKE_SYS/loaded")"
  for path in "$FAKE_SYS"/active.* "$FAKE_SYS"/enabled.*; do
    [[ ! -e $path ]] || fail "a unit is left active or enabled: ${path##*/}"
  done
  [[ -z $(<"$FAKE_SYS/listeners") ]] || fail "still listening: $(<"$FAKE_SYS/listeners")"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  ! called "GUARD *" || fail "a real system command was reached: $(grep GUARD "$FAKE_SYS/calls")"
  # The generic packages, the checkout and the rest of the sandbox stay.
  for path in /etc /etc/systemd/system /etc/ssl /opt /var/lib /var/log /run /tmp /etc/os-release; do
    [[ -e $SB$path ]] || fail "$path was removed"
  done
  grep -qx openssl "$FAKE_SYS/pkgs" || fail "openssl was removed"
  grep -qx ca-certificates "$FAKE_SYS/pkgs" || fail "ca-certificates was removed"
}

# --- the lifecycle ----------------------------------------------------------------

test_uninstall_all_removes_node_wallet_query_and_grpc_and_lets_them_be_set_up_again() {
  setup_all_components
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  assert_everything_absent
  # The lifecycle: a new node, then Wallet Query and gRPC again, none of
  # them refused as already set up.
  reinstall_node
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  [[ $status == 0 ]] || fail "Wallet Query could not be set up again: $stderr"
  [[ $stderr != *"already set up"* ]] || fail "Wallet Query was refused as already set up"
  grpc_ok
  [[ $status == 0 ]] || fail "Base Node gRPC could not be set up again: $stderr"
  [[ $(client_call GetVersion) == 0 ]] || fail "gRPC does not answer after the reinstall"
}

test_uninstall_all_with_wallet_query_only_removes_it_and_lets_it_be_set_up_again() {
  setup_node_and_wallet_query
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  [[ $stdout == *$'\n'"Uninstalled: Minotari node, Wallet Query
Removed: node service, node data, node logs, Tari release, tari account, tor package, Wallet Query files (Nginx site, certificate, acme.sh, renewal timer, record), nginx and nginx-common packages
Kept APT packages: jq, unzip, openssl
DNS, firewall and cloud security settings were not changed." ]] || fail "success output differs"
  assert_everything_absent
  assert_order "dpkg --no-act --purge -- nginx nginx-common" "systemctl stop minotari-mainnet.service" \
    "systemctl stop taritalk-wallet-query-renew.timer" "systemctl disable taritalk-wallet-query-renew.timer" \
    "systemctl stop nginx.service" "systemctl disable nginx.service" "systemctl daemon-reload" \
    "dpkg --purge -- nginx nginx-common" "dpkg --purge -- tor" "userdel tari"
  [[ $(grep -cx 'dpkg --no-act --purge -- nginx nginx-common' "$FAKE_SYS/calls") == 2 ]] ||
    fail "dpkg's dry run did not run before the confirmation and again before the purge"
  ! called "*taritalk-grpc*" || fail "touched gRPC units that were never set up"
  reinstall_node
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  [[ $status == 0 ]] || fail "Wallet Query could not be set up again: $stderr"
  assert_stdout_contains "Wallet Query: https://$WQ_DOMAIN (CORS: any origin)"
}

test_uninstall_all_removes_the_record_of_a_failed_setup_and_its_nginx() {
  # ZeroSSL never answered: Wallet Query's rollback kept Nginx, stopped,
  # with its retry record. Uninstall all takes both away.
  setup_wallet_query
  write_fake_acme issue
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  [[ $status == 1 && -f $SB/var/lib/taritalk-wallet-query-retry ]] || fail "no failed setup to start from: $stderr"
  : >"$FAKE_SYS/calls"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  assert_stdout_contains "Wallet Query:   the record of its failed setup, /var/lib/taritalk-wallet-query-retry"
  assert_stdout_has_line "Uninstalled: Minotari node"
  assert_stdout_contains "Removed: node service, node data, node logs, Tari release, tari account, tor package, record of the failed Wallet Query setup, nginx and nginx-common packages"
  assert_everything_absent
  ! called "systemctl stop taritalk-wallet-query-renew.timer" || fail "stopped a timer that was never created"
  # And once Nginx was changed after that failure, nothing is removed.
  rm -rf -- "${TEST_TMP:?}/sysroot" "$TEST_TMP/fakesys" "$TEST_TMP/web" "$TEST_TMP/zipsrc" \
    "$TEST_TMP/fakebin" "$TEST_TMP/curl-log" "$TEST_TMP/acme-calls" "$TEST_TMP/node-trace"
  setup_wallet_query
  write_fake_acme issue
  run_wallet_query --domain "$WQ_DOMAIN" --email "$WQ_EMAIL" --yes
  printf 'server { listen 8080; }\n' >"$SB/etc/nginx/conf.d/other.conf"
  expect_all_refusal changed-after-failure "Nginx was changed after the failed setup its record describes"
  rm -- "$SB/etc/nginx/conf.d/other.conf"
  "$TEST_TMP/fakebin/systemctl" start nginx.service
  expect_all_refusal started-after-failure "Nginx was started after the failed setup its record describes"
}

test_uninstall_all_leaves_an_nginx_this_tool_did_not_install() {
  # A node only, and someone else's Nginx on the host: not this tool's to
  # remove, and not even looked at.
  setup_uninstall
  echo nginx >>"$FAKE_SYS/pkgs"
  mkdir -p "$SB/etc/nginx/conf.d"
  printf 'server { listen 8080; }\n' >"$SB/etc/nginx/conf.d/mine.conf"
  touch "$FAKE_SYS/active.nginx.service" "$FAKE_SYS/enabled.nginx.service"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  assert_stdout_contains "Not changed:    DNS, Nginx, TLS, Cloudflare, firewalls, cloud security groups"
  assert_stdout_has_line "Uninstalled: Minotari node"
  [[ $stdout != *nginx* ]] || fail "mentioned nginx in the summary: $stdout"
  grep -qx nginx "$FAKE_SYS/pkgs" || fail "removed someone else's nginx"
  [[ $(<"$SB/etc/nginx/conf.d/mine.conf") == 'server { listen 8080; }' ]] || fail "touched /etc/nginx"
  [[ -e $FAKE_SYS/active.nginx.service && -e $FAKE_SYS/enabled.nginx.service ]] || fail "stopped or disabled Nginx"
  ! grep -qE '^(dpkg|dpkg-query|systemctl) .*nginx' "$FAKE_SYS/calls" || fail "ran commands on nginx: $(grep nginx "$FAKE_SYS/calls")"
}

# --- cancellation -----------------------------------------------------------------

# assert_only_reads_all: like assert_only_reads, allowing the read-only
# queries about Nginx and the units of the components.
assert_only_reads_all() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "dpkg-query -W -f=\${Status} "* | "dpkg-query -W -f=\${Conffiles}"* | "dpkg-query -L "* | "getent "* | \
        "systemctl show "* | "systemctl is-active "* | "systemd-analyze unit-paths" | \
        "dpkg --no-act --purge -- tor" | "dpkg --no-act --purge -- nginx nginx-common") ;;
      *) fail "unexpected system call: $line" ;;
    esac
  done <"$FAKE_SYS/calls"
  [[ -z $(ls -A "$TEST_TMP/curl-log") ]] || fail "network requests were made"
}

test_uninstall_all_cancel_changes_nothing() {
  setup_all_components
  local before answer line
  before=$(system_snapshot)
  for answer in "" EOF n N no yes Y\  x; do
    : >"$FAKE_SYS/calls"
    if [[ $answer == EOF ]]; then
      UNINSTALL_EOF=1 run_uninstall
    else
      UNINSTALL_INPUT=$answer run_uninstall
    fi
    [[ $status == 0 ]] || fail "[$answer]: expected exit 0, got $status: $stderr"
    assert_stdout_contains "Uninstall all plan"
    for line in "  Wallet Query:   https://$WQ_DOMAIN: /etc/nginx/conf.d/taritalk-wallet-query.conf, /etc/ssl/taritalk-wallet-query," \
      "  Base Node gRPC: $GRPC_DOMAIN:443: /etc/nginx/conf.d/taritalk-grpc.conf, /etc/ssl/taritalk-grpc," \
      "  Nginx:          the nginx and nginx-common packages, installed by this tool on" \
      "  Not changed:    DNS, Cloudflare, firewalls, cloud security groups"; do
      assert_stdout_has_line "$line"
    done
    [[ $stdout == *$'\n'"Uninstall the node, Wallet Query and Base Node gRPC? [y/N]: "$'\n'"Uninstall cancelled; nothing was changed." ]] ||
      fail "[$answer]: prompt or cancel message differs"
    assert_only_reads_all
    [[ $(system_snapshot) == "$before" ]] || fail "[$answer]: the system changed"
  done
}

# --- refusals --------------------------------------------------------------------

# expect_all_refusal NAME MESSAGE: uninstall, even confirmed, exits 1 with
# MESSAGE before the confirmation and changes nothing.
expect_all_refusal() {
  local name=$1 message=$2 before
  before=$(system_snapshot)
  : >"$FAKE_SYS/calls"
  rm -f -- "$TEST_TMP"/curl-log/*
  (
    UNINSTALL_INPUT=y run_uninstall
    [[ $status == 1 ]] || fail "[$name]: expected exit 1, got $status"
    assert_stderr_contains "$message"
    assert_stderr_contains "uninstall refused; nothing was changed."
    [[ $stdout != *"[y/N]"* ]] || fail "[$name]: asked for confirmation"
    assert_only_reads_all
    [[ $(system_snapshot) == "$before" ]] || fail "[$name]: the system changed"
  ) || exit 1
}

test_uninstall_all_refuses_changed_or_foreign_endpoint_state_before_any_change() {
  setup_all_components
  save_installed
  # shellcheck disable=SC2034 # Used by the eval'd actions.
  local WQ=$SB/var/lib/taritalk-wallet-query GRPC=$SB/var/lib/taritalk-grpc NGX=$SB/etc/nginx
  local -a cases=(
    "chmod 644 \$WQ/state@@'/var/lib/taritalk-wallet-query/state' is not a private file of root"
    "echo garbage >>\$WQ/state@@'/var/lib/taritalk-wallet-query/state' is not a valid Wallet Query record of taritalk-node-deploy: unexpected line"
    "sed -i 's/^format=1\$/format=2/' \$GRPC/state@@'/var/lib/taritalk-grpc/state' is not a valid Base Node gRPC record of taritalk-node-deploy: format is not 1"
    "sed -i 's/^packages_installed=.*/packages_installed=apache2/' \$WQ/state@@packages_installed lists apache2"
    "sed -i '/^packages_installed=/d' \$WQ/state@@'/var/lib/taritalk-wallet-query/state' is not a valid Wallet Query record of taritalk-node-deploy: invalid packages_installed"
    "sed -i '/^domain=/d' \$GRPC/state@@'/var/lib/taritalk-grpc/state' is not a valid Base Node gRPC record of taritalk-node-deploy: invalid domain"
    "sed -i 's/^with_wallet_query=1\$/with_wallet_query=0/' \$GRPC/state@@says gRPC was set up without Wallet Query, but Wallet Query is set up"
    "echo 'note=\$(touch \$TEST_TMP/pwned)' >>\$WQ/state@@is not a valid Wallet Query record"
    "printf 'format=1\\nnginx_fingerprint=%064d\\npackages_installed=\\n' 0 >\$SB/var/lib/taritalk-wallet-query-retry && chmod 600 \$SB/var/lib/taritalk-wallet-query-retry@@'/var/lib/taritalk-wallet-query-retry' exists although Wallet Query is set up"
    "echo '# edited' >>\$NGX/conf.d/taritalk-wallet-query.conf@@'/etc/nginx/conf.d/taritalk-wallet-query.conf' differs from what this tool wrote for $WQ_DOMAIN"
    "sed -i 's/18142/18143/' \$NGX/conf.d/taritalk-grpc.conf@@'/etc/nginx/conf.d/taritalk-grpc.conf' differs from what this tool wrote for $GRPC_DOMAIN"
    "printf 'server { listen 8080; }\\n' >\$NGX/conf.d/other.conf@@'/etc/nginx/conf.d' contains unexpected entries"
    "ln -s /etc/nginx/sites-available/default \$NGX/sites-enabled/default@@'/etc/nginx/sites-enabled' contains unexpected entries"
    "mkdir \$NGX/snippets && echo x >\$NGX/snippets/mine.conf@@'/etc/nginx/snippets' was written by neither the nginx package nor this tool"
    "echo '# edited' >>\$NGX/nginx.conf@@'/etc/nginx/nginx.conf' was changed after the nginx package installed it"
    "echo '# edited' >>\$NGX/sites-available/default@@'/etc/nginx/sites-available/default' was changed after the nginx package installed it"
    "chmod 644 \$SB/etc/ssl/taritalk-wallet-query/privkey.pem@@'/etc/ssl/taritalk-wallet-query/privkey.pem' is not a root-owned regular file with mode 600"
    "touch \$SB/etc/ssl/taritalk-grpc/extra.pem@@'/etc/ssl/taritalk-grpc' contains unexpected entries"
    "echo x >>\$SB/opt/taritalk-wallet-query/acme.sh@@'/opt/taritalk-wallet-query/acme.sh' does not match the acme.sh this tool installed"
    "touch \$WQ/notes@@'/var/lib/taritalk-wallet-query' contains unexpected entries"
    "echo '# edited' >>\$SB/etc/systemd/system/taritalk-grpc-renew.timer@@'/etc/systemd/system/taritalk-grpc-renew.timer' differs from this tool's template"
    "sed -i 's/^OnCalendar=.*/OnCalendar=hourly/' \$SB/etc/systemd/system/taritalk-wallet-query-renew.timer@@'/etc/systemd/system/taritalk-wallet-query-renew.timer' differs from this tool's template"
    "mkdir \$SB/etc/systemd/system/taritalk-grpc-renew.timer.d@@'/etc/systemd/system/taritalk-grpc-renew.timer.d' holds drop-ins for taritalk-grpc-renew.timer"
    "mkdir -p \$SB/run/systemd/system && touch \$SB/run/systemd/system/taritalk-wallet-query-renew.service && \$TEST_TMP/fakebin/systemctl daemon-reload@@'/run/systemd/system/taritalk-wallet-query-renew.service' also defines taritalk-wallet-query-renew.service"
    "echo libnginx-mod-http-echo >>\$FAKE_SYS/pkgs && echo 'libnginx-mod-http-echo nginx' >>\$FAKE_SYS/depends@@other packages depend on nginx"
    "sed -i '/^nginx\$/d' \$FAKE_SYS/pkgs@@the nginx package this tool installed is missing"
    "MOUNT /etc/nginx@@'/etc/nginx' is or contains a mount point"
    "MOUNT /var/lib/taritalk-grpc/acme@@'/var/lib/taritalk-grpc' is or contains a mount point"
    "MOUNT /etc/ssl/taritalk-wallet-query@@'/etc/ssl/taritalk-wallet-query' is or contains a mount point"
    "MOUNT /var/log/nginx@@'/var/log/nginx' is or contains a mount point"
  )
  local c action message
  cp "$TEST_TMP/mountinfo" "$TEST_TMP/mountinfo.saved"
  for c in "${cases[@]}"; do
    action=${c%%@@*}
    message=${c#*@@}
    restore_installed
    cp "$TEST_TMP/mountinfo.saved" "$TEST_TMP/mountinfo"
    rm -rf -- "${TEST_TMP:?}/pwned"
    if [[ $action == MOUNT* ]]; then
      mount_at "${action#MOUNT }"
    else
      eval "$action" || fail "[$action]: setup failed"
    fi
    expect_all_refusal "$action" "$message"
    [[ ! -e $TEST_TMP/pwned ]] || fail "[$action]: a record was executed"
  done
  # Free content where acme.sh and Nginx write theirs is accepted.
  restore_installed
  cp "$TEST_TMP/mountinfo.saved" "$TEST_TMP/mountinfo"
  echo token >"$SB/var/lib/taritalk-wallet-query/webroot/.well-known/acme-challenge/abc"
  mkdir -p "$SB/var/lib/taritalk-grpc/acme/ca"
  echo key >"$SB/var/lib/taritalk-grpc/acme/account.key"
  mkdir -p "$SB/var/log/nginx"
  echo log >"$SB/var/log/nginx/access.log"
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
}

# --- failures -------------------------------------------------------------------

test_uninstall_all_stops_honestly_at_a_failed_step() {
  # FAIL GLOB @@ message @@ a later call that must not happen @@ what must still exist
  local -a cases=(
    "systemctl stop taritalk-wallet-query-renew.timer@@cannot stop taritalk-wallet-query-renew.timer@@systemctl stop nginx.service@@/var/lib/taritalk-wallet-query/state"
    "systemctl disable taritalk-grpc-renew.timer@@cannot disable taritalk-grpc-renew.timer@@systemctl stop nginx.service@@/var/lib/taritalk-grpc/state"
    "systemctl stop nginx.service@@cannot stop nginx.service@@dpkg --purge *@@/etc/nginx/conf.d/taritalk-wallet-query.conf"
    "dpkg --purge -- nginx nginx-common@@dpkg --purge nginx nginx-common failed@@dpkg --purge -- tor@@/opt/tari"
  )
  local c glob message later keep
  setup_all_components
  save_installed
  for c in "${cases[@]}"; do
    IFS='|' read -r glob message later keep <<<"${c//@@/|}"
    restore_installed
    (
      export FAKE_SYS_FAIL=$glob
      UNINSTALL_INPUT=y run_uninstall
      [[ $status == 1 ]] || fail "[$glob]: expected exit 1, got $status"
      assert_stderr_contains "$message"
      assert_stderr_contains "uninstall stopped; later steps were not run, so the removal may be incomplete"
      [[ $stdout != *"Uninstalled:"* ]] || fail "[$glob]: claimed success"
      ! called "$later" || fail "[$glob]: continued with '$later'"
      [[ -e $SB$keep ]] || fail "[$glob]: $keep was removed"
      [[ -e $SB/var/lib/tari/taritalk-install-state ]] || fail "[$glob]: the install record was removed"
    ) || exit 1
  done
  # Nginx's purge left its directory with files in it: not emptied.
  restore_installed
  FAKE_NGINX_POSTRM_KEEPS=1 UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "'/etc/nginx' is left after purging nginx and is not empty; leaving it untouched"
  [[ -e $SB/etc/nginx/nginx.conf ]] || fail "emptied /etc/nginx"
  [[ $stdout != *"Uninstalled:"* ]] || fail "claimed success"
  # A site replaced after the checks (while the services stop): nothing is
  # removed.
  restore_installed
  printf '#!/usr/bin/env bash\necho "# edited" >>%q\n' "$SB/etc/nginx/conf.d/taritalk-grpc.conf" >"$TEST_TMP/hook"
  chmod +x "$TEST_TMP/hook"
  FAKE_SYS_HOOK_ON="systemctl stop nginx.service" FAKE_SYS_HOOK=$TEST_TMP/hook UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "'/etc/nginx/conf.d/taritalk-grpc.conf' changed after the checks; leaving it untouched"
  ! called "dpkg --purge *" || fail "continued with a purge"
  [[ -e $SB/var/lib/taritalk-wallet-query/state && -e $SB/var/lib/taritalk-grpc/state && -e $SB/opt/tari ]] ||
    fail "removed files after a change"
}

# --- the saved submission ID ------------------------------------------------------

# saved_id_ready: a copy of the tool as the user has it, with a submission
# ID saved next to deploy.sh, as the directory of deploy.sh for
# run_uninstall. Sets TOOL_DIR, RECORD and TOOL_LISTING (without the
# record).
saved_id_ready() {
  TOOL_DIR=$TEST_TMP/unpacked/taritalk-node-deploy
  RECORD=$TOOL_DIR/submission-id.txt
  # shellcheck disable=SC2034 # Read by run_uninstall (tests/test_uninstall.sh).
  UNINSTALL_SOURCE_DIR=$TOOL_DIR
  tool_copy "$TOOL_DIR"
  TOOL_LISTING=$(dir_listing "$TOOL_DIR")
  printf 'Submission ID: sub_0123456789abcdef\nSubmitted: 2026-01-02 03:04:05 UTC\n' >"$RECORD"
  chmod 600 "$RECORD"
}

test_uninstall_all_removes_the_saved_submission_id_last_and_only_on_success() {
  setup_all_components
  saved_id_ready
  local before
  before=$(file_identity "$RECORD")
  save_installed
  # Cancelled: the plan names the record; nothing goes.
  UNINSTALL_INPUT=n run_uninstall
  assert_status 0
  assert_stdout_has_line "  Submission ID:  $RECORD (the submission ID saved by submit)"
  assert_stdout_contains "Uninstall cancelled; nothing was changed."
  [[ $(file_identity "$RECORD") == "$before" ]] || fail "[cancel]: the record changed"
  # Refused (a changed site): kept.
  printf '# edited\n' >>"$SB/etc/nginx/conf.d/taritalk-wallet-query.conf"
  UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "uninstall refused; nothing was changed."
  [[ $(file_identity "$RECORD") == "$before" ]] || fail "[refused]: the record changed"
  restore_installed
  # Stopped at a failed step: kept.
  FAKE_SYS_FAIL="dpkg --purge -- nginx nginx-common" UNINSTALL_INPUT=y run_uninstall
  assert_status 1
  assert_stderr_contains "uninstall stopped; later steps were not run"
  [[ $(file_identity "$RECORD") == "$before" ]] || fail "[failed step]: the record changed"
  restore_installed
  # Success: the record goes, and nothing else of the tool's directory.
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  [[ $stderr != *warning* ]] || fail "warned: $stderr"
  assert_everything_absent
  [[ ! -e $RECORD ]] || fail "the record was kept"
  [[ $(dir_listing "$TOOL_DIR") == "$TOOL_LISTING" ]] || fail "the tool's directory changed beyond the record"
  assert_stdout_contains ", saved submission ID (submission-id.txt)"
  # Without a record, nothing is said about one and the directory is untouched.
  reinstall_node
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  [[ $stdout != *"submission-id.txt"* && $stdout != *"Submission ID"* ]] || fail "named a record that does not exist"
  [[ $(dir_listing "$TOOL_DIR") == "$TOOL_LISTING" ]] || fail "the tool's directory changed"
  # Something else at the path (a symlink) is left, with a warning.
  reinstall_node
  ln -s "$TOOL_DIR/deploy.sh" "$RECORD"
  UNINSTALL_INPUT=y run_uninstall
  [[ $status == 0 ]] || fail "uninstall failed: $stderr"
  assert_stderr_contains "warning: cannot remove '$RECORD'; remove it by hand"
  [[ -L $RECORD && -f $TOOL_DIR/deploy.sh ]] || fail "removed the symlink or its target"
  [[ $stdout != *", saved submission ID"* ]] || fail "claimed to have removed the record"
}

test_menu_uninstall_all_names_and_removes_the_saved_submission_id() {
  setup_all_components
  saved_id_ready
  # shellcheck disable=SC2034 # Read by menu_session (tests/test_menu.sh).
  MENU_TOOL_DIR=$TOOL_DIR
  local before line="  - the saved TariTalk submission ID (submission-id.txt next to deploy.sh)"
  before=$(file_identity "$RECORD")
  run_menu 8 "" 0
  assert_status 0
  assert_stdout_has_line "$line"
  assert_stdout_contains "Uninstall cancelled; nothing was changed."
  assert_plain_language
  [[ $(file_identity "$RECORD") == "$before" ]] || fail "the record changed"
  run_menu 8 y "" 0
  assert_status 0
  assert_stdout_contains "Uninstalled: Minotari node, Wallet Query, Base Node gRPC"
  assert_stdout_contains ", saved submission ID (submission-id.txt)"
  assert_stderr_empty
  assert_plain_language
  [[ ! -e $RECORD ]] || fail "the record was kept"
  [[ $(dir_listing "$TOOL_DIR") == "$TOOL_LISTING" ]] || fail "the tool's directory changed beyond the record"
}

# --- the menu, the help and the README ------------------------------------------------

test_menu_uninstall_all_in_plain_language() {
  setup_all_components
  local before
  before=$(system_snapshot)
  run_menu 8 "" 0
  assert_status 0
  local line
  for line in "Uninstall all" "  - Wallet Query over HTTPS: its web server setup, certificate and renewal" \
    "  - Base Node gRPC over HTTPS: its web server setup, certificate and renewal" \
    "  - the Nginx web server, which this tool installed for them" \
    "  Kept: the other APT packages and this tool."; do
    assert_stdout_has_line "$line"
  done
  assert_stdout_contains "Uninstall the node, Wallet Query and Base Node gRPC? [y/N]: "
  assert_stdout_contains "Uninstall cancelled; nothing was changed."
  assert_stderr_empty
  assert_plain_language
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
  # Refused (a changed site): the outcome first, in plain words.
  printf '# edited\n' >>"$SB/etc/nginx/conf.d/taritalk-wallet-query.conf"
  before=$(system_snapshot)
  run_menu 8 y "" 0
  assert_status 0
  local outcome="Nothing was removed; nothing was changed. This tool removes only what it installed itself, and only while all of it is still as it left it."
  assert_stdout_contains "$outcome"
  assert_stdout_contains "Reason: "
  ((0 < $(line_no "$outcome") && $(line_no "$outcome") < $(line_no "Reason: "))) || fail "the outcome is not said first"
  [[ $stdout != *"Uninstalled:"* ]] || fail "claimed success"
  assert_plain_language
  [[ $(system_snapshot) == "$before" ]] || fail "the system changed"
  # Confirmed: everything goes, and the menu shows no node.
  sed -i '$d' "$SB/etc/nginx/conf.d/taritalk-wallet-query.conf"
  run_menu 8 y "" 0
  assert_status 0
  assert_stdout_contains "Uninstalled: Minotari node, Wallet Query, Base Node gRPC"
  [[ ${stdout##*TariTalk Node Tool} == *"Node: not installed"* ]] || fail "the last menu does not show the node gone"
  assert_stderr_empty
  assert_plain_language
  assert_everything_absent
}

test_menu_uninstall_all_failure_says_first_that_it_stopped_part_way() {
  setup_all_components
  FAKE_SYS_FAIL="dpkg --purge -- nginx nginx-common" run_menu 8 y "" 0
  assert_status 0
  local outcome="Uninstall stopped part way: some parts may be removed and others not. Check this server before trying again."
  assert_stdout_contains "$outcome"
  assert_stdout_contains "Reason: "
  ((0 < $(line_no "$outcome") && $(line_no "$outcome") < $(line_no "Reason: "))) || fail "the outcome is not said first"
  [[ $stdout != *"Uninstalled:"* ]] || fail "claimed success"
  assert_plain_language
  [[ -e $SB/opt/tari && -e $SB/var/lib/tari/taritalk-install-state ]] || fail "the node went although the uninstall stopped"
}

test_uninstall_all_menu_help_and_readme_agree() {
  local readme=$REPO_ROOT/README.md section
  grep -qxF '8. Uninstall all' "$readme" || fail "README menu lacks 8. Uninstall all"
  grep -qF '"8. Uninstall all"' "$REPO_ROOT/lib/menu.sh" || fail "the menu does not say 8. Uninstall all"
  grep -qF '8) menu_run uninstall ;;' "$REPO_ROOT/lib/menu.sh" || fail "menu item 8 is not the uninstall"
  grep -qF "printf 'Uninstall the node, Wallet Query and Base Node gRPC? [y/N]: '" "$REPO_ROOT/lib/uninstall.sh" ||
    fail "the prompt differs"
  # shellcheck disable=SC2016 # awk anchors, not shell.
  section=$(awk '/^### Feature 8: Uninstall all$/ { on = 1 } on && /^## / { exit } on' "$readme")
  [[ $section == *$'```bash\n./deploy.sh uninstall\n```'* ]] || fail "README lacks the uninstall command"
  local phrase
  # shellcheck disable=SC2016 # Markdown code spans, not shell.
  for phrase in 'everything this tool installed' 'asking you to confirm once' 'Wallet Query' 'Base Node gRPC' 'Nginx this tool installed' \
    'certificates, renewal timers and records' 'set up again' 'ca-certificates, curl, jq, openssl and unzip' \
    'DNS, Cloudflare, firewalls and cloud security groups are not changed' 'refuses before changing anything' 'There is no undo' \
    'except the saved `submission-id.txt`, which is removed last'; do
    [[ $section == *"$phrase"* ]] || fail "README Feature 8 lacks: $phrase"
  done
  run_cli --help
  assert_status 0
  assert_stdout_contains "uninstall   Uninstall all: remove the node installed by this tool"
  run_cli uninstall --help
  assert_status 0
  assert_stdout_contains "Uninstall all: remove everything this tool installed"
  assert_stdout_contains "  - submission-id.txt next to deploy.sh, the submission ID saved by"
}
