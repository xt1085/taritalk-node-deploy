# shellcheck shell=bash
# uninstall: "Uninstall all": removes everything this tool installed and
# nothing else: the node of lib/install.sh and, when this tool set them up,
# the Wallet Query of lib/wallet-query.sh, the Base Node gRPC of lib/grpc.sh
# and the Nginx it installed for them, so that all of it can be set up again
# afterwards. Sourced by deploy.sh after lib/fetch.sh, lib/install.sh,
# lib/status.sh, lib/wallet-query.sh and lib/grpc.sh, whose fixed layouts,
# templates, records and identity-checked removal it reuses (lib/upgrade.sh
# sources it for the install record alone). Must be run as root; never
# escalates privileges itself.

# Internal settings. Tests that source this file may point them at a
# sandbox; the CLI offers no way to change them.
SYSTEM_UID_MIN=1
SYSTEM_UID_MAX=999
MOUNTINFO=/proc/self/mountinfo

# Tor's directories. Install refused a host where /etc/tor, /var/lib/tor or
# /run/tor existed; the tor package's purge itself runs
# `rm -rf /var/log/tor/ /var/lib/tor/ /run/tor/` (its postrm), so all four
# must hold only the default Tor instance's own files before it runs.
readonly TOR_DIRS=(/etc/tor /var/lib/tor /var/log/tor /run/tor)
readonly UNINSTALL_DEPENDENCIES=(systemctl systemd-analyze dpkg dpkg-query getent userdel
  groupdel timeout stat sha256sum md5sum readlink rm rmdir find sort xargs cut)
# Nginx's directories (nginx-common's postrm removes all three on purge).
readonly NGINX_DIRS=(/etc/nginx /var/log/nginx /var/lib/nginx)

# shellcheck disable=SC2153 # The fixed layouts of lib/wallet-query.sh and lib/grpc.sh.
uninstall_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD uninstall

Uninstall all: remove everything this tool installed, so that a new node,
Wallet Query and Base Node gRPC can be set up again afterwards.
Must be run as root; this tool itself never escalates privileges (no sudo,
su, doas or pkexec).

Everything below is permanently deleted, with no backup: the node's
blockchain database, its node identity, configuration and logs cannot be
recovered.
  - $NODE_SERVICE: stopped, disabled and its unit file removed
  - $UNIT_FILE, $OPT_TARI, $TARI_HOME
    (with the install record) and $LOG_DIR
  - the system user and group $SERVICE_USER
  - the tor package, with 'dpkg --purge -- tor' (dpkg removes no other
    package; it refuses while one depends on tor), after stopping
    $TOR_SERVICE and disabling $TOR_MASTER_SERVICE. The package's
    own purge removes /var/lib/tor, /var/log/tor and /run/tor; any of
    these or /etc/tor still left afterwards is removed only if empty.
    Tor is removed (and the uninstall runs at all) only if its install
    record shows this tool installed tor on a clean host, /etc/tor holds
    only this tool's exact torrc, and no other Tor instance, Tor process,
    log or foreign file uses Tor's directories
  - Wallet Query, if this tool set it up ('$USAGE_CMD wallet-query'):
    $WQ_HOME (its record, acme.sh account and
    webroot), $WQ_OPT, $WQ_TLS_DIR,
    $WQ_NGINX_CONF, $RENEW_TIMER and
    $RENEW_SERVICE
  - Base Node gRPC, if this tool set it up ('$USAGE_CMD grpc'): the same
    under $GRPC_HOME, $GRPC_OPT, $GRPC_TLS_DIR,
    $GRPC_NGINX_CONF and $GRPC_RENEW_TIMER (the node's
    configuration goes with the node)
  - the record of a Wallet Query or gRPC setup that failed and kept Nginx
    ($WQ_RETRY_RECORD, $GRPC_RETRY_RECORD)
  - the nginx package (with nginx-common), with 'dpkg --purge', after
    stopping and disabling $NGINX_SERVICE, only when the Wallet Query or
    gRPC records show this tool installed it on a host without a web
    server, and /etc/nginx still holds exactly the nginx package's own
    unchanged files and this tool's configuration. The package's own purge
    removes /etc/nginx, /var/log/nginx and /var/lib/nginx; any of them
    still left afterwards is removed only if empty
  - $SUBMISSION_ID_FILE next to deploy.sh, the submission ID saved by
    '$USAGE_CMD submit', last of all (the rest of this checkout is kept)

Kept: ca-certificates, curl, jq, openssl and unzip are kept even if this
tool installed them (other software may use them), as are all other
packages, APT caches and this checkout. DNS, Cloudflare, firewalls and
cloud security groups are not changed. An Nginx this tool did not install
is never touched.

Before changing anything it checks, read-only, that the node, its account,
Tor and every Wallet Query or gRPC component that exists are exactly as
this tool left them, shows the plan and asks once for confirmation;
anything unexpected (a changed torrc or Nginx configuration, another
release, extra files, a mount point, another user of group $SERVICE_USER,
another copy or drop-in of a unit, a file in /etc/nginx that neither the
nginx package nor this tool wrote, ...) refuses the whole uninstall and
leaves the host for you to handle by hand. There is no --yes or --force,
and no way to remove only some of the components.

There is no rollback: if a system command fails part way, the uninstall
stops there and the host may be left partially removed (the records are
kept as long as possible); check it before running uninstall again.

Options:
  --help  Show this help and exit
USAGE
}

# uninstall_refused: EXIT trap while the read-only checks run.
uninstall_refused() {
  local rc=$?
  ((rc == 0)) && return 0
  printf '%s: error: uninstall refused; nothing was changed. It removes only what this tool installed (the node, Wallet Query and Base Node gRPC) and only while all of it is still as this tool left it; check this host and handle it by hand.\n' "$PROG" >&2
  ((!${MENU_MODE:-0})) ||
    menu_outcome "Nothing was removed; nothing was changed. This tool removes only what it installed itself, and only while all of it is still as it left it."
  return "$rc"
}

# uninstall_failed MESSAGE: stop at a failed step; nothing after it runs.
uninstall_failed() {
  printf '%s: error: %s\n' "$PROG" "$1" >&2
  printf '%s: error: uninstall stopped; later steps were not run, so the removal may be incomplete (some parts removed, others not). Check the host before running it again.\n' "$PROG" >&2
  ((!${MENU_MODE:-0})) ||
    menu_outcome "Uninstall stopped part way: some parts may be removed and others not. Check this server before trying again."
  exit 1
}

# sys_do ARGS...: a time-limited system command, its output on stderr.
sys_do() {
  timeout --kill-after=5 "$SYSTEMCTL_SECONDS" "$@" >&2 </dev/null
}

# sys_query ARGS...: the output of a time-limited, read-only command
# (whatever its exit status).
sys_query() {
  timeout --kill-after=5 "$SYSTEMCTL_SECONDS" "$@" 2>/dev/null </dev/null || true
}

stop_services() {
  step "stopping the node"
  sys_do systemctl stop "$NODE_SERVICE" || uninstall_failed "cannot stop $NODE_SERVICE"
  sys_do systemctl disable "$NODE_SERVICE" || uninstall_failed "cannot disable $NODE_SERVICE"
  step "stopping Tor"
  sys_do systemctl stop "$TOR_SERVICE" || uninstall_failed "cannot stop $TOR_SERVICE"
  sys_do systemctl disable "$TOR_MASTER_SERVICE" || uninstall_failed "cannot disable $TOR_MASTER_SERVICE"
}

# The one package command: dpkg, not apt-get, so that by its own rules it
# removes tor and nothing else (it refuses while another installed package
# depends on tor, where apt-get would remove that package too). No network.
readonly -a DPKG_PURGE_TOR=(dpkg --purge -- tor)

purge_tor() {
  step "purging the tor package"
  timeout --kill-after=5 "$APT_SECONDS" env DEBIAN_FRONTEND=noninteractive \
    "${DPKG_PURGE_TOR[@]}" >&2 </dev/null || uninstall_failed "dpkg --purge tor failed"
}

