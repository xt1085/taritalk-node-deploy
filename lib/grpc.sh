# shellcheck shell=bash
# grpc: publishes the restricted, read-only Base Node gRPC of a node
# installed by lib/install.sh over HTTPS (HTTP/2) under the user's own
# domain name: the node's gRPC is turned on for 127.0.0.1:18142 only, with
# exactly the read-only methods of GRPC_METHODS allowed, and Nginx in front
# of it with a free ZeroSSL certificate from acme.sh, renewed by a systemd
# timer. On a server where lib/wallet-query.sh set up Wallet Query, it adds
# its own host name to that Nginx and leaves Wallet Query as it is. Sourced
# by deploy.sh after lib/fetch.sh, lib/install.sh, lib/status.sh and
# lib/wallet-query.sh, whose layout, transaction record, rollback helpers
# and checks it reuses. Must be run as root; never escalates privileges.
#
# Like install, every change is recorded as it is made, and a failure or
# signal rolls back exactly what this run created (installed APT packages
# are kept), the node's configuration included. It never changes DNS,
# firewalls or cloud security groups.

# Internal settings. Tests that source this file may point them at a
# sandbox; the CLI offers no way to change them.
GRPC_CALL_SECONDS=30
GRPC_CHALLENGE_SECONDS=30

readonly GRPC_SERVICE=tari.rpc.BaseNode
# The read-only methods the node allows (grpc_server_allow_methods), in
# this order; every other method is refused by the node itself.
readonly GRPC_METHODS=(get_version get_sync_info get_sync_progress get_tip_info identify
  get_network_status get_network_state list_headers)
readonly GRPC_RENEW_SERVICE=taritalk-grpc-renew.service
readonly GRPC_RENEW_TIMER=taritalk-grpc-renew.timer
readonly GRPC_DEPENDENCIES=("${WQ_DEPENDENCIES[@]}")

# Fixed layout (real paths; every file system access adds $SYSROOT).
readonly GRPC_HOME=/var/lib/taritalk-grpc
readonly GRPC_STATE=/var/lib/taritalk-grpc/state
# After a failed setup that installed Nginx on a server without Wallet
# Query: what lets the next run reuse that Nginx (see grpc_write_retry_record).
readonly GRPC_RETRY_RECORD=/var/lib/taritalk-grpc-retry
readonly GRPC_ACME_HOME=/var/lib/taritalk-grpc/acme
readonly GRPC_WEBROOT=/var/lib/taritalk-grpc/webroot
readonly GRPC_OPT=/opt/taritalk-grpc
readonly GRPC_ACME_SH=/opt/taritalk-grpc/acme.sh
readonly GRPC_TLS_DIR=/etc/ssl/taritalk-grpc
readonly GRPC_NGINX_CONF=/etc/nginx/conf.d/taritalk-grpc.conf
readonly GRPC_RENEW_SERVICE_FILE=/etc/systemd/system/taritalk-grpc-renew.service
readonly GRPC_RENEW_TIMER_FILE=/etc/systemd/system/taritalk-grpc-renew.timer
readonly NODE_CONFIG=/var/lib/tari/mainnet/mainnet/config/config.toml

# shellcheck disable=SC2153 # GRPC_PORT is defined by lib/install.sh.
grpc_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD grpc [--domain DOMAIN] [--email EMAIL] [--yes]

Make the restricted, read-only Base Node gRPC of the node installed by this
tool reachable from the internet at DOMAIN:443 (gRPC over HTTPS, HTTP/2),
for wallets, explorers and other gRPC clients. Not a website, and not the
Wallet Query. Must be run as root; this tool itself never escalates
privileges.

DOMAIN must be your own domain name (or a community subdomain from TariTalk,
see $SUBDOMAIN_HINT), used for nothing else on this server, whose DNS A
record already points to the public IPv4 address given at install. Inbound
TCP 80 and 443 must be open: ZeroSSL checks the domain over port 80, and
gRPC clients use port 443.

It turns on the node's gRPC for 127.0.0.1:$GRPC_PORT only, allowing just
these read-only methods: ${GRPC_METHODS[*]}
(second-layer methods stay off, mining stays off, no other method is
allowed), and restarts the node once. It installs the APT packages nginx,
openssl, ca-certificates and curl if missing, downloads acme.sh
$ACME_SH_VERSION from GitHub (checked against a pinned SHA-256) into
$GRPC_OPT, registers a free ZeroSSL account for EMAIL, gets a certificate
for DOMAIN into $GRPC_TLS_DIR, writes $GRPC_NGINX_CONF
and enables $GRPC_RENEW_TIMER.

On a server where this tool set up Wallet Query, it adds DOMAIN to that
Nginx and leaves the Wallet Query as it is. Otherwise Nginx must not be
installed yet (Wallet Query cannot be added afterwards: set it up first).

It does not change DNS, Cloudflare, firewalls or cloud security groups.
Before changing anything it shows the plan and asks once for confirmation.
On failure it rolls back what it created and puts the node's configuration
back; installed packages remain. Once the problem is fixed it can simply be
run again. Running it again once gRPC is set up is refused.

Options:
  --domain DOMAIN  Domain name for the gRPC endpoint (asked for when run
                   interactively; required otherwise)
  --email EMAIL    Email address for the ZeroSSL account (expiry notices;
                   asked for when run interactively; required otherwise)
  --yes            Do not ask for confirmation (all checks still run)
  --help           Show this help and exit
USAGE
}

# --- read-only checks --------------------------------------------------------

