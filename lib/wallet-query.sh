# shellcheck shell=bash
# wallet-query: makes the Wallet Query of a node installed by lib/install.sh
# reachable over HTTPS under the user's own domain name, as on TariTalk's
# public Wallet Query nodes: Nginx in front of 127.0.0.1:9000 (which stays
# loopback only) with a free ZeroSSL certificate from acme.sh, renewed by a
# systemd timer. Sourced by deploy.sh after lib/fetch.sh, lib/install.sh and
# lib/status.sh, whose layout, transaction record, rollback helpers and
# checks it reuses. Must be run as root; never escalates privileges itself.
#
# Like install, every change is recorded as it is made, and a failure or
# signal rolls back exactly what this run created (installed APT packages
# are kept). It never changes DNS, firewalls or cloud security groups.

# Internal settings. Tests that source this file may point them at a
# sandbox; the CLI offers no way to change them.
ACME_SH_URL=https://raw.githubusercontent.com/acmesh-official/acme.sh/3.1.1/acme.sh
ACME_SH_SHA256=e80e3e6d66ab02f7b448c55129c70ec57089a286d7df95282a68d607b4df7ed7
ACME_SERVER=zerossl
ACME_SECONDS=600
DOWNLOAD_SECONDS=120
NGINX_WAIT_SECONDS=30

readonly ACME_SH_VERSION=3.1.1
readonly MAX_ACME_SH_BYTES=1048576
readonly NGINX_SERVICE=nginx.service
readonly RENEW_SERVICE=taritalk-wallet-query-renew.service
readonly RENEW_TIMER=taritalk-wallet-query-renew.timer
readonly WQ_PACKAGES=(nginx openssl ca-certificates curl)
readonly WQ_DEPENDENCIES=(apt-get dpkg-query systemctl getent timeout curl jq openssl
  mktemp mkdir chmod chown cat mv ln rm rmdir stat sha256sum readlink date od tr sort grep
  find xargs cut)

# Fixed layout (real paths; every file system access adds $SYSROOT).
readonly WQ_HOME=/var/lib/taritalk-wallet-query
readonly WQ_STATE=/var/lib/taritalk-wallet-query/state
# After a failed setup that installed Nginx: what lets the next run reuse
# that Nginx (see write_retry_record).
readonly WQ_RETRY_RECORD=/var/lib/taritalk-wallet-query-retry
readonly NGINX_OWN_PACKAGES=(nginx nginx-common)
readonly WQ_ACME_HOME=/var/lib/taritalk-wallet-query/acme
readonly WQ_WEBROOT=/var/lib/taritalk-wallet-query/webroot
readonly WQ_OPT=/opt/taritalk-wallet-query
readonly WQ_ACME_SH=/opt/taritalk-wallet-query/acme.sh
readonly WQ_TLS_DIR=/etc/ssl/taritalk-wallet-query
readonly WQ_NGINX_CONF=/etc/nginx/conf.d/taritalk-wallet-query.conf
readonly NGINX_DEFAULT_SITE=/etc/nginx/sites-enabled/default
readonly RENEW_SERVICE_FILE=/etc/systemd/system/taritalk-wallet-query-renew.service
readonly RENEW_TIMER_FILE=/etc/systemd/system/taritalk-wallet-query-renew.timer
readonly SUBDOMAIN_HINT=nodes.taritalk.xyz

wallet_query_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD wallet-query [--domain DOMAIN] [--email EMAIL] [--yes]

Make the Wallet Query of the node installed by this tool reachable from the
internet over HTTPS at https://DOMAIN, as on TariTalk's public Wallet Query
nodes. Must be run as root; this tool itself never escalates privileges.

DOMAIN must be your own domain name (or a community subdomain from TariTalk,
see $SUBDOMAIN_HINT) whose DNS A record already points to the public IPv4
address given at install. Inbound TCP 80 and 443 must be open: ZeroSSL checks
the domain over port 80, and wallets use port 443.

It installs the APT packages nginx, openssl, ca-certificates and curl (only
those missing; nginx must not be installed yet), downloads acme.sh
$ACME_SH_VERSION from GitHub (checked against a pinned SHA-256) into $WQ_OPT,
registers a free ZeroSSL account for EMAIL, gets a certificate for DOMAIN
into $WQ_TLS_DIR, writes $WQ_NGINX_CONF
(replacing Nginx's default site) and enables $RENEW_TIMER.
The node keeps listening on 127.0.0.1:$WALLET_QUERY_PORT only; Nginx forwards the
read-only endpoints and /json_rpc to it, for any origin (CORS *).

It does not change the node, DNS, Cloudflare, firewalls or cloud security
groups. Before changing anything it shows the plan and asks once for
confirmation. On failure it rolls back what it created; installed packages
remain, with Nginx stopped. Once the problem is fixed it can simply be run
again: it reuses that Nginx if nothing in /etc/nginx changed meanwhile.
Running it again once Wallet Query is set up is refused.

Options:
  --domain DOMAIN  Domain name for the Wallet Query (asked for when run
                   interactively; required otherwise)
  --email EMAIL    Email address for the ZeroSSL account (expiry notices;
                   asked for when run interactively; required otherwise)
  --yes            Do not ask for confirmation (all checks still run)
  --help           Show this help and exit
USAGE
}

