# shellcheck shell=bash
# menu: what `./deploy.sh` without arguments shows in a terminal. One short
# list for the eight things an ordinary user does with a node; each choice
# runs the same command as the CLI (in a subshell, so that a failure returns
# to the menu), and the menu comes back afterwards. Sourced by deploy.sh
# after every other module.

# Set while a command runs from the menu: commands then show plain-language
# plans, results and status instead of paths, ports and service names.
MENU_MODE=0
# While a command runs from the menu: a private folder for what it reports
# (see menu_run).
MENU_DIR=''

# node_summary: one line on what this host has, read-only.
node_summary() {
  local state version='' line
  state=$(sysroot "$STATE_FILE")
  if ! exists "$state"; then
    printf 'Node: not installed\n'
    return 0
  fi
  while IFS= read -r line; do
    [[ $line =~ ^version=([0-9A-Za-z.+-]{1,64})$ ]] && version=${BASH_REMATCH[1]}
  done <"$state" 2>/dev/null
  if [[ $(sys_query systemctl is-active "$NODE_SERVICE") == active ]]; then
    printf 'Node: Minotari %s, running\n' "${version:-(unknown version)}"
  else
    printf 'Node: Minotari %s, installed but not running\n' "${version:-(unknown version)}"
  fi
}

print_menu() {
  # shellcheck disable=SC2153 # VERSION is defined by deploy.sh before this file is loaded.
  printf '%s\n' "TariTalk Node Tool" \
    "==============================================================" \
    "System Required: Debian 12/13, Ubuntu 24.04/26.04" \
    "Architecture: AMD64 / ARM64" \
    "Version: v$VERSION" \
    "Description: Install and manage a Minotari Mainnet full node" \
    "GitHub: https://github.com/xt1085/taritalk-node-deploy" \
    "==============================================================" \
    "$(node_summary)" "" "1. Install node" "2. Node status" "3. Node logs" \
    "4. Upgrade node" "5. Install Wallet Query" "6. Install Base Node gRPC" \
    "7. Submit node to TariTalk Nodes" "8. Uninstall all" "0. Exit" ""
}

# menu_run COMMAND ARGS...: run cmd_COMMAND in a subshell; whatever it does,
# the menu continues. Everything but install needs a node installed by this
# tool, and install one that is not. The command's technical messages
# (stderr) are kept back in MENU_DIR/details and shown only on request.
menu_run() {
  local cmd=$1 rc=0
  shift
  printf '\n'
  if [[ $cmd != install ]] && ! exists "$(sysroot "$STATE_FILE")"; then
    printf 'No node installed by this tool was found on this server.\n'
    [[ $cmd != wallet_query ]] ||
      printf 'Wallet Query needs the node: choose 1) Install node first.\n'
    [[ $cmd != grpc ]] ||
      printf 'Base Node gRPC needs the node: choose 1) Install node first.\n'
    return 0
  fi
  if [[ $cmd == wallet_query ]] && exists "$(sysroot "$WQ_STATE")"; then
    printf 'Wallet Query is already set up on this server.\n'
    return 0
  fi
  if [[ $cmd == grpc ]] && exists "$(sysroot "$GRPC_STATE")"; then
    printf 'Base Node gRPC is already set up on this server.\n'
    return 0
  fi
  if [[ $cmd == install ]] && exists "$(sysroot "$STATE_FILE")"; then
    printf 'A node installed by this tool is already on this server. To move to a newer Minotari release, choose 4) Upgrade node.\n'
    return 0
  fi
  MENU_DIR=$(mktemp -d "$(sysroot /tmp)/taritalk-menu.XXXXXXXX") || {
    printf 'Cannot create a temporary folder; nothing was done.\n'
    return 0
  }
  ("cmd_$cmd" "$@") 2>"$MENU_DIR/details" || rc=$?
  menu_report "$cmd" "$rc"
}

