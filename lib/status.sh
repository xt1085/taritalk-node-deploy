# shellcheck shell=bash
# status and logs: read-only views of a node installed by lib/install.sh.
# Sourced by deploy.sh after lib/fetch.sh and lib/install.sh, whose fixed
# layout, root check and /proc/net port helpers they reuse. Both must be run
# as root and change nothing: no file is written, no service is changed, and
# the only network request is status's fixed loopback Wallet Query request.

# Internal settings. Tests that source this file may point them at a
# sandbox; the CLI offers no way to change them.
OPS_PATH=/usr/sbin:/usr/bin:/sbin:/bin
STATUS_PROBE_SECONDS=10
STATUS_SYSTEMCTL_SECONDS=10
STATUS_QUERY_SECONDS=10

readonly TIP_INFO_URL=http://127.0.0.1:9000/get_tip_info
readonly MAX_TIP_INFO_BYTES=65536
readonly BASE_LAYER_LOG=/var/log/tari/log/base_node/base_layer.log
readonly STATUS_DEPENDENCIES=(systemctl runuser env timeout curl jq stat readlink)
readonly LOGS_DEPENDENCIES=(tail stat)

# The Minotari 6 /get_tip_info answer: prints "HEIGHT SYNCED" only if
# metadata.best_block_height is a non-negative integer and is_synced a
# boolean; fails otherwise.
# shellcheck disable=SC2016 # $h is a jq variable, not shell.
readonly JQ_TIP_INFO='
  if type == "object" and (.metadata | type) == "object"
    and (.metadata.best_block_height | type) == "number"
    and (.is_synced | type) == "boolean"
  then
    .metadata.best_block_height as $h
    | if $h >= 0 and $h == ($h | floor) and $h < 1000000000000000
      then "\($h) \(.is_synced)" else error("invalid best_block_height") end
  else error("unexpected answer") end'

status_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD status

Show the state of the Minotari node installed by this tool.
Must be run as root; read-only: it writes no files and changes no services.

It reads only this host: '/opt/tari/current/minotari_node --version' (run as
user tari), systemctl state of minotari-mainnet.service, tor@default.service
and tor.service, the listening sockets in /proc/net/tcp and tcp6, and the
local Wallet Query service at $TIP_INFO_URL
(loopback only; nothing on the internet is contacted).

Fields: Version, Node service, Tor service, Restarts (systemd NRestarts),
Sync (syncing or synced, as the node reports it), Block height (the node's
own best block, not the network's), P2P listener (TCP 18189 on 0.0.0.0 or
[::]) and Wallet Query (127.0.0.1:9000 only). It does not test whether
18189 is reachable from the internet.

Exit status: 0 healthy (also while still syncing), 1 a check failed (every
field is still shown; the failures are listed on stderr) or the node was not
installed by this tool, 2 invalid usage.

Options:
  --help  Show this help and exit
USAGE
}

logs_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD logs [--lines N] [--follow]

Show the last lines of the node's log $BASE_LAYER_LOG
(with tail; no journal, no other or rotated log files, no filtering).
Must be run as root; read-only.

Options:
  --lines N  Number of lines to show, 1 to 1000 (default: 100)
  --follow   Keep printing new lines as they are written; stop with Ctrl+C
  --help     Show this help and exit
USAGE
}

# --- shared checks ---------------------------------------------------------

# ops_prepare DEPENDENCY...: after the argument checks, refuse non-root,
# then use a fixed PATH and require DEPENDENCY commands.
ops_prepare() {
  local cmd
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$OPS_PATH
  export PATH
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
}

