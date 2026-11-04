#!/usr/bin/env bash
# deploy.sh: entry point of taritalk-node-deploy, an unofficial TariTalk
# community tool for ordinary Minotari Mainnet full nodes (not Tari Labs
# software). Early, non-production.
#
#   preflight  read-only platform check; no network requests, no writes.
#   fetch      downloads and verifies a Minotari release from Tari's
#              first-party GitHub Releases into a directory you choose
#              (lib/fetch.sh). It never installs a node, changes the system,
#              manages services, or needs root.
#   install    installs and starts a node on a clean Debian 12/13 or
#              Ubuntu 24.04/26.04 host
#              (lib/install.sh). Changes the system; must be run as root.
#   (none)     in a terminal, a simple menu for the commands below that
#              manage a node (lib/menu.sh).
#   status     read-only state of a node installed by this tool, and
#   logs       its base_layer.log (lib/status.sh); must be run as root.
#   upgrade    replaces the release of a node installed by this tool with a
#              newer one (lib/upgrade.sh); must be run as root.
#   uninstall  "Uninstall all": removes everything this tool installed: the
#              node and, if set up, Wallet Query, Base Node gRPC and their
#              Nginx (lib/uninstall.sh). Changes the system; must be run as
#              root.
#   wallet-query
#              makes that node's Wallet Query reachable over HTTPS under the
#              user's domain, with Nginx and a ZeroSSL certificate
#              (lib/wallet-query.sh). Changes the system; must be run as root.
#   grpc       publishes that node's restricted, read-only Base Node gRPC
#              over HTTPS (HTTP/2) under the user's domain, with Nginx and a
#              ZeroSSL certificate (lib/grpc.sh). Changes the system and the
#              node's configuration; must be run as root.
#   submit     offers that node to TariTalk Nodes, once, after showing what
#              is sent and asking for confirmation (lib/submit.sh). On this
#              host it only saves the confirmed submission ID next to this
#              script; must be run as root.
set -euo pipefail

readonly PROG=taritalk-node-deploy
readonly VERSION=0.1.0
readonly USAGE_CMD=./deploy.sh

# print_text: copy stdin (a here-document) to stdout using only builtins, so
# help works even when external tools are missing.
print_text() {
  local text
  IFS= read -r -d '' text || true
  printf '%s' "$text"
}

usage() {
  print_text <<USAGE
Usage: $USAGE_CMD <command> [options]
       $USAGE_CMD --help | --version
       $USAGE_CMD

Run without arguments in a terminal for a simple menu.

Unofficial TariTalk community tool for ordinary Minotari Mainnet full nodes.
Not Tari Labs software. Early, non-production.

Commands:
  preflight   Read-only platform check; makes no network requests
              and changes nothing
  fetch       Download and verify a Minotari release from Tari's
              first-party GitHub Releases into a directory you choose
              (see '$USAGE_CMD fetch --help'; does not install a node)
  install     Install and start a Minotari Mainnet node on a clean
              Debian 12/13 or Ubuntu 24.04/26.04 host; run as root
              (see '$USAGE_CMD install --help')
  status      Show the state of the installed node; read-only, run as root
              (asks only the node's local Wallet Query, never the internet)
  logs        Show the node's base_layer.log; read-only, run as root
              (see '$USAGE_CMD logs --help')
  upgrade     Upgrade the installed node to a newer Minotari release; run
              as root (see '$USAGE_CMD upgrade --help')
  uninstall   Uninstall all: remove the node installed by this tool with its
              data and its Tor, and the Wallet Query, Base Node gRPC and
              Nginx this tool set up; run as root
              (see '$USAGE_CMD uninstall --help')
  wallet-query
              Make the node's Wallet Query reachable over HTTPS at your
              domain, with Nginx and a free ZeroSSL certificate; run as
              root (see '$USAGE_CMD wallet-query --help')
  grpc        Make the node's read-only Base Node gRPC reachable over HTTPS
              (HTTP/2) at your domain, with Nginx and a free ZeroSSL
              certificate; run as root (see '$USAGE_CMD grpc --help')
  submit      Offer the installed node to TariTalk Nodes, once, after
              showing what is sent and asking for confirmation; run as
              root (see '$USAGE_CMD submit --help')

Options:
  --help      Show this help and exit
  --version   Show the version and exit
USAGE
}

preflight_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD preflight [--os-release FILE] [--arch ARCH]

Read-only check that this host is a supported platform. Nothing is installed,
written, or contacted over the network.

Options:
  --os-release FILE  OS metadata file to check
                     (default: /etc/os-release, else /usr/lib/os-release)
  --arch ARCH        Machine architecture to check (default: uname -m)
  --help             Show this help and exit

Supported: Debian 12 or 13, or Ubuntu 24.04 or 26.04, on aarch64/arm64 or x86_64/amd64.
USAGE
}