# read_install_record: the install record of lib/install.sh must be a
# private regular file of root; it is read strictly as data (never sourced
# or executed). Sets RECORDED_RELEASE_DIR, RECORDED_BINARY_SHA256,
# RECORDED_PACKAGES and RECORDED_VERIFICATION (the verification.txt that
# install wrote into the release).
read_install_record() {
  local state info line key value pkg
  local -a lines
  local -A seen=() known=()
  state=$(sysroot "$STATE_FILE")
  exists "$state" || die "'$STATE_FILE' is missing; no node installed by $PROG was found"
  [[ -f $state && ! -L $state ]] || die "'$STATE_FILE' is not a regular file"
  info=$(stat -c '%u %a %h %s' -- "$state") || die "cannot inspect '$STATE_FILE'"
  [[ ${info% *} == "${ROOT_IDS%%:*} 600 1" ]] ||
    die "'$STATE_FILE' is not a private file of root (owner, mode, links: ${info% *})"
  ((${info##* } <= 4096)) || invalid_record "too large"
  # Bash drops NUL bytes silently: `read -d ''` succeeds only if one exists.
  if IFS= read -r -d '' _ <"$state"; then invalid_record "contains a NUL byte"; fi
  mapfile -t lines <"$state" || die "cannot read '$STATE_FILE'"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_0-9]+)=([A-Za-z0-9.:/_,+-]*)$ ]] || invalid_record "unexpected line"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -z ${seen[$key]+x} ]] || invalid_record "duplicate $key"
    seen[$key]=$value
  done
  [[ ${seen[format]-} == 1 ]] || invalid_record "format is not 1"
  [[ ${seen[release_dir]-} =~ ^$RELEASES_DIR/minotari-[A-Za-z0-9._-]+$ ]] ||
    invalid_record "invalid release_dir"
  [[ ${seen[binary_sha256]-} =~ ^[0-9a-f]{64}$ ]] || invalid_record "invalid binary_sha256"
  [[ ${seen[packages_installed]-} =~ ^[a-z0-9.+-]+(,[a-z0-9.+-]+)*$ ]] ||
    invalid_record "invalid packages_installed"
  for key in tag version platform asset archive_sha256; do
    [[ -n ${seen[$key]-} ]] || invalid_record "no $key"
  done
  RECORDED_RELEASE_DIR=${seen[release_dir]}
  RECORDED_BINARY_SHA256=${seen[binary_sha256]}
  RECORDED_VERIFICATION=$(verification_record "${seen[tag]}" "${seen[version]}" \
    "${seen[platform]}" "${seen[asset]}" "${seen[archive_sha256]}" "${seen[binary_sha256]}")$'\n'
  # After an upgrade (lib/upgrade.sh): the release it replaced, kept for one
  # more upgrade; all of its keys or none.
  RECORDED_PREVIOUS_DIR='' RECORDED_PREVIOUS_SHA256='' RECORDED_PREVIOUS_VERIFICATION=''
  local n=0
  for key in tag version platform asset archive_sha256 binary_sha256 release_dir; do
    [[ -z ${seen[previous_$key]+x} ]] || n=$((n + 1))
  done
  if ((n > 0)); then
    ((n == 7)) || invalid_record "incomplete previous release"
    [[ ${seen[previous_release_dir]} =~ ^$RELEASES_DIR/minotari-[A-Za-z0-9._-]+$ &&
      ${seen[previous_release_dir]} != "$RECORDED_RELEASE_DIR" &&
      ${seen[previous_binary_sha256]} =~ ^[0-9a-f]{64}$ &&
      ${seen[previous_tag]} == "v${seen[previous_version]}" && ${seen[previous_tag]} =~ $RE_RELEASE_VERSION ]] ||
      invalid_record "invalid previous release"
    RECORDED_PREVIOUS_DIR=${seen[previous_release_dir]}
    RECORDED_PREVIOUS_SHA256=${seen[previous_binary_sha256]}
    RECORDED_PREVIOUS_VERIFICATION=$(verification_record "${seen[previous_tag]}" \
      "${seen[previous_version]}" "${seen[previous_platform]}" "${seen[previous_asset]}" \
      "${seen[previous_archive_sha256]}" "${seen[previous_binary_sha256]}")$'\n'
  fi
  IFS=, read -r -a RECORDED_PACKAGES <<<"${seen[packages_installed]}"
  # The whole record, for upgrade to carry forward.
  RECORD=()
  for key in "${!seen[@]}"; do
    RECORD[$key]=${seen[$key]}
  done
  for pkg in "${INSTALL_PACKAGES[@]}"; do
    known[$pkg]=1
  done
  for pkg in "${RECORDED_PACKAGES[@]}"; do
    [[ ${known[$pkg]-} == 1 ]] || invalid_record "packages_installed lists $pkg or lists it twice"
    known[$pkg]=0
  done
  [[ ${known[tor]} == 0 ]] ||
    invalid_record "tor was not installed by $PROG (an existing Tor setup is never removed)"
}

# verification_record TAG VERSION PLATFORM ASSET ARCHIVE_SHA256
# BINARY_SHA256: the release's verification.txt, as lib/install.sh
# verify_fetch_output writes it (without the final newline).
verification_record() {
  local record
  printf -v record '%s: %s\n' tag "$1" version "$2" platform "$3" asset "$4" \
    manifest_url "$RELEASE_BASE_URL/$1/tari_suite-$2.sha256-unsigned.txt" \
    asset_url "$RELEASE_BASE_URL/$1/$4" archive_sha256 "$5" binary_sha256 "$6"
  printf '%s' "${record%$'\n'}"
}

invalid_record() {
  die "'$STATE_FILE' is not a valid install record of $PROG: $1"
}

