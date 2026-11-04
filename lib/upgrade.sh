# shellcheck shell=bash
# upgrade: replaces the Minotari release of a node installed by
# lib/install.sh with a newer one, keeping its data, identity, configuration
# and Tor. Sourced by deploy.sh after lib/fetch.sh, lib/install.sh,
# lib/status.sh and lib/uninstall.sh, whose download, checks and helpers it
# reuses. Must be run as root; never escalates privileges itself.

upgrade_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD upgrade [--version VERSION] [--arch ARCH] [--yes]

Upgrade the Minotari node installed by '$USAGE_CMD install' to a newer
release. Must be run as root; this tool itself never escalates privileges
(no sudo, su, doas or pkexec).

The running node keeps running while the new release is downloaded and
verified; only then is it restarted with the new release. If the new release
does not start correctly, the previous one is put back and started again.
The node's data, identity, configuration, logs and Tor are not changed.

Options:
  --version VERSION  Release to upgrade to, e.g. 1.2.3 or v1.2.3-pre.4; it must
                     be newer than the installed one. Default: GitHub's latest
                     full (non-pre-release) release
  --arch ARCH        Architecture (default: uname -m); must match the node's
  --yes              Do not ask for confirmation (all checks still run)
  --help             Show this help and exit
USAGE
}