# grpc_node_config: the node configuration with gRPC turned on, from the
# install template (so that it is the same however often it is made).
grpc_node_config() {
  local text block method
  local old_header='# not a seed node, miner or public RPC service. gRPC is disabled, the'
  local new_header='# not a seed node or miner. Base Node gRPC is read-only on loopback, the'
  text=$(render_template config.toml.in PUBLIC_IPV4 "$PUBLIC_IP") || exit 1
  block='# Base Node gRPC, turned on by the grpc command of taritalk-node-deploy:
# loopback only, read-only methods only (Nginx publishes it over HTTPS).
grpc_enabled = true
grpc_address = "/ip4/127.0.0.1/tcp/'$GRPC_PORT'"
grpc_tls_enabled = false
second_layer_grpc_enabled = false
mining_enabled = false
grpc_server_allow_methods = ['
  for method in "${GRPC_METHODS[@]}"; do
    block+=$'\n'"    \"$method\","
  done
  block+=$'\n]'
  [[ $text == *$'\n'"$old_header"$'\n'* && $text == *$'\n[base_node]\ngrpc_enabled = false\n'* ]] ||
    die "unexpected node configuration template"
  text=${text/$'\n'"$old_header"$'\n'/$'\n'"$new_header"$'\n'}
  text=${text/$'\n[base_node]\ngrpc_enabled = false\n'/$'\n[base_node]\n'"$block"$'\n'}
  printf '%s\n' "$text"
}

# check_node_config: the node configuration is still exactly what install
# wrote (owned by the service user, private), so that it can be replaced
# and put back. Sets NODE_CONFIG_ORIGINAL.
check_node_config() {
  local path info ids
  path=$(sysroot "$NODE_CONFIG")
  ids=$(tari_ids) || die "cannot find the service user '$SERVICE_USER'"
  [[ -f $path && ! -L $path ]] || die "'$NODE_CONFIG' is not a regular file"
  info=$(stat -c '%u:%g %a %h' -- "$path") || die "cannot inspect '$NODE_CONFIG'"
  [[ $info == "$ids 600 1" ]] ||
    die "'$NODE_CONFIG' is not the private file of the node that install wrote ($info)"
  NODE_CONFIG_ORIGINAL=$(render_template config.toml.in PUBLIC_IPV4 "$PUBLIC_IP")$'\n' || exit 1
  [[ $(<"$path")$'\n' == "$NODE_CONFIG_ORIGINAL" &&
  $(stat -c %s -- "$path") == "$(LC_ALL=C grpc_byte_length "$NODE_CONFIG_ORIGINAL")" ]] ||
    die "the node configuration '$NODE_CONFIG' was changed after the installation, so this tool does not change it"
  TARI_IDS=$ids
}

grpc_byte_length() { printf '%s\n' "${#1}"; }

# read_wallet_query_state: the record of a Wallet Query set up by this
# tool (a private regular file of root, read as data). Sets GRPC_WQ_DOMAIN.
read_wallet_query_state() {
  local path info line key domain
  local -a lines
  local -A seen=()
  path=$(sysroot "$WQ_STATE")
  [[ -f $path && ! -L $path ]] || die "'$WQ_STATE' is not a regular file"
  info=$(stat -c '%u %a %h' -- "$path") || die "cannot inspect '$WQ_STATE'"
  [[ $info == "${ROOT_IDS%%:*} 600 1" ]] || die "'$WQ_STATE' is not a private file of root"
  mapfile -t lines <"$path" || die "cannot read '$WQ_STATE'"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_0-9]+)=([^[:space:][:cntrl:]]*)$ && -z ${seen[${BASH_REMATCH[1]}]+x} ]] ||
      die "'$WQ_STATE' is not a Wallet Query record of $PROG"
    key=${BASH_REMATCH[1]}
    seen[$key]=${BASH_REMATCH[2]}
  done
  domain=${seen[domain]-}
  { [[ ${seen[format]-} == 1 ]] && check_domain "$domain"; } ||
    die "'$WQ_STATE' is not a Wallet Query record of $PROG"
  GRPC_WQ_DOMAIN=$domain
}