# check_account: tari is still the system account lib/install.sh created.
# Sets TARI_IDS.
check_account() {
  local entry name uid gid home shell group_gid members accounts other other_gid
  entry=$(getent passwd "$SERVICE_USER") || die "user $SERVICE_USER does not exist"
  IFS=: read -r name _ uid gid _ home shell <<<"$entry"
  [[ $entry != *$'\n'* && $name == "$SERVICE_USER" && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] ||
    die "unexpected account entry for user $SERVICE_USER"
  ((uid >= SYSTEM_UID_MIN && uid <= SYSTEM_UID_MAX)) ||
    die "user $SERVICE_USER is not a system account (UID $uid)"
  [[ $home == "$TARI_HOME" ]] || die "user $SERVICE_USER does not have home $TARI_HOME"
  [[ $shell == /usr/sbin/nologin ]] || die "user $SERVICE_USER does not have shell /usr/sbin/nologin"
  group_gid=$(user_field group "$SERVICE_USER" 3) || die "group $SERVICE_USER does not exist"
  [[ $group_gid == "$gid" ]] || die "the primary group of user $SERVICE_USER is not group $SERVICE_USER"
  # groupdel must not take the group from anyone else.
  members=$(user_field group "$SERVICE_USER" 4) || die "group $SERVICE_USER does not exist"
  [[ -z $members || $members == "$SERVICE_USER" ]] ||
    die "group $SERVICE_USER has other members ($members)"
  accounts=$(getent passwd) || die "cannot list the user accounts"
  while IFS=: read -r other _ _ other_gid _; do
    [[ $other_gid != "$gid" || $other == "$SERVICE_USER" ]] ||
      die "group $SERVICE_USER is the primary group of user $other"
  done <<<"$accounts"
  in_debian_tor || die "user $SERVICE_USER is not a member of group debian-tor"
  TARI_IDS=$uid:$gid
}

# check_unit [UNIT FILE]: systemd loads UNIT (default: the node's service)
# from FILE, the unit file this tool wrote, with no drop-in of its own, and
# no other copy exists in any directory of systemd's unit search path (one
# that removing ours would reveal). The search path is systemd's own
# (systemd-analyze), not a list kept here; drop-ins are the manager's
# (DropInPaths), which covers the runtime, transient, control, attached and
# generator layers too.
check_unit() {
  local unit=${1:-$NODE_SERVICE} file=${2:-$UNIT_FILE} dir path dropins name prefix
  local type=${unit##*.}
  prefix=${unit%."$type"}
  local -a dirs names=("$unit.d")
  while [[ $prefix == *-* ]]; do
    prefix=${prefix%-*}
    names+=("$prefix-.$type.d")
  done
  mapfile -t dirs < <(sys_query systemd-analyze unit-paths)
  ((${#dirs[@]} > 0)) || die "cannot read systemd's unit search path"
  for dir in "${dirs[@]}"; do
    [[ $dir == /* ]] || die "cannot read systemd's unit search path"
    path=$dir/$unit
    if [[ $path != "$file" ]] && exists "$(sysroot "$path")"; then
      die "'$path' also defines $unit; handle it by hand"
    fi
    for name in "${names[@]}"; do
      ! exists "$(sysroot "$dir/$name")" ||
        die "'$dir/$name' holds drop-ins for $unit; handle it by hand"
    done
  done
  [[ $(sys_query systemctl show -p FragmentPath --value "$unit") == "$file" ]] ||
    die "$unit is not loaded from $file"
  dropins=$(sys_query systemctl show -p DropInPaths --value "$unit")
  for path in $dropins; do
    # Only drop-ins for every unit of the type (service.d, timer.d) are not
    # this unit's own.
    [[ $path == */$type.d/* ]] ||
      die "'${path%/*}' holds drop-ins for $unit; handle it by hand"
  done
}

# check_tor: tor is the package lib/install.sh installed on a clean host,
# configured with this tool's torrc, and purging it removes nothing else.
check_tor() {
  package_installed tor || die "the tor package is not installed"
  check_root_file "$TORRC" 644
  check_template_file "$TORRC" torrc
  check_tor_dirs
  check_tor_purge
}

# check_tor_dirs: only the default Tor instance uses Tor's directories and
# runs: no other instance, configuration, foreign state or log, and no Tor
# process but tor@default.service's. Also run again after Tor stopped.
check_tor_dirs() {
  local path entry info owner pid comm main
  for path in "${TOR_DIRS[@]}"; do
    # Only /etc/tor must exist (/run/tor exists while Tor runs).
    if [[ $path != /etc/tor ]] && ! exists "$(sysroot "$path")"; then
      continue
    fi
    [[ -d $(sysroot "$path") && ! -L $(sysroot "$path") ]] || die "'$path' is not a directory"
    check_same_device "$path"
  done
  check_entries /etc/tor torrc
  for path in /var/lib/tor-instances /run/tor-instances; do
    ! exists "$(sysroot "$path")" || die "'$path' exists: other Tor instances use this host's Tor; remove Tor by hand"
  done
  if exists "$(sysroot /var/log/tor)"; then
    for entry in "$(sysroot /var/log/tor)"/* "$(sysroot /var/log/tor)"/.[!.]* "$(sysroot /var/log/tor)"/..?*; do
      ! exists "$entry" || die "'/var/log/tor' is not empty (this tool's Tor logs to syslog); remove Tor by hand"
    done
  fi
  # Tor's state and runtime files: written by Tor itself, as the owner of
  # the directory (debian-tor), and only files, directories or sockets. In
  # its runtime directory, also as root (before Tor drops privileges).
  for path in /var/lib/tor /run/tor; do
    exists "$(sysroot "$path")" || continue
    owner=$(stat -c %u -- "$(sysroot "$path")") || die "cannot inspect '$path'"
    for entry in "$(sysroot "$path")"/* "$(sysroot "$path")"/.[!.]* "$(sysroot "$path")"/..?*; do
      exists "$entry" || continue
      info=$(stat -c '%u|%F' -- "$entry") || die "cannot inspect '$path/${entry##*/}'"
      [[ $path == /run/tor && ${info%%|*} == "${ROOT_IDS%%:*}" ]] && info=$owner\|${info#*|}
      case "$info" in
        "$owner|regular file" | "$owner|regular empty file" | "$owner|directory" | "$owner|socket") ;;
        *) die "'$path/${entry##*/}' is not something the default Tor instance wrote ($info); remove Tor by hand" ;;
      esac
    done
  done
  main=$(sys_query systemctl show -p MainPID --value "$TOR_SERVICE")
  for path in "$(sysroot /proc)"/[0-9]*; do
    { read -r comm <"$path/comm"; } 2>/dev/null || continue
    pid=${path##*/}
    [[ $comm != tor || $pid == "$main" ]] ||
      die "another Tor process is running (PID $pid); remove Tor by hand"
  done
}

# check_tor_purge: dpkg's dry run (read-only) of the purge must succeed:
# no other installed package depends on tor.
check_tor_purge() {
  timeout --kill-after=5 "$APT_SECONDS" env DEBIAN_FRONTEND=noninteractive \
    dpkg --no-act --purge -- tor >/dev/null 2>&1 </dev/null ||
    die "other packages depend on tor, or dpkg cannot purge it now; remove Tor by hand"
}

# check_real_dir PATH OWNER MODE: PATH is a real directory (no symlink) on
# the same file system as its parent, with exactly OWNER (UID:GID) and MODE.
check_real_dir() {
  local path info
  path=$(sysroot "$1")
  [[ -d $path && ! -L $path ]] || die "'$1' is not a directory"
  info=$(stat -c '%u:%g %a' -- "$path") || die "cannot inspect '$1'"
  [[ $info == "$2 $3" ]] || die "'$1' has an unexpected owner or mode ($info, expected $2 $3)"
  check_same_device "$1"
}

# check_same_device PATH: PATH is not a mount point of its own (same device
# as its parent directory).
check_same_device() {
  local dev parent
  if ! dev=$(stat -c %d -- "$(sysroot "$1")") || ! parent=$(stat -c %d -- "$(sysroot "${1%/*}")"); then
    die "cannot inspect '$1'"
  fi
  [[ $dev == "$parent" ]] || die "'$1' is a separate mount point"
}

# check_no_mounts: nothing that uninstall removes is, or contains, a mount
# point (see check_no_mounts_in).
check_no_mounts() {
  local -a paths=("$UNIT_FILE" "$STATE_FILE" "$OPT_TARI" "$TARI_HOME" "$LOG_DIR" "${TOR_DIRS[@]}")
  local kind
  for kind in wq grpc; do
    component_present "$kind" || continue
    endpoint "$kind"
    paths+=("$E_HOME" "$E_OPT" "$E_TLS" "$E_CONF" "$E_RENEW_SERVICE" "$E_RENEW_TIMER" "$E_RETRY")
  done
  ((!REMOVE_NGINX)) || paths+=("${NGINX_DIRS[@]}")
  check_no_mounts_in "handle it by hand" "${paths[@]}"
}

# check_no_mounts_in HINT PATH...: no PATH is, or contains, a mount point,
# of whatever file system: a bind mount of the same file system has the
# same device number, and rm --one-file-system would enter it. Mount points
# are field 5 of mountinfo(5), with special characters escaped (the fixed
# paths here have none, so a plain prefix match is exact).
check_no_mounts_in() {
  local hint=$1 table line path target
  local -a fields paths=("${@:2}")
  table=$(<"$MOUNTINFO") || die "cannot read the mount table $MOUNTINFO"
  [[ -n $table ]] || die "cannot read the mount table $MOUNTINFO"
  while IFS= read -r line; do
    read -r -a fields <<<"$line"
    for path in "${paths[@]}"; do
      target=$(sysroot "$path")
      [[ ${fields[4]-} != "$target" && ${fields[4]-} != "$target"/* ]] ||
        die "'$path' is or contains a mount point (${fields[4]#"$SYSROOT"}); $hint"
    done
  done <<<"$table"
}

# check_root_file PATH MODE: PATH is a regular file of root (no symlink) with
# exactly MODE and a single link.
check_root_file() {
  local path info
  path=$(sysroot "$1")
  info=$(stat -c '%F|%u|%a|%h' -- "$path" 2>/dev/null) || info=missing
  [[ ! -L $path && $info == "regular file|${ROOT_IDS%%:*}|$2|1" ]] ||
    die "'$1' is not a root-owned regular file with mode $2 and one link ($info)"
}

# check_template_file PATH TEMPLATE [KEY VALUE...]: PATH holds exactly what
# this tool wrote from templates/TEMPLATE (of this checkout), with the
# given placeholder values.
check_template_file() {
  local expected actual size
  expected=$(render_template "$2" "${@:3}")$'\n' || exit 1
  actual=$(<"$(sysroot "$1")") || die "cannot read '$1'"
  size=$(stat -c %s -- "$(sysroot "$1")") || die "cannot inspect '$1'"
  [[ $actual$'\n' == "$expected" && $size == "$(LC_ALL=C byte_length "$expected")" ]] ||
    die "'$1' differs from this tool's template $2; it was changed after the installation"
}

byte_length() { printf '%s\n' "${#1}"; }

# check_entries DIR NAME...: DIR contains exactly the entries NAME...
check_entries() {
  local dir=$1 entry
  local -a found=()
  shift
  for entry in "$(sysroot "$dir")"/* "$(sysroot "$dir")"/.[!.]* "$(sysroot "$dir")"/..?*; do
    exists "$entry" && found+=("${entry##*/}")
  done
  [[ $(printf '%s\n' "${found[@]}" | sort) == "$(printf '%s\n' "$@" | sort)" ]] ||
    die "'$dir' contains unexpected entries (${found[*]}); handle it by hand"
}

# check_release DIR SHA256 VERIFICATION: DIR is a release install wrote:
# exactly its binary (with SHA256) and its verification.txt (VERIFICATION).
check_release() {
  local bin=$1/minotari_node
  check_real_dir "$1" "$ROOT_IDS" 755
  check_root_file "$bin" 755
  [[ $(sha256_of_file "$(sysroot "$bin")") == "$2" ]] ||
    die "'$bin' does not match the recorded SHA-256"
  check_root_file "$1/verification.txt" 644
  [[ $(<"$(sysroot "$1/verification.txt")") == "${3%$'\n'}" &&
  $(stat -c %s -- "$(sysroot "$1/verification.txt")") == "$(LC_ALL=C byte_length "$3")" ]] ||
    die "'$1/verification.txt' does not match the install record"
  check_entries "$1" minotari_node verification.txt
}

# check_node_files: the release, data and log directories and the unit are
# still exactly as lib/install.sh left them (contents of the data and log
# directories aside, which the node changes).
check_node_files() {
  local release=$RECORDED_RELEASE_DIR link target
  check_real_dir "$OPT_TARI" "$ROOT_IDS" 755
  link=$(sysroot "$CURRENT_LINK")
  [[ -L $link ]] || die "'$CURRENT_LINK' is missing or not a symlink"
  target=$(readlink -- "$link") || die "cannot read '$CURRENT_LINK'"
  [[ $target == "releases/${release##*/}" ]] ||
    die "'$CURRENT_LINK' does not point to the installed release $release"
  check_entries "$OPT_TARI" releases current
  check_real_dir "$RELEASES_DIR" "$ROOT_IDS" 755
  if [[ -n $RECORDED_PREVIOUS_DIR ]]; then
    check_entries "$RELEASES_DIR" "${release##*/}" "${RECORDED_PREVIOUS_DIR##*/}"
    check_release "$RECORDED_PREVIOUS_DIR" "$RECORDED_PREVIOUS_SHA256" "$RECORDED_PREVIOUS_VERIFICATION"
  else
    check_entries "$RELEASES_DIR" "${release##*/}"
  fi
  check_release "$release" "$RECORDED_BINARY_SHA256" "$RECORDED_VERIFICATION"
  check_real_dir "$TARI_HOME" "${ROOT_IDS%%:*}:${TARI_IDS#*:}" 750
  check_real_dir "$NODE_BASE" "$TARI_IDS" 700
  check_entries "$TARI_HOME" mainnet "${STATE_FILE##*/}"
  check_real_dir "$LOG_DIR" "$TARI_IDS" 700
  check_real_dir "$LOG_DIR/log" "$TARI_IDS" 700
  check_entries "$LOG_DIR" log
  check_root_file "$UNIT_FILE" 644
  check_template_file "$UNIT_FILE" minotari-mainnet.service
}

# --- Wallet Query and Base Node gRPC -------------------------------------------
# Optional components of the same uninstall: each is present when its
# record (lib/wallet-query.sh WQ_STATE, lib/grpc.sh GRPC_STATE) exists, or
# when the record of a failed setup that kept Nginx exists (WQ_RETRY_RECORD,
# GRPC_RETRY_RECORD). Every present component is checked, read-only, before
# the confirmation; the Nginx they use is removed only when their records
# show this tool installed it. Without any component, Nginx is never
# touched and no extra system command runs.

# Global (-g): deploy.sh sources this file from inside a function.
declare -g WQ_PRESENT=0 GRPC_PRESENT=0 WQ_RETRY=0 GRPC_RETRY=0 REMOVE_NGINX=0
declare -g WQ_RETRY_FP='' GRPC_RETRY_FP=''
declare -ga ENDPOINT_PACKAGES=()
# The records, read strictly as data (key -> value).
declare -gA WQ_REC=() GRPC_REC=() ENDPOINT_REC=()
# The paths of the component `endpoint` was last called for.
declare -g E_NAME='' E_HOME='' E_STATE='' E_OPT='' E_ACME_SH='' E_TLS='' E_CONF='' E_RETRY=''
declare -g E_RENEW_SERVICE='' E_RENEW_TIMER='' E_ACME_HOME='' E_WEBROOT='' E_SET_UP=0

# component_present KIND: true if the Wallet Query (wq) or gRPC (grpc)
# component exists, set up or as a failed setup's record.
component_present() {
  case "$1" in
    wq) ((WQ_PRESENT || WQ_RETRY)) ;;
    grpc) ((GRPC_PRESENT || GRPC_RETRY)) ;;
  esac
}

# endpoint KIND: the fixed paths of the component KIND (wq or grpc), into
# the E_* variables; E_SET_UP is 1 when it is set up (its record exists),
# 0 when only a failed setup's record exists.
# shellcheck disable=SC2153 # The fixed layouts of lib/wallet-query.sh and lib/grpc.sh.
endpoint() {
  case "$1" in
    wq)
      E_NAME='Wallet Query' E_HOME=$WQ_HOME E_STATE=$WQ_STATE E_OPT=$WQ_OPT E_ACME_SH=$WQ_ACME_SH
      E_TLS=$WQ_TLS_DIR E_CONF=$WQ_NGINX_CONF E_RETRY=$WQ_RETRY_RECORD E_ACME_HOME=$WQ_ACME_HOME
      E_WEBROOT=$WQ_WEBROOT E_RENEW_SERVICE=$RENEW_SERVICE_FILE E_RENEW_TIMER=$RENEW_TIMER_FILE
      E_SET_UP=$WQ_PRESENT
      ;;
    grpc)
      E_NAME='Base Node gRPC' E_HOME=$GRPC_HOME E_STATE=$GRPC_STATE E_OPT=$GRPC_OPT E_ACME_SH=$GRPC_ACME_SH
      E_TLS=$GRPC_TLS_DIR E_CONF=$GRPC_NGINX_CONF E_RETRY=$GRPC_RETRY_RECORD E_ACME_HOME=$GRPC_ACME_HOME
      E_WEBROOT=$GRPC_WEBROOT E_RENEW_SERVICE=$GRPC_RENEW_SERVICE_FILE E_RENEW_TIMER=$GRPC_RENEW_TIMER_FILE
      E_SET_UP=$GRPC_PRESENT
      ;;
  esac
}

invalid_endpoint_record() {
  die "'$1' is not a valid $2 record of $PROG: $3"
}

# read_endpoint_record PATH NAME: the record lib/wallet-query.sh or
# lib/grpc.sh wrote must be a private regular file of root; it is read
# strictly as data (never sourced or executed) into ENDPOINT_REC.
read_endpoint_record() {
  local path=$1 name=$2 file info line key value pkg
  local -a lines pkgs
  file=$(sysroot "$path")
  [[ -f $file && ! -L $file ]] || die "'$path' is not a regular file"
  info=$(stat -c '%u %a %h %s' -- "$file") || die "cannot inspect '$path'"
  [[ ${info% *} == "${ROOT_IDS%%:*} 600 1" ]] ||
    die "'$path' is not a private file of root (owner, mode, links: ${info% *})"
  ((${info##* } <= 4096)) || invalid_endpoint_record "$path" "$name" "too large"
  if IFS= read -r -d '' _ <"$file"; then invalid_endpoint_record "$path" "$name" "contains a NUL byte"; fi
  mapfile -t lines <"$file" || die "cannot read '$path'"
  ENDPOINT_REC=()
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_0-9]+)=([A-Za-z0-9.:/_,+-]*)$ ]] || invalid_endpoint_record "$path" "$name" "unexpected line"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -z ${ENDPOINT_REC[$key]+x} ]] || invalid_endpoint_record "$path" "$name" "duplicate $key"
    ENDPOINT_REC[$key]=$value
  done
  [[ ${ENDPOINT_REC[format]-} == 1 ]] || invalid_endpoint_record "$path" "$name" "format is not 1"
  check_domain "${ENDPOINT_REC[domain]-}" || invalid_endpoint_record "$path" "$name" "invalid domain"
  [[ ${ENDPOINT_REC[acme_sh_sha256]-} =~ ^[0-9a-f]{64}$ ]] ||
    invalid_endpoint_record "$path" "$name" "invalid acme_sh_sha256"
  [[ -n ${ENDPOINT_REC[packages_installed]+x} && ${ENDPOINT_REC[packages_installed]} =~ ^([a-z0-9.+-]+(,[a-z0-9.+-]+)*)?$ ]] ||
    invalid_endpoint_record "$path" "$name" "invalid packages_installed"
  IFS=, read -r -a pkgs <<<"${ENDPOINT_REC[packages_installed]}"
  for pkg in "${pkgs[@]}"; do
    [[ -n $pkg && " ${WQ_PACKAGES[*]} " == *" $pkg "* ]] ||
      invalid_endpoint_record "$path" "$name" "packages_installed lists $pkg"
  done
  [[ ${ENDPOINT_REC[default_site_disabled]-} == [01] ]] ||
    invalid_endpoint_record "$path" "$name" "invalid default_site_disabled"
  for key in tool_version acme_sh_version installed_at; do
    [[ -n ${ENDPOINT_REC[$key]-} ]] || invalid_endpoint_record "$path" "$name" "no $key"
  done
}

