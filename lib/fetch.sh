# shellcheck shell=bash
# fetch: download and verify a fixed-version, first-party Minotari release
# into a user-chosen directory. Sourced by deploy.sh; relies on
# its die/usage_error helpers.

readonly RELEASE_BASE_URL=https://github.com/tari-project/tari/releases/download
readonly RELEASE_API_URL=https://api.github.com/repos/tari-project/tari/releases
readonly MAX_API_BYTES=2097152

# Release versions: MAJOR.MINOR.PATCH with an optional dot-separated
# alphanumeric pre-release (e.g. 6.0.1-pre.2), optionally prefixed by "v".
# This excludes whitespace, '/', '..', URLs, '%', '?', and shell syntax, so
# the version is safe to use in URLs and file names.
readonly RE_RELEASE_VERSION='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'

# Resolved destinations may not be, or be inside, any of these.
readonly SYSTEM_DIRS=(/etc /opt /usr /var /bin /sbin /boot /root /proc /sys
  /dev /run /lib /lib64)

# is_system_path PATH: true if the resolved absolute PATH is /, or is or is
# inside a system directory.
is_system_path() {
  local system
  [[ $1 == / ]] && return 0
  for system in "${SYSTEM_DIRS[@]}"; do
    [[ $1 == "$system" || $1 == "$system"/* ]] && return 0
  done
  return 1
}

# resolve_destination DIR: set DESTINATION to the real path of DIR after
# checking it is an existing, writable, non-system directory. Symlinks are
# resolved first, so they cannot be used to reach a system location.
resolve_destination() {
  local dir=$1 real
  [[ -d $dir ]] || die "destination '$dir' is not an existing directory"
  real=$(realpath -e -- "$dir") || die "cannot resolve destination '$dir'"
  ! is_system_path "$real" ||
    die "destination '$dir' resolves to '$real': refusing system location"
  # Only a private directory of the current user: nobody else may rename
  # or replace what fetch creates inside it.
  local info owner mode
  info=$(stat -c '%u %a' -- "$real") || die "cannot inspect destination '$real'"
  read -r owner mode <<<"$info"
  [[ $owner == "$EUID" ]] ||
    die "destination '$real' is not owned by the current user"
  ((8#$mode & 8#022)) &&
    die "destination '$real' is group- or world-writable"
  [[ -w $real ]] || die "destination '$real' is not writable"
  DESTINATION=$real
  # Its identity as validated; fetch later works only inside the directory
  # with exactly this identity (see pin_destination).
  DEST_ID=$(path_id "$real")
  [[ $DEST_ID == *":$EUID:directory" ]] ||
    die "destination '$real' changed while it was being checked"
}

# is_target_asset NAME VERSION PLATFORM: true if NAME is exactly
# tari_suite-VERSION-mainnet-<7-40 lowercase hex commit>-PLATFORM.zip.
is_target_asset() {
  local prefix="tari_suite-$2-mainnet-" suffix="-$3.zip" commit
  [[ $1 == "$prefix"*"$suffix" ]] || return 1
  commit=${1#"$prefix"}
  commit=${commit%"$suffix"}
  [[ $commit =~ ^[0-9a-f]{7,40}$ ]]
}

# sha256sum(1) check lines: 64 lowercase hex digits, then two spaces (text
# mode) or space-asterisk (binary mode, as real Tari manifests use for some
# assets), then a plain file name: no directories, no "..".
readonly RE_CHECKSUM_LINE='^([0-9a-f]{64}) [ *]([A-Za-z0-9._+-]+)$'

# parse_checksums FILE LABEL: parse FILE strictly as data into the
# CHECKSUMS associative array (file name -> SHA-256). Fails closed on NUL
# bytes, empty files, any non-conforming line, and duplicate file names.
parse_checksums() {
  local file=$1 label=$2 line lineno=0
  local -a lines
  CHECKSUMS=()
  if IFS= read -r -d '' _ <"$file"; then
    die "malformed $label: contains NUL byte"
  fi
  mapfile -t lines <"$file" || die "cannot read $label"
  ((${#lines[@]} > 0)) || die "malformed $label: empty"
  for line in "${lines[@]}"; do
    lineno=$((lineno + 1))
    [[ $line =~ $RE_CHECKSUM_LINE && ${BASH_REMATCH[2]} != *..* ]] ||
      die "malformed $label line $lineno: expected '<sha256>  <file name>'"
    [[ -z ${CHECKSUMS[${BASH_REMATCH[2]}]-} ]] ||
      die "malformed $label line $lineno: duplicate file name"
    CHECKSUMS[${BASH_REMATCH[2]}]=${BASH_REMATCH[1]}
  done
}

# Hosts requests may go to: the API, and github.com release downloads with
# their redirects to GitHub's release asset storage. Checked before each
# request, including every redirect hop.
readonly API_HOSTS=api.github.com
readonly DOWNLOAD_HOSTS='github.com objects.githubusercontent.com release-assets.githubusercontent.com'

# The external command currently being waited for: CHILD_STARTING is set
# from just before it is started until its PID is in ACTIVE_CHILD. A signal
# arriving in that window is held in PENDING_SIGNAL and delivered to the
# child as soon as its PID is known.
ACTIVE_CHILD=
CHILD_STARTING=0
PENDING_SIGNAL=

install_signal_traps() {
  trap 'on_signal HUP 129' HUP
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
}

child_starting() {
  PENDING_SIGNAL=
  CHILD_STARTING=1
}

# child_started PID: register the started child; deliver a pending signal.
child_started() {
  ACTIVE_CHILD=$1
  CHILD_STARTING=0
  if [[ -n $PENDING_SIGNAL ]]; then
    # shellcheck disable=SC2086 # "SIGNAL STATUS", split on purpose.
    on_signal $PENDING_SIGNAL
  fi
}

# run_child SECONDS CMD...: run CMD under `timeout` (which gives it its own
# process group) as a tracked background child and wait for it, so that
# on_signal can forward HUP/INT/TERM to it. Returns CMD's status (124 on
# timeout). CMD never gets the terminal as input: in its own process group
# it is in the terminal's background, where reading the terminal stops it
# (apt-get, given a terminal, also switches it to raw mode and reads it).
# Bash would give it /dev/null by itself only until the shell has once run
# a loop or block with redirected input.
run_child() {
  local secs=$1 rc=0
  shift
  child_starting
  timeout --kill-after=5 "$secs" "$@" </dev/null &
  child_started "$!"
  wait "$ACTIVE_CHILD" || rc=$?
  ACTIVE_CHILD=
  return "$rc"
}

# await_child_exec PID: a child just forked by `cmd &` is, until it execs
# CMD, still a copy of this shell, whose inherited trap would swallow a
# signal. Wait (bounded, builtins only) until PID runs another program or
# is gone.
await_child_exec() {
  local self child i
  { read -r self <"/proc/$BASHPID/comm"; } 2>/dev/null || return 0
  for ((i = 0; i < 200000; i++)); do
    { read -r child <"/proc/$1/comm"; } 2>/dev/null || return 0
    [[ $child == "$self" ]] || return 0
  done
}

# on_signal SIGNAL STATUS: stop the active child's process group (via
# timeout), wait for it, and exit with STATUS (the EXIT trap cleans up).
# While a child is starting and its PID is not yet known, only record the
# signal; child_started delivers it. Whatever SIGNAL was, the child gets
# TERM: every timeout passes TERM on and waits for the child to clean up
# (uutils timeout 0.10, Ubuntu 26.04's, does not for INT or HUP). Its status
# does not matter (GNU timeout reports 128+SIGNAL, uutils timeout 124).
on_signal() {
  if ((CHILD_STARTING)) && [[ -z ${ACTIVE_CHILD-} ]]; then
    PENDING_SIGNAL="$1 $2"
    return 0
  fi
  trap '' HUP INT TERM
  if [[ -n ${ACTIVE_CHILD-} ]]; then
    await_child_exec "$ACTIVE_CHILD"
    kill -s TERM "$ACTIVE_CHILD" 2>/dev/null
    wait "$ACTIVE_CHILD" 2>/dev/null || true
  fi
  # Leave through errexit, as a command failing with STATUS: bash then first
  # drops the redirections of the interrupted step, so the EXIT trap's
  # messages reach the real stderr (`exit` alone would keep them).
  fail_with "$2"
  exit "$2"
}

# fail_with STATUS: a command that fails with STATUS (see on_signal).
fail_with() { return "$1"; }

# Pipeline for http_get: stream curl's output through `head -c LIMIT`, so at
# most LIMIT bytes (MAX_BYTES + 1) are ever written; exit with curl's status.
# shellcheck disable=SC2016 # Expanded by the child bash, not here.
readonly CAPPED_PIPE='limit=$1 out=$2; shift 2; "$@" | head -c "$limit" >"$out"; status=("${PIPESTATUS[@]}"); exit "${status[0]}"'

# url_authority URL: print the authority (host[:port]) of an absolute
# https URL without userinfo, whitespace or control characters; fail
# otherwise.
url_authority() {
  [[ $1 =~ ^https://([A-Za-z0-9.-]+(:[0-9]{1,5})?)(/[^[:space:][:cntrl:]]*)?$ ]] ||
    return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# redirect_target URL HEADERS: from the response headers in file HEADERS,
# print the absolute URL a redirect from URL points to. Only an absolute
# https URL, or a path starting with a single "/" (resolved against URL's own
# scheme and authority), is accepted; anything else fails.
redirect_target() {
  local line location='' count=0 authority
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ ${line,,} == location:* ]]; then
      location=${line#*:}
      location=${location#"${location%%[![:blank:]]*}"}
      count=$((count + 1))
    fi
  done <"$2"
  ((count == 1)) && [[ -n $location && $location != *[[:space:][:cntrl:]]* ]] ||
    return 1
  if [[ $location == /* && $location != //* ]]; then
    authority=$(url_authority "$1") || return 1
    location="https://$authority$location"
  fi
  printf '%s\n' "$location"
}

# http_get URL OUTPUT MAX_SECONDS MAX_BYTES ALLOWED_HOSTS [CURL_ARGS...]:
# fetch URL (built by the caller from fixed first-party constants and
# validated parts) into OUTPUT, relative to the current directory. curl's
# config files are ignored (--disable) and HTTPS is required. Redirects are
# NOT followed by curl: each Location is parsed and checked here (https,
# host in ALLOWED_HOSTS, at most 5 hops) before the next request is made.
# The body is capped at MAX_BYTES while streaming, and all hops together get
# MAX_SECONDS. No credentials are sent. Fails with a message that
# distinguishes size, timeout, HTTP, early-end, redirect and other errors.
http_get() {
  local first=$1 url=$1 out=$2 max=$4 hosts=$5 hops=0 deadline=$((SECONDS + $3))
  local rc left size code line next authority
  shift 5
  if ! authority=$(url_authority "$url") || [[ " $hosts " != *" $authority "* ]]; then
    die "refusing to download from $url"
  fi
  while :; do
    left=$((deadline - SECONDS))
    ((left > 0)) || die "download timed out: $first"
    rc=0
    run_child $((left + 15)) bash -c "$CAPPED_PIPE" capped "$((max + 1))" "$out" \
      curl --disable --fail --silent --show-error --proto =https \
      --connect-timeout 30 --max-time "$left" --max-filesize "$max" \
      --dump-header "$out.headers" --write-out '%{stderr}%{http_code}\n' \
      "$@" -- "$url" 2>"$out.stderr" || rc=$?
    size=0
    [[ -f $out ]] && size=$(stat -c %s -- "$out")
    if ((size > max || rc == 63)); then
      die "download exceeds the $max-byte limit: $first"
    fi
    case "$rc" in
      0) ;;
      22) die "download failed with an HTTP error: $first" ;;
      28 | 124 | 137) die "download timed out: $first" ;;
      18 | 56) die "download ended early: $first" ;;
      *) die "download failed (curl exit $rc): $first" ;;
    esac
    code=
    while IFS= read -r line; do code=$line; done <"$out.stderr"
    case "$code" in
      2[0-9][0-9]) break ;;
      301 | 302 | 303 | 307 | 308) ;;
      *) die "download failed with unexpected HTTP status ${code:-none}: $first" ;;
    esac
    hops=$((hops + 1))
    ((hops <= 5)) || die "too many redirects: $first"
    next=$(redirect_target "$url" "$out.headers") ||
      die "invalid redirect location: $first"
    [[ $next == https://* ]] || die "download was redirected to a non-HTTPS URL: $first"
    authority=$(url_authority "$next") || die "invalid redirect location: $first"
    [[ " $hosts " == *" $authority "* ]] ||
      die "download was redirected to a disallowed host ($authority): $first"
    url=$next
  done
  rm -f -- "$out.stderr" "$out.headers" ||
    die "cannot remove temporary files for $out"
}

# download TAG NAME OUTPUT MAX_SECONDS: fetch release asset NAME, capped at
# the exact size the GitHub Releases API reported for it.
download() {
  check_stage
  http_get "$RELEASE_BASE_URL/$1/$2" "$3" "$4" "${ASSET_SIZES[$2]}" "$DOWNLOAD_HOSTS"
}

# verify_api_digest NAME FILE: FILE's SHA-256 must equal the digest the
# GitHub Releases API reported for asset NAME.
verify_api_digest() {
  local actual
  actual=$(sha256_of_file "$2") || exit 1
  [[ sha256:$actual == "${ASSET_DIGESTS[$1]}" ]] ||
    die "$1 does not match its SHA-256 digest from the GitHub API"
}

# fetch_release_metadata URL: fetch GitHub Releases API metadata into
# release.json in the metadata directory (the working directory; never the
# destination). No credentials are sent.
fetch_release_metadata() {
  check_meta_dir
  http_get "$1" release.json 60 "$MAX_API_BYTES" "$API_HOSTS" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28'
}

# jq program: check the release object's shape and types, then print one
# header line (tag_name, draft, prerelease) and one line per asset (name,
# size, digest or "", browser_download_url). Fields are joined with the
# ASCII unit separator (0x1f, not IFS whitespace, so empty fields survive);
# control characters in any field are rejected.
# shellcheck disable=SC2016 # $m and $ names are jq variables, not shell.
readonly JQ_RELEASE='
  def fail($m): error("malformed release metadata: " + $m);
  def row: map(tostring)
    | if any(.[]; test("[\u0000-\u001f\u007f]")) then fail("control character")
      else join("\u001f") end;
  if type != "object" then fail("not an object") else . end
  | if (.tag_name | type) != "string" then fail("tag_name") else . end
  | if (.draft | type) != "boolean" then fail("draft") else . end
  | if (.prerelease | type) != "boolean" then fail("prerelease") else . end
  | if (.assets | type) != "array" then fail("assets") else . end
  | ([.tag_name, .draft, .prerelease] | row),
    (.assets[]
      | if type != "object" or (.name | type) != "string" or .name == ""
          or (.size | type) != "number"
          or (.browser_download_url | type) != "string"
          or ((.digest | type) != "string" and .digest != null)
        then fail("asset entry") else . end
      | [.name, .size, (.digest // ""), .browser_download_url] | row)'

# load_release_metadata EXPECTED_TAG: validate release.json and set
# RELEASE_TAG, RELEASE_PRERELEASE and the per-asset ASSET_SIZES,
# ASSET_DIGESTS and ASSET_URLS maps. EXPECTED_TAG is empty for "latest".
load_release_metadata() {
  local expected=$1 listing header draft name size digest url
  check_meta_dir
  listing=$(jq -r "$JQ_RELEASE" release.json 2>/dev/null) ||
    die "malformed release metadata from the GitHub Releases API"
  IFS=$'\x1f' read -r RELEASE_TAG draft RELEASE_PRERELEASE <<<"${listing%%$'\n'*}"
  [[ $RELEASE_TAG == v* && ${#RELEASE_TAG} -le 65 && $RELEASE_TAG =~ $RE_RELEASE_VERSION ]] ||
    die "release metadata has an invalid tag_name"
  [[ $draft == false ]] || die "release $RELEASE_TAG is a draft"
  if [[ -n $expected ]]; then
    [[ $RELEASE_TAG == "$expected" ]] ||
      die "release metadata is for tag $RELEASE_TAG, not $expected"
  else
    [[ $RELEASE_PRERELEASE == false ]] ||
      die "latest release $RELEASE_TAG is a pre-release"
  fi
  ASSET_SIZES=()
  ASSET_DIGESTS=()
  ASSET_URLS=()
  ASSET_COUNTS=()
  header=1
  while IFS=$'\x1f' read -r name size digest url; do
    if ((header)); then
      header=0
      continue
    fi
    ASSET_COUNTS[$name]=$((${ASSET_COUNTS[$name]-0} + 1))
    ASSET_SIZES[$name]=$size
    ASSET_DIGESTS[$name]=$digest
    ASSET_URLS[$name]=$url
  done <<<"$listing"
}

# require_asset NAME MAX_BYTES: NAME must be listed exactly once in the
# release metadata, with the exact first-party download URL for this tag, a
# sha256 digest, and a positive size of at most MAX_BYTES.
require_asset() {
  local name=$1 max=$2 size
  case "${ASSET_COUNTS[$name]-0}" in
    0) die "release asset $name: missing from release $RELEASE_TAG" ;;
    1) ;;
    *) die "release asset $name: listed more than once" ;;
  esac
  [[ ${ASSET_URLS[$name]} == "$RELEASE_BASE_URL/$RELEASE_TAG/$name" ]] ||
    die "release asset $name: unexpected download URL"
  [[ ${ASSET_DIGESTS[$name]} =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "release asset $name: missing or invalid digest"
  size=${ASSET_SIZES[$name]}
  if [[ ! $size =~ ^[1-9][0-9]{0,11}$ ]] || ((size > max)); then
    die "release asset $name: invalid size"
  fi
}
# Directories fetch works in: the validated destination, a private
# metadata directory under TMPDIR, and a staging directory inside the
# destination. Each is identified by its lstat identity
# (device:inode:owner:type). fetch enters each with `cd -P` and checks the
# identity of `.` (and of `..` for the staging directory), then uses only
# relative names: once entered, renaming or replacing a directory's pathname
# cannot redirect any write, publication or cleanup. Path strings are kept
# only for messages.
DESTINATION=
DEST_ID=
META_PATH=
META_NAME=
META_ID=
STAGE_NAME=
STAGE_ID=
STAGE_FILES=()

warn() {
  printf '%s: warning: %s\n' "$PROG" "$1" >&2
}

# path_id PATH: lstat identity of PATH (symlinks are not followed), or empty.
path_id() {
  stat -c '%d:%i:%u:%F' -- "$1" 2>/dev/null
}

# create_private_dir TEMPLATE: mktemp -d TEMPLATE and print "PATH" on line 1
# and its identity on line 2; it must be a directory owned by this user.
create_private_dir() {
  local path id
  path=$(mktemp -d "$1") || return 1
  id=$(path_id "$path")
  [[ $id == *":$EUID:directory" ]] || return 1
  printf '%s\n%s\n' "$path" "$id"
}

# enter_meta_dir: create the private metadata directory under TMPDIR (never
# the destination) and make it the working directory.
enter_meta_dir() {
  local created
  created=$(create_private_dir "${TMPDIR:-/tmp}/taritalk-fetch.XXXXXXXX") ||
    die "cannot create a private temporary directory"
  META_PATH=${created%%$'\n'*}
  META_ID=${created#*$'\n'}
  META_NAME=${META_PATH##*/}
  cd -P -- "$META_PATH" || die "cannot enter temporary directory '$META_PATH'"
  check_meta_dir
}

check_meta_dir() {
  [[ $(path_id .) == "$META_ID" ]] ||
    die "temporary directory '$META_PATH' was moved or replaced; stopping"
}

# leave_meta_dir: remove the metadata files and directory through the
# working directory, ending in its parent.
leave_meta_dir() {
  check_meta_dir
  remove_temp release.json release.json.stderr release.json.headers
  cd -P .. || die "cannot leave temporary directory '$META_PATH'"
  if [[ $(path_id "$META_NAME") == "$META_ID" ]]; then
    rmdir -- "$META_NAME" || die "cannot remove temporary directory '$META_PATH'"
  else
    warn "temporary directory '$META_PATH' was moved or replaced; leaving that path untouched"
  fi
  META_ID=
}

# pin_destination: enter the validated destination and require that what
# was entered is the directory that was validated (not something swapped in
# at its pathname since). From here on the destination is only used as the
# working directory or as `..` of the staging directory.
pin_destination() {
  local info owner mode
  cd -P -- "$DESTINATION" || die "cannot enter destination '$DESTINATION'"
  [[ $(path_id .) == "$DEST_ID" ]] ||
    die "destination '$DESTINATION' was moved or replaced; stopping"
  info=$(stat -c '%u %a' .) || die "cannot inspect destination '$DESTINATION'"
  read -r owner mode <<<"$info"
  if [[ $owner != "$EUID" ]] || ((8#$mode & 8#022)); then
    die "destination '$DESTINATION' changed ownership or permissions; stopping"
  fi
}

# create_stage FILE...: create the staging directory inside the pinned
# destination (the working directory), record its identity and the only
# file names fetch may create there, and enter it.
create_stage() {
  local created
  STAGE_FILES=("$@")
  created=$(create_private_dir "./.minotari-fetch.XXXXXXXX") ||
    die "cannot create a staging directory in '$DESTINATION'"
  STAGE_NAME=${created%%$'\n'*}
  STAGE_NAME=${STAGE_NAME#./}
  STAGE_ID=${created#*$'\n'}
  cd -P -- "$STAGE_NAME" || die "cannot enter staging directory '$DESTINATION/$STAGE_NAME'"
  check_stage
}

# check_stage: the working directory must be the staging directory, its
# parent the pinned destination, and the stage still at its name there.
check_stage() {
  [[ $(path_id .) == "$STAGE_ID" && $(path_id ..) == "$DEST_ID" &&
  $(path_id "../$STAGE_NAME") == "$STAGE_ID" ]] ||
    die "staging directory '$DESTINATION/$STAGE_NAME' was moved or replaced; stopping"
}

# fetch_cleanup: EXIT trap. Removes only fetch's own recorded file names and
# directories, only through working directories whose identity matches;
# otherwise warns and leaves the path alone. Never changes the exit status.
fetch_cleanup() {
  set +e
  local name
  if [[ -n $META_ID ]]; then
    if [[ $(path_id .) == "$META_ID" ]]; then
      rm -f -- release.json release.json.stderr release.json.headers
      cd -P .. && if [[ $(path_id "$META_NAME") == "$META_ID" ]]; then
        rmdir -- "$META_NAME" 2>/dev/null ||
          warn "could not remove temporary directory '$META_PATH'"
      else
        warn "temporary directory '$META_PATH' was moved or replaced; leaving that path untouched"
      fi
    elif [[ $(path_id "$META_PATH") == "$META_ID" ]]; then
      # Created but never entered, so still empty.
      rmdir -- "$META_PATH" 2>/dev/null ||
        warn "could not remove temporary directory '$META_PATH'"
    else
      warn "temporary directory '$META_PATH' was moved or replaced; leaving that path untouched"
    fi
  fi
  [[ -n $STAGE_ID ]] || return 0
  if [[ $(path_id .) == "$STAGE_ID" ]]; then
    for name in "${STAGE_FILES[@]}"; do
      if [[ -f $name || -L $name ]]; then
        rm -f -- "$name" || warn "could not remove staged file '$name'"
      fi
    done
    cd -P .. || return 0
  fi
  if [[ $(path_id .) == "$DEST_ID" && $(path_id "$STAGE_NAME") == "$STAGE_ID" ]]; then
    rmdir -- "$STAGE_NAME" 2>/dev/null ||
      warn "could not remove staging directory '$DESTINATION/$STAGE_NAME'"
  else
    warn "staging directory '$DESTINATION/$STAGE_NAME' was moved or replaced; leaving that path untouched"
  fi
}

# write_new_file NAME CONTENT: create NAME in the working directory with
# CONTENT, never following or overwriting an existing entry of that name
# (noclobber opens new files with O_EXCL).
write_new_file() {
  [[ ! -e $1 && ! -L $1 ]] || return 1
  (
    set -o noclobber
    printf '%s' "$2" >"$1"
  )
}

# check_private_regular NAME MODE: NAME (not following symlinks) must be a
# regular file owned by this user with exactly MODE and a single link.
check_private_regular() {
  local info
  info=$(stat -c '%F|%a|%u|%h' -- "$1" 2>/dev/null) ||
    die "refusing to publish: $1 is missing"
  [[ $info == "regular file|$2|$EUID|1" || $info == "regular empty file|$2|$EUID|1" ]] ||
    die "refusing to publish: $1 is not a private regular file (found ${info//|/, })"
}

# reverify_staged NAME SHA256 MODE: NAME must still be a private regular file
# with MODE and, unless SHA256 is empty, still have that SHA-256.
reverify_staged() {
  check_private_regular "$1" "$3"
  [[ -z $2 ]] && return 0
  [[ $(sha256_of_file "$1") == "$2" ]] ||
    die "refusing to publish: $1 changed after verification"
}

# remove_temp NAME...: remove fetch's own temporary files from the staging
# (working) directory, failing clearly if that is not possible.
remove_temp() {
  local name
  for name in "$@"; do
    rm -f -- "$name" || die "cannot remove temporary file $name"
  done
}

# publish_stage OUTPUT_NAME EXPECTED...: the staging directory must contain
# exactly the EXPECTED entries; then rename it, inside the pinned destination
# (via ..), to OUTPUT_NAME, never replacing or writing into an existing entry,
# and confirm that what now sits there is the staging directory itself.
publish_stage() {
  local out=$1 entry unexpected=''
  shift
  local -A expected=()
  for entry in "$@"; do expected[$entry]=1; done
  check_stage
  local -a present
  shopt -s nullglob dotglob
  present=(*)
  shopt -u nullglob dotglob
  for entry in "${present[@]}"; do
    [[ -n ${expected[$entry]-} ]] || unexpected+=" $entry"
  done
  [[ -z $unexpected ]] ||
    die "staging directory contains unexpected entries:$unexpected"
  ((${#present[@]} == $#)) || die "staging directory is missing expected files"
  # Publishing itself happens via `..`; this only makes sure the reported
  # path still names the pinned destination.
  [[ $(path_id "$DESTINATION") == "$DEST_ID" ]] ||
    die "destination '$DESTINATION' was moved or replaced; not publishing"
  [[ ! -e ../$out && ! -L ../$out ]] ||
    die "'$DESTINATION/$out' already exists; refusing to overwrite"
  # The outcome is classified below, so a failing mv must not end the script.
  mv --no-clobber --no-target-directory -- "../$STAGE_NAME" "../$out" 2>/dev/null || true
  if [[ $(path_id "../$out") == "$STAGE_ID" && -z $(path_id "../$STAGE_NAME") ]]; then
    STAGE_ID=
    return 0
  fi
  [[ -e ../$out || -L ../$out ]] &&
    die "'$DESTINATION/$out' already exists; refusing to overwrite"
  [[ $(path_id "../$STAGE_NAME") == "$STAGE_ID" ]] &&
    die "cannot move the staging directory to '$DESTINATION/$out'"
  die "staging directory '$DESTINATION/$STAGE_NAME' was moved or replaced while publishing"
}

# Commands fetch relies on; checked before anything else happens. Nothing is
# ever installed automatically.
readonly FETCH_DEPENDENCIES=(curl jq sha256sum unzip zipinfo mktemp realpath mv
  chmod rm rmdir timeout env uname stat head)

check_dependencies() {
  local cmd
  for cmd in "${FETCH_DEPENDENCIES[@]}"; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
}

# Archive limits: time for zipinfo and unzip, size of a listing, and the
# largest minotari_node accepted (declared in the ZIP and actually written).
readonly ZIP_LIST_SECONDS=30
readonly ZIP_EXTRACT_SECONDS=300
readonly MAX_LISTING_BYTES=1048576
readonly MAX_BINARY_BYTES=1073741824

# run_zipinfo ZIP OUT ZIPINFO_ARGS...: run zipinfo with a time limit,
# capping its output (written to OUT) at MAX_LISTING_BYTES.
run_zipinfo() {
  local zip=$1 out=$2 rc=0
  shift 2
  run_child "$ZIP_LIST_SECONDS" bash -c "$CAPPED_PIPE" capped \
    "$((MAX_LISTING_BYTES + 1))" "$out" zipinfo "$@" 2>/dev/null || rc=$?
  ((rc != 124 && rc != 137)) || die "timed out listing the contents of $zip"
  ((rc == 0)) || die "cannot list the contents of $zip"
  (($(stat -c %s -- "$out") <= MAX_LISTING_BYTES)) ||
    die "the listing of $zip is too large"
}

# extract_entry ZIP ENTRY OUT MAX_BYTES SECONDS: write the single archive
# entry ENTRY to OUT with a time limit, stopping at MAX_BYTES + 1 bytes while
# streaming (the ZIP's own size metadata is not trusted for this).
extract_entry() {
  local zip=$1 entry=$2 out=$3 max=$4 secs=$5 rc=0 size=0
  run_child "$secs" bash -c "$CAPPED_PIPE" capped "$((max + 1))" "$out" \
    unzip -p -- "$zip" "$entry" 2>/dev/null || rc=$?
  [[ -f $out ]] && size=$(stat -c %s -- "$out")
  ((size <= max)) || die "$entry from $zip exceeds the $max-byte limit"
  ((rc != 124 && rc != 137)) || die "timed out extracting $entry from $zip"
  ((rc == 0)) || die "cannot extract $entry from $zip"
}

# sha256_of_file FILE: print FILE's SHA-256 or fail.
sha256_of_file() {
  local sum
  if ! sum=$(sha256sum -- "$1") || [[ ! ${sum:0:64} =~ ^[0-9a-f]{64}$ ]]; then
    die "cannot compute SHA-256 of '${1##*/}'"
  fi
  printf '%s\n' "${sum:0:64}"
}

fetch_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD fetch --destination DIR [--version VERSION] [--arch ARCH] [--dry-run]

Download a Minotari Mainnet release from Tari's first-party GitHub Releases
and verify it, into a new directory inside DIR. Release metadata comes from
the GitHub Releases API ($RELEASE_API_URL);
files come only from $RELEASE_BASE_URL/<tag>/.

The ZIP must match the SHA-256 digest GitHub reports for it, the release
checksum manifest and the asset's .sha256 file. Only minotari_node is
extracted; nothing downloaded is ever executed. These checksums come from
the same GitHub release channel and are not a publisher signature (see
README).

This does not install a node, change the system, or start anything. It does
not need, and refuses to run as, root.

Options:
  --destination DIR  Existing directory owned by you, not group- or
                     world-writable, and not a system location (required)
  --version VERSION  Release to fetch, e.g. 1.2.3 or v1.2.3-pre.4. Default:
                     GitHub's latest full (non-pre-release) release
  --arch ARCH        Architecture (default: uname -m)
  --dry-run          Read the release metadata and show what would be fetched;
                     no assets are downloaded and nothing is written to DIR
  --help             Show this help and exit
USAGE
}

cmd_fetch() {
  local version='' destination='' arch='' dry_run=0
  while (($# > 0)); do
    case "$1" in
      --version | --destination | --arch)
        # A following option (e.g. `--version --help`) is a missing value.
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "$1 requires a value"
        case "$1" in
          --version) version=$2 ;;
          --destination) destination=$2 ;;
          --arch) arch=$2 ;;
        esac
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --help | -h)
        fetch_usage
        return 0
        ;;
      *)
        usage_error "unknown fetch option '$1'"
        ;;
    esac
  done
  [[ -n $destination ]] || usage_error "fetch requires --destination"

  if [[ -n $version ]]; then
    [[ ${#version} -le 64 && $version =~ $RE_RELEASE_VERSION ]] ||
      usage_error "invalid version (expected e.g. 1.2.3 or v1.2.3-pre.4)"
  fi
  # Only after all argument syntax is valid: runtime checks. fetch only
  # downloads into a user directory, so it never needs or accepts root.
  ((EUID != 0)) || die "fetch must not run as root"
  check_dependencies
  if [[ -z $arch ]]; then
    arch=$(uname -m) || die "cannot determine architecture with 'uname -m'"
  fi
  set_platform "$arch"
  resolve_destination "$destination"
  # Release metadata from the GitHub Releases API (read-only, also in dry-run).
  local tag='' version_source api_url
  if [[ -n $version ]]; then
    tag=v${version#v}
    version_source=explicit
    api_url="$RELEASE_API_URL/tags/$tag"
  else
    version_source=github-latest
    api_url="$RELEASE_API_URL/latest"
  fi
  umask 077
  trap fetch_cleanup EXIT
  install_signal_traps
  enter_meta_dir
  fetch_release_metadata "$api_url"
  local RELEASE_TAG RELEASE_PRERELEASE
  local -A ASSET_SIZES ASSET_DIGESTS ASSET_URLS ASSET_COUNTS
  load_release_metadata "$tag"
  leave_meta_dir
  tag=$RELEASE_TAG
  version=${tag#v}
  local manifest="tari_suite-$version.sha256-unsigned.txt"
  local output_name="minotari-$version-$PLATFORM"
  local output_dir="$DESTINATION/$output_name"
  [[ ! -e $output_dir && ! -L $output_dir ]] ||
    die "'$output_dir' already exists; refusing to overwrite"
  local name api_asset='' api_matches=0
  for name in "${!ASSET_COUNTS[@]}"; do
    if is_target_asset "$name" "$version" "$PLATFORM"; then
      api_asset=$name
      api_matches=$((api_matches + 1))
    fi
  done
  ((api_matches == 1)) ||
    die "release $tag has $api_matches Mainnet $PLATFORM assets (expected 1)"
  require_asset "$manifest" 65536
  require_asset "$api_asset.sha256" 4096
  require_asset "$api_asset" 2147483648

  if ((dry_run)); then
    printf 'version_source: %s\n' "$version_source"
    printf 'tag: %s\n' "$tag"
    printf 'version: %s\n' "$version"
    printf 'platform: %s\n' "$PLATFORM"
    printf 'release_api_url: %s\n' "$api_url"
    printf 'manifest_url: %s/%s/%s\n' "$RELEASE_BASE_URL" "$tag" "$manifest"
    printf 'asset: %s\n' "$api_asset"
    printf 'asset_url: %s/%s/%s\n' "$RELEASE_BASE_URL" "$tag" "$api_asset"
    printf 'destination: %s\n' "$DESTINATION"
    printf 'output_directory: %s\n' "$output_dir"
    printf 'fetch: dry-run (release metadata only; no assets downloaded, nothing written to the destination)\n'
    return 0
  fi

  # unzip/zipinfo read default options from these; never let them apply.
  unset UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT
  local asset=$api_asset
  pin_destination
  [[ ! -e $output_name && ! -L $output_name ]] ||
    die "'$output_dir' already exists; refusing to overwrite"
  create_stage "$manifest" "$manifest.stderr" "$manifest.headers" \
    "$asset.sha256" "$asset.sha256.stderr" "$asset.sha256.headers" \
    "$asset" "$asset.stderr" "$asset.headers" \
    .entries .entry minotari_node verification.txt

  download "$tag" "$manifest" "$manifest" 120
  check_stage
  verify_api_digest "$manifest" "$manifest"
  local -A CHECKSUMS
  parse_checksums "$manifest" "release manifest $manifest"
  local manifest_asset='' matches=0
  for name in "${!CHECKSUMS[@]}"; do
    if is_target_asset "$name" "$version" "$PLATFORM"; then
      manifest_asset=$name
      matches=$((matches + 1))
    fi
  done
  ((matches > 0)) ||
    die "no Mainnet $PLATFORM asset for $version in $manifest"
  ((matches == 1)) ||
    die "multiple Mainnet $PLATFORM assets for $version in $manifest"
  [[ $manifest_asset == "$asset" ]] ||
    die "the release manifest and the release metadata select different assets"
  local expected_sha256=${CHECKSUMS[$asset]}

  download "$tag" "$asset.sha256" "$asset.sha256" 120
  check_stage
  verify_api_digest "$asset.sha256" "$asset.sha256"
  parse_checksums "$asset.sha256" "$asset.sha256"
  ((${#CHECKSUMS[@]} == 1)) ||
    die "$asset.sha256 must contain exactly one entry"
  [[ -n ${CHECKSUMS[$asset]-} ]] ||
    die "$asset.sha256 does not describe $asset"
  [[ ${CHECKSUMS[$asset]} == "$expected_sha256" ]] ||
    die "$asset.sha256 disagrees with the release manifest"
  # Three consistency records of the archive hash, all from the same trusted
  # GitHub release channel (not independent trust roots), must agree before
  # the (large) archive is downloaded: GitHub's digest, manifest and sidecar.
  [[ ${ASSET_DIGESTS[$asset]} == "sha256:$expected_sha256" ]] ||
    die "$asset: the GitHub API digest disagrees with the release checksum files"
  download "$tag" "$asset" "$asset" 1800
  check_stage
  local archive_sha256 binary_sha256
  archive_sha256=$(sha256_of_file "$asset") || exit 1
  [[ $archive_sha256 == "$expected_sha256" ]] ||
    die "SHA-256 mismatch for $asset: expected $expected_sha256, got $archive_sha256"
  # Inspect the central directory first; extract nothing but the single entry
  # whose path is exactly "minotari_node", and only if its declared size is
  # within the limit.
  local entry count=0 info declared
  check_stage
  run_zipinfo "$asset" .entries -1 -- "$asset"
  while IFS= read -r entry; do
    [[ $entry == minotari_node ]] && count=$((count + 1))
  done <.entries
  remove_temp .entries
  ((count > 0)) || die "$asset has no 'minotari_node' entry at its root"
  ((count == 1)) || die "$asset has $count 'minotari_node' entries"
  check_stage
  run_zipinfo "$asset" .entry -s -- "$asset" minotari_node
  info=$(<.entry)
  remove_temp .entry
  read -r _ _ _ declared _ <<<"$info"
  [[ $info != *$'\n'* && $declared =~ ^[0-9]{1,15}$ ]] ||
    die "cannot read the size of minotari_node in $asset"
  ((declared <= MAX_BINARY_BYTES)) ||
    die "minotari_node in $asset is larger than the $MAX_BINARY_BYTES-byte limit"
  check_stage
  extract_entry "$asset" minotari_node minotari_node "$MAX_BINARY_BYTES" \
    "$ZIP_EXTRACT_SECONDS"
  [[ -s minotari_node ]] || die "extracted minotari_node is empty"
  check_stage
  chmod 700 minotari_node || die "cannot make minotari_node executable"
  binary_sha256=$(sha256_of_file minotari_node) || exit 1
  check_stage
  local record
  printf -v record '%s: %s\n' tag "$tag" version "$version" platform "$PLATFORM" \
    asset "$asset" manifest_url "$RELEASE_BASE_URL/$tag/$manifest" \
    asset_url "$RELEASE_BASE_URL/$tag/$asset" archive_sha256 "$archive_sha256" \
    binary_sha256 "$binary_sha256"
  write_new_file verification.txt "$record" ||
    die "cannot write verification record"

  # Nothing downloaded was ever executed, but re-check everything right
  # before publishing anyway: each file must still be the private regular
  # file that was verified, with the same content.
  check_stage
  reverify_staged "$manifest" "${ASSET_DIGESTS[$manifest]#sha256:}" 600
  reverify_staged "$asset.sha256" "${ASSET_DIGESTS[$asset.sha256]#sha256:}" 600
  reverify_staged "$asset" "$expected_sha256" 600
  reverify_staged minotari_node "$binary_sha256" 700
  reverify_staged verification.txt "" 600
  [[ $(<verification.txt) == "${record%$'\n'}" &&
  $(stat -c %s -- verification.txt) == "${#record}" ]] ||
    die "refusing to publish: verification.txt changed after it was written"
  local name
  for name in "$manifest" "$asset.sha256" "$asset" verification.txt; do
    check_private_regular "$name" 600
  done
  check_private_regular minotari_node 700
  publish_stage "$output_name" "$manifest" "$asset.sha256" "$asset" \
    minotari_node verification.txt

  printf 'version_source: %s\n' "$version_source"
  printf 'tag: %s\n' "$tag"
  printf 'version: %s\n' "$version"
  printf 'platform: %s\n' "$PLATFORM"
  printf 'asset: %s\n' "$asset"
  printf 'archive_sha256: %s\n' "$archive_sha256"
  printf 'binary_sha256: %s\n' "$binary_sha256"
  printf 'output_directory: %s\n' "$output_dir"
  printf 'fetch: verified\n'
}