# version_newer A B: true if release version A is newer than B, by SemVer
# precedence (a leading "v" is ignored; pre-releases sort before their
# release; numeric identifiers compare numerically and before alphanumeric
# ones). Both must match RE_RELEASE_VERSION.
version_newer() {
  local a=${1#v} b=${2#v} i x y
  local -a ca cb pa=() pb=()
  IFS=. read -r -a ca <<<"${a%%-*}"
  IFS=. read -r -a cb <<<"${b%%-*}"
  for i in 0 1 2; do
    ((10#${ca[i]} == 10#${cb[i]})) && continue
    ((10#${ca[i]} > 10#${cb[i]}))
    return
  done
  [[ $a == *-* ]] && IFS=. read -r -a pa <<<"${a#*-}"
  [[ $b == *-* ]] && IFS=. read -r -a pb <<<"${b#*-}"
  # A release is newer than any of its pre-releases.
  if ((${#pa[@]} == 0 || ${#pb[@]} == 0)); then
    ((${#pa[@]} == 0 && ${#pb[@]} > 0))
    return
  fi
  for ((i = 0; i < ${#pa[@]} && i < ${#pb[@]}; i++)); do
    x=${pa[i]} y=${pb[i]}
    [[ $x == "$y" ]] && continue
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then
      ((10#$x > 10#$y))
    elif [[ $x =~ ^[0-9]+$ ]]; then
      return 1
    elif [[ $y =~ ^[0-9]+$ ]]; then
      return 0
    else
      [[ $x > $y ]]
    fi
    return
  done
  ((${#pa[@]} > ${#pb[@]}))
}

readonly UPGRADE_DEPENDENCIES=(systemctl systemd-analyze getent runuser timeout mktemp mkdir
  chmod chown cp cat mv ln rm rmdir stat sha256sum readlink realpath sleep date uname sort
  curl jq)

# upgrade_outcome CLI_TEXT MENU_TEXT: how the upgrade ended. The command
# line gets CLI_TEXT among the tool's messages; the menu says MENU_TEXT
# first, before any reason.
upgrade_outcome() {
  if ((${MENU_MODE:-0})); then
    menu_outcome "$2"
  else
    printf '%s: %s\n' "$PROG" "$1" >&2
  fi
}

# upgrade_refused: EXIT trap while the read-only checks run.
upgrade_refused() {
  local rc=$?
  ((rc == 0)) ||
    upgrade_outcome "error: upgrade refused; nothing was changed." \
      "The upgrade did not go ahead; nothing was changed."
  return "$rc"
}

# Where the upgrade is: prepare (the node untouched), refused (a release
# was looked up, but not one to upgrade to), switched (the node stopped or
# running the new release), done.
PHASE=prepare

# upgrade_cleanup: EXIT trap once the work directory exists. Before the
# switch, remove what this run staged; the node was never touched.
upgrade_cleanup() {
  local rc=$?
  set +e
  trap '' HUP INT TERM
  if [[ $PHASE == refused ]]; then
    upgrade_outcome "error: upgrade refused; nothing was changed." \
      "The upgrade did not go ahead; nothing was changed."
  elif [[ $PHASE == prepare ]] && ((rc != 0)); then
    remove_staged
    upgrade_outcome "Upgrade failed before the node was touched: it keeps running Minotari ${RECORD[version]}." \
      "The upgrade did not go ahead. Your node was not changed and keeps running Minotari ${RECORD[version]}. You can try again later."
  elif [[ $PHASE == switched ]]; then
    restore_previous
  fi
  remove_work_dir
  return "$rc"
}

# remove_staged: remove the release this run staged (identity-checked),
# never through a mount.
remove_staged() {
  local i kind path id
  for ((i = ${#CREATED[@]} - 1; i > 0; i--)); do
    read -r kind path id <<<"${CREATED[$i]}"
    if ! (check_no_mounts_in "it was not removed; remove it by hand" "${path#"$SYSROOT"}"); then
      # shellcheck disable=SC2034 # Read by lib/install.sh.
      CLEANUP_INCOMPLETE=1
      continue
    fi
    undo "$kind" "$path" "$id" remove_tree "$path" "$id"
  done
}

# restore_previous: after a failed switch, put the previous release and
# install record back and start it; say it is running only once it passes
# the same checks the new release failed.
restore_previous() {
  local old=${RECORD[release_dir]}
  quiet systemctl stop "$NODE_SERVICE"
  if restore_protected && point_current "${old##*/}" && install_record "$TX/state.old" &&
    quiet systemctl start "$NODE_SERVICE" && (verify_running "$old") >/dev/null 2>&1 &&
    [[ $(protected_sums 2>/dev/null) == "$SUMS_BEFORE" ]]; then
    remove_staged
    if ((${MENU_MODE:-0})); then
      menu_outcome "Minotari $TARGET_VERSION did not start correctly, so the previous release (Minotari ${RECORD[version]}) was put back and is running again. Nothing else was changed; you can try again later."
      return 0
    fi
    printf '%s: Upgrade failed: Minotari %s did not start correctly. The previous release (Minotari %s) was put back and is running again.\n' \
      "$PROG" "$TARGET_VERSION" "${RECORD[version]}" >&2
    printf "%s: Nothing else was changed. See '%s logs' for why the new release failed; you can try again later.\n" \
      "$PROG" "$USAGE_CMD" >&2
  else
    if ((${MENU_MODE:-0})); then
      menu_outcome "Minotari $TARGET_VERSION did not start correctly, and the previous release (Minotari ${RECORD[version]}) could not be confirmed running either. The files of both releases were kept. Check the node with 2) Node status and 3) Node logs."
      return 0
    fi
    printf '%s: Upgrade failed: Minotari %s did not start correctly, and the previous release (Minotari %s) could not be confirmed running either.\n' \
      "$PROG" "$TARGET_VERSION" "${RECORD[version]}" >&2
    printf "%s: Check the node with '%s status' and '%s logs'; the files of both releases were kept.\n" \
      "$PROG" "$USAGE_CMD" "$USAGE_CMD" >&2
  fi
}

# check_node_running: upgrade only a node that runs as installed.
check_node_running() {
  [[ $(sys_query systemctl is-active "$NODE_SERVICE") == active ]] ||
    die "the node is not running; check it with '$USAGE_CMD status' first"
  [[ $(sys_query systemctl is-active "$TOR_SERVICE") == active ]] ||
    die "Tor is not running; check the node with '$USAGE_CMD status' first"
}

# resolve_latest: GitHub's latest full release, from fetch's read-only dry
# run as the service user. Sets TARGET_VERSION.
resolve_latest() {
  local line key value
  local -A got=()
  step "looking for the latest Minotari release"
  run_step "$FETCH_SECONDS" runuser -u "$SERVICE_USER" -- env -i PATH="$CHILD_PATH" \
    HOME="$TARI_HOME" LC_ALL=C TMPDIR="$DL_TMP" "$TOOL/deploy.sh" fetch --dry-run \
    --destination "$DL" --arch "$ARCH_INPUT" >"$TX/latest.out" || die "cannot look up the latest release"
  while IFS= read -r line; do
    [[ $line =~ ^([a-z_]+):\ ([^[:space:][:cntrl:]]+)$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -z ${got[$key]-} ]] || die "unexpected release lookup output"
    got[$key]=$value
  done <"$TX/latest.out"
  [[ ${got[version_source]-} == github-latest && ${got[tag]-} == "v${got[version]-}" &&
    v${got[version]-} =~ $RE_RELEASE_VERSION && ${got[platform]-} == "$PLATFORM" ]] ||
    die "unexpected release lookup output"
  TARGET_VERSION=${got[version]}
}

# The two identity files and the configuration, which an upgrade must never
# change (checked by SHA-256, owner and mode; never shown).
readonly PROTECTED_FILES=("$NODE_CONFIG_DIR/base_node_id.json" "$NODE_CONFIG_DIR/base_node_tor_id.json"
  "$NODE_CONFIG_DIR/config.toml" "$NODE_CONFIG_DIR/base_node/log4rs.yml")

# protected_state FILE: FILE's SHA-256, UID:GID and mode on one line.
protected_state() {
  local sum meta
  sum=$(sha256_of_file "$1") && meta=$(stat -c '%u:%g:%a' -- "$1") || return 1
  printf '%s %s\n' "$sum" "$meta"
}

# protected_sums: protected_state of each of PROTECTED_FILES, one per line.
protected_sums() {
  local f
  for f in "${PROTECTED_FILES[@]}"; do
    protected_state "$(sysroot "$f")"
  done
}

# Identities (path_id) of the directories holding PROTECTED_FILES.
PROTECTED_DIR_IDS=()

# backup_protected: copy PROTECTED_FILES (contents, owner and mode) into the
# root-only work directory before the node is stopped; they must still be
# what the upgrade started with.
backup_protected() {
  local i f sums=''
  for i in "${!PROTECTED_FILES[@]}"; do
    f=$(sysroot "${PROTECTED_FILES[i]}")
    [[ -f $f && ! -L $f ]] || die "'${PROTECTED_FILES[i]}' is not a regular file"
    PROTECTED_DIR_IDS[i]=$(path_id "${f%/*}") || die "cannot inspect '${PROTECTED_FILES[i]%/*}'"
    cp -p -- "$f" "$TX/protected.$i" || die "cannot keep a copy of the node's identity and configuration"
    sums+=$(protected_state "$TX/protected.$i")$'\n'
  done
  [[ ${sums%$'\n'} == "$SUMS_BEFORE" ]] ||
    die "the node's identity or configuration changed during the upgrade; check it by hand"
}

# restore_protected: put back every protected file whose contents, owner or
# mode differ from its copy: written next to it, from inside the directory it
# was copied from (re-checked), and renamed over it.
restore_protected() {
  local i f
  for i in "${!PROTECTED_FILES[@]}"; do
    f=$(sysroot "${PROTECTED_FILES[i]}")
    if [[ -f $f && ! -L $f && $(protected_state "$f") == "$(protected_state "$TX/protected.$i")" ]]; then
      continue
    fi
    (
      cd -P -- "${f%/*}" 2>/dev/null || exit 1
      [[ $(path_id .) == "${PROTECTED_DIR_IDS[i]}" ]] || exit 1
      tmp=$(mktemp .restore.XXXXXXXX) || exit 1
      if ! { cp -p -- "$TX/protected.$i" "$tmp" && mv --no-target-directory -- "$tmp" "${f##*/}"; }; then
        rm -f -- "$tmp"
        exit 1
      fi
    ) || return 1
  done
}

print_upgrade_plan() {
  local origin="explicit"
  ((!LATEST)) || origin="GitHub's latest full release"
  print_text <<PLAN
Minotari node upgrade
  Installed:   Minotari $CURRENT_VERSION
  Upgrade to:  Minotari $TARGET_VERSION ($origin)
  The node keeps running while the new release is downloaded and checked.
  Then it is restarted with the new release (a short interruption). If the
  new release does not start correctly, the installed one is put back.
  Not changed: the node's data, identity, configuration, logs and Tor; DNS,
  firewalls and cloud security groups.
PLAN
}

# stage_release: copy the verified binary into a new root-owned release
# directory next to the running one (the node keeps running). Sets
# RELEASE_ID and RELEASE_DIR.
stage_release() {
  RELEASE_ID="minotari-$F_VERSION-$PLATFORM-${F_BINARY_SHA256:0:16}"
  # shellcheck disable=SC2153 # RELEASES_DIR is lib/install.sh's layout.
  RELEASE_DIR=$RELEASES_DIR/$RELEASE_ID
  step "installing Minotari $F_VERSION next to the running node"
  local stage target stage_id
  target=$(sysroot "$RELEASE_DIR")
  ! exists "$target" || die "a release of Minotari $F_VERSION already exists on this host; remove it by hand"
  stage=$(mktemp -d "$(sysroot "$RELEASES_DIR")/.stage.XXXXXXXX") || die "cannot create a staging directory"
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
    die "the copied binary does not match its verified SHA-256"
  stage_id=$(path_id "$stage") || die "cannot inspect the staging directory"
  mv --no-clobber --no-target-directory -- "$stage" "$target" 2>/dev/null || true
  exists "$stage" && die "cannot install the new release"
  CREATED[-1]="tree $target $stage_id"
  checkpoint
}

# write_record FILE: the install record for the staged release, with the
# running one as previous; everything else is carried over.
write_record() {
  local now old=${RECORD[release_dir]}
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the time"
  # shellcheck disable=SC2153 # VERSION is the tool version (deploy.sh).
  printf '%s=%s\n' format 1 tool_version "$VERSION" tag "$F_TAG" version "$F_VERSION" \
    platform "$F_PLATFORM" asset "$F_ASSET" archive_sha256 "$F_ARCHIVE_SHA256" \
    binary_sha256 "$F_BINARY_SHA256" release_dir "$RELEASE_DIR" public_ip "${RECORD[public_ip]-}" \
    installed_at "${RECORD[installed_at]-}" packages_installed "${RECORD[packages_installed]}" \
    upgraded_at "$now" previous_tag "${RECORD[tag]}" previous_version "${RECORD[version]}" \
    previous_platform "${RECORD[platform]}" previous_asset "${RECORD[asset]}" \
    previous_archive_sha256 "${RECORD[archive_sha256]}" \
    previous_binary_sha256 "${RECORD[binary_sha256]}" previous_release_dir "$old" >"$1"
}

# install_record FILE: make FILE the install record (root's, 0600; renamed
# into place, never half written).
install_record() {
  local tmp
  tmp=$(mktemp "$(sysroot "$TARI_HOME")/.state.XXXXXXXX") || return 1
  if ! { cat -- "$1" >"$tmp" && chown -- "$ROOT_IDS" "$tmp" && chmod 600 "$tmp" &&
    mv --no-target-directory -- "$tmp" "$(sysroot "$STATE_FILE")"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# point_current RELEASE_ID: switch /opt/tari/current atomically.
point_current() {
  local tmp
  tmp=$(sysroot "$OPT_TARI/.current.$$")
  rm -f -- "$tmp"
  ln -s -- "releases/$1" "$tmp" && mv --no-target-directory -- "$tmp" "$(sysroot "$CURRENT_LINK")"
}

# upgrade_node_ready: the node service is active and listens as installed.
upgrade_node_ready() {
  [[ $(sys_query systemctl is-active "$NODE_SERVICE") == active ]] &&
    listening_on "$P2P_PORT" 0.0.0.0 '[::]' && listening_on "$WALLET_QUERY_PORT" 127.0.0.1
}

# verify_running RELEASE_DIR: the node runs RELEASE_DIR's binary, listens,
# answers on the Wallet Query service, and Tor runs.
verify_running() {
  local pid exe
  wait_until "$NODE_WAIT_SECONDS" "the node to start" upgrade_node_ready
  pid=$(sys_query systemctl show -p MainPID --value "$NODE_SERVICE")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || die "the node has no main process"
  exe=$(readlink -- "$(sysroot "/proc/$pid/exe")") || die "cannot inspect the node process"
  [[ $exe == "$(sysroot "$1/minotari_node")" ]] || die "the node does not run the expected release"
  [[ $(sys_query systemctl is-active "$TOR_SERVICE") == active ]] || die "Tor is not running"
  query_tip_info || die "the node's local Wallet Query service $TIP_ERROR"
}

# oldest_release_kept FROM: the upgrade from FROM worked, but the oldest
# release stays.
oldest_release_kept() {
  printf 'Upgraded: Minotari %s -> %s. The node is running.\n' "$1" "$F_VERSION"
  ((!${MENU_MODE:-0})) ||
    menu_outcome "An old release could not be removed safely and was left in place."
}

cmd_upgrade() {
  local assume_yes=0
  VERSION_INPUT='' ARCH_INPUT='' LATEST=0
  while (($# > 0)); do
    case "$1" in
      --version | --arch)
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "$1 requires a value"
        if [[ $1 == --version ]]; then
          [[ -z $VERSION_INPUT ]] || usage_error "--version given more than once"
          VERSION_INPUT=$2
        else
          [[ -z $ARCH_INPUT ]] || usage_error "--arch given more than once"
          ARCH_INPUT=$2
        fi
        shift 2
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      --help | -h)
        upgrade_usage
        return 0
        ;;
      *)
        usage_error "unknown upgrade option '$1'"
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
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$INSTALL_PATH
  export PATH
  umask 022
  local cmd
  for cmd in "${UPGRADE_DEPENDENCIES[@]}"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done

  # Read-only: the node must be exactly as this tool left it, and running.
  trap upgrade_refused EXIT
  read_install_record
  check_account
  check_no_mounts_in "upgrade the node by hand" "$OPT_TARI"
  check_node_files
  check_unit
  check_node_running
  local f
  for f in "${PROTECTED_FILES[@]}"; do
    [[ -f $(sysroot "$f") ]] || die "the node has not created its identity yet; let it run first"
  done
  STATE_ID=$(object_id file "$(sysroot "$STATE_FILE")") || die "cannot inspect '$STATE_FILE'"
  if [[ -n $RECORDED_PREVIOUS_DIR ]]; then
    OLDEST_ID=$(path_id "$(sysroot "$RECORDED_PREVIOUS_DIR")") || die "cannot inspect '$RECORDED_PREVIOUS_DIR'"
  fi
  if [[ -z $ARCH_INPUT ]]; then
    ARCH_INPUT=$(uname -m) || die "cannot determine architecture with 'uname -m'"
  fi
  set_platform "$ARCH_INPUT"
  [[ $PLATFORM == "${RECORD[platform]}" ]] ||
    die "the node runs ${RECORD[platform]}, not $PLATFORM"
  local current=${RECORD[version]}
  if [[ -n $VERSION_INPUT ]]; then
    TARGET_VERSION=${VERSION_INPUT#v}
    if [[ $TARGET_VERSION == "$current" ]]; then
      trap - EXIT
      printf 'Minotari %s is already installed; nothing was changed.\n' "$current"
      return 0
    fi
    version_newer "$TARGET_VERSION" "$current" ||
      die "Minotari $TARGET_VERSION is older than the installed Minotari $current; downgrades are not supported"
  fi
  trap - EXIT

  trap upgrade_cleanup EXIT
  install_signal_traps_deferred
  # shellcheck disable=SC2034 # Used by lib/install.sh prepare_fetch.
  TARI_IDS=$(tari_ids) || die "cannot look up user $SERVICE_USER"
  make_work_dirs
  prepare_fetch
  if [[ -z $VERSION_INPUT ]]; then
    resolve_latest
    if [[ $TARGET_VERSION == "$current" ]]; then
      printf 'Minotari %s is already the latest release; nothing was changed.\n' "$current"
      return 0
    fi
    if ! version_newer "$TARGET_VERSION" "$current"; then
      PHASE=refused
      die "GitHub's latest full release (Minotari $TARGET_VERSION) is older than the installed Minotari $current; downgrades are not supported"
    fi
    VERSION_INPUT=$TARGET_VERSION
    LATEST=1
  fi
  CURRENT_VERSION=$current
  print_upgrade_plan
  if ((!assume_yes)); then
    local answer=''
    printf 'Upgrade Minotari %s to %s? [y/N]: ' "$current" "$TARGET_VERSION"
    IFS= read -r answer || answer=''
    if [[ $answer != y && $answer != Y ]]; then
      printf '\nUpgrade cancelled; nothing was changed.\n'
      return 0
    fi
    printf '\n'
  fi

  # The old node keeps running until the new release is fully checked.
  SUMS_BEFORE=$(protected_sums)
  fetch_as_service_user
  verify_fetch_output
  stage_release
  probe_binary_version
  write_record "$TX/state.new"
  cp -- "$(sysroot "$STATE_FILE")" "$TX/state.old" || die "cannot keep a copy of the install record"
  # The download may have taken a while: still the node that was checked?
  [[ $(readlink -- "$(sysroot "$CURRENT_LINK")") == "releases/${RECORD[release_dir]##*/}" &&
  $(object_id file "$(sysroot "$STATE_FILE")") == "$STATE_ID" ]] ||
    die "the installed node changed during the upgrade; check it by hand"
  backup_protected

  step "restarting the node with Minotari $F_VERSION"
  PHASE=switched
  sys_do systemctl stop "$NODE_SERVICE" || die "cannot stop the node"
  point_current "$RELEASE_ID" || die "cannot switch to the new release"
  install_record "$TX/state.new" || die "cannot update the install record"
  sys_do systemctl start "$NODE_SERVICE" || die "cannot start the node"
  step "checking the node"
  verify_running "$RELEASE_DIR"
  [[ $(protected_sums) == "$SUMS_BEFORE" ]] ||
    die "the node's identity or configuration changed during the upgrade"
  PHASE='done'
  # Keep the new and the previous release; the one before goes, but never
  # through a mount (checked again: the upgrade took a while).
  if [[ -n $RECORDED_PREVIOUS_DIR ]]; then
    local kept="the oldest release (Minotari ${RECORD[previous_version]}) was not removed; remove it by hand"
    step "removing the oldest release (Minotari ${RECORD[previous_version]})"
    if ! (check_no_mounts_in "$kept" "$OPT_TARI"); then
      oldest_release_kept "$current"
      exit 1
    fi
    if ! remove_tree "$(sysroot "$RECORDED_PREVIOUS_DIR")" "$OLDEST_ID"; then
      oldest_release_kept "$current"
      die "cannot remove '$RECORDED_PREVIOUS_DIR'; $kept"
    fi
  fi
  printf 'Upgraded: Minotari %s -> %s. The node is running.\n' "$current" "$F_VERSION"
}