# note_packages LIST: remember the packages a component's record says this
# tool installed (comma-separated), for the final summary and Nginx's
# ownership.
note_packages() {
  local pkg
  local -a pkgs
  IFS=, read -r -a pkgs <<<"$1"
  for pkg in "${pkgs[@]}"; do
    [[ -z $pkg || " ${ENDPOINT_PACKAGES[*]} " == *" $pkg "* ]] || ENDPOINT_PACKAGES+=("$pkg")
  done
}

# check_endpoints: which components exist, that their records are this
# tool's and consistent with each other, and that every one of them (and
# the Nginx they use) is still exactly as this tool left it. Read-only.
check_endpoints() {
  WQ_PRESENT=0 GRPC_PRESENT=0 WQ_RETRY=0 GRPC_RETRY=0 REMOVE_NGINX=0
  WQ_REC=() GRPC_REC=() ENDPOINT_PACKAGES=()
  local key
  if exists "$(sysroot "$WQ_STATE")"; then
    read_endpoint_record "$WQ_STATE" "Wallet Query"
    for key in "${!ENDPOINT_REC[@]}"; do WQ_REC[$key]=${ENDPOINT_REC[$key]}; done
    note_packages "${WQ_REC[packages_installed]}"
    WQ_PRESENT=1
  fi
  if exists "$(sysroot "$GRPC_STATE")"; then
    read_endpoint_record "$GRPC_STATE" "Base Node gRPC"
    for key in "${!ENDPOINT_REC[@]}"; do GRPC_REC[$key]=${ENDPOINT_REC[$key]}; done
    [[ ${GRPC_REC[with_wallet_query]-} == [01] && ${GRPC_REC[node_config_sha256]-} =~ ^[0-9a-f]{64}$ ]] ||
      invalid_endpoint_record "$GRPC_STATE" "Base Node gRPC" "invalid with_wallet_query or node_config_sha256"
    [[ ${GRPC_REC[with_wallet_query]} == "$WQ_PRESENT" ]] ||
      die "'$GRPC_STATE' says gRPC was set up $( ((WQ_PRESENT)) && printf without || printf 'next to') Wallet Query, but Wallet Query is $( ((WQ_PRESENT)) && printf 'set up' || printf 'not set up'); handle it by hand"
    note_packages "${GRPC_REC[packages_installed]}"
    GRPC_PRESENT=1
  fi
  if exists "$(sysroot "$WQ_RETRY_RECORD")"; then
    ((!WQ_PRESENT)) || die "'$WQ_RETRY_RECORD' exists although Wallet Query is set up; handle it by hand"
    ((!GRPC_PRESENT)) || die "'$WQ_RETRY_RECORD' (a failed Wallet Query setup) exists although Base Node gRPC is set up; handle it by hand"
    read_retry_record
    WQ_RETRY_FP=$RETRY_FINGERPRINT
    note_packages "$(
      IFS=,
      printf '%s' "${RETRY_PACKAGES[*]-}"
    )"
    WQ_RETRY=1
  fi
  if exists "$(sysroot "$GRPC_RETRY_RECORD")"; then
    ((!GRPC_PRESENT)) || die "'$GRPC_RETRY_RECORD' exists although Base Node gRPC is set up; handle it by hand"
    ((!WQ_PRESENT)) || die "'$GRPC_RETRY_RECORD' (a failed gRPC setup) exists although Wallet Query is set up; handle it by hand"
    ((!WQ_RETRY)) || die "both '$WQ_RETRY_RECORD' and '$GRPC_RETRY_RECORD' exist; handle it by hand"
    grpc_read_retry_record
    GRPC_RETRY_FP=$RETRY_FINGERPRINT
    note_packages "$(
      IFS=,
      printf '%s' "${RETRY_PACKAGES[*]-}"
    )"
    GRPC_RETRY=1
  fi
  component_present wq || component_present grpc || return 0
  # Nginx: only the one these records show this tool installed on a host
  # without a web server (lib/wallet-query.sh and lib/grpc.sh refuse any
  # other), and still as the package and this tool left it.
  [[ " ${ENDPOINT_PACKAGES[*]} " == *" nginx "* ]] ||
    die "no record shows that this tool installed Nginx, so it does not remove it; remove Wallet Query, gRPC and Nginx by hand"
  package_installed nginx || die "the nginx package this tool installed is missing; handle Nginx and its configuration by hand"
  REMOVE_NGINX=1
  ((!WQ_PRESENT)) || check_endpoint_files wq
  ((!GRPC_PRESENT)) || check_endpoint_files grpc
  check_endpoint_contents
}