# die MESSAGE: report a failed check and exit 1.
die() {
  printf '%s: error: %s\n' "$PROG" "$1" >&2
  exit 1
}

# usage_error MESSAGE: report invalid command-line usage and exit 2.
usage_error() {
  printf '%s: error: %s\n' "$PROG" "$1" >&2
  printf "Try '%s --help' for more information.\n" "$USAGE_CMD" >&2
  exit 2
}

# os-release(5) syntax. Values may be double-quoted (with backslash escapes),
# single-quoted, or bare words without shell metacharacters.
readonly RE_ASSIGNMENT='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
readonly RE_DOUBLE_QUOTED='^"(([^"\\$`]|\\.)*)"$'
readonly RE_SINGLE_QUOTED="^'([^']*)'$"
readonly RE_BARE_WORD='^[A-Za-z0-9._:/@%+,-]*$'
readonly RE_ID='^[a-z0-9._-]+$'
readonly RE_VERSION_ID='^[A-Za-z0-9._~-]+$'

malformed() {
  die "malformed OS metadata in '$1'${2:+ line $2}: $3"
}

# read_os_release FILE: set OS_ID and OS_VERSION_ID from FILE. The file is
# parsed as data and never sourced or executed. Fails closed on any line that
# is not valid os-release syntax, on duplicate keys, and on missing or invalid
# ID / VERSION_ID values.
read_os_release() {
  local file=$1 line key raw value lineno=0
  local -a lines
  local -A seen=()
  OS_ID=
  OS_VERSION_ID=
  [[ -f $file && -r $file ]] ||
    die "missing OS metadata: cannot read '$file'"

  # Bash strings cannot hold NUL bytes and silently drop them, so check the
  # raw file first: `read -d ''` succeeds only if it reaches a NUL delimiter.
  if IFS= read -r -d '' _ <"$file"; then
    malformed "$file" "" "contains NUL byte"
  fi
  mapfile -t lines <"$file" || die "missing OS metadata: cannot read '$file'"
  for line in "${lines[@]}"; do
    lineno=$((lineno + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ $line =~ $RE_ASSIGNMENT ]] ||
      malformed "$file" "$lineno" "expected KEY=VALUE"
    key=${BASH_REMATCH[1]}
    raw=${BASH_REMATCH[2]}
    if [[ $raw =~ $RE_DOUBLE_QUOTED || $raw =~ $RE_SINGLE_QUOTED ]]; then
      value=${BASH_REMATCH[1]}
    elif [[ $raw =~ $RE_BARE_WORD ]]; then
      value=$raw
    else
      malformed "$file" "$lineno" "invalid quoting or characters in $key"
    fi
    [[ -z ${seen[$key]-} ]] || malformed "$file" "$lineno" "duplicate $key"
    seen[$key]=1
    case "$key" in
      ID) OS_ID=$value ;;
      VERSION_ID) OS_VERSION_ID=$value ;;
    esac
  done

  [[ -n ${seen[ID]-} ]] || die "missing OS metadata: no ID in '$file'"
  [[ -n ${seen[VERSION_ID]-} ]] ||
    die "missing OS metadata: no VERSION_ID in '$file'"
  [[ $OS_ID =~ $RE_ID ]] || malformed "$file" "" "invalid ID value"
  [[ $OS_VERSION_ID =~ $RE_VERSION_ID ]] ||
    malformed "$file" "" "invalid VERSION_ID value"
}

# set_platform ARCH: set PLATFORM to the Tari release asset platform for ARCH.
set_platform() {
  case "$1" in
    aarch64 | arm64) PLATFORM=linux-arm64 ;;
    x86_64 | amd64) PLATFORM=linux-x86_64 ;;
    *) die "unsupported architecture '$1' (supported: aarch64, arm64, x86_64, amd64)" ;;
  esac
}

cmd_preflight() {
  local os_release='' arch=''
  while (($# > 0)); do
    case "$1" in
      --os-release | --arch)
        # A following option (e.g. `--arch --help`) is a missing value.
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "$1 requires a value"
        if [[ $1 == --arch ]]; then arch=$2; else os_release=$2; fi
        shift 2
        ;;
      --help | -h)
        preflight_usage
        return 0
        ;;
      *)
        usage_error "unknown preflight option '$1'"
        ;;
    esac
  done

  if [[ -z $os_release ]]; then
    os_release=/etc/os-release
    [[ -e $os_release ]] || os_release=/usr/lib/os-release
  fi
  if [[ -z $arch ]]; then
    arch=$(uname -m) || die "cannot determine architecture with 'uname -m'"
  fi

  read_os_release "$os_release"
  case "$OS_ID" in
    debian)
      [[ $OS_VERSION_ID == 12 || $OS_VERSION_ID == 13 ]] ||
        die "unsupported Debian version '$OS_VERSION_ID' in '$os_release' (supported: 12, 13)"
      ;;
    ubuntu)
      [[ $OS_VERSION_ID == 24.04 || $OS_VERSION_ID == 26.04 ]] ||
        die "unsupported Ubuntu version '$OS_VERSION_ID' in '$os_release' (supported: 24.04, 26.04)"
      ;;
    *)
      die "unsupported Linux distribution '$OS_ID' in '$os_release' (supported: debian, ubuntu)"
      ;;
  esac
  set_platform "$arch"
  local platform=$PLATFORM

  printf 'os_release: %s\n' "$os_release"
  printf 'os: %s %s\n' "$OS_ID" "$OS_VERSION_ID"
  printf 'arch: %s\n' "$arch"
  printf 'tari_asset_platform: %s\n' "$platform"
  printf 'preflight: supported\n'
}