# plain TEXT: TEXT has no internals (paths, hashes, addresses, ports,
# service names), so the menu may show it.
plain() {
  local text=${1//"$USAGE_CMD"/}
  ! grep -qE '/|[0-9a-f]{16,}|https?:|\.service|systemd|127\.0\.0\.1|:[0-9]{2,5}' <<<"$text"
}

# menu_report COMMAND STATUS: after a failed command, how it left the node
# (unless it said so itself), then the reason in plain words: its first
# error if that is plain, else the step it stopped at.
menu_report() {
  local cmd=$1 rc=$2 line first='' reason
  if ((rc == 0)); then
    ! grep -q ': warning: ' "$MENU_DIR/details" ||
      printf '\nThe tool reported a warning; see the technical details.\n'
    return 0
  fi
  # Status and logs say in plain words what is wrong.
  [[ $cmd == status || $cmd == logs ]] && return 0
  local name=${cmd^}
  [[ $cmd != wallet_query ]] || name='Wallet Query setup'
  [[ $cmd != grpc ]] || name='Base Node gRPC setup'
  [[ $cmd != submit ]] || name='Submission'
  [[ -e $MENU_DIR/outcome ]] || printf '%s did not complete.\n' "$name"
  while IFS= read -r line; do
    if [[ $line =~ ^[a-z-]+:\ error:\ (.+)$ ]]; then
      first=${BASH_REMATCH[1]}
      break
    fi
  done <"$MENU_DIR/details"
  if [[ -n $first ]] && plain "$first"; then
    reason=$first
  elif [[ -s $MENU_DIR/step ]]; then
    reason="it stopped while $(<"$MENU_DIR/step")"
  else
    reason="it stopped at one of its checks, before changing anything"
  fi
  printf 'Reason: %s.\n' "${reason%.}"
  ! grep -q ': warning: ' "$MENU_DIR/details" ||
    printf 'There were also warnings; see the technical details.\n'
}

# menu_back: back to the menu on Enter; with technical details kept back,
# "d" shows them first. Ends the menu at end of input.
menu_back() {
  local answer=''
  if [[ -n ${MENU_DIR-} && -s $MENU_DIR/details ]]; then
    printf '\nPress Enter to return to the menu, or type d and press Enter to see the technical details.'
    IFS= read -r answer || answer=EOF
    if [[ $answer == [dD] ]]; then
      printf '\n'
      cat -- "$MENU_DIR/details"
      printf '\nPress Enter to return to the menu.'
      IFS= read -r answer || answer=EOF
    fi
  else
    printf '\nPress Enter to return to the menu.'
    IFS= read -r answer || answer=EOF
  fi
  if [[ -n ${MENU_DIR-} ]]; then
    rm -rf -- "$MENU_DIR"
    MENU_DIR=''
  fi
  printf '\n'
  [[ $answer != EOF ]]
}

cmd_menu() {
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$INSTALL_PATH
  export PATH
  # shellcheck disable=SC2034 # Read by lib/install.sh, status.sh and uninstall.sh.
  MENU_MODE=1
  # shellcheck disable=SC2016 # Expanded when the menu ends.
  trap '[[ -z $MENU_DIR ]] || rm -rf -- "$MENU_DIR"' EXIT
  # Once, on a terminal: start from a clear screen. Back from a command,
  # the menu follows its result, which stays readable above it.
  [[ ! -t 1 || ${TERM:-dumb} == dumb ]] || printf '\033[H\033[2J'
  local choice
  while true; do
    print_menu
    while true; do
      printf 'Please choose: '
      IFS= read -r choice || {
        printf '\n'
        return 0
      }
      # Surrounding spaces are a typing slip, nothing more.
      choice=${choice#"${choice%%[![:space:]]*}"}
      choice=${choice%"${choice##*[![:space:]]}"}
      [[ $choice == [012345678] ]] && break
      printf 'Please enter a number from 0 to 8.\n'
    done
    case "$choice" in
      0) return 0 ;;
      1) menu_run install ;;
      2) menu_run status ;;
      3) menu_run logs --lines 50 ;;
      4) menu_run upgrade ;;
      5) menu_run wallet_query ;;
      6) menu_run grpc ;;
      7) menu_run submit ;;
      8) menu_run uninstall ;;
    esac
    menu_back || return 0
  done
}
