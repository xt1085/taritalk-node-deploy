# shellcheck shell=bash
# install: a conservative, audited fresh install of a Minotari Mainnet node
# on a clean Debian 12/13 or Ubuntu 24.04/26.04 host. Sourced by deploy.sh together with
# lib/fetch.sh (whose verified download, run as the unprivileged service
# user, it reuses). Must be run as root; never escalates privileges itself.
#
# Every system change is recorded as it is made, and a failure or signal
# rolls back exactly what this run created, each path re-checked by
# identity first (see install_cleanup).

# Internal settings. Tests that source this file may point them at a
# sandbox; the CLI offers no way to change them.
SYSROOT=
ROOT_IDS=0:0
INSTALL_PATH=/usr/sbin:/usr/bin:/sbin:/bin
CHILD_PATH=/usr/bin:/bin
INSTALL_SOURCE_DIR=
# The latest confirmed TariTalk Nodes submission, written by the submit
# command next to deploy.sh (in INSTALL_SOURCE_DIR) and removed by
# "Uninstall all".
# shellcheck disable=SC2034 # Used by the submit and uninstall commands.
SUBMISSION_ID_FILE=submission-id.txt
TOR_WAIT_SECONDS=60
NODE_WAIT_SECONDS=300
APT_SECONDS=1800
FETCH_SECONDS=7200
PROBE_SECONDS=30
SYSTEMCTL_SECONDS=300
TOR_VERIFY_SECONDS=60

readonly NODE_SERVICE=minotari-mainnet.service
readonly TOR_SERVICE=tor@default.service
readonly TOR_MASTER_SERVICE=tor.service
readonly SERVICE_USER=tari
readonly P2P_PORT=18189
readonly WALLET_QUERY_PORT=9000
readonly TOR_SOCKS_PORT=9050
readonly TOR_CONTROL_PORT=9051
readonly GRPC_PORT=18142
readonly INSTALL_PACKAGES=(ca-certificates curl jq unzip tor)
readonly INSTALL_DEPENDENCIES=(apt-get dpkg-query systemctl useradd groupadd
  userdel groupdel getent runuser timeout mktemp mkdir chmod chown cp cat mv ln
  rm rmdir stat sha256sum readlink realpath sleep date uname sort)

# Fixed layout (real paths; every file system access adds $SYSROOT).
readonly OPT_TARI=/opt/tari
readonly RELEASES_DIR=/opt/tari/releases
readonly CURRENT_LINK=/opt/tari/current
readonly TARI_HOME=/var/lib/tari
readonly NODE_BASE=/var/lib/tari/mainnet
readonly NODE_CONFIG_DIR=/var/lib/tari/mainnet/mainnet/config
readonly LOG_DIR=/var/log/tari
readonly UNIT_FILE=/etc/systemd/system/minotari-mainnet.service
readonly TORRC=/etc/tor/torrc
readonly STATE_FILE=/var/lib/tari/taritalk-install-state

install_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD install [--version VERSION] [--arch ARCH] [--public-ip IPV4] [--yes]

Install a Minotari Mainnet full node on a clean Debian 12 or 13, or
Ubuntu 24.04 or 26.04, host (aarch64/arm64 or x86_64/amd64).
Must be run as root; this tool itself
never escalates privileges (no sudo, su, doas or pkexec).

It installs the APT packages ca-certificates, curl, jq, unzip and tor from
the configured APT sources (only those missing; no system upgrade; on
Ubuntu, tor is in Universe, which those sources must already provide: no
repository or component is added), creates the system user 'tari',
downloads and verifies the release with '$USAGE_CMD fetch' run as that user,
installs it under /opt/tari, writes the node configuration under
/var/lib/tari, configures the system Tor for loopback use only, and starts
minotari-mainnet.service. P2P is public on TCP 18189; the Wallet Query
service listens on 127.0.0.1:9000 only; gRPC is disabled.

It does not change DNS, Nginx, TLS, Cloudflare, firewalls or cloud security
groups: allow TCP 18189 yourself. A started node has only begun syncing.

Before changing anything it shows the plan and asks once for confirmation.
On failure it rolls back what it created (installed packages may remain).

Options:
  --version VERSION  Release to install, e.g. 1.2.3 or v1.2.3-pre.4. Default:
                     GitHub's latest full (non-pre-release) release
  --arch ARCH        Architecture (default: uname -m)
  --public-ip IPV4   Public IPv4 address announced for P2P (asked for when
                     run interactively; required otherwise)
  --yes              Do not ask for confirmation (all checks still run)
  --help             Show this help and exit
USAGE
}

# is_root / is_interactive: separate so that tests can stand in for them.
is_root() { ((EUID == 0)); }
is_interactive() { [[ -t 0 && -t 1 ]]; }

# check_public_ipv4 ADDRESS: true if ADDRESS is a plain dotted-decimal IPv4
# address (ASCII digits and dots only, whatever the locale; no leading
# zeros, spaces, ports or paths) that is publicly routable; otherwise false
# with IPV4_ERROR set.
check_public_ipv4() {
  local ip=$1 o1 o2 o3 o4
  IPV4_ERROR=
  # Explicit character lists: ranges like [0-9] may match other digits in
  # some locales.
  if [[ -z $ip || $ip == *[!0123456789.]* ||
    ! $ip =~ ^(0|[123456789][0123456789]{0,2})\.(0|[123456789][0123456789]{0,2})\.(0|[123456789][0123456789]{0,2})\.(0|[123456789][0123456789]{0,2})$ ]]; then
    IPV4_ERROR="invalid public IPv4 address (expected four dot-separated decimal numbers)"
    return 1
  fi
  o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]}
  if ((o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255)); then
    IPV4_ERROR="invalid public IPv4 address (octet out of range)"
    return 1
  fi
  local kind=
  if ((o1 == 0)); then
    kind=unspecified
  elif ((o1 == 10 || (o1 == 172 && o2 >= 16 && o2 <= 31) || (o1 == 192 && o2 == 168))); then
    kind=private
  elif ((o1 == 100 && o2 >= 64 && o2 <= 127)); then
    kind="shared (carrier-grade NAT)"
  elif ((o1 == 127)); then
    kind=loopback
  elif ((o1 == 169 && o2 == 254)); then
    kind='link-local'
  elif ((o1 == 192 && o2 == 0 && o3 == 0)); then
    kind="IETF protocol assignment"
  elif ((o1 == 198 && (o2 == 18 || o2 == 19))); then
    kind=benchmarking
  elif ((o1 == 192 && o2 == 0 && o3 == 2)) || ((o1 == 198 && o2 == 51 && o3 == 100)) ||
    ((o1 == 203 && o2 == 0 && o3 == 113)); then
    kind="documentation (RFC 5737)"
  elif ((o1 >= 224 && o1 <= 239)); then
    kind=multicast
  elif ((o1 >= 240)); then
    kind="reserved or broadcast"
  fi
  if [[ -n $kind ]]; then
    IPV4_ERROR="$ip is a $kind address, not a public IPv4 address"
    return 1
  fi
}