# load_fetch: source lib/fetch.sh from next to this script. Only the fetch
# command needs it, so preflight keeps running without realpath.
load_fetch() {
  local self
  command -v realpath >/dev/null || die "missing required command: realpath"
  self=$(realpath -- "${BASH_SOURCE[0]}") || die "cannot locate $PROG"
  # shellcheck source=lib/fetch.sh
  source "${self%/*}/lib/fetch.sh"
}

# load_install: source lib/fetch.sh and lib/install.sh from next to this
# script using only builtins (realpath only if deploy.sh is itself a
# symlink), so that 'install --help' works even without the runtime tools.
load_install() {
  local self=${BASH_SOURCE[0]} dir
  if [[ -L $self ]]; then
    command -v realpath >/dev/null || die "missing required command: realpath"
    self=$(realpath -- "$self") || die "cannot locate $PROG"
  fi
  [[ $self == */* ]] || self=./$self
  dir=$(cd -P -- "${self%/*}" && pwd -P) || die "cannot locate $PROG"
  # shellcheck source=lib/fetch.sh
  source "$dir/lib/fetch.sh"
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$dir/lib/install.sh"
  # shellcheck disable=SC2034 # Used by lib/install.sh.
  INSTALL_SOURCE_DIR=$dir
}

# load_status: what install loads, plus lib/status.sh (status and logs
# reuse its layout and port checks).
load_status() {
  load_install
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/status.sh"
}

# load_uninstall: what grpc loads (the layouts and records of the node,
# Wallet Query and gRPC), plus lib/uninstall.sh.
load_uninstall() {
  load_grpc
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/uninstall.sh"
}

# load_upgrade: everything upgrade reuses (install, status and uninstall
# checks), plus lib/upgrade.sh.
load_upgrade() {
  load_status
  # Linted on their own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/uninstall.sh"
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/upgrade.sh"
}

# load_wallet_query: what status loads, plus lib/wallet-query.sh.
load_wallet_query() {
  load_status
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/wallet-query.sh"
}

# load_grpc: what wallet-query loads, plus lib/grpc.sh.
load_grpc() {
  load_wallet_query
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/grpc.sh"
}

# load_submit: what grpc loads, plus lib/submit.sh.
load_submit() {
  load_grpc
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/submit.sh"
}

# load_menu: every module, plus lib/menu.sh.
load_menu() {
  load_upgrade
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/wallet-query.sh"
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/grpc.sh"
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/submit.sh"
  # Linted on its own (scripts/shell-files.sh); not followed from here.
  # shellcheck source=/dev/null
  source "$INSTALL_SOURCE_DIR/lib/menu.sh"
}

main() {
  case "${1-}" in
    --help | -h)
      usage
      ;;
    --version)
      printf '%s %s\n' "$PROG" "$VERSION"
      ;;
    preflight)
      shift
      cmd_preflight "$@"
      ;;
    fetch)
      shift
      load_fetch
      cmd_fetch "$@"
      ;;
    install)
      shift
      load_install
      cmd_install "$@"
      ;;
    status)
      shift
      load_status
      cmd_status "$@"
      ;;
    logs)
      shift
      load_status
      cmd_logs "$@"
      ;;
    upgrade)
      shift
      load_upgrade
      cmd_upgrade "$@"
      ;;
    uninstall)
      shift
      load_uninstall
      cmd_uninstall "$@"
      ;;
    wallet-query)
      shift
      load_wallet_query
      cmd_wallet_query "$@"
      ;;
    grpc)
      shift
      load_grpc
      cmd_grpc "$@"
      ;;
    submit)
      shift
      load_submit
      cmd_submit "$@"
      ;;
    '')
      # A person at a terminal gets the menu; anything else (a pipe, cron,
      # CI) gets the help and never waits for input.
      if [[ -t 0 && -t 1 ]]; then
        load_menu
        cmd_menu
      else
        usage >&2
        exit 2
      fi
      ;;
    *)
      usage_error "unknown command '$1'"
      ;;
  esac
}

# Run only when executed, so tests can source the helpers.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