# check_install_state: the install record of lib/install.sh must be a
# private regular file of root, and is read as data (never sourced). Sets
# INSTALLED_RELEASE_DIR.
check_install_state() {
  local state info line format=0 count=0 release_dir=''
  state=$(sysroot "$STATE_FILE")
  exists "$state" || die "'$STATE_FILE' is missing; no node installed by $PROG was found"
  [[ -f $state && ! -L $state ]] || die "'$STATE_FILE' is not a regular file"
  info=$(stat -c '%u %a %h' -- "$state") || die "cannot inspect '$STATE_FILE'"
  [[ $info == "${ROOT_IDS%%:*} 600 1" ]] ||
    die "'$STATE_FILE' is not a private file of root (owner, mode, links: $info)"
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      format=1) format=1 ;;
      release_dir=*)
        release_dir=${line#release_dir=}
        count=$((count + 1))
        ;;
    esac
  done <"$state" || die "cannot read '$STATE_FILE'"
  if ! ((format && count == 1)) || [[ ! $release_dir =~ ^$RELEASES_DIR/minotari-[A-Za-z0-9._-]+$ ]]; then
    die "'$STATE_FILE' is not an install record of $PROG"
  fi
  INSTALLED_RELEASE_DIR=$release_dir
}

# check_node_install: the installed release is in place.
check_node_install() {
  local link target bin
  link=$(sysroot "$CURRENT_LINK")
  [[ -L $link ]] || die "'$CURRENT_LINK' is missing or not a symlink"
  target=$(readlink -- "$link") || die "cannot read '$CURRENT_LINK'"
  [[ $target == "releases/${INSTALLED_RELEASE_DIR##*/}" ]] ||
    die "'$CURRENT_LINK' does not point to the installed release $INSTALLED_RELEASE_DIR"
  bin=$(sysroot "$INSTALLED_RELEASE_DIR/minotari_node")
  [[ -f $bin && ! -L $bin && -x $bin ]] ||
    die "'$INSTALLED_RELEASE_DIR/minotari_node' is missing or not an executable file"
  [[ -f $(sysroot "$UNIT_FILE") ]] || die "'$UNIT_FILE' is missing"
}

# --- status ------------------------------------------------------------------

# systemctl_read ARGS...: the output of a read-only, time-limited systemctl
# query (whatever its exit status).
systemctl_read() {
  timeout --kill-after=2 "$STATUS_SYSTEMCTL_SECONDS" systemctl "$@" 2>/dev/null </dev/null || true
}

# unit_word ARGS...: a systemctl answer that is a single state word, else
# "unknown".
unit_word() {
  local out
  out=$(systemctl_read "$@")
  [[ $out =~ ^[a-z][a-z-]*$ ]] || out=unknown
  printf '%s\n' "$out"
}