# check_endpoint_files KIND: the files of the set-up component KIND are
# exactly as lib/wallet-query.sh or lib/grpc.sh left them (what acme.sh
# writes into its own home and into the webroot aside).
check_endpoint_files() {
  endpoint "$1"
  local sha
  sha=$([[ $1 == wq ]] && printf '%s' "${WQ_REC[acme_sh_sha256]}" || printf '%s' "${GRPC_REC[acme_sh_sha256]}")
  check_real_dir "$E_HOME" "$ROOT_IDS" 755
  check_entries "$E_HOME" "${E_STATE##*/}" "${E_ACME_HOME##*/}" "${E_WEBROOT##*/}"
  check_real_dir "$E_ACME_HOME" "$ROOT_IDS" 700
  check_real_dir "$E_WEBROOT" "$ROOT_IDS" 755
  check_entries "$E_WEBROOT" .well-known
  check_real_dir "$E_WEBROOT/.well-known" "$ROOT_IDS" 755
  check_entries "$E_WEBROOT/.well-known" acme-challenge
  check_real_dir "$E_WEBROOT/.well-known/acme-challenge" "$ROOT_IDS" 755
  check_real_dir "$E_OPT" "$ROOT_IDS" 755
  check_entries "$E_OPT" "${E_ACME_SH##*/}"
  check_root_file "$E_ACME_SH" 755
  [[ $(sha256_of_file "$(sysroot "$E_ACME_SH")") == "$sha" ]] ||
    die "'$E_ACME_SH' does not match the acme.sh this tool installed (its record); handle it by hand"
  check_real_dir "$E_TLS" "$ROOT_IDS" 700
  check_entries "$E_TLS" privkey.pem fullchain.pem
  check_root_file "$E_TLS/privkey.pem" 600
  check_root_file "$E_TLS/fullchain.pem" 644
  check_root_file "$E_CONF" 644
  check_root_file "$E_RENEW_SERVICE" 644
  check_template_file "$E_RENEW_SERVICE" "${E_RENEW_SERVICE##*/}" ACME_HOME "$E_ACME_HOME" ACME_SH "$E_ACME_SH"
  check_root_file "$E_RENEW_TIMER" 644
  check_template_file "$E_RENEW_TIMER" "${E_RENEW_TIMER##*/}"
  check_unit "${E_RENEW_SERVICE##*/}" "$E_RENEW_SERVICE"
  check_unit "${E_RENEW_TIMER##*/}" "$E_RENEW_TIMER"
}