# check_domain NAME: true if NAME is a lower-case DNS host name of at least
# two labels (letters, digits and inner hyphens, at most 63 per label, 253
# in all) with an alphabetic or IDN top-level label; otherwise false with
# DOMAIN_ERROR set. Explicit character lists: ranges may match other
# characters in some locales.
check_domain() {
  local name=$1 label
  local -a labels
  DOMAIN_ERROR="'$name' is not a valid domain name (expected something like wallet.example.com)"
  [[ -n $name && ${#name} -le 253 && $name != *[!abcdefghijklmnopqrstuvwxyz0123456789.-]* ]] ||
    return 1
  [[ $name == *.* && $name != .* && $name != *. && $name != *..* ]] || return 1
  IFS=. read -r -a labels <<<"$name"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
  done
  label=${labels[-1]}
  [[ $label != *[!abcdefghijklmnopqrstuvwxyz]* || $label == xn--* ]] || return 1
  DOMAIN_ERROR=
}

# check_email ADDRESS: a plain user@domain address, at most 254 characters.
check_email() {
  local address=$1
  EMAIL_ERROR="'$address' is not a valid email address"
  [[ ${#address} -le 254 && $address == ?*@?* && $address != *@*@* ]] || return 1
  [[ ${address%@*} != *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._%+-]* ]] ||
    return 1
  check_domain "$(printf '%s' "${address#*@}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')" ||
    return 1
  EMAIL_ERROR=
}

# normalize_domain TEXT: TEXT without surrounding spaces, a trailing dot or
# upper case, as typed by a person.
normalize_domain() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  text=${text%.}
  printf '%s' "$text" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# trim TEXT: TEXT without surrounding spaces.
trim() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# --- read-only checks --------------------------------------------------------

# recorded_public_ip: the public IPv4 address install recorded (read as data).
recorded_public_ip() {
  local line ip=''
  local -a lines
  mapfile -t lines <"$(sysroot "$STATE_FILE")" || die "cannot read '$STATE_FILE'"
  for line in "${lines[@]}"; do
    if [[ $line == public_ip=* ]]; then ip=${line#public_ip=}; fi
  done
  check_public_ipv4 "$ip" || die "'$STATE_FILE' has no valid public_ip"
  printf '%s\n' "$ip"
}

# nginx_fingerprint: one SHA-256 over everything in /etc/nginx: each
# entry's path, type, mode, owner and link target, and each file's content.
nginx_fingerprint() {
  (
    cd -P -- "$(sysroot /etc/nginx)" 2>/dev/null || exit 1
    find . -printf '%P|%y|%m|%U|%G|%l\n' | LC_ALL=C sort &&
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | sha256sum | cut -c1-64
}

# read_retry_record: the record a failed run left (a private regular file
# of root, read as data). Sets RETRY_FINGERPRINT and RETRY_PACKAGES.
read_retry_record() {
  local path info line key
  local -a lines
  local -A seen=()
  path=$(sysroot "$WQ_RETRY_RECORD")
  [[ -f $path && ! -L $path ]] || die "'$WQ_RETRY_RECORD' is not a regular file"
  info=$(stat -c '%u %a %h %s' -- "$path") || die "cannot inspect '$WQ_RETRY_RECORD'"
  [[ ${info% *} == "${ROOT_IDS%%:*} 600 1" && ${info##* } -le 1024 ]] ||
    die "'$WQ_RETRY_RECORD' is not a private file of root"
  mapfile -t lines <"$path" || die "cannot read '$WQ_RETRY_RECORD'"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_]+)=([a-z0-9,.+-]*)$ && -z ${seen[${BASH_REMATCH[1]}]+x} ]] ||
      die "'$WQ_RETRY_RECORD' is not a record of $PROG"
    key=${BASH_REMATCH[1]}
    seen[$key]=${BASH_REMATCH[2]}
  done
  [[ ${seen[format]-} == 1 && ${seen[nginx_fingerprint]-} =~ ^[0-9a-f]{64}$ &&
    ${seen[packages_installed]-x} =~ ^([a-z0-9.+-]+(,[a-z0-9.+-]+)*)?$ ]] ||
    die "'$WQ_RETRY_RECORD' is not a record of $PROG"
  RETRY_FINGERPRINT=${seen[nginx_fingerprint]}
  IFS=, read -r -a RETRY_PACKAGES <<<"${seen[packages_installed]}"
}

# write_retry_record: after a rollback that leaves this run's Nginx in
# place (stopped, as its package installed it): remember it exactly, with
# the packages installed so far, so that the next run may reuse it.
write_retry_record() {
  local path tmp fp pkg
  local -a pkgs=()
  fp=$(nginx_fingerprint) && [[ $fp =~ ^[0-9a-f]{64}$ ]] || return 1
  for pkg in "${RETRY_PACKAGES[@]}" "${PKGS_NEW[@]}"; do
    [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
  done
  path=$(sysroot "$WQ_RETRY_RECORD")
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

# check_wallet_query_host: a node of this tool runs with its Wallet Query on
# loopback only, Wallet Query is not set up yet, and nothing else serves
# the web on this host. Read-only.
check_wallet_query_host() {
  local path pkg
  if exists "$(sysroot "$WQ_STATE")"; then
    die "Wallet Query is already set up on this server; setting it up again is not supported"
  fi
  check_install_state
  check_node_install
  listening_on "$WALLET_QUERY_PORT" 127.0.0.1 ||
    die "the node's local Wallet Query is not running, or not private to this server; check the node with '$USAGE_CMD status' first"
  for path in "$WQ_HOME" "$WQ_OPT" "$WQ_TLS_DIR" "$RENEW_SERVICE_FILE" "$RENEW_TIMER_FILE"; do
    ! exists "$(sysroot "$path")" || die "conflict: '$path' already exists"
  done
  RETRY=0
  if exists "$(sysroot "$WQ_RETRY_RECORD")"; then
    read_retry_record
    RETRY=1
  fi
  for pkg in nginx nginx-common nginx-core nginx-light nginx-full nginx-extras apache2 lighttpd caddy; do
    package_installed "$pkg" || continue
    # The Nginx an earlier failed run of this tool installed, and kept.
    ((RETRY)) && [[ " ${NGINX_OWN_PACKAGES[*]} " == *" $pkg "* ]] && continue
    die "a web server ($pkg) is already installed on this server; this tool sets up Wallet Query only on a server without one"
  done
  if exists "$(sysroot /etc/nginx)"; then
    ((RETRY)) || die "conflict: '/etc/nginx' already exists"
    [[ $(nginx_fingerprint) == "$RETRY_FINGERPRINT" ]] ||
      die "Nginx was changed after the last failed Wallet Query setup, so this tool does not take it over; restore it or remove it by hand"
    [[ $(timeout --kill-after=2 30 systemctl is-active "$NGINX_SERVICE" 2>/dev/null </dev/null) != active ]] ||
      die "Nginx was started after the last failed Wallet Query setup, so this tool does not take it over; stop it or remove it by hand"
  fi
  for path in 80 443; do
    port_free "$path" || die "TCP port $path is already in use on this server; this tool sets up Wallet Query only on a server where it is free"
  done
  for path in /etc /etc/ssl /etc/systemd/system /opt /var /var/lib; do
    check_system_dir "$path"
  done
  check_system_dir /tmp
}

# resolve_ipv4 NAME: the distinct IPv4 addresses NAME resolves to, sorted.
resolve_ipv4() {
  local out addr
  out=$(timeout --kill-after=2 15 getent ahostsv4 "$1" 2>/dev/null </dev/null) || return 0
  while read -r addr _; do
    [[ $addr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && printf '%s\n' "$addr"
  done <<<"$out" | sort -u
}

# check_dns DOMAIN IPV4: DOMAIN resolves to IPV4 and nothing else, so that
# ZeroSSL's check reaches this server.
check_dns() {
  local -a addrs
  mapfile -t addrs < <(resolve_ipv4 "$1")
  if ((${#addrs[@]} == 0)); then
    die "$1 does not point to this server yet (no DNS A record found); set its A record to $2, wait a few minutes and try again"
  fi
  if [[ ${#addrs[@]} != 1 || ${addrs[0]} != "$2" ]]; then
    die "$1 points to ${addrs[*]}, not to this server ($2); set its A record to $2, wait a few minutes and try again"
  fi
}

print_wallet_query_intro() {
  print_text <<INTRO
Wallet Query over HTTPS
  This makes your node's Wallet Query available to wallets and websites over
  HTTPS, like TariTalk's public Wallet Query nodes, with a free ZeroSSL
  certificate. It needs a domain name whose DNS A record points to this
  server ($1).
  No domain name? You can ask TariTalk for a free community subdomain (see
  $SUBDOMAIN_HINT). Come back here once it points to this server.

INTRO
}

# ask_domain: ask until a valid domain name is typed; empty input or end of
# input cancels (returns 1).
ask_domain() {
  local answer
  while true; do
    printf 'Domain name (press Enter without typing anything to cancel): '
    IFS= read -r answer || return 1
    answer=$(normalize_domain "$answer")
    [[ -n $answer ]] || return 1
    if check_domain "$answer"; then
      DOMAIN=$answer
      return 0
    fi
    printf '%s.\n' "$DOMAIN_ERROR"
  done
}

# ask_email: like ask_domain, for the ZeroSSL account's email address.
ask_email() {
  local answer
  while true; do
    printf 'Email address for the free ZeroSSL account (certificate notices; press Enter to cancel): '
    IFS= read -r answer || return 1
    answer=$(trim "$answer")
    [[ -n $answer ]] || return 1
    if check_email "$answer"; then
      EMAIL=$answer
      return 0
    fi
    printf '%s.\n' "$EMAIL_ERROR"
  done
}

print_wallet_query_plan() {
  if ((${MENU_MODE:-0})); then
    print_text <<PLAN
Wallet Query setup
  Domain:        $DOMAIN (points to this server, $PUBLIC_IP)
  Certificate:   free ZeroSSL certificate for $EMAIL, renewed automatically
  It installs Nginx and the certificate tool acme.sh, gets the certificate,
  and makes the Wallet Query available at $DOMAIN over HTTPS. The node
  itself is not changed and keeps its Wallet Query private to this server;
  Nginx passes on only the requests wallets need.
  Before you go on: inbound TCP ports 80 and 443 must be open in your
  firewall or cloud security group. This tool does not change them.
  Not changed:   DNS, firewalls and cloud security groups
PLAN
    return 0
  fi
  print_text <<PLAN
Wallet Query setup plan
  Domain:         $DOMAIN (DNS A record: $PUBLIC_IP)
  Public URL:     https://$DOMAIN (TCP 443; TCP 80 for the ZeroSSL check and redirects)
  Backend:        127.0.0.1:$WALLET_QUERY_PORT (unchanged, loopback only)
  Packages:       ${WQ_PACKAGES[*]} (only missing ones; no system upgrade)
  acme.sh:        $ACME_SH_VERSION from $ACME_SH_URL
                  (SHA-256 $ACME_SH_SHA256) into $WQ_ACME_SH
  Certificate:    ZeroSSL (ACME, HTTP-01, EC-256), account $EMAIL,
                  installed into $WQ_TLS_DIR
  Nginx:          $WQ_NGINX_CONF; the default site is disabled
  Renewal:        $RENEW_TIMER, daily: $RENEW_SERVICE runs acme.sh --cron
  Data:           $WQ_HOME
  Not changed:    the node, DNS, Cloudflare, firewalls, cloud security groups
PLAN
}

# --- steps ---------------------------------------------------------------------

WQ_DONE=0
DEFAULT_SITE_REMOVED=0 DEFAULT_SITE_TARGET=''
NGINX_TOUCHED=0 RENEW_UNITS_CREATED=0 TIMER_ENABLED=0
RETRY=0 RETRY_FINGERPRINT='' RETRY_PACKAGES=()

wq_install_packages() {
  local pkg
  for pkg in "${WQ_PACKAGES[@]}"; do
    package_installed "$pkg" || PKGS_NEW+=("$pkg")
  done
  ((${#PKGS_NEW[@]} > 0)) || return 0
  step "installing APT packages: ${PKGS_NEW[*]}"
  # From the package's own start on, Nginx may run.
  [[ " ${PKGS_NEW[*]} " != *" nginx "* ]] || NGINX_TOUCHED=1
  run_step "$APT_SECONDS" env DEBIAN_FRONTEND=noninteractive apt-get -q update >&2 ||
    die "apt-get update failed"
  run_step "$APT_SECONDS" env DEBIAN_FRONTEND=noninteractive apt-get -q -y \
    --no-install-recommends -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confdef install -- "${PKGS_NEW[@]}" >&2 ||
    die "apt-get install failed"
  for pkg in "${PKGS_NEW[@]}"; do
    package_installed "$pkg" || die "package $pkg is not installed after apt-get"
  done
}

# disable_default_site: the nginx package's default site also claims
# "listen 80 default_server"; take its link out of sites-enabled (restored
# on rollback). Only the package's own link is accepted.
disable_default_site() {
  local link target
  [[ -d $(sysroot /etc/nginx/conf.d) && ! -L $(sysroot /etc/nginx/conf.d) ]] ||
    die "'/etc/nginx/conf.d' is missing after installing nginx"
  grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
    "$(sysroot /etc/nginx/nginx.conf)" 2>/dev/null ||
    die "'/etc/nginx/nginx.conf' does not include /etc/nginx/conf.d/*.conf"
  link=$(sysroot "$NGINX_DEFAULT_SITE")
  exists "$link" || return 0
  [[ -L $link ]] || die "'$NGINX_DEFAULT_SITE' is not the nginx package's symlink"
  target=$(readlink -- "$link") || die "cannot read '$NGINX_DEFAULT_SITE'"
  [[ $target == /etc/nginx/sites-available/default || $target == ../sites-available/default ]] ||
    die "'$NGINX_DEFAULT_SITE' points to '$target', not to the package's default site"
  DEFAULT_SITE_TARGET=$target
  rm -f -- "$link" || die "cannot disable Nginx's default site"
  DEFAULT_SITE_REMOVED=1
  checkpoint
}

# nginx_new_http2: Nginx 1.25.1 and later want "http2 on;" instead of
# the "http2" listen parameter (Debian 12 has 1.22, Ubuntu 24.04 1.24).
nginx_new_http2() {
  local out major minor patch
  out=$(nginx -v 2>&1 </dev/null) || die "'nginx -v' failed"
  [[ $out =~ nginx/([0-9]+)\.([0-9]+)\.([0-9]+) ]] || die "cannot read the Nginx version"
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
  ((major > 1 || (major == 1 && (minor > 25 || (minor == 25 && patch >= 1)))))
}

# render_nginx NAME: templates/NAME for this domain and this Nginx.
render_nginx() {
  local text
  text=$(render_template "$1" DOMAIN "$DOMAIN" WEBROOT "$WQ_WEBROOT" TLS_DIR "$WQ_TLS_DIR") ||
    exit 1
  if ((NGINX_NEW_HTTP2)); then
    text=${text//"listen 443 ssl http2 default_server;"/"listen 443 ssl default_server;"$'\n'"    http2 on;"}
    text=${text//"listen 443 ssl http2;"/"listen 443 ssl;"$'\n'"    http2 on;"}
  fi
  printf '%s\n' "$text"
}

# as_tree PATH: the recorded directory PATH goes with its contents on
# rollback.
as_tree() {
  local i path
  path=$(sysroot "$1")
  for i in "${!CREATED[@]}"; do
    if [[ ${CREATED[$i]} == "dir $path "* ]]; then
      CREATED[i]="tree ${CREATED[$i]#dir }"
    fi
  done
}

# replace_file PATH CONTENT: replace a file this run created (recorded in
# CREATED) with new CONTENT, atomically, keeping the record current.
replace_file() {
  local path tmp i
  path=$(sysroot "$1")
  for i in "${!CREATED[@]}"; do
    [[ ${CREATED[$i]} == "file $path "* ]] && break
  done
  [[ ${CREATED[$i]} == "file $path $(object_id file "$path")" ]] ||
    die "'$1' changed while setting up Wallet Query"
  tmp=$(mktemp "${path%/*}/.taritalk-wallet-query.XXXXXXXX") || die "cannot write '$1'"
  record file "$tmp"
  if ! { printf '%s' "$2" >"$tmp" && chown -- "$ROOT_IDS" "$tmp" && chmod 644 "$tmp"; }; then
    die "cannot write '$1'"
  fi
  mv --no-target-directory -- "$tmp" "$path" || die "cannot replace '$1'"
  unset 'CREATED[-1]'
  CREATED[i]="file $path $(object_id file "$path")"
  checkpoint
}

nginx_test() {
  run_step 60 nginx -t -q >&2 || die "nginx -t rejected the configuration"
}

nginx_ready() {
  [[ $(run_step 30 systemctl is-active "$NGINX_SERVICE") == active ]] && listening_on 80 0.0.0.0
}

nginx_https_ready() { nginx_ready && listening_on 443 0.0.0.0; }

configure_http() {
  step "configuring Nginx for the certificate check"
  command -v nginx >/dev/null || die "nginx is missing after installing the nginx package"
  NGINX_NEW_HTTP2=0
  if nginx_new_http2; then NGINX_NEW_HTTP2=1; fi
  disable_default_site
  make_dir "$WQ_HOME" 755 "$ROOT_IDS"
  make_dir "$WQ_ACME_HOME" 700 "$ROOT_IDS"
  make_dir "$WQ_WEBROOT" 755 "$ROOT_IDS"
  make_dir "$WQ_WEBROOT/.well-known" 755 "$ROOT_IDS"
  make_dir "$WQ_WEBROOT/.well-known/acme-challenge" 755 "$ROOT_IDS"
  # acme.sh keeps its account and keys here: on rollback the whole tree goes.
  as_tree "$WQ_ACME_HOME"
  local conf
  conf=$(render_nginx wallet-query-acme.conf) || exit 1
  write_file "$WQ_NGINX_CONF" 644 "$ROOT_IDS" "$conf"$'\n'
  NGINX_TOUCHED=1
  nginx_test
  systemctl_do enable "$NGINX_SERVICE" || die "cannot enable $NGINX_SERVICE"
  systemctl_do restart "$NGINX_SERVICE" || die "cannot start $NGINX_SERVICE"
  wait_until "$NGINX_WAIT_SECONDS" "Nginx on TCP 80" nginx_ready
}

# check_challenge_path: a file in the webroot is served for DOMAIN on port
# 80 of this server, as ZeroSSL will fetch it (over loopback; reachability
# from the internet is ZeroSSL's own check).
check_challenge_path() {
  local token name=taritalk-check
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || token=''
  [[ $token =~ ^[0-9a-f]{32}$ ]] || token=$RANDOM$RANDOM$RANDOM
  write_file "$WQ_WEBROOT/.well-known/acme-challenge/$name" 644 "$ROOT_IDS" "$token"$'\n'
  run_step 30 curl --disable --silent --show-error --fail --noproxy '*' --max-redirs 0 \
    --connect-timeout 5 --max-time 10 --resolve "$DOMAIN:80:127.0.0.1" \
    --output "$TX/challenge" -- "http://$DOMAIN/.well-known/acme-challenge/$name" >&2 ||
    die "Nginx does not serve the certificate check for $DOMAIN on this server"
  [[ $(<"$TX/challenge") == "$token" ]] ||
    die "Nginx does not serve the certificate check for $DOMAIN on this server"
  rm -f -- "$(sysroot "$WQ_WEBROOT/.well-known/acme-challenge/$name")"
  unset 'CREATED[-1]'
  checkpoint
}

# install_acme_sh: download the pinned acme.sh, check its SHA-256 and
# install it read-only for root.
install_acme_sh() {
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
  make_dir "$WQ_OPT" 755 "$ROOT_IDS"
  dir=$(sysroot "$WQ_ACME_SH")
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

# acme ARGS...: run the installed acme.sh with its fixed home, a minimal
# environment and a time limit; its output goes to the technical details.
acme() {
  local home
  home=$(sysroot "$WQ_ACME_HOME")
  run_step "$ACME_SECONDS" env -i PATH="$INSTALL_PATH" HOME="$home" LC_ALL=C \
    "$(sysroot "$WQ_ACME_SH")" --home "$home" --config-home "$home" --server "$ACME_SERVER" \
    --no-color "$@" >&2 </dev/null
}

obtain_certificate() {
  local tls key chain
  step "getting a free ZeroSSL certificate for $DOMAIN (this can take a few minutes)"
  acme --register-account -m "$EMAIL" ||
    die "ZeroSSL did not accept the account for $EMAIL; check the address and try again later"
  acme --issue -d "$DOMAIN" --webroot "$(sysroot "$WQ_WEBROOT")" --keylength ec-256 ||
    die "ZeroSSL did not issue a certificate for $DOMAIN; check that it points to this server and that inbound TCP port 80 is open, then try again"
  make_dir "$WQ_TLS_DIR" 700 "$ROOT_IDS"
  as_tree "$WQ_TLS_DIR"
  tls=$(sysroot "$WQ_TLS_DIR")
  key=$tls/privkey.pem chain=$tls/fullchain.pem
  umask 077
  acme --install-cert -d "$DOMAIN" --ecc --key-file "$key" --fullchain-file "$chain" \
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
  # The same "O=..., CN=..." layout on every OpenSSL (3.0 defaults to "O = ...").
  CERT_ISSUER=$(openssl x509 -in "$chain" -noout -issuer -nameopt utf8,esc_ctrl,sep_comma_plus_space 2>/dev/null) ||
    CERT_ISSUER=unknown
  CERT_END=$(openssl x509 -in "$chain" -noout -enddate 2>/dev/null) || CERT_END=unknown
  CERT_ISSUER=${CERT_ISSUER#issuer=} CERT_END=${CERT_END#notAfter=}
}

configure_https() {
  local conf
  step "turning on HTTPS for $DOMAIN"
  conf=$(render_nginx wallet-query.conf) || exit 1
  replace_file "$WQ_NGINX_CONF" "$conf"$'\n'
  nginx_test
  systemctl_do reload "$NGINX_SERVICE" || die "cannot reload $NGINX_SERVICE"
  wait_until "$NGINX_WAIT_SECONDS" "Nginx on TCP 443" nginx_https_ready
}

enable_renewal() {
  local unit
  step "turning on automatic certificate renewal"
  unit=$(render_template taritalk-wallet-query-renew.service ACME_HOME "$WQ_ACME_HOME" \
    ACME_SH "$WQ_ACME_SH") || exit 1
  write_file "$RENEW_SERVICE_FILE" 644 "$ROOT_IDS" "$unit"$'\n'
  RENEW_UNITS_CREATED=1
  unit=$(render_template taritalk-wallet-query-renew.timer) || exit 1
  write_file "$RENEW_TIMER_FILE" 644 "$ROOT_IDS" "$unit"$'\n'
  systemctl_do daemon-reload || die "systemctl daemon-reload failed"
  TIMER_ENABLED=1
  systemctl_do enable "$RENEW_TIMER" || die "cannot enable $RENEW_TIMER"
  systemctl_do start "$RENEW_TIMER" || die "cannot start $RENEW_TIMER"
}

# verify_wallet_query: the public endpoint answers through Nginx with a
# valid certificate (curl checks it against the system CAs), and the node
# still listens on loopback only.
verify_wallet_query() {
  local state parsed unit
  step "checking Wallet Query over HTTPS"
  run_step 30 curl --disable --silent --show-error --fail --noproxy '*' --proto =https \
    --max-redirs 0 --connect-timeout 5 --max-time 20 --max-filesize "$MAX_TIP_INFO_BYTES" \
    --resolve "$DOMAIN:443:127.0.0.1" --output "$TX/tip.json" \
    -- "https://$DOMAIN/get_tip_info" >&2 ||
    die "Wallet Query does not answer at https://$DOMAIN on this server"
  parsed=$(jq -r "$JQ_TIP_INFO" <"$TX/tip.json" 2>/dev/null) ||
    die "Wallet Query at https://$DOMAIN gave an unexpected answer"
  [[ $parsed =~ ^(0|[123456789][0123456789]*)\ (true|false)$ ]] ||
    die "Wallet Query at https://$DOMAIN gave an unexpected answer"
  TIP_HEIGHT=${BASH_REMATCH[1]}
  listening_on "$WALLET_QUERY_PORT" 127.0.0.1 ||
    die "the node's Wallet Query listens beyond 127.0.0.1:$WALLET_QUERY_PORT"
  for unit in "$NGINX_SERVICE" "$RENEW_TIMER"; do
    state=$(run_step 30 systemctl is-active "$unit") || true
    [[ $state == active ]] || die "$unit is not active ($state)"
    state=$(run_step 30 systemctl is-enabled "$unit") || true
    [[ $state == enabled ]] || die "$unit is not enabled ($state)"
  done
}

write_wallet_query_state() {
  local now record
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the time"
  # shellcheck disable=SC2153 # VERSION is the tool version (deploy.sh).
  local pkg
  local -a pkgs=()
  # Also what an earlier failed run installed for this setup.
  for pkg in "${RETRY_PACKAGES[@]}" "${PKGS_NEW[@]}"; do
    [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
  done
  printf -v record '%s=%s\n' format 1 tool_version "$VERSION" domain "$DOMAIN" \
    acme_sh_version "$ACME_SH_VERSION" acme_sh_sha256 "$ACME_SH_SHA256" \
    default_site_disabled "$DEFAULT_SITE_REMOVED" installed_at "$now" \
    packages_installed "$(
      IFS=,
      printf '%s' "${pkgs[*]-}"
    )"
  write_file "$WQ_STATE" 600 "$ROOT_IDS" "$record"
}

# --- rollback ----------------------------------------------------------------

wq_cleanup() {
  local rc=$?
  set +e
  trap '' HUP INT TERM
  ((WQ_DONE)) && return 0
  ((${#CREATED[@]} > 0 || ${#PKGS_NEW[@]} > 0 || DEFAULT_SITE_REMOVED)) || return 0
  printf '%s: Wallet Query setup failed; undoing the changes made by this run\n' "$PROG" >&2
  if ((TIMER_ENABLED)); then
    quiet systemctl stop "$RENEW_TIMER"
    quiet systemctl disable "$RENEW_TIMER"
  fi
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
  if ((NGINX_TOUCHED)); then
    # Nginx came with this run or an earlier failed one (any other web
    # server is refused): leave it stopped rather than serving anything.
    if ! quiet systemctl stop "$NGINX_SERVICE"; then
      printf '%s: warning: cannot stop %s\n' "$PROG" "$NGINX_SERVICE" >&2
      CLEANUP_INCOMPLETE=1
    fi
    quiet systemctl disable "$NGINX_SERVICE"
    if ((!CLEANUP_INCOMPLETE)) && exists "$(sysroot /etc/nginx)"; then
      if write_retry_record; then
        printf '%s: note: Nginx is kept, stopped; once the problem is fixed, run the Wallet Query setup again: it reuses this Nginx\n' "$PROG" >&2
      else
        printf '%s: warning: cannot write %s; Nginx must be removed by hand before trying again\n' \
          "$PROG" "$WQ_RETRY_RECORD" >&2
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
      menu_outcome "Wallet Query was not set up, and some of the changes made could not be undone. The node was not changed."
  elif ((${MENU_MODE:-0})); then
    if ((NGINX_TOUCHED)); then
      menu_outcome "Wallet Query was not set up; the changes made were undone. The node was not changed. Once the problem is fixed, you can choose 5 again."
    else
      menu_outcome "Wallet Query was not set up; the changes made were undone. The node was not changed."
    fi
  fi
  return "$rc"
}

# --- command -------------------------------------------------------------------

cmd_wallet_query() {
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
        wallet_query_usage
        return 0
        ;;
      *)
        usage_error "unknown wallet-query option '$1'"
        ;;
    esac
  done
  if ! is_interactive; then
    [[ -n $DOMAIN ]] || usage_error "wallet-query needs --domain DOMAIN when not run interactively"
    [[ -n $EMAIL ]] || usage_error "wallet-query needs --email EMAIL when not run interactively"
  fi
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$INSTALL_PATH
  export PATH
  umask 022
  local cmd
  for cmd in "${WQ_DEPENDENCIES[@]}"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
  check_install_platform
  [[ -n $INSTALL_SOURCE_DIR && -f $INSTALL_SOURCE_DIR/templates/wallet-query.conf ]] ||
    die "cannot locate the files of $PROG"
  check_wallet_query_host
  PUBLIC_IP=$(recorded_public_ip) || exit 1

  if [[ -z $DOMAIN ]]; then
    print_wallet_query_intro "$PUBLIC_IP"
    if ! ask_domain; then
      printf '\nCancelled; nothing was changed.\n'
      return 0
    fi
  fi
  check_dns "$DOMAIN" "$PUBLIC_IP"
  if [[ -z $EMAIL ]] && ! ask_email; then
    printf '\nCancelled; nothing was changed.\n'
    return 0
  fi
  printf '\n'
  print_wallet_query_plan
  if ((!assume_yes)); then
    local answer=''
    printf 'Set up Wallet Query over HTTPS? [y/N]: '
    IFS= read -r answer || answer=''
    if [[ $answer != y && $answer != Y ]]; then
      printf '\nCancelled; nothing was changed.\n'
      return 0
    fi
  fi

  trap wq_cleanup EXIT
  install_signal_traps_deferred
  # Reusing the Nginx an earlier failed run kept: it is this setup's.
  if ((RETRY)) && exists "$(sysroot /etc/nginx)"; then NGINX_TOUCHED=1; fi
  make_work_dirs
  wq_install_packages
  configure_http
  check_challenge_path
  install_acme_sh
  obtain_certificate
  configure_https
  enable_renewal
  verify_wallet_query
  write_wallet_query_state
  # Set up: from here on a signal no longer rolls anything back.
  WQ_DONE=1
  rm -f -- "$(sysroot "$WQ_RETRY_RECORD")" ||
    printf "%s: warning: cannot remove '%s'\n" "$PROG" "$WQ_RETRY_RECORD" >&2
  remove_work_dir

  if ((${MENU_MODE:-0})); then
    print_text <<DONE
Wallet Query is ready at $DOMAIN over HTTPS (free ZeroSSL certificate,
renewed automatically). Your node answered through it at block $TIP_HEIGHT.
Keep inbound TCP ports 80 and 443 open, so that wallets can reach it and the
certificate can be renewed.
DONE
    return 0
  fi
  print_text <<DONE
Wallet Query: https://$DOMAIN (CORS: any origin)
Backend: 127.0.0.1:$WALLET_QUERY_PORT (loopback only; answered at block $TIP_HEIGHT)
Certificate: $CERT_ISSUER, valid until $CERT_END
Renewal: $RENEW_TIMER (active)
Nginx: $WQ_NGINX_CONF
Keep inbound TCP 80 and 443 open; this tool did not change any firewall and
has not tested reachability from outside.
DONE
}