# check_wallet_query_nginx: Nginx serves exactly the Wallet Query this tool
# set up, unchanged: its one configuration file as written, the default
# site disabled, nothing else enabled, Nginx running.
check_wallet_query_nginx() {
  local expected path entry pkg
  read_wallet_query_state
  [[ $GRPC_WQ_DOMAIN != "$DOMAIN" ]] ||
    die "$DOMAIN is the Wallet Query's domain name; the gRPC endpoint needs a domain name of its own"
  ! exists "$(sysroot "$WQ_RETRY_RECORD")" ||
    die "a failed Wallet Query setup is pending on this server; finish it (or remove it by hand) first"
  package_installed nginx || die "Wallet Query is set up, but the nginx package is missing"
  for pkg in nginx-core nginx-light nginx-full nginx-extras apache2 lighttpd caddy; do
    ! package_installed "$pkg" ||
      die "a web server ($pkg) is installed besides the Wallet Query's Nginx; this tool does not change it"
  done
  for path in /etc/nginx /etc/nginx/conf.d /etc/nginx/sites-enabled; do
    [[ -d $(sysroot "$path") && ! -L $(sysroot "$path") ]] ||
      die "'$path' is missing or not a directory"
  done
  for entry in "$(sysroot /etc/nginx/conf.d)"/* "$(sysroot /etc/nginx/conf.d)"/.[!.]* \
    "$(sysroot /etc/nginx/conf.d)"/..?* "$(sysroot /etc/nginx/sites-enabled)"/* \
    "$(sysroot /etc/nginx/sites-enabled)"/.[!.]* "$(sysroot /etc/nginx/sites-enabled)"/..?*; do
    exists "$entry" || continue
    [[ $entry == "$(sysroot "$WQ_NGINX_CONF")" ]] ||
      die "Nginx has configuration that Wallet Query did not write ('${entry#"$SYSROOT"}'), so this tool does not change it"
  done
  NGINX_NEW_HTTP2=0
  if nginx_new_http2; then NGINX_NEW_HTTP2=1; fi
  path=$(sysroot "$WQ_NGINX_CONF")
  [[ -f $path && ! -L $path ]] || die "'$WQ_NGINX_CONF' is missing"
  expected=$(DOMAIN=$GRPC_WQ_DOMAIN render_nginx wallet-query.conf) || exit 1
  [[ $(<"$path") == "$expected" ]] ||
    die "the Wallet Query's Nginx configuration was changed after it was set up, so this tool does not change it"
  grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
    "$(sysroot /etc/nginx/nginx.conf)" 2>/dev/null ||
    die "'/etc/nginx/nginx.conf' does not include /etc/nginx/conf.d/*.conf"
  {
    [[ $(timeout --kill-after=2 30 systemctl is-active "$NGINX_SERVICE" 2>/dev/null </dev/null) == active ]] &&
      listening_on 80 0.0.0.0 && listening_on 443 0.0.0.0
  } || die "the Wallet Query's Nginx is not running on TCP 80 and 443; check it first"
}

# check_grpc_host: a healthy node of this tool with its configuration as
# installed, gRPC not set up yet, and either the Wallet Query of this tool
# (WITH_WQ=1) or nothing serving the web on this host. Read-only.
check_grpc_host() {
  local path pkg
  if exists "$(sysroot "$GRPC_STATE")"; then
    die "Base Node gRPC is already set up on this server; setting it up again is not supported"
  fi
  check_install_state
  check_node_install
  {
    [[ $(timeout --kill-after=2 30 systemctl is-active "$NODE_SERVICE" 2>/dev/null </dev/null) == active ]] &&
      listening_on "$WALLET_QUERY_PORT" 127.0.0.1
  } || die "the node is not running with its local Wallet Query private to this server; check it with '$USAGE_CMD status' first"
  port_free "$GRPC_PORT" ||
    die "something already listens on the gRPC port $GRPC_PORT; this tool turns on gRPC only for a node that has it off"
  PUBLIC_IP=$(recorded_public_ip) || exit 1
  check_node_config
  for path in "$GRPC_HOME" "$GRPC_OPT" "$GRPC_TLS_DIR" "$GRPC_NGINX_CONF" \
    "$GRPC_RENEW_SERVICE_FILE" "$GRPC_RENEW_TIMER_FILE"; do
    ! exists "$(sysroot "$path")" || die "conflict: '$path' already exists"
  done
  RETRY=0 WITH_WQ=0
  if exists "$(sysroot "$WQ_STATE")"; then
    ! exists "$(sysroot "$GRPC_RETRY_RECORD")" ||
      die "conflict: '$GRPC_RETRY_RECORD' exists although Wallet Query is set up"
    WITH_WQ=1
    [[ -z $DOMAIN ]] || check_wallet_query_nginx
  else
    if exists "$(sysroot "$GRPC_RETRY_RECORD")"; then
      grpc_read_retry_record
      RETRY=1
    fi
    for pkg in nginx nginx-common nginx-core nginx-light nginx-full nginx-extras apache2 lighttpd caddy; do
      package_installed "$pkg" || continue
      # The Nginx an earlier failed run of this command installed, and kept.
      ((RETRY)) && [[ " ${NGINX_OWN_PACKAGES[*]} " == *" $pkg "* ]] && continue
      die "a web server ($pkg) is already installed on this server; this tool sets up gRPC only on a server without one, or next to its own Wallet Query"
    done
    if exists "$(sysroot /etc/nginx)"; then
      ((RETRY)) || die "conflict: '/etc/nginx' already exists"
      [[ $(nginx_fingerprint) == "$RETRY_FINGERPRINT" ]] ||
        die "Nginx was changed after the last failed gRPC setup, so this tool does not take it over; restore it or remove it by hand"
      [[ $(timeout --kill-after=2 30 systemctl is-active "$NGINX_SERVICE" 2>/dev/null </dev/null) != active ]] ||
        die "Nginx was started after the last failed gRPC setup, so this tool does not take it over; stop it or remove it by hand"
    fi
    for path in 80 443; do
      port_free "$path" || die "TCP port $path is already in use on this server; this tool sets up gRPC only on a server where it is free, or next to its own Wallet Query"
    done
  fi
  for path in /etc /etc/ssl /etc/systemd/system /opt /var /var/lib; do
    check_system_dir "$path"
  done
  check_system_dir /tmp
}

# grpc_read_retry_record / grpc_write_retry_record: as read_retry_record and
# write_retry_record of lib/wallet-query.sh, for this command's record.
grpc_read_retry_record() {
  local path info line key
  local -a lines
  local -A seen=()
  path=$(sysroot "$GRPC_RETRY_RECORD")
  [[ -f $path && ! -L $path ]] || die "'$GRPC_RETRY_RECORD' is not a regular file"
  info=$(stat -c '%u %a %h %s' -- "$path") || die "cannot inspect '$GRPC_RETRY_RECORD'"
  [[ ${info% *} == "${ROOT_IDS%%:*} 600 1" && ${info##* } -le 1024 ]] ||
    die "'$GRPC_RETRY_RECORD' is not a private file of root"
  mapfile -t lines <"$path" || die "cannot read '$GRPC_RETRY_RECORD'"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_]+)=([a-z0-9,.+-]*)$ && -z ${seen[${BASH_REMATCH[1]}]+x} ]] ||
      die "'$GRPC_RETRY_RECORD' is not a record of $PROG"
    key=${BASH_REMATCH[1]}
    seen[$key]=${BASH_REMATCH[2]}
  done
  [[ ${seen[format]-} == 1 && ${seen[nginx_fingerprint]-} =~ ^[0-9a-f]{64}$ &&
    ${seen[packages_installed]-x} =~ ^([a-z0-9.+-]+(,[a-z0-9.+-]+)*)?$ ]] ||
    die "'$GRPC_RETRY_RECORD' is not a record of $PROG"
  RETRY_FINGERPRINT=${seen[nginx_fingerprint]}
  IFS=, read -r -a RETRY_PACKAGES <<<"${seen[packages_installed]}"
}

grpc_write_retry_record() {
  local path tmp fp pkg
  local -a pkgs=()
  fp=$(nginx_fingerprint) && [[ $fp =~ ^[0-9a-f]{64}$ ]] || return 1
  for pkg in "${RETRY_PACKAGES[@]}" "${PKGS_NEW[@]}"; do
    [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
  done
  path=$(sysroot "$GRPC_RETRY_RECORD")
  tmp=$(mktemp "$path.XXXXXXXX") || return 1
  if ! { printf 'format=1\nnginx_fingerprint=%s\npackages_installed=%s\n' "$fp" \
    "$(
      IFS=,
      printf '%s' "${pkgs[*]}"
    )" >"$tmp" && chown -- "$ROOT_IDS" "$tmp" && chmod 600 "$tmp" &&
    mv -f --no-target-directory -- "$tmp" "$path"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

print_grpc_intro() {
  print_text <<INTRO
Base Node gRPC over HTTPS
  This makes your node's Base Node gRPC available to wallets, explorers and
  other gRPC clients over HTTPS, with a free ZeroSSL certificate. Only
  read-only calls are allowed (such as the chain tip, sync state and block
  headers); it is not a website. It needs a domain name of its own whose DNS
  A record points to this server ($1).
  No domain name? You can ask TariTalk for a free community subdomain (see
  $SUBDOMAIN_HINT). Come back here once it points to this server.

INTRO
}

print_grpc_plan() {
  local nginx_line='Nginx is installed for it'
  ((!WITH_WQ)) || nginx_line="Nginx (already serving Wallet Query at $GRPC_WQ_DOMAIN) also serves it"
  if ((${MENU_MODE:-0})); then
    print_text <<PLAN
Base Node gRPC setup
  Domain:        $DOMAIN (points to this server, $PUBLIC_IP)
  Certificate:   free ZeroSSL certificate for $EMAIL, renewed automatically
  It turns on the node's gRPC for read-only calls, for this server only, and
  restarts the node once (a short pause). $nginx_line,
  with the certificate tool acme.sh, and makes the gRPC available at $DOMAIN
  over HTTPS. Nothing that changes the node or its wallet can be called.
  Before you go on: inbound TCP ports 80 and 443 must be open in your
  firewall or cloud security group. This tool does not change them.
  Not changed:   DNS, firewalls and cloud security groups
PLAN
    return 0
  fi
  local packages="${WQ_PACKAGES[*]} (only missing ones; no system upgrade)"
  ((!WITH_WQ)) || packages="none (Wallet Query's Nginx is reused)"
  print_text <<PLAN
Base Node gRPC setup plan
  Domain:         $DOMAIN (DNS A record: $PUBLIC_IP)
  Public gRPC:    $DOMAIN:443 (TLS, HTTP/2; TCP 80 for the ZeroSSL check)
  Node:           gRPC on 127.0.0.1:$GRPC_PORT only, in $NODE_CONFIG;
                  allowed: ${GRPC_METHODS[*]};
                  second-layer methods and mining off; the node restarts once
  Packages:       $packages
  acme.sh:        $ACME_SH_VERSION from $ACME_SH_URL
                  (SHA-256 $ACME_SH_SHA256) into $GRPC_ACME_SH
  Certificate:    ZeroSSL (ACME, HTTP-01, EC-256), account $EMAIL,
                  installed into $GRPC_TLS_DIR
  Nginx:          $GRPC_NGINX_CONF$( ((WITH_WQ)) && printf ' (next to Wallet Query at %s)' "$GRPC_WQ_DOMAIN")
  Renewal:        $GRPC_RENEW_TIMER, daily: $GRPC_RENEW_SERVICE runs acme.sh --cron
  Data:           $GRPC_HOME
  Not changed:    Wallet Query, P2P, DNS, Cloudflare, firewalls, cloud security groups
PLAN
}

# --- steps ---------------------------------------------------------------------

GRPC_DONE=0 WITH_WQ=0 GRPC_WQ_DOMAIN=''
NODE_CONFIG_REPLACED=0 NODE_CONFIG_ID='' NODE_CONFIG_ORIGINAL='' NGINX_RELOAD_NEEDED=0

# grpc_render NAME: templates/NAME for this domain and this Nginx.
grpc_render() {
  local text
  text=$(render_template "$1" DOMAIN "$DOMAIN" WEBROOT "$GRPC_WEBROOT" TLS_DIR "$GRPC_TLS_DIR") ||
    exit 1
  if ((NGINX_NEW_HTTP2)); then
    text=${text//"listen 443 ssl http2 default_server;"/"listen 443 ssl default_server;"$'\n'"    http2 on;"}
    text=${text//"listen 443 ssl http2;"/"listen 443 ssl;"$'\n'"    http2 on;"}
  fi
  printf '%s\n' "$text"
}

# grpc_nginx_conf STAGE: this command's Nginx configuration for STAGE (acme
# or https): on a server without Wallet Query with the default servers.
grpc_nginx_conf() {
  local conf defaults='' name=grpc.conf default=grpc-default.conf
  if [[ $1 == acme ]]; then name=grpc-acme.conf default=grpc-default-acme.conf; fi
  if ((!WITH_WQ)); then
    defaults=$(grpc_render "$default") || exit 1
    defaults+=$'\n\n'
  fi
  conf=$(grpc_render "$name") || exit 1
  printf '%s%s\n' "$defaults" "$conf"
}

grpc_configure_http() {
  step "configuring Nginx for the certificate check"
  command -v nginx >/dev/null || die "nginx is missing after installing the nginx package"
  NGINX_NEW_HTTP2=0
  if nginx_new_http2; then NGINX_NEW_HTTP2=1; fi
  ((WITH_WQ)) || disable_default_site
  make_dir "$GRPC_HOME" 755 "$ROOT_IDS"
  make_dir "$GRPC_ACME_HOME" 700 "$ROOT_IDS"
  make_dir "$GRPC_WEBROOT" 755 "$ROOT_IDS"
  make_dir "$GRPC_WEBROOT/.well-known" 755 "$ROOT_IDS"
  make_dir "$GRPC_WEBROOT/.well-known/acme-challenge" 755 "$ROOT_IDS"
  # acme.sh keeps its account and keys here: on rollback the whole tree goes.
  as_tree "$GRPC_ACME_HOME"
  local conf
  conf=$(grpc_nginx_conf acme) || exit 1
  write_file "$GRPC_NGINX_CONF" 644 "$ROOT_IDS" "$conf"$'\n'
  if ((WITH_WQ)); then
    # From here on, the Wallet Query's Nginx must be reloaded on rollback.
    NGINX_RELOAD_NEEDED=1
    nginx_test
    systemctl_do reload "$NGINX_SERVICE" || die "cannot reload $NGINX_SERVICE"
    wait_until "$NGINX_WAIT_SECONDS" "Nginx on TCP 80" nginx_https_ready
    return 0
  fi
  NGINX_TOUCHED=1
  nginx_test
  systemctl_do enable "$NGINX_SERVICE" || die "cannot enable $NGINX_SERVICE"
  systemctl_do restart "$NGINX_SERVICE" || die "cannot start $NGINX_SERVICE"
  wait_until "$NGINX_WAIT_SECONDS" "Nginx on TCP 80" nginx_ready
}

# challenge_served NAME TOKEN: Nginx serves the file NAME of the webroot,
# holding TOKEN, for DOMAIN on port 80 of this server.
challenge_served() {
  rm -f -- "$TX/challenge"
  run_step 30 curl --disable --silent --show-error --fail --noproxy '*' --max-redirs 0 \
    --connect-timeout 5 --max-time 10 --resolve "$DOMAIN:80:127.0.0.1" \
    --output "$TX/challenge" -- "http://$DOMAIN/.well-known/acme-challenge/$1" >&2 &&
    [[ $(<"$TX/challenge") == "$2" ]]
}

# grpc_check_challenge_path: as check_challenge_path, for this webroot.
# After a reload (next to Wallet Query, Nginx's listeners are there before),
# the workers may need a moment to serve the new host name: try again for
# up to GRPC_CHALLENGE_SECONDS.
grpc_check_challenge_path() {
  local token name=taritalk-check start=$SECONDS
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || token=''
  [[ $token =~ ^[0-9a-f]{32}$ ]] || token=$RANDOM$RANDOM$RANDOM
  write_file "$GRPC_WEBROOT/.well-known/acme-challenge/$name" 644 "$ROOT_IDS" "$token"$'\n'
  until challenge_served "$name" "$token"; do
    ((SECONDS - start < GRPC_CHALLENGE_SECONDS)) ||
      die "Nginx does not serve the certificate check for $DOMAIN on this server"
    checkpoint
    sleep 1
  done
  rm -f -- "$(sysroot "$GRPC_WEBROOT/.well-known/acme-challenge/$name")"
  unset 'CREATED[-1]'
  checkpoint
}

# grpc_install_acme_sh: as install_acme_sh, into this command's directory.
grpc_install_acme_sh() {
  local file=$TX/acme.sh dir
  step "downloading the certificate tool acme.sh $ACME_SH_VERSION"
  run_step "$DOWNLOAD_SECONDS" curl --disable --silent --show-error --fail --noproxy '*' \
    --proto =https --tlsv1.2 --max-redirs 0 --connect-timeout 15 --max-time 90 \
    --max-filesize "$MAX_ACME_SH_BYTES" --output "$file" -- "$ACME_SH_URL" >&2 ||
    die "cannot download acme.sh"
  [[ -f $file && $(stat -c %s -- "$file") -le $MAX_ACME_SH_BYTES ]] ||
    die "the downloaded acme.sh is not a file of the expected size"
  [[ $(sha256_of_file "$file") == "$ACME_SH_SHA256" ]] ||
    die "the downloaded acme.sh does not match its pinned SHA-256"
  make_dir "$GRPC_OPT" 755 "$ROOT_IDS"
  dir=$(sysroot "$GRPC_ACME_SH")
  (
    set -o noclobber
    umask 077
    cat -- "$file" >"$dir"
  ) 2>/dev/null || die "cannot install acme.sh"
  record file "$dir"
  { chown -- "$ROOT_IDS" "$dir" && chmod 755 "$dir"; } || die "cannot install acme.sh"
  CREATED[-1]="file $dir $(object_id file "$dir")"
  checkpoint
  [[ $(sha256_of_file "$dir") == "$ACME_SH_SHA256" ]] ||
    die "the installed acme.sh does not match its pinned SHA-256"
}

# grpc_acme ARGS...: as acme of lib/wallet-query.sh, with this command's
# acme.sh and home.
grpc_acme() {
  local home
  home=$(sysroot "$GRPC_ACME_HOME")
  run_step "$ACME_SECONDS" env -i PATH="$INSTALL_PATH" HOME="$home" LC_ALL=C \
    "$(sysroot "$GRPC_ACME_SH")" --home "$home" --config-home "$home" --server "$ACME_SERVER" \
    --no-color "$@" >&2 </dev/null
}

grpc_obtain_certificate() {
  local tls key chain
  step "getting a free ZeroSSL certificate for $DOMAIN (this can take a few minutes)"
  grpc_acme --register-account -m "$EMAIL" ||
    die "ZeroSSL did not accept the account for $EMAIL; check the address and try again later"
  grpc_acme --issue -d "$DOMAIN" --webroot "$(sysroot "$GRPC_WEBROOT")" --keylength ec-256 ||
    die "ZeroSSL did not issue a certificate for $DOMAIN; check that it points to this server and that inbound TCP port 80 is open, then try again"
  make_dir "$GRPC_TLS_DIR" 700 "$ROOT_IDS"
  as_tree "$GRPC_TLS_DIR"
  tls=$(sysroot "$GRPC_TLS_DIR")
  key=$tls/privkey.pem chain=$tls/fullchain.pem
  umask 077
  grpc_acme --install-cert -d "$DOMAIN" --ecc --key-file "$key" --fullchain-file "$chain" \
    --reloadcmd "systemctl reload $NGINX_SERVICE" ||
    die "acme.sh could not install the certificate"
  umask 022
  [[ -f $key && ! -L $key && -f $chain && ! -L $chain ]] ||
    die "the certificate files are missing after acme.sh"
  { chown -- "$ROOT_IDS" "$key" "$chain" && chmod 600 "$key" && chmod 644 "$chain"; } ||
    die "cannot set up the certificate files"
  openssl x509 -in "$chain" -noout -checkend 86400 >/dev/null 2>&1 ||
    die "the new certificate is not valid for at least another day"
  openssl x509 -in "$chain" -noout -ext subjectAltName 2>/dev/null |
    grep -qE "(^|[ ,])DNS:$DOMAIN(,|$)" || die "the new certificate is not for $DOMAIN"
  CERT_ISSUER=$(openssl x509 -in "$chain" -noout -issuer -nameopt utf8,esc_ctrl,sep_comma_plus_space 2>/dev/null) ||
    CERT_ISSUER=unknown
  CERT_END=$(openssl x509 -in "$chain" -noout -enddate 2>/dev/null) || CERT_END=unknown
  CERT_ISSUER=${CERT_ISSUER#issuer=} CERT_END=${CERT_END#notAfter=}
}

# grpc_call URL METHOD CURL_ARGS...: call METHOD (one that takes an empty
# request) of the BaseNode service at URL over HTTP/2 and print its gRPC
# status code; false if the answer is no gRPC answer over HTTP/2.
grpc_call() {
  local url=$1 method=$2 out line code=''
  shift 2
  rm -f -- "$TX/grpc.headers" "$TX/grpc.body"
  [[ -f $TX/grpc.request ]] || printf '\0\0\0\0\0' >"$TX/grpc.request" || return 1
  out=$(run_step "$GRPC_CALL_SECONDS" curl --disable --silent --show-error --noproxy '*' \
    --max-redirs 0 --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
    -H 'content-type: application/grpc' -H 'te: trailers' --data-binary "@$TX/grpc.request" \
    --dump-header "$TX/grpc.headers" --output "$TX/grpc.body" \
    --write-out '%{http_version} %{http_code}' "$@" -- "$url/$GRPC_SERVICE/$method" 2>/dev/null) ||
    return 1
  [[ $out == "2 200" ]] || return 1
  grep -qiE '^content-type: application/grpc' "$TX/grpc.headers" || return 1
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ ${line,,} =~ ^grpc-status:\ *([0-9]{1,2})$ ]]; then code=${BASH_REMATCH[1]}; fi
  done <"$TX/grpc.headers"
  [[ -n $code ]] || return 1
  printf '%s\n' "$code"
}

local_grpc() { grpc_call "http://127.0.0.1:$GRPC_PORT" "$1" --http2-prior-knowledge; }

public_grpc() {
  grpc_call "https://$DOMAIN" "$1" --proto =https --http2 --resolve "$DOMAIN:443:127.0.0.1"
}

# node_grpc_ready: the node runs, with gRPC on loopback only, answering.
node_grpc_ready() {
  node_ready && listening_on "$GRPC_PORT" 127.0.0.1 && [[ $(local_grpc GetVersion) == 0 ]]
}

# replace_node_config CONTENT: replace the node configuration atomically
# (same owner and mode), keeping its identity for rollback.
replace_node_config() {
  local path tmp
  path=$(sysroot "$NODE_CONFIG")
  tmp=$(mktemp "${path%/*}/.taritalk-grpc.XXXXXXXX") || return 1
  if ! { printf '%s' "$1" >"$tmp" && chown -- "$TARI_IDS" "$tmp" && chmod 600 "$tmp" &&
    mv --no-target-directory -- "$tmp" "$path"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

enable_node_grpc() {
  local config
  step "turning on the node's read-only gRPC (the node restarts once)"
  config=$(grpc_node_config) || exit 1
  # The configuration must still be the one checked before.
  [[ $(<"$(sysroot "$NODE_CONFIG")")$'\n' == "$NODE_CONFIG_ORIGINAL" ]] ||
    die "the node configuration changed while setting up gRPC"
  NODE_CONFIG_REPLACED=1
  replace_node_config "$config"$'\n' || die "cannot write '$NODE_CONFIG'"
  NODE_CONFIG_ID=$(object_id file "$(sysroot "$NODE_CONFIG")") || die "cannot inspect '$NODE_CONFIG'"
  checkpoint
  systemctl_do restart "$NODE_SERVICE" || die "cannot restart $NODE_SERVICE"
  wait_until "$NODE_WAIT_SECONDS" "the node's gRPC on 127.0.0.1:$GRPC_PORT" node_grpc_ready
  [[ $(local_grpc GetPeers) == 7 ]] ||
    die "the node's gRPC does not refuse methods outside the read-only list"
}

grpc_configure_https() {
  local conf
  step "turning on HTTPS for $DOMAIN"
  conf=$(grpc_nginx_conf https) || exit 1
  replace_file "$GRPC_NGINX_CONF" "$conf"$'\n'
  nginx_test
  systemctl_do reload "$NGINX_SERVICE" || die "cannot reload $NGINX_SERVICE"
  wait_until "$NGINX_WAIT_SECONDS" "Nginx on TCP 443" nginx_https_ready
}

grpc_enable_renewal() {
  local unit
  step "turning on automatic certificate renewal"
  unit=$(render_template taritalk-grpc-renew.service ACME_HOME "$GRPC_ACME_HOME" \
    ACME_SH "$GRPC_ACME_SH") || exit 1
  write_file "$GRPC_RENEW_SERVICE_FILE" 644 "$ROOT_IDS" "$unit"$'\n'
  RENEW_UNITS_CREATED=1
  unit=$(render_template taritalk-grpc-renew.timer) || exit 1
  write_file "$GRPC_RENEW_TIMER_FILE" 644 "$ROOT_IDS" "$unit"$'\n'
  systemctl_do daemon-reload || die "systemctl daemon-reload failed"
  TIMER_ENABLED=1
  systemctl_do enable "$GRPC_RENEW_TIMER" || die "cannot enable $GRPC_RENEW_TIMER"
  systemctl_do start "$GRPC_RENEW_TIMER" || die "cannot start $GRPC_RENEW_TIMER"
}

# verify_grpc: through Nginx, with a valid certificate (curl checks it
# against the system CAs) and HTTP/2, an allowed method answers and a
# method outside the list is refused by the node; the node still listens
# on loopback only, and Wallet Query (if set up) still answers.
verify_grpc() {
  local state unit code parsed
  step "checking Base Node gRPC over HTTPS"
  code=$(public_grpc GetVersion) || die "Base Node gRPC does not answer at $DOMAIN:443 on this server"
  [[ $code == 0 ]] || die "Base Node gRPC at $DOMAIN:443 refused get_version (gRPC status $code)"
  code=$(public_grpc GetPeers) || die "Base Node gRPC does not answer at $DOMAIN:443 on this server"
  [[ $code == 7 ]] || die "Base Node gRPC at $DOMAIN:443 does not refuse get_peers (gRPC status $code)"
  listening_on "$GRPC_PORT" 127.0.0.1 || die "the node's gRPC listens beyond 127.0.0.1:$GRPC_PORT"
  listening_on "$WALLET_QUERY_PORT" 127.0.0.1 ||
    die "the node's Wallet Query listens beyond 127.0.0.1:$WALLET_QUERY_PORT"
  if ((WITH_WQ)); then
    run_step 30 curl --disable --silent --show-error --fail --noproxy '*' --proto =https \
      --max-redirs 0 --connect-timeout 5 --max-time 20 --max-filesize "$MAX_TIP_INFO_BYTES" \
      --resolve "$GRPC_WQ_DOMAIN:443:127.0.0.1" --output "$TX/tip.json" \
      -- "https://$GRPC_WQ_DOMAIN/get_tip_info" >&2 ||
      die "Wallet Query no longer answers at https://$GRPC_WQ_DOMAIN"
    {
      parsed=$(jq -r "$JQ_TIP_INFO" <"$TX/tip.json" 2>/dev/null) &&
        [[ $parsed =~ ^(0|[123456789][0123456789]*)\ (true|false)$ ]]
    } || die "Wallet Query at https://$GRPC_WQ_DOMAIN gave an unexpected answer"
  fi
  for unit in "$NGINX_SERVICE" "$GRPC_RENEW_TIMER"; do
    state=$(run_step 30 systemctl is-active "$unit") || true
    [[ $state == active ]] || die "$unit is not active ($state)"
    state=$(run_step 30 systemctl is-enabled "$unit") || true
    [[ $state == enabled ]] || die "$unit is not enabled ($state)"
  done
}

write_grpc_state() {
  local now record pkg sum
  local -a pkgs=()
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the time"
  sum=$(sha256_of_file "$(sysroot "$NODE_CONFIG")") || die "cannot read '$NODE_CONFIG'"
  # Also what an earlier failed run installed for this setup.
  for pkg in "${RETRY_PACKAGES[@]}" "${PKGS_NEW[@]}"; do
    [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
  done
  # shellcheck disable=SC2153 # VERSION is the tool version (deploy.sh).
  printf -v record '%s=%s\n' format 1 tool_version "$VERSION" domain "$DOMAIN" \
    with_wallet_query "$WITH_WQ" grpc_address "127.0.0.1:$GRPC_PORT" \
    allowed_methods "$(
      IFS=,
      printf '%s' "${GRPC_METHODS[*]}"
    )" node_config_sha256 "$sum" acme_sh_version "$ACME_SH_VERSION" \
    acme_sh_sha256 "$ACME_SH_SHA256" default_site_disabled "$DEFAULT_SITE_REMOVED" \
    installed_at "$now" packages_installed "$(
      IFS=,
      printf '%s' "${pkgs[*]-}"
    )"
  write_file "$GRPC_STATE" 600 "$ROOT_IDS" "$record"
}

# --- rollback ----------------------------------------------------------------

# restore_node_config: put the configuration install wrote back (only over
# the one this run wrote) and restart the node with it.
restore_node_config() {
  local path now start
  path=$(sysroot "$NODE_CONFIG")
  if [[ -z $NODE_CONFIG_ID ]]; then
    # Never replaced: the node still runs with its configuration.
    [[ $(<"$path")$'\n' != "$NODE_CONFIG_ORIGINAL" ]] || return 0
  else
    now=$(object_id file "$path") || now=''
    if [[ $now != "$NODE_CONFIG_ID" ]]; then
      printf '%s: warning: %s was replaced; leaving it untouched\n' "$PROG" "$NODE_CONFIG" >&2
      CLEANUP_INCOMPLETE=1
      return 0
    fi
  fi
  if ! replace_node_config "$NODE_CONFIG_ORIGINAL"; then
    printf '%s: warning: cannot restore %s\n' "$PROG" "$NODE_CONFIG" >&2
    CLEANUP_INCOMPLETE=1
    return 0
  fi
  if ! quiet systemctl restart "$NODE_SERVICE"; then
    printf '%s: warning: cannot restart %s\n' "$PROG" "$NODE_SERVICE" >&2
    CLEANUP_INCOMPLETE=1
    return 0
  fi
  start=$SECONDS
  until node_back; do
    if ((SECONDS - start >= NODE_WAIT_SECONDS)); then
      printf '%s: warning: %s did not come back with its previous configuration\n' "$PROG" "$NODE_SERVICE" >&2
      CLEANUP_INCOMPLETE=1
      return 0
    fi
    sleep 1
  done
}

# node_back: during rollback, the node runs as before (never dies).
node_back() {
  [[ $(timeout --kill-after=2 30 systemctl is-active "$NODE_SERVICE" 2>/dev/null </dev/null) == active ]] &&
    listening_on "$P2P_PORT" 0.0.0.0 '[::]' && listening_on "$WALLET_QUERY_PORT" 127.0.0.1 &&
    port_free "$GRPC_PORT"
}

grpc_cleanup() {
  local rc=$?
  set +e
  trap '' HUP INT TERM
  ((GRPC_DONE)) && return 0
  ((${#CREATED[@]} > 0 || ${#PKGS_NEW[@]} > 0 || DEFAULT_SITE_REMOVED || NODE_CONFIG_REPLACED)) ||
    return 0
  printf '%s: gRPC setup failed; undoing the changes made by this run\n' "$PROG" >&2
  if ((TIMER_ENABLED)); then
    quiet systemctl stop "$GRPC_RENEW_TIMER"
    quiet systemctl disable "$GRPC_RENEW_TIMER"
  fi
  if ((NODE_CONFIG_REPLACED)); then restore_node_config; fi
  local i kind path id
  for ((i = ${#CREATED[@]} - 1; i >= 0; i--)); do
    read -r kind path id <<<"${CREATED[$i]}"
    case "$kind" in
      file | link) undo "$kind" "$path" "$id" rm -f -- "$path" ;;
      dir) undo dir "$path" "$id" rmdir -- "$path" ;;
      tree) undo tree "$path" "$id" remove_tree "$path" "$id" ;;
    esac
  done
  if ((DEFAULT_SITE_REMOVED)); then
    path=$(sysroot "$NGINX_DEFAULT_SITE")
    if exists "$path"; then
      printf '%s: warning: %s was recreated; leaving it untouched\n' "$PROG" "$NGINX_DEFAULT_SITE" >&2
      CLEANUP_INCOMPLETE=1
    elif ! ln -s -- "$DEFAULT_SITE_TARGET" "$path"; then
      printf '%s: warning: cannot restore %s\n' "$PROG" "$NGINX_DEFAULT_SITE" >&2
      CLEANUP_INCOMPLETE=1
    fi
  fi
  if ((RENEW_UNITS_CREATED)); then quiet systemctl daemon-reload; fi
  if ((NGINX_RELOAD_NEEDED)); then
    # The Wallet Query's Nginx, back to serving only Wallet Query.
    if ! quiet systemctl reload "$NGINX_SERVICE"; then
      printf '%s: warning: cannot reload %s; Wallet Query may be affected\n' "$PROG" "$NGINX_SERVICE" >&2
      CLEANUP_INCOMPLETE=1
    fi
  fi
  if ((NGINX_TOUCHED)); then
    # Nginx came with this run or an earlier failed one (any other web
    # server is refused): leave it stopped rather than serving anything.
    if ! quiet systemctl stop "$NGINX_SERVICE"; then
      printf '%s: warning: cannot stop %s\n' "$PROG" "$NGINX_SERVICE" >&2
      CLEANUP_INCOMPLETE=1
    fi
    quiet systemctl disable "$NGINX_SERVICE"
    if ((!CLEANUP_INCOMPLETE)) && exists "$(sysroot /etc/nginx)"; then
      if grpc_write_retry_record; then
        printf '%s: note: Nginx is kept, stopped; once the problem is fixed, run the gRPC setup again: it reuses this Nginx\n' "$PROG" >&2
      else
        printf '%s: warning: cannot write %s; Nginx must be removed by hand before trying again\n' \
          "$PROG" "$GRPC_RETRY_RECORD" >&2
        CLEANUP_INCOMPLETE=1
      fi
    fi
  fi
  if ((${#PKGS_NEW[@]} > 0)); then
    printf '%s: note: APT packages installed by this run are kept (removing packages could break the system): %s\n' \
      "$PROG" "${PKGS_NEW[*]}" >&2
  fi
  if ((CLEANUP_INCOMPLETE)); then
    printf '%s: warning: rollback was incomplete; see the warnings above\n' "$PROG" >&2
    ((!${MENU_MODE:-0})) ||
      menu_outcome "Base Node gRPC was not set up, and some of the changes made could not be undone."
  elif ((${MENU_MODE:-0})); then
    menu_outcome "Base Node gRPC was not set up; the changes made were undone and the node runs as before. Once the problem is fixed, you can choose 6 again."
  fi
  return "$rc"
}

# --- command -------------------------------------------------------------------

cmd_grpc() {
  local assume_yes=0
  DOMAIN='' EMAIL=''
  while (($# > 0)); do
    case "$1" in
      --domain | --email)
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "$1 requires a value"
        if [[ $1 == --domain ]]; then
          DOMAIN=$(normalize_domain "$2")
          check_domain "$DOMAIN" || usage_error "$DOMAIN_ERROR"
        else
          EMAIL=$2
          check_email "$EMAIL" || usage_error "$EMAIL_ERROR"
        fi
        shift 2
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      --help | -h)
        grpc_usage
        return 0
        ;;
      *)
        usage_error "unknown grpc option '$1'"
        ;;
    esac
  done
  if ! is_interactive; then
    [[ -n $DOMAIN ]] || usage_error "grpc needs --domain DOMAIN when not run interactively"
    [[ -n $EMAIL ]] || usage_error "grpc needs --email EMAIL when not run interactively"
  fi
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$INSTALL_PATH
  export PATH
  umask 022
  local cmd
  for cmd in "${GRPC_DEPENDENCIES[@]}"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
  check_install_platform
  [[ -n $INSTALL_SOURCE_DIR && -f $INSTALL_SOURCE_DIR/templates/grpc.conf ]] ||
    die "cannot locate the files of $PROG"
  check_grpc_host

  if [[ -z $DOMAIN ]]; then
    print_grpc_intro "$PUBLIC_IP"
    if ! ask_domain; then
      printf '\nCancelled; nothing was changed.\n'
      return 0
    fi
    ((!WITH_WQ)) || check_wallet_query_nginx
  fi
  check_dns "$DOMAIN" "$PUBLIC_IP"
  if [[ -z $EMAIL ]] && ! ask_email; then
    printf '\nCancelled; nothing was changed.\n'
    return 0
  fi
  printf '\n'
  print_grpc_plan
  if ((!assume_yes)); then
    local answer=''
    printf 'Set up Base Node gRPC over HTTPS? [y/N]: '
    IFS= read -r answer || answer=''
    if [[ $answer != y && $answer != Y ]]; then
      printf '\nCancelled; nothing was changed.\n'
      return 0
    fi
  fi

  trap grpc_cleanup EXIT
  install_signal_traps_deferred
  # Reusing the Nginx an earlier failed run kept: it is this setup's.
  if ((RETRY)) && exists "$(sysroot /etc/nginx)"; then NGINX_TOUCHED=1; fi
  make_work_dirs
  ((WITH_WQ)) || wq_install_packages
  grpc_configure_http
  grpc_check_challenge_path
  grpc_install_acme_sh
  grpc_obtain_certificate
  enable_node_grpc
  grpc_configure_https
  grpc_enable_renewal
  verify_grpc
  write_grpc_state
  # Set up: from here on a signal no longer rolls anything back.
  GRPC_DONE=1
  if ((RETRY)); then
    rm -f -- "$(sysroot "$GRPC_RETRY_RECORD")" ||
      printf "%s: warning: cannot remove '%s'\n" "$PROG" "$GRPC_RETRY_RECORD" >&2
  fi
  remove_work_dir

  if ((${MENU_MODE:-0})); then
    print_text <<DONE
Base Node gRPC is ready at $DOMAIN, port 443 (HTTPS, free ZeroSSL
certificate, renewed automatically). Only read-only calls are allowed; your
node answered through it. Keep inbound TCP ports 80 and 443 open, so that
gRPC clients can reach it and the certificate can be renewed.
DONE
    return 0
  fi
  print_text <<DONE
Base Node gRPC: $DOMAIN:443 (TLS, HTTP/2; service $GRPC_SERVICE)
Allowed methods: ${GRPC_METHODS[*]}
Backend: 127.0.0.1:$GRPC_PORT (loopback only; get_version answered, get_peers refused)
Certificate: $CERT_ISSUER, valid until $CERT_END
Renewal: $GRPC_RENEW_TIMER (active)
Nginx: $GRPC_NGINX_CONF$( ((WITH_WQ)) && printf ' (Wallet Query at %s unchanged)' "$GRPC_WQ_DOMAIN")
Keep inbound TCP 80 and 443 open; this tool did not change any firewall and
has not tested reachability from outside.
DONE
}