# check_endpoint_contents: the configuration that proves Nginx is this
# tool's: each set-up component's Nginx site is exactly what this tool
# wrote for its recorded domain, /etc/nginx holds nothing else but the
# nginx package's own unchanged files (or, after a failed setup, is exactly
# as that setup's record fingerprints it, with Nginx stopped), and dpkg
# would purge nginx and nginx-common without touching another package.
# Run before the confirmation and again after the services stopped.
check_endpoint_contents() {
  ((REMOVE_NGINX)) || return 0
  local kind fp dir
  local -a confs=()
  for kind in wq grpc; do
    component_present "$kind" || continue
    endpoint "$kind"
    ((E_SET_UP)) || continue
    check_endpoint_conf "$kind"
    confs+=("${E_CONF##*/}")
  done
  check_real_dir /etc/nginx "$ROOT_IDS" 755
  for dir in /var/log/nginx /var/lib/nginx; do
    exists "$(sysroot "$dir")" || continue
    [[ -d $(sysroot "$dir") && ! -L $(sysroot "$dir") ]] || die "'$dir' is not a directory"
    check_same_device "$dir"
  done
  if ((WQ_RETRY || GRPC_RETRY)); then
    fp=$WQ_RETRY_FP
    ((WQ_RETRY)) || fp=$GRPC_RETRY_FP
    [[ $(nginx_fingerprint) == "$fp" ]] ||
      die "Nginx was changed after the failed setup its record describes, so this tool does not remove it; handle it by hand"
    [[ $(sys_query systemctl is-active "$NGINX_SERVICE") != active ]] ||
      die "Nginx was started after the failed setup its record describes, so this tool does not remove it; handle it by hand"
  else
    check_real_dir /etc/nginx/conf.d "$ROOT_IDS" 755
    check_real_dir /etc/nginx/sites-enabled "$ROOT_IDS" 755
    check_entries /etc/nginx/conf.d "${confs[@]}"
    check_entries /etc/nginx/sites-enabled
    grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
      "$(sysroot /etc/nginx/nginx.conf)" 2>/dev/null ||
      die "'/etc/nginx/nginx.conf' does not include /etc/nginx/conf.d/*.conf; handle Nginx by hand"
    check_nginx_package_files "${confs[@]}"
  fi
  check_nginx_purge
}

# check_endpoint_conf KIND: the Nginx site of the set-up component KIND is
# exactly what this tool writes for its recorded domain (with either of
# the two HTTP/2 spellings, for the Nginx of the time).
check_endpoint_conf() {
  endpoint "$1"
  local actual size domain with_wq expected old new
  actual=$(<"$(sysroot "$E_CONF")") || die "cannot read '$E_CONF'"
  size=$(stat -c %s -- "$(sysroot "$E_CONF")") || die "cannot inspect '$E_CONF'"
  if [[ $1 == wq ]]; then
    domain=${WQ_REC[domain]}
    old=$(DOMAIN=$domain NGINX_NEW_HTTP2=0 render_nginx wallet-query.conf) || exit 1
    new=$(DOMAIN=$domain NGINX_NEW_HTTP2=1 render_nginx wallet-query.conf) || exit 1
  else
    domain=${GRPC_REC[domain]} with_wq=${GRPC_REC[with_wallet_query]}
    old=$(DOMAIN=$domain WITH_WQ=$with_wq NGINX_NEW_HTTP2=0 grpc_nginx_conf https) || exit 1
    new=$(DOMAIN=$domain WITH_WQ=$with_wq NGINX_NEW_HTTP2=1 grpc_nginx_conf https) || exit 1
  fi
  [[ ($actual == "$old" || $actual == "$new") && $size == "$(LC_ALL=C byte_length "$actual"$'\n')" ]] ||
    die "'$E_CONF' differs from what this tool wrote for $domain; it was changed after the setup, so this tool does not remove Nginx; handle it by hand"
}