# probe_version: print the installed binary's version line, run as the
# service user with a minimal environment and a time limit.
probe_version() {
  local out version
  out=$(timeout --kill-after=2 "$STATUS_PROBE_SECONDS" runuser -u "$SERVICE_USER" -- \
    env -i PATH="$CHILD_PATH" HOME="$TARI_HOME" LC_ALL=C \
    "$(sysroot "$CURRENT_LINK/minotari_node")" --version 2>/dev/null </dev/null) || return 1
  [[ ${#out} -le 256 && $out =~ ^minotari_node\ ([^[:space:]]+)$ ]] || return 1
  version=${BASH_REMATCH[1]}
  [[ $version != v* && $version =~ $RE_RELEASE_VERSION ]] || return 1
  printf '%s\n' "$out"
}

# query_tip_info: ask the loopback Wallet Query service for the tip. Sets
# TIP_HEIGHT and TIP_SYNCED, or TIP_ERROR.
query_tip_info() {
  local body parsed rc=0
  TIP_HEIGHT='' TIP_SYNCED='' TIP_ERROR=''
  body=$(timeout --kill-after=2 "$STATUS_QUERY_SECONDS" curl --disable --silent --fail \
    --noproxy '*' --proto =http --max-redirs 0 --connect-timeout 2 --max-time 5 \
    --max-filesize "$MAX_TIP_INFO_BYTES" -- "$TIP_INFO_URL" 2>/dev/null </dev/null) || rc=$?
  case "$rc" in
    0) ;;
    28 | 124 | 137)
      TIP_ERROR="timed out"
      return 1
      ;;
    *)
      TIP_ERROR="failed (curl exit $rc)"
      return 1
      ;;
  esac
  TIP_ERROR="returned an invalid answer"
  ((${#body} <= MAX_TIP_INFO_BYTES)) || return 1
  parsed=$(printf '%s' "$body" | jq -r "$JQ_TIP_INFO" 2>/dev/null) || return 1
  [[ $parsed =~ ^(0|[123456789][0123456789]*)\ (true|false)$ ]] || return 1
  TIP_HEIGHT=${BASH_REMATCH[1]}
  TIP_SYNCED=${BASH_REMATCH[2]}
  TIP_ERROR=''
}

cmd_status() {
  while (($# > 0)); do
    case "$1" in
      --help | -h)
        status_usage
        return 0
        ;;
      *)
        usage_error "unknown status option '$1'"
        ;;
    esac
  done
  ops_prepare "${STATUS_DEPENDENCIES[@]}"
  check_install_state
  check_node_install

  # Collect every field first; a failed check is listed, not fatal.
  local -a problems=()
  local version node_active node_enabled tor_active tor_enabled restarts
  local sync=unknown height=unknown p2p wallet addr others=''
  local -a addrs
  version=$(probe_version) || {
    version=unknown
    problems+=("'minotari_node --version' failed or printed an unexpected version")
  }
  node_active=$(unit_word is-active "$NODE_SERVICE")
  node_enabled=$(unit_word is-enabled "$NODE_SERVICE")
  [[ $node_active == active ]] || problems+=("$NODE_SERVICE is not active ($node_active)")
  [[ $node_enabled == enabled ]] || problems+=("$NODE_SERVICE is not enabled ($node_enabled)")
  restarts=$(systemctl_read show "$NODE_SERVICE" -p NRestarts --value)
  [[ $restarts =~ ^(0|[123456789][0123456789]{0,9})$ ]] || {
    restarts=unknown
    problems+=("cannot read the restart count of $NODE_SERVICE")
  }
  tor_active=$(unit_word is-active "$TOR_SERVICE")
  tor_enabled=$(unit_word is-enabled "$TOR_MASTER_SERVICE")
  [[ $tor_active == active ]] || problems+=("$TOR_SERVICE is not active ($tor_active)")
  [[ $tor_enabled == enabled ]] || problems+=("$TOR_MASTER_SERVICE is not enabled ($tor_enabled)")

  p2p="not listening ($P2P_PORT)"
  mapfile -t addrs < <(port_listeners "$P2P_PORT")
  for addr in "${addrs[@]}"; do
    [[ $addr == 0.0.0.0 || $addr == '[::]' ]] && p2p="ready ($P2P_PORT)"
  done
  [[ $p2p == ready* ]] || problems+=("nothing listens on TCP $P2P_PORT on 0.0.0.0 or [::]")

  # The Wallet Query service must listen on 127.0.0.1 and nowhere else.
  # Other loopback ports the node opens are not checked.
  mapfile -t addrs < <(port_listeners "$WALLET_QUERY_PORT")
  for addr in "${addrs[@]}"; do
    [[ $addr == 127.0.0.1 ]] || others+="${others:+, }$addr:$WALLET_QUERY_PORT"
  done
  if [[ -n $others ]]; then
    wallet="unexpected listener ($others)"
    problems+=("TCP $WALLET_QUERY_PORT listens on addresses other than 127.0.0.1: $others")
  elif ((${#addrs[@]} == 0)); then
    wallet="not listening (127.0.0.1:$WALLET_QUERY_PORT)"
    problems+=("nothing listens on 127.0.0.1:$WALLET_QUERY_PORT")
  fi
  if [[ " ${addrs[*]} " == *" 127.0.0.1 "* ]]; then
    if query_tip_info; then
      height=$TIP_HEIGHT
      sync=syncing
      [[ $TIP_SYNCED == true ]] && sync=synced
      : "${wallet:=ready (127.0.0.1:$WALLET_QUERY_PORT)}"
    else
      problems+=("Wallet Query request to $TIP_INFO_URL $TIP_ERROR")
      : "${wallet:=no valid answer (127.0.0.1:$WALLET_QUERY_PORT)}"
    fi
  fi

  if ((${MENU_MODE:-0})); then
    print_plain_status
    return 0
  fi
  printf '%s\n' "Minotari node status" "Version: $version" \
    "Node service: $node_active ($node_enabled)" "Tor service: $tor_active ($tor_enabled)" \
    "Restarts: $restarts" "Sync: $sync" "Block height: $height" "P2P listener: $p2p" \
    "Wallet Query: $wallet"
  ((${#problems[@]} == 0)) && return 0
  local problem
  for problem in "${problems[@]}"; do
    printf '%s: error: %s\n' "$PROG" "$problem" >&2
  done
  exit 1
}

# print_plain_status: cmd_status's fields for the menu, in plain words
# (reads cmd_status's locals); any problem is summed up in one line.
# Whatever cmd_status counts as a problem is marked with (!).
print_plain_status() {
  local word p wallet_word
  # plain_state ACTIVE ENABLED: a service's state in words.
  plain_state() {
    if [[ $1 != active ]]; then
      printf 'not running (!)'
    elif [[ $2 != enabled ]]; then
      printf 'running, but it will not start again after a server restart (!)'
    else
      printf 'running'
    fi
  }
  word=$sync
  [[ $sync == unknown ]] || word="$sync, block $height"
  [[ $p2p == ready* ]] && p='accepting connections' || p='not listening (!)'
  [[ $wallet == ready* ]] && wallet_word=answering || wallet_word='not answering (!)'
  [[ $version != unknown ]] || version='unknown (!)'
  [[ $restarts != unknown ]] || restarts='unknown (!)'
  printf '%s\n' "Node status" "  Minotari:    ${version#minotari_node }" \
    "  Node:        $(plain_state "$node_active" "$node_enabled")" \
    "  Tor:         $(plain_state "$tor_active" "$tor_enabled")" \
    "  Sync:        $word" "  Restarts:    $restarts" "  Peers:       $p" \
    "  Wallet service (local): $wallet_word"
  if ((${#problems[@]} > 0)); then
    printf "\nSomething needs attention (marked with !). For the technical details run '%s status'.\n" "$USAGE_CMD"
    exit 1
  fi
}

# --- logs ----------------------------------------------------------------------

# check_log_file: the fixed log path consists of real directories and a
# regular file (no symlink anywhere below /var/log/tari).
check_log_file() {
  local dir path
  for dir in "$LOG_DIR" "$LOG_DIR/log" "$LOG_DIR/log/base_node"; do
    path=$(sysroot "$dir")
    # The node creates the folders below LOG_DIR when it first logs.
    [[ $dir == "$LOG_DIR" ]] || exists "$path" || ! ((${MENU_MODE:-0})) || no_log_yet
    [[ -d $path && ! -L $path ]] || die "'$dir' is not a directory"
  done
  path=$(sysroot "$BASE_LAYER_LOG")
  exists "$path" || no_log_yet "'$BASE_LAYER_LOG' does not exist (the node may not have logged yet)"
  [[ -f $path && ! -L $path ]] || die "'$BASE_LAYER_LOG' is not a regular file"
}

# no_log_yet [MESSAGE]: there is no log (yet); in the menu, said plainly.
no_log_yet() {
  if ((${MENU_MODE:-0})); then
    printf 'The node has not written a log yet; it usually does within a minute of starting. Try again in a minute.\n'
    exit 1
  fi
  die "$1"
}

cmd_logs() {
  local lines='' follow=0
  while (($# > 0)); do
    case "$1" in
      --lines)
        [[ -z $lines ]] || usage_error "--lines given more than once"
        # A following option (e.g. `--lines --follow`) is a missing value.
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "--lines requires a value"
        # ASCII digits only, whatever the locale; no sign or leading zero.
        if [[ $2 != [123456789]* || $2 == *[!0123456789]* || ${#2} -gt 4 ]] || ((10#$2 > 1000)); then
          usage_error "invalid --lines value (expected a whole number from 1 to 1000)"
        fi
        lines=$2
        shift 2
        ;;
      --follow)
        ((!follow)) || usage_error "--follow given more than once"
        follow=1
        shift
        ;;
      --help | -h)
        logs_usage
        return 0
        ;;
      *)
        usage_error "unknown logs option '$1'"
        ;;
    esac
  done
  ops_prepare "${LOGS_DEPENDENCIES[@]}"
  check_install_state
  check_log_file
  local -a args=(-n "${lines:-100}")
  ((follow)) && args+=(-F)
  # Replaced by tail: Ctrl+C ends it as it would end tail itself.
  exec tail "${args[@]}" -- "$(sysroot "$BASE_LAYER_LOG")"
}