# Services that answer with the IPv4 address a request comes from, tried in
# order. Asked only from the menu (detect_public_ipv4).
PUBLIC_IPV4_URLS=(https://api.ipify.org https://checkip.amazonaws.com)

# detect_public_ipv4: print this server's public IPv4 address as the first
# service that answers sees it; false (printing nothing) when curl is
# missing or no service gives a valid public IPv4 address in time.
detect_public_ipv4() {
  local url ip
  command -v curl >/dev/null || return 1
  for url in "${PUBLIC_IPV4_URLS[@]}"; do
    ip=$(timeout --kill-after=2 10 curl --disable --silent --fail --ipv4 \
      --noproxy '*' --proto =https --tlsv1.2 --max-redirs 0 --connect-timeout 4 \
      --max-time 6 --max-filesize 64 -- "$url" 2>/dev/null </dev/null) || continue
    if check_public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

# --- small helpers -----------------------------------------------------

# sysroot PATH: PATH inside $SYSROOT.
sysroot() { printf '%s%s\n' "$SYSROOT" "$1"; }

# step MESSAGE: progress on stderr, kept separate from the final summary.
# step TEXT: say which step runs (in the menu on stdout, kept for its
# failure report).
step() {
  if ((${MENU_MODE:-0})); then
    printf '==> %s\n' "$1"
    printf '%s\n' "$1" 2>/dev/null >"$MENU_DIR/step" || true
  else
    printf '==> %s\n' "$1" >&2
  fi
}

# menu_outcome TEXT: in the menu, how a failed command left the node,
# said first (the technical messages are kept back; see lib/menu.sh).
menu_outcome() {
  printf '%s\n' "$1"
  : 2>/dev/null >"$MENU_DIR/outcome" || true
}

# exists PATH: true if PATH exists in any form, including a dangling symlink.
exists() { [[ -e $1 || -L $1 ]]; }

# user_field DB NAME FIELD: print FIELD (1-based) of NAME's getent DB entry.
user_field() {
  local entry
  entry=$(getent "$1" "$2") || return 1
  [[ $entry != *$'\n'* ]] || return 1
  IFS=: read -r -a _fields <<<"$entry"
  printf '%s\n' "${_fields[$3 - 1]-}"
}

# tari_ids: print "UID:GID" of the service user.
tari_ids() {
  local uid gid
  uid=$(user_field passwd "$SERVICE_USER" 3) && gid=$(user_field passwd "$SERVICE_USER" 4) ||
    return 1
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s\n' "$uid" "$gid"
}

# port_listeners PORT: print the local address of every listening TCP
# socket on PORT, from /proc/net/tcp and tcp6 (no external tools).
port_listeners() {
  local hexport file local_addr st addr
  printf -v hexport '%04X' "$1"
  for file in "$(sysroot /proc/net/tcp)" "$(sysroot /proc/net/tcp6)"; do
    [[ -e $file ]] || continue
    [[ -r $file ]] || return 1
    while read -r _ local_addr _ st _; do
      [[ $st == 0A && ${local_addr##*:} == "$hexport" ]] || continue
      addr=${local_addr%:*}
      if ((${#addr} == 8)); then
        printf '%d.%d.%d.%d\n' "$((16#${addr:6:2}))" "$((16#${addr:4:2}))" \
          "$((16#${addr:2:2}))" "$((16#${addr:0:2}))"
      elif [[ $addr == 00000000000000000000000000000000 ]]; then
        printf '[::]\n'
      elif [[ $addr == 00000000000000000000000001000000 ]]; then
        printf '[::1]\n'
      else
        printf '[%s]\n' "$addr"
      fi
    done <"$file"
  done
}

# listening_on PORT ADDRESSES...: true if PORT has listeners and every one
# is in ADDRESSES (and the first of ADDRESSES is among them).
listening_on() {
  local port=$1 found=0 addr allowed ok
  shift
  local -a addrs
  mapfile -t addrs < <(port_listeners "$port") || return 1
  ((${#addrs[@]} > 0)) || return 1
  for addr in "${addrs[@]}"; do
    ok=0
    for allowed in "$@"; do
      [[ $addr == "$allowed" ]] && ok=1
    done
    ((ok)) || return 1
    [[ $addr == "$1" ]] && found=1
  done
  ((found))
}

# port_free PORT: true if nothing listens on TCP PORT.
port_free() {
  local out
  out=$(port_listeners "$1") || return 1
  [[ -z $out ]]
}

# processes_named COMM: true if a running process has command name COMM.
processes_named() {
  local dir comm
  for dir in "$(sysroot /proc)"/[0-9]*; do
    { read -r comm <"$dir/comm"; } 2>/dev/null || continue
    [[ $comm == "$1" ]] && return 0
  done
  return 1
}

# processes_of_uid UID: true if a running process has real or effective UID.
processes_of_uid() {
  local dir key real effective _rest
  for dir in "$(sysroot /proc)"/[0-9]*; do
    while read -r key real effective _rest; do
      [[ $key == Uid: ]] || continue
      [[ $real == "$1" || $effective == "$1" ]] && return 0
      break
    done 2>/dev/null <"$dir/status" || true
  done
  return 1
}

# --- transaction record -------------------------------------------------

# Everything this run creates, in order: "KIND PATH ID" with KIND one of
# dir, file, link, tree (a directory removed with its contents). Cleanup
# undoes them in reverse, only while PATH still has identity ID.
CREATED=()
INSTALL_DONE=0
CLEANUP_INCOMPLETE=0
WORK=''
TX=''
TOOL=''
DL=''
DL_TMP=''
PKGS_BEFORE=() PKGS_NEW=()
GROUP_CREATED=0 USER_CREATED=0
TORRC_REPLACED=0 TORRC_ID=
TOR_STARTED=0 TOR_MASTER_ENABLED=0
UNIT_CREATED=0 DAEMON_RELOADED=0 NODE_ENABLED=0 NODE_STARTED=0
DEFERRED_SIGNAL=

# object_id KIND PATH: the identity cleanup checks before removing PATH.
# Directories: device, inode, owner and type. Files and symlinks, which are
# never changed after creation, also their change time, so that a
# replacement which happens to reuse the inode number is still noticed.
object_id() {
  case "$1" in
    file | link) stat -c '%d:%i:%u:%F:%z' -- "$2" 2>/dev/null ;;
    *) path_id "$2" 2>/dev/null ;;
  esac
}

# record KIND PATH: remember a just-created PATH with its current identity.
record() {
  local id
  id=$(object_id "$1" "$2") || die "cannot inspect '$2' after creating it"
  CREATED+=("$1 $2 $id")
}

# Signals: while a child runs, forward and stop (lib/fetch.sh on_signal).
# Otherwise hold the signal until the current step has recorded what it
# created (checkpoint), so cleanup knows about everything.
install_signal() {
  if [[ -n ${ACTIVE_CHILD-} ]] || ((CHILD_STARTING)); then
    on_signal "$1" "$2"
    return 0
  fi
  DEFERRED_SIGNAL="$1 $2"
}

checkpoint() {
  if [[ -n $DEFERRED_SIGNAL ]]; then
    # shellcheck disable=SC2086 # "SIGNAL STATUS", split on purpose.
    on_signal $DEFERRED_SIGNAL
  fi
}

install_signal_traps_deferred() {
  trap 'install_signal HUP 129' HUP
  trap 'install_signal INT 130' INT
  trap 'install_signal TERM 143' TERM
}

# run_step SECONDS CMD...: run CMD as a tracked, time-limited child.
run_step() {
  checkpoint
  run_child "$@"
}

# make_dir PATH MODE OWNER: create PATH (which must not exist) and record it.
make_dir() {
  local path
  path=$(sysroot "$1")
  ! exists "$path" || die "'$1' already exists"
  mkdir -m 700 -- "$path" || die "cannot create '$1'"
  record dir "$path"
  chown -- "$3" "$path" || die "cannot set up '$1'"
  chmod -- "$2" "$path" || die "cannot set up '$1'"
  CREATED[-1]="dir $path $(object_id dir "$path")"
  checkpoint
}

# write_file PATH MODE OWNER CONTENT: create the new file PATH (never
# through an existing entry) with CONTENT, and record it.
write_file() {
  local path
  path=$(sysroot "$1")
  ! exists "$path" || die "'$1' already exists"
  (
    set -o noclobber
    umask 077
    printf '%s' "$4" >"$path"
  ) 2>/dev/null || die "cannot write '$1'"
  record file "$path"
  chown -- "$3" "$path" || die "cannot set up '$1'"
  chmod -- "$2" "$path" || die "cannot set up '$1'"
  CREATED[-1]="file $path $(object_id file "$path")"
  checkpoint
}

# --- templates -----------------------------------------------------------

# render_template NAME [PLACEHOLDER VALUE]...: print templates/NAME with each
# @PLACEHOLDER@ replaced literally. Only the given placeholders may occur,
# values are restricted to safe characters, and none may remain afterwards.
render_template() {
  local name=$1 text key value
  shift
  local file="$INSTALL_SOURCE_DIR/templates/$name"
  [[ -f $file && ! -L $file ]] || die "missing template $name"
  text=$(<"$file") || die "cannot read template $name"
  text+=$'\n'
  while (($# > 0)); do
    key=$1 value=$2
    shift 2
    [[ $key =~ ^[A-Z0-9_]+$ && $value =~ ^[0-9A-Za-z.:/_-]+$ ]] ||
      die "invalid template value for $key"
    text=${text//"@$key@"/"$value"}
  done
  [[ ! $text =~ @[A-Z0-9_]+@ ]] ||
    die "template $name has an unreplaced placeholder ${BASH_REMATCH[0]}"
  printf '%s' "$text"
}

# --- read-only checks ------------------------------------------------------

check_install_dependencies() {
  local cmd
  for cmd in "${INSTALL_DEPENDENCIES[@]}"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
}

check_install_platform() {
  local os_release
  os_release=$(sysroot /etc/os-release)
  [[ -e $os_release ]] || os_release=$(sysroot /usr/lib/os-release)
  read_os_release "$os_release"
  local supported="install supports Debian 12 and 13 and Ubuntu 24.04 and 26.04"
  case "$OS_ID" in
    debian)
      [[ $OS_VERSION_ID == 12 || $OS_VERSION_ID == 13 ]] ||
        die "unsupported Debian version '$OS_VERSION_ID' ($supported)"
      OS_NAME=Debian
      ;;
    ubuntu)
      [[ $OS_VERSION_ID == 24.04 || $OS_VERSION_ID == 26.04 ]] ||
        die "unsupported Ubuntu version '$OS_VERSION_ID' ($supported)"
      OS_NAME=Ubuntu
      ;;
    *)
      die "unsupported Linux distribution '$OS_ID' ($supported)"
      ;;
  esac
}

# check_system_dir PATH: PATH must be a real directory owned by root and not
# group- or world-writable (except a sticky /tmp, and Ubuntu's /var/log).
check_system_dir() {
  local path info
  path=$(sysroot "$1")
  [[ -d $path && ! -L $path ]] || die "unexpected host layout: '$1' is not a directory"
  info=$(stat -c '%u:%g %a' -- "$path") || die "cannot inspect '$1'"
  [[ ${info%% *} == "${ROOT_IDS%%:*}":* ]] || die "unexpected host layout: '$1' is not owned by root"
  if [[ $1 == /tmp ]]; then
    [[ ${info#* } == 1777 ]] || die "unexpected host layout: /tmp is not mode 1777"
  else
    ((!(8#${info#* } & 8#022))) || ubuntu_var_log "$1" "$info" ||
      die "unexpected host layout: '$1' is group- or world-writable"
  fi
}

# ubuntu_var_log PATH "UID:GID MODE": true for the one writable layout
# Ubuntu itself ships: /var/log of root, group syslog (rsyslog writes
# there), exactly 0775. Nothing else, and never on Debian.
ubuntu_var_log() {
  local name gid
  [[ $OS_ID == ubuntu && $1 == /var/log && ${2#* } == 775 ]] || return 1
  IFS=: read -r name _ gid _ <<<"$(getent group syslog)" || return 1
  [[ $name == syslog && $gid =~ ^[0-9]+$ && ${2%% *} == *:"$gid" ]]
}

# check_clean_host: refuse anything an earlier install, another Tari setup
# or another Tor use may own. Read-only.
check_clean_host() {
  local path
  if exists "$(sysroot "$STATE_FILE")"; then
    die "a Minotari node installed by $PROG already exists; reinstalling is not supported; to move to a newer release run '$USAGE_CMD upgrade'"
  fi
  for path in /etc/systemd/system/$NODE_SERVICE /etc/systemd/system/$NODE_SERVICE.d \
    /run/systemd/system/$NODE_SERVICE /lib/systemd/system/$NODE_SERVICE \
    /usr/lib/systemd/system/$NODE_SERVICE; do
    ! exists "$(sysroot "$path")" || die "conflict: '$path' already exists"
  done
  for path in "$OPT_TARI" "$TARI_HOME" "$LOG_DIR"; do
    ! exists "$(sysroot "$path")" ||
      die "conflict: '$path' already exists (only a clean host is supported)"
  done
  getent passwd "$SERVICE_USER" >/dev/null &&
    die "conflict: user '$SERVICE_USER' already exists"
  getent group "$SERVICE_USER" >/dev/null &&
    die "conflict: group '$SERVICE_USER' already exists"
  package_installed tor &&
    die "conflict: the tor package is already installed; an existing Tor setup is not taken over"
  for path in /etc/tor /var/lib/tor /run/tor; do
    ! exists "$(sysroot "$path")" ||
      die "conflict: '$path' exists; an existing Tor setup is not taken over"
  done
  processes_named tor && die "conflict: a Tor process is running"
  for path in "$P2P_PORT" "$WALLET_QUERY_PORT" "$TOR_SOCKS_PORT" "$TOR_CONTROL_PORT" "$GRPC_PORT"; do
    port_free "$path" || die "conflict: TCP port $path is already in use"
  done
  for path in /etc /etc/systemd/system /opt /var /var/lib /var/log; do
    check_system_dir "$path"
  done
  check_system_dir /tmp
}

# package_installed NAME: true if the APT (dpkg) package NAME is installed.
package_installed() {
  local status
  status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [[ $status == "install ok installed" ]]
}

print_install_plan() {
  local release=$1 ip=$2
  if ((${MENU_MODE:-0})); then
    [[ -n $VERSION_INPUT ]] || release="the latest official Minotari release"
    # shellcheck disable=SC2153 # PLATFORM is set by set_platform (deploy.sh).
    print_text <<PLAN
Minotari node installation
  This server:   $OS_NAME $OS_VERSION_ID, $PLATFORM
  Version:       $release
  Public IPv4:   $ip (other nodes connect to this address)
  It installs Tor and a few standard APT packages, creates a system user
  for the node, downloads and checks Minotari, and starts the node. The node
  then begins its first sync, which can take a long time.
  Not changed:   DNS, firewalls and cloud security groups
PLAN
    return 0
  fi
  # shellcheck disable=SC2153 # PLATFORM is set by set_platform (deploy.sh).
  print_text <<PLAN
Minotari node installation plan
  Host:           $OS_NAME $OS_VERSION_ID, $PLATFORM ($ARCH_INPUT)
  Release:        $release
  Public P2P:     $ip:$P2P_PORT (TCP, clearnet) and Tor via the system tor
  Packages:       ${INSTALL_PACKAGES[*]} (only missing ones; no system upgrade)
  Service user:   $SERVICE_USER (system user, no login shell), in group debian-tor
  Services:       $NODE_SERVICE, $TOR_SERVICE
  Directories:    $RELEASES_DIR/<release>, $CURRENT_LINK, $TARI_HOME, $LOG_DIR
  Configuration:  $NODE_CONFIG_DIR/config.toml, $TORRC
  Wallet Query:   127.0.0.1:$WALLET_QUERY_PORT only; gRPC disabled
  Tor:            SOCKS 127.0.0.1:$TOR_SOCKS_PORT and control 127.0.0.1:$TOR_CONTROL_PORT only
  Not changed:    DNS, Nginx, TLS, Cloudflare, firewalls, cloud security groups
PLAN
}

# --- installation steps ----------------------------------------------------

make_work_dirs() {
  local tmp
  tmp=$(sysroot /tmp)
  WORK=$(mktemp -d "$tmp/taritalk-install.XXXXXXXX") || die "cannot create a temporary directory"
  record tree "$WORK"
  checkpoint
  # Traversable but not listable: the service user reaches only tool/ and
  # its own download directories.
  chmod 711 "$WORK" || die "cannot set up '$WORK'"
  mkdir -m 700 "$WORK/tx" || die "cannot create '$WORK/tx'"
  TX=$WORK/tx
}

install_packages() {
  local pkg
  for pkg in "${INSTALL_PACKAGES[@]}"; do
    if package_installed "$pkg"; then PKGS_BEFORE+=("$pkg"); else PKGS_NEW+=("$pkg"); fi
  done
  printf 'packages already installed: %s\n' "${PKGS_BEFORE[*]-}" >"$TX/packages"
  ((${#PKGS_NEW[@]} > 0)) || return 0
  step "installing APT packages: ${PKGS_NEW[*]}"
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

# systemctl_do ARGS...: a time-limited systemctl call.
systemctl_do() {
  run_step "$SYSTEMCTL_SECONDS" systemctl "$@"
}

# The tor package starts Tor with its default configuration; stop it
# before anything is configured.
stop_packaged_tor() {
  local unit
  for unit in "$TOR_SERVICE" "$TOR_MASTER_SERVICE"; do
    systemctl_do stop "$unit" || die "cannot stop $unit after installing tor"
  done
  checkpoint
  processes_named tor && die "a Tor process is still running after stopping tor"
  local torrc info
  torrc=$(sysroot "$TORRC")
  [[ -f $torrc && ! -L $torrc ]] || die "'$TORRC' is not a regular file after installing tor"
  info=$(stat -c '%u %h' -- "$torrc") || die "cannot inspect '$TORRC'"
  [[ $info == "${ROOT_IDS%%:*} 1" ]] || die "'$TORRC' has an unexpected owner or link count"
  getent group debian-tor >/dev/null || die "group debian-tor is missing after installing tor"
}

create_service_account() {
  step "creating system user $SERVICE_USER"
  run_step 60 groupadd --system "$SERVICE_USER" || die "cannot create group $SERVICE_USER"
  GROUP_CREATED=1
  checkpoint
  run_step 60 useradd --system --gid "$SERVICE_USER" --groups debian-tor \
    --home-dir "$TARI_HOME" --no-create-home --shell /usr/sbin/nologin \
    "$SERVICE_USER" || die "cannot create user $SERVICE_USER"
  USER_CREATED=1
  checkpoint
  TARI_IDS=$(tari_ids) || die "cannot look up the new user $SERVICE_USER"
}

# prepare_fetch: a read-only, root-owned copy of the fetch tool that the
# service user can read (the checkout may be under /root), and private
# directories owned by the service user for the download.
prepare_fetch() {
  TOOL=$WORK/tool
  mkdir -m 755 "$TOOL" "$TOOL/lib" || die "cannot create '$TOOL'"
  if ! { cp -- "$INSTALL_SOURCE_DIR/deploy.sh" "$TOOL/deploy.sh" &&
    cp -- "$INSTALL_SOURCE_DIR/lib/fetch.sh" "$TOOL/lib/fetch.sh" &&
    chmod 755 "$TOOL/deploy.sh" && chmod 644 "$TOOL/lib/fetch.sh" &&
    chown -R -- "$ROOT_IDS" "$TOOL"; }; then
    die "cannot copy the fetch tool"
  fi
  DL=$WORK/dl
  DL_TMP=$WORK/dltmp
  mkdir -m 700 "$DL" "$DL_TMP" || die "cannot create the download directories"
  chown -- "$TARI_IDS" "$DL" "$DL_TMP" || die "cannot create the download directories"
  checkpoint
}

# fetch_as_service_user: run the real Phase 2 fetch as the service user and
# read its result.
fetch_as_service_user() {
  local -a args=(fetch --destination "$DL" --arch "$ARCH_INPUT")
  [[ -z $VERSION_INPUT ]] || args+=(--version "$VERSION_INPUT")
  step "downloading and verifying the release as user $SERVICE_USER"
  run_step "$FETCH_SECONDS" runuser -u "$SERVICE_USER" -- env -i PATH="$CHILD_PATH" \
    HOME="$TARI_HOME" LC_ALL=C TMPDIR="$DL_TMP" "$TOOL/deploy.sh" "${args[@]}" \
    >"$TX/fetch.out" || die "fetch failed"
  parse_fetch_output "$TX/fetch.out"
}

# parse_fetch_output FILE: strictly read fetch's "key: value" summary.
parse_fetch_output() {
  local line key value
  local -A seen=()
  local -a lines
  mapfile -t lines <"$1" || die "cannot read the fetch result"
  ((${#lines[@]} == 9)) || die "unexpected fetch output"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_0-9]+):\ ([^[:space:][:cntrl:]]+)$ ]] || die "unexpected fetch output"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -z ${seen[$key]-} ]] || die "unexpected fetch output"
    seen[$key]=1
    case "$key" in
      version_source) F_SOURCE=$value ;;
      tag) F_TAG=$value ;;
      version) F_VERSION=$value ;;
      platform) F_PLATFORM=$value ;;
      asset) F_ASSET=$value ;;
      archive_sha256) F_ARCHIVE_SHA256=$value ;;
      binary_sha256) F_BINARY_SHA256=$value ;;
      output_directory) F_OUTPUT=$value ;;
      fetch) [[ $value == verified ]] || die "fetch did not verify the release" ;;
      *) die "unexpected fetch output" ;;
    esac
  done
  [[ $F_TAG == "v$F_VERSION" && "v$F_VERSION" =~ $RE_RELEASE_VERSION &&
    $F_PLATFORM == "$PLATFORM" && $F_ARCHIVE_SHA256 =~ ^[0-9a-f]{64}$ &&
    $F_BINARY_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "unexpected fetch output"
  is_target_asset "$F_ASSET" "$F_VERSION" "$PLATFORM" || die "unexpected fetch output"
  if [[ -n $VERSION_INPUT ]]; then
    [[ $F_SOURCE == explicit && $F_TAG == "v${VERSION_INPUT#v}" ]] ||
      die "fetch returned another release than requested"
  else
    [[ $F_SOURCE == github-latest ]] || die "unexpected fetch output"
  fi
  local real_dl
  real_dl=$(realpath -e -- "$DL") || die "cannot resolve '$DL'"
  [[ $F_OUTPUT == "$real_dl/minotari-$F_VERSION-$PLATFORM" ]] ||
    die "fetch wrote to an unexpected directory"
}

# check_owned_regular PATH MODE: PATH is a regular file of the service user
# with exactly MODE and a single link.
check_owned_regular() {
  local info
  info=$(stat -c '%F|%a|%u:%g|%h' -- "$1" 2>/dev/null) ||
    die "refusing to install: '${1##*/}' is missing"
  [[ $info == "regular file|$2|$TARI_IDS|1" ]] ||
    die "refusing to install: '${1##*/}' is not a private regular file of $SERVICE_USER ($info)"
}

# verify_fetch_output: root re-checks the downloaded files before using them.
verify_fetch_output() {
  local out=$F_OUTPUT manifest="tari_suite-$F_VERSION.sha256-unsigned.txt"
  local info name expected record
  step "re-verifying the downloaded release"
  info=$(stat -c '%F|%a|%u:%g' -- "$out" 2>/dev/null) || die "refusing to install: the fetch output is missing"
  [[ $info == "directory|700|$TARI_IDS" ]] ||
    die "refusing to install: the fetch output directory is not private to $SERVICE_USER"
  local -a entries=()
  for name in "$out"/* "$out"/.[!.]* "$out"/..?*; do
    exists "$name" && entries+=("${name##*/}")
  done
  expected=$(printf '%s\n' "$F_ASSET" "$F_ASSET.sha256" minotari_node "$manifest" verification.txt | sort)
  [[ $(printf '%s\n' "${entries[@]}" | sort) == "$expected" ]] ||
    die "refusing to install: unexpected files in the fetch output"
  for name in "$manifest" "$F_ASSET.sha256" "$F_ASSET" verification.txt; do
    check_owned_regular "$out/$name" 600
  done
  check_owned_regular "$out/minotari_node" 700
  printf -v record '%s: %s\n' tag "$F_TAG" version "$F_VERSION" platform "$F_PLATFORM" \
    asset "$F_ASSET" manifest_url "$RELEASE_BASE_URL/$F_TAG/$manifest" \
    asset_url "$RELEASE_BASE_URL/$F_TAG/$F_ASSET" archive_sha256 "$F_ARCHIVE_SHA256" \
    binary_sha256 "$F_BINARY_SHA256"
  [[ $(<"$out/verification.txt") == "${record%$'\n'}" &&
  $(stat -c %s -- "$out/verification.txt") == "${#record}" ]] ||
    die "refusing to install: verification.txt does not match the verified release"
  VERIFICATION_RECORD=$record
  [[ $(sha256_of_file "$out/$F_ASSET") == "$F_ARCHIVE_SHA256" ]] ||
    die "refusing to install: $F_ASSET does not match its verified SHA-256"
  local -A CHECKSUMS
  parse_checksums "$out/$F_ASSET.sha256" "$F_ASSET.sha256"
  [[ ${#CHECKSUMS[@]} == 1 && ${CHECKSUMS[$F_ASSET]-} == "$F_ARCHIVE_SHA256" ]] ||
    die "refusing to install: $F_ASSET.sha256 does not match the verified archive"
  parse_checksums "$out/$manifest" "release manifest"
  [[ ${CHECKSUMS[$F_ASSET]-} == "$F_ARCHIVE_SHA256" ]] ||
    die "refusing to install: the release manifest does not match the verified archive"
}

# publish_release: copy the verified binary into a new root-owned release
# directory (its SHA-256 checked on the copy), then point current at it.
publish_release() {
  RELEASE_ID="minotari-$F_VERSION-$PLATFORM-${F_BINARY_SHA256:0:16}"
  RELEASE_DIR=$RELEASES_DIR/$RELEASE_ID
  step "installing Minotari $F_VERSION"
  make_dir "$OPT_TARI" 755 "$ROOT_IDS"
  make_dir "$RELEASES_DIR" 755 "$ROOT_IDS"
  local releases stage
  releases=$(sysroot "$RELEASES_DIR")
  stage=$(mktemp -d "$releases/.stage.XXXXXXXX") || die "cannot create a staging directory"
  record tree "$stage"
  checkpoint
  (
    set -o noclobber
    cat -- "$F_OUTPUT/minotari_node" >"$stage/minotari_node" &&
      printf '%s' "$VERIFICATION_RECORD" >"$stage/verification.txt"
  ) 2>/dev/null || die "cannot copy the verified binary"
  if ! { chown -- "$ROOT_IDS" "$stage/minotari_node" "$stage/verification.txt" "$stage" &&
    chmod 755 "$stage/minotari_node" "$stage" && chmod 644 "$stage/verification.txt"; }; then
    die "cannot set up the release directory"
  fi
  [[ $(sha256_of_file "$stage/minotari_node") == "$F_BINARY_SHA256" ]] ||
    die "refusing to install: the copied binary does not match its verified SHA-256"
  local target
  target=$(sysroot "$RELEASE_DIR")
  ! exists "$target" || die "'$RELEASE_DIR' already exists; refusing to overwrite"
  local stage_id
  stage_id=$(path_id "$stage") || die "cannot inspect the staging directory"
  mv --no-clobber --no-target-directory -- "$stage" "$target" 2>/dev/null || true
  exists "$stage" && die "cannot publish '$RELEASE_DIR'"
  CREATED[-1]="tree $target $stage_id"
  checkpoint
  [[ $(path_id "$target") == "$stage_id" ]] || die "'$RELEASE_DIR' changed while publishing"
  # current: a new symlink renamed into place (atomic; never a half link).
  local link tmp_link
  link=$(sysroot "$CURRENT_LINK")
  tmp_link=$(sysroot "$OPT_TARI/.current.$$")
  if exists "$link" || exists "$tmp_link"; then die "'$CURRENT_LINK' already exists"; fi
  ln -s -- "releases/$RELEASE_ID" "$tmp_link" || die "cannot create '$CURRENT_LINK'"
  record link "$tmp_link"
  mv --no-target-directory -- "$tmp_link" "$link" || die "cannot publish '$CURRENT_LINK'"
  # A rename changes the link's change time: record it as published.
  CREATED[-1]="link $link $(object_id link "$link")"
  checkpoint
  [[ $(readlink -- "$link") == "releases/$RELEASE_ID" ]] || die "'$CURRENT_LINK' is wrong"
}

# probe_binary_version: the first and only execution before the service
# starts, as the service user with a minimal environment and a time limit.
probe_binary_version() {
  local bin=$RELEASE_DIR/minotari_node output
  step "checking the downloaded Minotari program"
  run_step "$PROBE_SECONDS" runuser -u "$SERVICE_USER" -- env -i PATH="$CHILD_PATH" \
    HOME="$TARI_HOME" LC_ALL=C "$(sysroot "$bin")" --version \
    >"$TX/version.out" 2>/dev/null </dev/null || die "'minotari_node --version' failed"
  [[ $(stat -c %s -- "$TX/version.out") -le 256 ]] || die "unexpected 'minotari_node --version' output"
  output=$(<"$TX/version.out")
  [[ $output == "minotari_node $F_VERSION" ]] ||
    die "'minotari_node --version' does not report version $F_VERSION"
}

write_node_files() {
  local config log4rs
  step "writing the node configuration"
  config=$(render_template config.toml.in PUBLIC_IPV4 "$PUBLIC_IP") || exit 1
  log4rs=$(render_template log4rs.yml) || exit 1
  make_dir "$TARI_HOME" 750 "${ROOT_IDS%%:*}:${TARI_IDS#*:}"
  make_dir "$NODE_BASE" 700 "$TARI_IDS"
  make_dir "$NODE_BASE/mainnet" 700 "$TARI_IDS"
  make_dir "$NODE_CONFIG_DIR" 700 "$TARI_IDS"
  make_dir "$NODE_CONFIG_DIR/base_node" 700 "$TARI_IDS"
  write_file "$NODE_CONFIG_DIR/config.toml" 600 "$TARI_IDS" "$config"$'\n'
  write_file "$NODE_CONFIG_DIR/base_node/log4rs.yml" 600 "$TARI_IDS" "$log4rs"$'\n'
  make_dir "$LOG_DIR" 700 "$TARI_IDS"
  make_dir "$LOG_DIR/log" 700 "$TARI_IDS"
  make_dir "$LOG_DIR/log/base_node" 700 "$TARI_IDS"
  # The node creates its database and identities under $NODE_BASE on first
  # start; on a failed install that whole tree goes.
  local i
  for i in "${!CREATED[@]}"; do
    if [[ ${CREATED[$i]} == "dir $(sysroot "$NODE_BASE") "* ]]; then
      CREATED[i]="tree ${CREATED[$i]#dir }"
    fi
    if [[ ${CREATED[$i]} == "dir $(sysroot "$LOG_DIR") "* ]]; then
      CREATED[i]="tree ${CREATED[$i]#dir }"
    fi
  done
}

write_unit_file() {
  local unit
  unit=$(render_template minotari-mainnet.service) || exit 1
  write_file "$UNIT_FILE" 644 "$ROOT_IDS" "$unit"$'\n'
  UNIT_CREATED=1
}

# configure_tor: replace the package's default torrc (kept for rollback)
# and have tor verify the result as debian-tor.
configure_tor() {
  local torrc tmp content
  step "configuring Tor (for this node only)"
  torrc=$(sysroot "$TORRC")
  content=$(render_template torrc) || exit 1
  [[ -f $torrc && ! -L $torrc && $(stat -c %h -- "$torrc") == 1 ]] ||
    die "'$TORRC' is not a regular file"
  cp -- "$torrc" "$TX/torrc.orig" || die "cannot back up '$TORRC'"
  TORRC_ORIGINAL_ID=$(path_id "$torrc")
  tmp=$(mktemp "$torrc.taritalk.XXXXXXXX") || die "cannot write '$TORRC'"
  record file "$tmp"
  if ! { printf '%s\n' "$content" >"$tmp" && chown -- "$ROOT_IDS" "$tmp" && chmod 644 "$tmp"; }; then
    die "cannot write '$TORRC'"
  fi
  [[ $(path_id "$torrc") == "$TORRC_ORIGINAL_ID" ]] || die "'$TORRC' changed while configuring Tor"
  mv --no-target-directory -- "$tmp" "$torrc" || die "cannot replace '$TORRC'"
  TORRC_REPLACED=1
  TORRC_ID=$(object_id file "$torrc")
  unset 'CREATED[-1]'
  checkpoint
  run_step "$TOR_VERIFY_SECONDS" runuser -u debian-tor -- tor --verify-config \
    -f "$torrc" >"$TX/tor-verify.out" 2>&1 ||
    die "tor --verify-config rejected the configuration"
}

# wait_until SECONDS DESCRIPTION CHECK...: poll CHECK until true or timeout.
wait_until() {
  local secs=$1 what=$2 start=$SECONDS
  shift 2
  until "$@"; do
    ((SECONDS - start < secs)) || die "timed out after ${secs}s waiting for $what"
    checkpoint
    sleep 1
  done
}

tor_ports_ready() {
  listening_on "$TOR_SOCKS_PORT" 127.0.0.1 && listening_on "$TOR_CONTROL_PORT" 127.0.0.1
}

start_tor() {
  step "starting Tor"
  systemctl_do daemon-reload || die "systemctl daemon-reload failed"
  DAEMON_RELOADED=1
  # tor@default.service has no [Install] section: the enabled tor.service
  # (plus Debian's tor generator) starts it at boot.
  systemctl_do enable "$TOR_MASTER_SERVICE" || die "cannot enable $TOR_MASTER_SERVICE"
  TOR_MASTER_ENABLED=1
  checkpoint
  TOR_STARTED=1
  systemctl_do start "$TOR_SERVICE" || die "cannot start $TOR_SERVICE"
  wait_until "$TOR_WAIT_SECONDS" "Tor on 127.0.0.1:$TOR_SOCKS_PORT and :$TOR_CONTROL_PORT" tor_ports_ready
}

start_node() {
  step "starting the node"
  systemctl_do enable "$NODE_SERVICE" || die "cannot enable $NODE_SERVICE"
  NODE_ENABLED=1
  checkpoint
  NODE_STARTED=1
  systemctl_do start "$NODE_SERVICE" || die "cannot start $NODE_SERVICE"
}

# unit_value UNIT PROPERTY: print a systemd unit property.
unit_value() {
  run_step 30 systemctl show -p "$2" --value "$1"
}

node_ready() {
  [[ $(run_step 30 systemctl is-active "$NODE_SERVICE") == active ]] || {
    [[ $(unit_value "$NODE_SERVICE" NRestarts) == 0 ]] ||
      die "$NODE_SERVICE restarted while starting"
    return 1
  }
  listening_on "$P2P_PORT" 0.0.0.0 '[::]' && listening_on "$WALLET_QUERY_PORT" 127.0.0.1
}

# verify_install: the node and Tor run as configured.
verify_install() {
  step "waiting for the node to start (this can take a few minutes)"
  wait_until "$NODE_WAIT_SECONDS" "$NODE_SERVICE to listen" node_ready
  local state unit
  for unit in "$NODE_SERVICE" "$TOR_SERVICE"; do
    state=$(run_step 30 systemctl is-active "$unit") || true
    [[ $state == active ]] || die "$unit is not active ($state)"
  done
  state=$(run_step 30 systemctl is-enabled "$NODE_SERVICE") || true
  [[ $state == enabled ]] || die "$NODE_SERVICE is not enabled ($state)"
  state=$(run_step 30 systemctl is-enabled "$TOR_MASTER_SERVICE") || true
  [[ $state == enabled ]] || die "$TOR_MASTER_SERVICE is not enabled ($state)"
  state=$(run_step 30 systemctl is-enabled "$TOR_SERVICE") || true
  [[ $state == enabled || $state == enabled-runtime || $state == static ]] ||
    die "$TOR_SERVICE is not started at boot ($state)"
  [[ $(unit_value "$NODE_SERVICE" NRestarts) == 0 ]] || die "$NODE_SERVICE has restarted"
  port_free "$GRPC_PORT" || die "something listens on the gRPC port $GRPC_PORT"
  listening_on "$WALLET_QUERY_PORT" 127.0.0.1 ||
    die "the Wallet Query service listens beyond 127.0.0.1:$WALLET_QUERY_PORT"
  tor_ports_ready || die "Tor listens beyond 127.0.0.1"
  [[ $(readlink -- "$(sysroot "$CURRENT_LINK")") == "releases/$RELEASE_ID" ]] ||
    die "'$CURRENT_LINK' no longer points to $RELEASE_DIR"
  local pid exe exec_start
  pid=$(unit_value "$NODE_SERVICE" MainPID) || die "cannot read the $NODE_SERVICE main PID"
  [[ $pid =~ ^[1-9][0-9]*$ ]] || die "$NODE_SERVICE has no main process"
  exe=$(readlink -- "$(sysroot "/proc/$pid/exe")") || die "cannot inspect the $NODE_SERVICE process"
  [[ $exe == "$(sysroot "$RELEASE_DIR/minotari_node")" ]] ||
    die "the $NODE_SERVICE process does not run $RELEASE_DIR/minotari_node"
  exec_start=$(unit_value "$NODE_SERVICE" ExecStart) || die "cannot read the $NODE_SERVICE command"
  [[ $exec_start == *"path=$CURRENT_LINK/minotari_node ;"* ]] ||
    die "$NODE_SERVICE does not run $CURRENT_LINK/minotari_node"
}

write_state_record() {
  local now record
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the time"
  # shellcheck disable=SC2153 # VERSION is the tool version (deploy.sh).
  printf -v record '%s=%s\n' format 1 tool_version "$VERSION" tag "$F_TAG" \
    version "$F_VERSION" platform "$F_PLATFORM" asset "$F_ASSET" \
    archive_sha256 "$F_ARCHIVE_SHA256" binary_sha256 "$F_BINARY_SHA256" \
    release_dir "$RELEASE_DIR" public_ip "$PUBLIC_IP" installed_at "$now" \
    packages_installed "$(
      IFS=,
      printf '%s' "${PKGS_NEW[*]-}"
    )"
  write_file "$STATE_FILE" 600 "$ROOT_IDS" "$record"
}

# --- rollback ----------------------------------------------------------------

# undo KIND PATH ID ACTION...: run ACTION only while PATH still has
# identity ID.
undo() {
  local kind=$1 path=$2 id=$3 now
  shift 3
  if ! now=$(object_id "$kind" "$path"); then
    return 0
  fi
  if [[ $now != "$id" ]]; then
    printf '%s: warning: %s was replaced; leaving it untouched\n' "$PROG" "$path" >&2
    CLEANUP_INCOMPLETE=1
    return 0
  fi
  "$@" || {
    printf '%s: warning: cannot remove %s\n' "$PROG" "$path" >&2
    CLEANUP_INCOMPLETE=1
  }
}

# remove_tree PATH ID: remove PATH and its contents, never crossing into
# another file system and never following symlinks, after re-checking the
# identity from inside the parent directory.
remove_tree() {
  (
    cd -P -- "${1%/*}" 2>/dev/null || exit 1
    [[ $(path_id "${1##*/}") == "$2" ]] || exit 1
    rm -rf --one-file-system -- "./${1##*/}"
  )
}

quiet() { timeout "$SYSTEMCTL_SECONDS" "$@" >/dev/null 2>&1; }

install_cleanup() {
  local rc=$?
  set +e
  trap '' HUP INT TERM
  ((INSTALL_DONE)) && return 0
  ((${#CREATED[@]} > 0 || GROUP_CREATED || USER_CREATED)) || return 0
  printf '%s: installation failed; undoing the changes made by this run\n' "$PROG" >&2
  if ((NODE_STARTED)); then quiet systemctl stop "$NODE_SERVICE"; fi
  if ((NODE_ENABLED)); then quiet systemctl disable "$NODE_SERVICE"; fi
  if ((TOR_STARTED)) || [[ " ${PKGS_NEW[*]-} " == *" tor "* ]]; then
    # Started by this run, or by the tor package this run installed.
    quiet systemctl stop "$TOR_SERVICE" ||
      printf '%s: warning: cannot stop %s\n' "$PROG" "$TOR_SERVICE" >&2
  fi
  if ((TORRC_REPLACED)); then
    local torrc
    torrc=$(sysroot "$TORRC")
    if [[ $(object_id file "$torrc") == "$TORRC_ID" ]]; then
      if ! { cp -- "$TX/torrc.orig" "$torrc.taritalk-restore" &&
        chown -- "$ROOT_IDS" "$torrc.taritalk-restore" && chmod 644 "$torrc.taritalk-restore" &&
        mv --no-target-directory -- "$torrc.taritalk-restore" "$torrc"; }; then
        printf '%s: warning: cannot restore %s\n' "$PROG" "$TORRC" >&2
        CLEANUP_INCOMPLETE=1
      fi
    else
      printf '%s: warning: %s was changed; not restoring it\n' "$PROG" "$TORRC" >&2
      CLEANUP_INCOMPLETE=1
    fi
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
  if ((UNIT_CREATED || DAEMON_RELOADED)); then quiet systemctl daemon-reload; fi
  if ((USER_CREATED)); then
    if [[ -n ${TARI_IDS-} ]] && processes_of_uid "${TARI_IDS%%:*}"; then
      printf '%s: warning: processes of %s are running; keeping the user\n' "$PROG" "$SERVICE_USER" >&2
      CLEANUP_INCOMPLETE=1
    elif ((CLEANUP_INCOMPLETE)); then
      printf '%s: warning: keeping user %s because files may remain\n' "$PROG" "$SERVICE_USER" >&2
    else
      quiet userdel "$SERVICE_USER" ||
        printf '%s: warning: cannot remove user %s\n' "$PROG" "$SERVICE_USER" >&2
    fi
  fi
  if ((GROUP_CREATED)) && ! ((CLEANUP_INCOMPLETE)) && getent group "$SERVICE_USER" >/dev/null 2>&1; then
    quiet groupdel "$SERVICE_USER" ||
      printf '%s: warning: cannot remove group %s\n' "$PROG" "$SERVICE_USER" >&2
  fi
  if ((${#PKGS_NEW[@]} > 0)); then
    printf '%s: note: APT packages installed by this run are kept (removing packages could break the system): %s\n' \
      "$PROG" "${PKGS_NEW[*]}" >&2
    if ((TOR_MASTER_ENABLED)) || [[ " ${PKGS_NEW[*]} " == *" tor "* ]]; then
      printf '%s: note: the tor package keeps its default configuration and may start Tor at boot\n' "$PROG" >&2
    fi
  fi
  if ((CLEANUP_INCOMPLETE)); then
    printf '%s: warning: rollback was incomplete; see the warnings above\n' "$PROG" >&2
    ((!${MENU_MODE:-0})) ||
      menu_outcome "The node was not installed, and some of the changes made could not be undone."
  elif ((${MENU_MODE:-0})); then
    menu_outcome "The node was not installed; the changes made were undone."
  fi
  return "$rc"
}

# --- command -------------------------------------------------------------------

cmd_install() {
  local assume_yes=0
  VERSION_INPUT='' ARCH_INPUT='' PUBLIC_IP=''
  while (($# > 0)); do
    case "$1" in
      --version | --arch | --public-ip)
        # A following option (e.g. `--version --help`) is a missing value.
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "$1 requires a value"
        case "$1" in
          --version) VERSION_INPUT=$2 ;;
          --arch) ARCH_INPUT=$2 ;;
          --public-ip) PUBLIC_IP=$2 ;;
        esac
        shift 2
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      --help | -h)
        install_usage
        return 0
        ;;
      *)
        usage_error "unknown install option '$1'"
        ;;
    esac
  done
  if [[ -n $VERSION_INPUT ]]; then
    [[ ${#VERSION_INPUT} -le 64 && $VERSION_INPUT =~ $RE_RELEASE_VERSION ]] ||
      usage_error "invalid version (expected e.g. 1.2.3 or v1.2.3-pre.4)"
  fi
  case "$ARCH_INPUT" in
    '' | aarch64 | arm64 | x86_64 | amd64) ;;
    *) usage_error "unsupported architecture '$ARCH_INPUT' (supported: aarch64, arm64, x86_64, amd64)" ;;
  esac
  if [[ -n $PUBLIC_IP ]]; then
    check_public_ipv4 "$PUBLIC_IP" || usage_error "$IPV4_ERROR"
  elif ! is_interactive; then
    usage_error "install needs --public-ip IPV4 when not run interactively"
  fi
  # Only after all argument syntax is valid: runtime checks.
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$INSTALL_PATH
  export PATH
  umask 022
  check_install_dependencies
  if [[ -z $ARCH_INPUT ]]; then
    ARCH_INPUT=$(uname -m) || die "cannot determine architecture with 'uname -m'"
  fi
  set_platform "$ARCH_INPUT"
  check_install_platform
  [[ -n $INSTALL_SOURCE_DIR && -f $INSTALL_SOURCE_DIR/lib/fetch.sh ]] ||
    die "cannot locate the files of $PROG"
  check_clean_host
  if [[ -z $PUBLIC_IP ]]; then
    # From the menu, an address found out by asking the internet is
    # offered as the default; the command line asks nothing outside.
    local detected=''
    if ((${MENU_MODE:-0})) && detected=$(detect_public_ipv4); then
      printf 'Detected public IPv4 address: %s\n' "$detected"
      printf 'Public IPv4 address [%s]: ' "$detected"
    else
      printf 'Public IPv4 address: '
    fi
    IFS= read -r PUBLIC_IP || usage_error "no public IPv4 address given"
    [[ -n $PUBLIC_IP || -z $detected ]] || PUBLIC_IP=$detected
    check_public_ipv4 "$PUBLIC_IP" || usage_error "$IPV4_ERROR"
  fi
  local release="GitHub's latest full release (resolved and verified during installation)"
  [[ -z $VERSION_INPUT ]] || release="v${VERSION_INPUT#v} (explicit)"
  print_install_plan "$release" "$PUBLIC_IP"
  if ((!assume_yes)); then
    local answer=''
    printf 'Install the Minotari node? [y/N]: '
    IFS= read -r answer || answer=''
    if [[ $answer != y && $answer != Y ]]; then
      printf '\nInstallation cancelled; nothing was changed.\n'
      return 0
    fi
  fi

  trap install_cleanup EXIT
  install_signal_traps_deferred
  make_work_dirs
  install_packages
  stop_packaged_tor
  create_service_account
  prepare_fetch
  fetch_as_service_user
  verify_fetch_output
  publish_release
  probe_binary_version
  write_node_files
  write_unit_file
  configure_tor
  start_tor
  start_node
  verify_install
  write_state_record
  # Installed: from here on a signal no longer rolls anything back.
  INSTALL_DONE=1
  remove_work_dir

  if ((${MENU_MODE:-0})); then
    print_text <<DONE
Installed: Minotari $F_VERSION. The node is running and has started its first sync.
Next: allow inbound TCP port $P2P_PORT in your firewall or cloud security group,
so that other nodes can connect to yours. This tool did not change them.
DONE
    return 0
  fi
  print_text <<DONE
Installed: Minotari $F_VERSION ($F_PLATFORM)
Release directory: $RELEASE_DIR
Service: $NODE_SERVICE (active)
Public P2P address: $PUBLIC_IP:$P2P_PORT
Wallet Query: 127.0.0.1:$WALLET_QUERY_PORT (local only)
gRPC: disabled
Data directory: $NODE_BASE
The node has started its initial sync; it is not yet synced.
Allow inbound TCP $P2P_PORT in your cloud security group or firewall; this
tool did not change any firewall and has not tested reachability from outside.
DONE
}

remove_work_dir() {
  local entry kind path id
  entry=${CREATED[0]}
  read -r kind path id <<<"$entry"
  [[ $kind == tree && $path == "$WORK" ]] || return 0
  undo tree "$path" "$id" remove_tree "$path" "$id"
}