# check_nginx_package_files CONF...: everything under /etc/nginx is either
# one of this tool's sites (CONF..., already checked) or a file the nginx
# or nginx-common package installed, and each of the packages' conffiles
# there is unchanged (its md5sum as dpkg recorded it). Purging the
# packages removes /etc/nginx entirely, so nothing else may be in it.
check_nginx_package_files() {
  local listed conffiles entry rel sum
  local -a ours=()
  for rel in "$@"; do ours+=("/etc/nginx/conf.d/$rel"); done
  listed=$(dpkg-query -L nginx-common nginx 2>/dev/null) ||
    die "cannot list the files of the nginx packages; handle Nginx by hand"
  conffiles=$(dpkg-query -W -f='${Conffiles}\n' nginx-common nginx 2>/dev/null) ||
    die "cannot list the conffiles of the nginx packages; handle Nginx by hand"
  while IFS= read -r -d '' entry; do
    rel=${entry#"$SYSROOT"}
    [[ $rel != /etc/nginx ]] || continue
    [[ " ${ours[*]} " != *" $rel "* ]] || continue
    grep -qxF -- "$rel" <<<"$listed" ||
      die "'$rel' was written by neither the nginx package nor this tool, so this tool does not remove Nginx; handle it by hand"
    if [[ $'\n'$conffiles =~ $'\n'\ "$rel"\ ([0-9a-f]{32}) ]]; then
      [[ -f $entry && ! -L $entry ]] || die "'$rel' is not a regular file; handle Nginx by hand"
      sum=$(md5sum -- "$entry") || die "cannot read '$rel'"
      [[ ${sum:0:32} == "${BASH_REMATCH[1]}" ]] ||
        die "'$rel' was changed after the nginx package installed it, so this tool does not remove Nginx; handle it by hand"
    fi
  done < <(find "$(sysroot /etc/nginx)" -mindepth 1 -print0 2>/dev/null)
}

# The one package command for Nginx: dpkg, not apt-get, so that by its own
# rules it removes nginx and nginx-common and nothing else (it refuses while
# another installed package depends on them). No network. nginx-common came
# with nginx on a host that had neither (lib/wallet-query.sh and lib/grpc.sh
# refuse a host with any web server package), so both are this tool's.
readonly -a DPKG_PURGE_NGINX=(dpkg --purge -- nginx nginx-common)

# check_nginx_purge: dpkg's dry run (read-only) of the purge must succeed:
# no other installed package depends on nginx or nginx-common.
check_nginx_purge() {
  timeout --kill-after=5 "$APT_SECONDS" env DEBIAN_FRONTEND=noninteractive \
    dpkg --no-act --purge -- nginx nginx-common >/dev/null 2>&1 </dev/null ||
    die "other packages depend on nginx, or dpkg cannot purge it now; handle Nginx by hand"
}

# stop_endpoint_services: the renewal timers of the set-up components and,
# when it is this tool's, Nginx are stopped and disabled.
stop_endpoint_services() {
  local kind
  for kind in wq grpc; do
    component_present "$kind" || continue
    endpoint "$kind"
    ((E_SET_UP)) || continue
    step "stopping the certificate renewal of $E_NAME"
    sys_do systemctl stop "${E_RENEW_TIMER##*/}" || uninstall_failed "cannot stop ${E_RENEW_TIMER##*/}"
    sys_do systemctl disable "${E_RENEW_TIMER##*/}" || uninstall_failed "cannot disable ${E_RENEW_TIMER##*/}"
  done
  if ((REMOVE_NGINX)); then
    step "stopping Nginx"
    sys_do systemctl stop "$NGINX_SERVICE" || uninstall_failed "cannot stop $NGINX_SERVICE"
    sys_do systemctl disable "$NGINX_SERVICE" || uninstall_failed "cannot disable $NGINX_SERVICE"
  fi
}

# remove_endpoints: the files of every present component (its record
# last), then the Nginx packages and whatever their purge left empty.
remove_endpoints() {
  local kind units=0
  for kind in wq grpc; do
    component_present "$kind" || continue
    endpoint "$kind"
    if ((E_SET_UP)); then
      step "removing $E_NAME: its Nginx site, certificate, acme.sh, renewal timer and record"
      remove_target file "$E_CONF"
      remove_target file "$E_RENEW_TIMER"
      remove_target file "$E_RENEW_SERVICE"
      units=1
      remove_target tree "$E_TLS"
      remove_target tree "$E_OPT"
      remove_target tree "$E_HOME"
    else
      step "removing the record of the failed $E_NAME setup"
      remove_target file "$E_RETRY"
    fi
  done
  ((!units)) || sys_do systemctl daemon-reload || uninstall_failed "systemctl daemon-reload failed"
  ((REMOVE_NGINX)) || return 0
  step "purging the nginx and nginx-common packages"
  timeout --kill-after=5 "$APT_SECONDS" env DEBIAN_FRONTEND=noninteractive \
    "${DPKG_PURGE_NGINX[@]}" >&2 </dev/null || uninstall_failed "dpkg --purge nginx nginx-common failed"
  remove_leftovers nginx "${NGINX_DIRS[@]}"
}

# remove_leftovers PACKAGE DIR...: the purge normally removes PACKAGE's
# directories; one still there is removed only if it is empty and still the
# directory seen before the confirmation (never recursively).
remove_leftovers() {
  local pkg=$1 path now
  for path in "${@:2}"; do
    exists "$(sysroot "$path")" || continue
    [[ ${TARGET_ID[$path]} != absent ]] ||
      uninstall_failed "'$path' appeared after the checks; leaving it untouched"
    now=$(object_id tree "$(sysroot "$path")") || now=''
    [[ $now == "${TARGET_ID[$path]}" ]] ||
      uninstall_failed "'$path' changed after the checks; leaving it untouched"
    step "removing a leftover empty $pkg folder"
    rmdir -- "$(sysroot "$path")" 2>/dev/null ||
      uninstall_failed "'$path' is left after purging $pkg and is not empty; leaving it untouched"
  done
}

# The install record as read by read_install_record (key -> value). Global
# (-g): deploy.sh sources this file from inside a function.
# shellcheck disable=SC2034 # Read by lib/upgrade.sh.
declare -gA RECORD=()

# Identities (lib/install.sh object_id) and kinds (file or tree) of the
# objects to remove, taken before the confirmation; "absent" for an optional
# path that does not exist.
# Global (-g): deploy.sh sources this file from inside load_uninstall.
declare -gA TARGET_ID=() TARGET_KIND=()

# record_target KIND PATH: remember PATH's identity.
record_target() {
  local path
  path=$(sysroot "$2")
  TARGET_KIND[$2]=$1
  if ! exists "$path"; then
    TARGET_ID[$2]=absent
    return 0
  fi
  TARGET_ID[$2]=$(object_id "$1" "$path") || die "cannot inspect '$2'"
}

record_targets() {
  record_target file "$UNIT_FILE"
  record_target file "$TORRC"
  record_target file "$STATE_FILE"
  record_target tree "$OPT_TARI"
  record_target tree "$LOG_DIR"
  record_target tree "$NODE_BASE"
  record_target tree "$TARI_HOME"
  local path kind
  for path in "${TOR_DIRS[@]}"; do
    record_target tree "$path"
  done
  for kind in wq grpc; do
    component_present "$kind" || continue
    endpoint "$kind"
    if ((E_SET_UP)); then
      record_target file "$E_CONF"
      record_target file "$E_RENEW_SERVICE"
      record_target file "$E_RENEW_TIMER"
      record_target file "$E_STATE"
      record_target tree "$E_TLS"
      record_target tree "$E_OPT"
      record_target tree "$E_HOME"
    else
      record_target file "$E_RETRY"
    fi
  done
  if ((REMOVE_NGINX)); then
    for path in "${NGINX_DIRS[@]}"; do
      record_target tree "$path"
    done
  fi
}

# recheck_targets: after the services stopped and before anything is
# removed, every object to remove (and the files that prove ownership) is
# still the one checked before the confirmation.
recheck_targets() {
  local path now
  step "re-checking the files to remove"
  for path in "${!TARGET_ID[@]}"; do
    [[ ${TARGET_ID[$path]} != absent ]] || continue
    # A Tor directory that went away with Tor needs no removal.
    if [[ " ${TOR_DIRS[*]} " == *" $path "* ]] && ! exists "$(sysroot "$path")"; then
      continue
    fi
    now=$(object_id "${TARGET_KIND[$path]}" "$(sysroot "$path")") || now=''
    [[ $now == "${TARGET_ID[$path]}" ]] ||
      uninstall_failed "'$path' changed after the checks; leaving it untouched"
  done
  (check_template_file "$TORRC" torrc && check_template_file "$UNIT_FILE" minotari-mainnet.service &&
    check_tor_dirs && check_tor_purge && check_no_mounts && check_endpoint_contents) ||
    uninstall_failed "the Tor, node, Wallet Query, gRPC or Nginx configuration changed after the checks; nothing was removed"
}

# remove_target KIND PATH: remove PATH (a file, or a tree with
# lib/install.sh remove_tree: no symlink followed, no other file system),
# only while it still has the identity recorded before the confirmation.
remove_target() {
  local kind=$1 path id now
  path=$(sysroot "$2")
  id=${TARGET_ID[$2]}
  now=$(object_id "$kind" "$path") || now=''
  [[ -n $now && $now == "$id" ]] ||
    uninstall_failed "'$2' changed after the checks; leaving it untouched"
  case "$kind" in
    file) rm -f -- "$path" ;;
    tree) remove_tree "$path" "$id" ;;
  esac || uninstall_failed "cannot remove '$2'"
  ! exists "$path" || uninstall_failed "cannot remove '$2'"
}

remove_unit() {
  step "removing the node service"
  remove_target file "$UNIT_FILE"
  sys_do systemctl daemon-reload || uninstall_failed "systemctl daemon-reload failed"
}

remove_node_files() {
  step "removing the Minotari program, the node data and its logs"
  remove_target tree "$OPT_TARI"
  remove_target tree "$LOG_DIR"
  remove_target tree "$NODE_BASE"
}

remove_account() {
  step "removing user and group $SERVICE_USER"
  sys_do userdel "$SERVICE_USER" || uninstall_failed "cannot remove user $SERVICE_USER"
  # userdel may already have removed the user's own group.
  if getent group "$SERVICE_USER" >/dev/null; then
    sys_do groupdel "$SERVICE_USER" || uninstall_failed "cannot remove group $SERVICE_USER"
  fi
}

remove_state() {
  step "removing the install record"
  remove_target file "$STATE_FILE"
  rmdir -- "$(sysroot "$TARI_HOME")" || uninstall_failed "cannot remove '$TARI_HOME' (not empty?)"
}

remove_tor_leftovers() {
  remove_leftovers tor "${TOR_DIRS[@]}"
}

# in_debian_tor: true if the service user is listed in group debian-tor.
in_debian_tor() {
  local members
  members=$(user_field group debian-tor 4) || return 1
  [[ ,$members, == *",$SERVICE_USER,"* ]]
}

# submission_id_saved: a submit command saved a submission ID next to
# deploy.sh (anything at that path; what it is matters only when removing).
submission_id_saved() {
  [[ -n $INSTALL_SOURCE_DIR ]] && exists "$INSTALL_SOURCE_DIR/$SUBMISSION_ID_FILE"
}

# remove_submission_id: last of all, once everything else is verified gone,
# remove the saved submission ID (SUBMISSION_ID_FILE next to deploy.sh) and
# nothing else of this checkout. Only a plain file is removed; anything
# else at that path, or a file that cannot be removed, is left and
# reported: the uninstall itself is complete. Sets SUBMISSION_ID_REMOVED.
remove_submission_id() {
  local path=$INSTALL_SOURCE_DIR/$SUBMISSION_ID_FILE
  SUBMISSION_ID_REMOVED=0
  submission_id_saved || return 0
  if [[ -f $path && ! -L $path ]] && rm -f -- "$path" && ! exists "$path"; then
    SUBMISSION_ID_REMOVED=1
    return 0
  fi
  printf '%s: warning: cannot remove %s; remove it by hand\n' "$PROG" "'$path'" >&2
}

# verify_removed: the node, its account, tor and every component that was
# to be removed are really gone.
verify_removed() {
  local path problem kind unit
  local -a problems=() paths=("$UNIT_FILE" "$OPT_TARI" "$TARI_HOME" "$LOG_DIR") units=("$NODE_SERVICE")
  for kind in wq grpc; do
    component_present "$kind" || continue
    endpoint "$kind"
    paths+=("$E_HOME" "$E_OPT" "$E_TLS" "$E_CONF" "$E_RENEW_SERVICE" "$E_RENEW_TIMER" "$E_RETRY")
    ((!E_SET_UP)) || units+=("${E_RENEW_SERVICE##*/}" "${E_RENEW_TIMER##*/}")
  done
  ((!REMOVE_NGINX)) || paths+=("${NGINX_DIRS[@]}")
  for path in "${paths[@]}"; do
    ! exists "$(sysroot "$path")" || problems+=("'$path' still exists")
  done
  for unit in "${units[@]}"; do
    [[ $(sys_query systemctl show -p LoadState --value "$unit") == not-found ]] ||
      problems+=("$unit is still known to systemd")
  done
  if ((REMOVE_NGINX)); then
    ! package_installed nginx || problems+=("the nginx package is still installed")
    ! package_installed nginx-common || problems+=("the nginx-common package is still installed")
  fi
  ! getent passwd "$SERVICE_USER" >/dev/null || problems+=("user $SERVICE_USER still exists")
  ! getent group "$SERVICE_USER" >/dev/null || problems+=("group $SERVICE_USER still exists")
  ! in_debian_tor || problems+=("$SERVICE_USER is still a member of group debian-tor")
  ! package_installed tor || problems+=("the tor package is still installed")
  ((${#problems[@]} == 0)) && return 0
  for problem in "${problems[@]}"; do
    printf '%s: error: uninstall did not complete: %s\n' "$PROG" "$problem" >&2
  done
  exit 1
}

print_uninstall_plan() {
  local wq='' grpc='' nginx='' saved=''
  if ((${MENU_MODE:-0})); then
    ((!WQ_PRESENT)) || wq=$'\n  - Wallet Query over HTTPS: its web server setup, certificate and renewal'
    ((!WQ_RETRY)) || wq=$'\n  - what was left of the Wallet Query setup that failed'
    ((!GRPC_PRESENT)) || grpc=$'\n  - Base Node gRPC over HTTPS: its web server setup, certificate and renewal'
    ((!GRPC_RETRY)) || grpc=$'\n  - what was left of the Base Node gRPC setup that failed'
    ((!REMOVE_NGINX)) || nginx=$'\n  - the Nginx web server, which this tool installed for them'
    ! submission_id_saved || saved=$'\n  - the saved TariTalk submission ID ('$SUBMISSION_ID_FILE' next to deploy.sh)'
    print_text <<PLAN
Uninstall all
  This permanently deletes, with no backup and no way to undo it:
  - the node, its blockchain data and its identity (other nodes will see a
    new node if you install again)
  - its configuration and logs, the installed Minotari program and the
    node's system user
  - Tor, which this tool installed for the node$wq$grpc$nginx$saved
  Kept: the other APT packages and this tool.
  Not changed: DNS, firewalls and cloud security groups.
PLAN
    return 0
  fi
  if ((WQ_PRESENT)); then
    printf -v wq '  Wallet Query:   https://%s: %s, %s,\n                  %s, %s and\n                  %s (with its record)\n' \
      "${WQ_REC[domain]}" "$WQ_NGINX_CONF" "$WQ_TLS_DIR" "$WQ_OPT" "$RENEW_TIMER" "$WQ_HOME"
  elif ((WQ_RETRY)); then
    printf -v wq '  Wallet Query:   the record of its failed setup, %s\n' "$WQ_RETRY_RECORD"
  fi
  if ((GRPC_PRESENT)); then
    printf -v grpc '  Base Node gRPC: %s:443: %s, %s,\n                  %s, %s and\n                  %s (with its record)\n' \
      "${GRPC_REC[domain]}" "$GRPC_NGINX_CONF" "$GRPC_TLS_DIR" "$GRPC_OPT" "$GRPC_RENEW_TIMER" "$GRPC_HOME"
  elif ((GRPC_RETRY)); then
    printf -v grpc '  Base Node gRPC: the record of its failed setup, %s\n' "$GRPC_RETRY_RECORD"
  fi
  if ((REMOVE_NGINX)); then
    printf -v nginx '  Nginx:          the nginx and nginx-common packages, installed by this tool on\n                  a host without a web server (%s stopped and\n                  disabled, dpkg --purge), with /etc/nginx, /var/log/nginx and\n                  /var/lib/nginx (removed by the package'"'"'s own purge)\n' "$NGINX_SERVICE"
  fi
  ! submission_id_saved ||
    printf -v saved '  Submission ID:  %s (the submission ID saved by submit)\n' "$INSTALL_SOURCE_DIR/$SUBMISSION_ID_FILE"
  local unchanged='DNS, Cloudflare, firewalls, cloud security groups'
  ((REMOVE_NGINX)) || unchanged='DNS, Nginx, TLS, Cloudflare, firewalls, cloud security groups'
  print_text <<PLAN
Uninstall all plan
  This permanently deletes, with no backup and no way to undo it:
  Node service:   $NODE_SERVICE (stopped, disabled, unit file removed)
  Node data:      $TARI_HOME: the blockchain database, the node identity,
                  the configuration and the install record
  Node logs:      $LOG_DIR
  Release:        $OPT_TARI (the installed Minotari release)
  Account:        system user and group $SERVICE_USER
  Tor:            the tor package and its service, installed and configured
                  by this tool on a clean host ($TOR_SERVICE stopped,
                  $TOR_MASTER_SERVICE disabled, dpkg --purge), with
                  /var/lib/tor, /var/log/tor and /run/tor (removed by the
                  package's own purge)
$wq$grpc$nginx${saved}  Kept:           ca-certificates, curl, jq, openssl, unzip, other packages,
                  APT caches and this checkout
  Not changed:    $unchanged
PLAN
}

cmd_uninstall() {
  # The command takes no options: only a lone --help, anything else is
  # refused before any check of the host.
  if (($# > 0)); then
    if [[ $# == 1 && ($1 == --help || $1 == -h) ]]; then
      uninstall_usage
      return 0
    fi
    [[ $1 == --help || $1 == -h ]] && usage_error "uninstall takes no arguments besides --help"
    usage_error "unknown uninstall option '$1'"
  fi
  if ! is_root; then
    printf 'Please run as root.\n' >&2
    exit 1
  fi
  PATH=$INSTALL_PATH
  export PATH
  umask 022
  local cmd
  for cmd in "${UNINSTALL_DEPENDENCIES[@]}"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
  # Every check is read-only; any failure (die) refuses the whole uninstall.
  trap uninstall_refused EXIT
  read_install_record
  check_account
  check_node_files
  check_unit
  check_tor
  check_endpoints
  check_no_mounts
  record_targets
  trap - EXIT
  print_uninstall_plan
  local answer=''
  printf 'Uninstall the node, Wallet Query and Base Node gRPC? [y/N]: '
  IFS= read -r answer || answer=''
  if [[ $answer != y && $answer != Y ]]; then
    printf '\nUninstall cancelled; nothing was changed.\n'
    return 0
  fi
  printf '\n'
  stop_services
  ! processes_of_uid "${TARI_IDS%%:*}" ||
    uninstall_failed "processes of user $SERVICE_USER are still running after stopping the services; nothing was removed"
  stop_endpoint_services
  recheck_targets
  remove_endpoints
  purge_tor
  remove_unit
  remove_node_files
  remove_account
  remove_state
  remove_tor_leftovers
  verify_removed
  remove_submission_id

  local kept='' pkg uninstalled='Minotari node' removed=''
  local removed_base='node service, node data, node logs, Tari release, tari account, tor package'
  for pkg in "${RECORDED_PACKAGES[@]}" "${ENDPOINT_PACKAGES[@]}"; do
    [[ $pkg != tor && $pkg != nginx && ", $kept, " != *", $pkg, "* ]] || continue
    kept+="${kept:+, }$pkg"
  done
  ((!WQ_PRESENT)) || uninstalled+=', Wallet Query'
  ((!GRPC_PRESENT)) || uninstalled+=', Base Node gRPC'
  ((!WQ_PRESENT)) || removed+=', Wallet Query files (Nginx site, certificate, acme.sh, renewal timer, record)'
  ((!WQ_RETRY)) || removed+=', record of the failed Wallet Query setup'
  ((!GRPC_PRESENT)) || removed+=', Base Node gRPC files (Nginx site, certificate, acme.sh, renewal timer, record)'
  ((!GRPC_RETRY)) || removed+=', record of the failed Base Node gRPC setup'
  ((!REMOVE_NGINX)) || removed+=', nginx and nginx-common packages'
  ((!SUBMISSION_ID_REMOVED)) || removed+=", saved submission ID ($SUBMISSION_ID_FILE)"
  print_text <<DONE
Uninstalled: $uninstalled
Removed: $removed_base$removed
Kept APT packages: ${kept:-none}
DNS, firewall and cloud security settings were not changed.
DONE
}
