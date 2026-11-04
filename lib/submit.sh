# shellcheck shell=bash
# submit: offer a node installed by this tool to TariTalk Nodes, once, by
# hand. Sourced by deploy.sh after lib/install.sh, lib/status.sh,
# lib/wallet-query.sh and lib/grpc.sh, whose fixed layout, record checks
# and domain check it reuses. Must be run as root. On this host it changes
# no service or configuration and writes one file, only after TariTalk
# confirmed the submission: SUBMISSION_ID_FILE next to deploy.sh, with the
# latest submission ID and time. Its only network request is one HTTPS POST
# to TariTalk, made after the user has seen every field and confirmed;
# nothing is retried.

# Internal settings. Tests that source this file may point them at a local
# stand-in; the CLI offers no way to change them.
SUBMIT_URL=https://taritalk-nodes-submit.taritalk-status.workers.dev/submit
SUBMIT_CONNECT_SECONDS=10
SUBMIT_MAX_SECONDS=30

readonly SUBMIT_SCHEMA_VERSION=2
readonly SUBMIT_NETWORK=mainnet
readonly MAX_SUBMIT_ANSWER_BYTES=4096
readonly SUBMIT_DEPENDENCIES=(systemctl timeout curl jq stat readlink mktemp date mv chmod)
# Submission IDs as the service issues them (opaque; shown, never used).
readonly RE_SUBMISSION_ID='^[A-Za-z0-9_-]{8,64}$'
# The optional operator name: at most this many characters (not bytes).
readonly MAX_OPERATOR_NAME_CHARS=64
# UTF-8 byte sequences of characters that show as nothing, reorder text or
# have no agreed meaning (matched with LC_ALL=C): soft hyphen and no-break
# space, Arabic letter mark, Ogham and Mongolian spaces, U+2000-U+200F
# (spaces, zero-width characters, bidi marks), U+2028-U+202F (separators,
# bidi embeddings and overrides, narrow no-break space), U+205F-U+206F
# (word joiner, invisible operators, bidi isolates), ideographic space,
# private-use characters (U+E000-U+F8FF and planes 15 and 16), byte order
# mark, interlinear annotation characters and tag characters.
readonly RE_INVISIBLE_UTF8=$'\xc2[\xa0\xad]|\xd8\x9c|\xe1\x9a\x80|\xe1\xa0\x8e|\xe2\x80[\x80-\x8f\xa8-\xaf]|\xe2\x81[\x9f-\xaf]|\xe3\x80\x80|\xee[\x80-\xbf][\x80-\xbf]|\xef[\x80-\xa3][\x80-\xbf]|\xef\xbb\xbf|\xef\xbf[\xb9-\xbb]|\xf3\xa0[\x80\x81][\x80-\xbf]|\xf3[\xb0-\xbf][\x80-\xbf][\x80-\xbf]|\xf4[\x80-\x8f][\x80-\xbf][\x80-\xbf]'

submit_usage() {
  print_text <<USAGE
Usage: $USAGE_CMD submit

Offer the Minotari node installed by this tool to TariTalk Nodes
(nodes.taritalk.xyz), once. Must be run as root.

It reads only the records this tool wrote, checks that the node is still
installed and running, asks for an optional operator name, and shows what
it would send: the network, the node's public IPv4 address and P2P port,
the Minotari and tool versions, only if this tool set them up the public
Wallet Query URL and Base Node gRPC URL (https://DOMAIN), and the operator
name if you typed one. The operator name is a display name and nothing
more; without one, a node TariTalk publishes is listed as
"Community registered". No email address, key, Tor identity, log or
configuration is read or sent.

Only after you confirm, it makes one HTTPS POST to
$SUBMIT_URL
(certificate checked, no retry). TariTalk stores the submission privately
as "pending" and checks it by hand; nothing is published automatically and
no account or management token is created. On success it shows the
submission ID and saves it, with the time, to $SUBMISSION_ID_FILE next to
deploy.sh (a private file of root); a later successful submission replaces
it with the newer ID. If the file cannot be written, the submission still
stands and the ID is shown for you to copy.

Nothing else on this host is changed: no service or configuration is
touched.

Options:
  --help  Show this help and exit
USAGE
}

# --- what is sent ----------------------------------------------------------

# read_submit_record: after check_install_state, the whole install record
# read strictly as data. Sets SUBMIT_VERSION (the installed Minotari
# release) and SUBMIT_PUBLIC_IP.
read_submit_record() {
  local line key value
  local -a lines
  local -A seen=()
  mapfile -t lines <"$(sysroot "$STATE_FILE")" || die "cannot read '$STATE_FILE'"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_0-9]+)=([A-Za-z0-9.:/_,+-]*)$ ]] || invalid_submit_record "unexpected line"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    [[ -z ${seen[$key]+x} ]] || invalid_submit_record "duplicate $key"
    seen[$key]=$value
  done
  [[ ${seen[format]-} == 1 ]] || invalid_submit_record "format is not 1"
  [[ ${seen[version]-} != v* && ${seen[version]-} =~ $RE_RELEASE_VERSION &&
    ${seen[tag]-} == "v${seen[version]-}" ]] || invalid_submit_record "invalid version"
  check_public_ipv4 "${seen[public_ip]-}" || invalid_submit_record "invalid public_ip"
  SUBMIT_VERSION=${seen[version]}
  SUBMIT_PUBLIC_IP=${seen[public_ip]}
}

invalid_submit_record() {
  die "'$STATE_FILE' is not a valid install record of $PROG: $1"
}

# check_submit_node: the node the record describes is in place and runs
# as this tool left it: its release and service unit (check_node_install),
# the service active and enabled, and P2P listening for other nodes.
check_submit_node() {
  local state
  check_node_install
  state=$(unit_word is-active "$NODE_SERVICE")
  [[ $state == active ]] || die "$NODE_SERVICE is not active ($state); only a running node can be submitted"
  state=$(unit_word is-enabled "$NODE_SERVICE")
  [[ $state == enabled ]] || die "$NODE_SERVICE is not enabled ($state)"
  listening_on "$P2P_PORT" 0.0.0.0 '[::]' ||
    die "nothing listens on TCP $P2P_PORT on 0.0.0.0 or [::]; the node is not reachable for other nodes"
}

# endpoint_domain PATH NAME: the domain of a Wallet Query or Base Node gRPC
# record this tool wrote at PATH (a private regular file of root, read as
# data), or nothing if there is no record at all. Anything in between (a
# record that is not this tool's, or not valid) is refused.
endpoint_domain() {
  local path info line key domain
  local -a lines
  local -A seen=()
  path=$(sysroot "$1")
  exists "$path" || return 0
  [[ -f $path && ! -L $path ]] || die "'$1' is not a regular file"
  info=$(stat -c '%u %a %h' -- "$path") || die "cannot inspect '$1'"
  [[ $info == "${ROOT_IDS%%:*} 600 1" ]] || die "'$1' is not a private file of root"
  mapfile -t lines <"$path" || die "cannot read '$1'"
  for line in "${lines[@]}"; do
    [[ $line =~ ^([a-z_0-9]+)=([A-Za-z0-9.:/_,+-]*)$ && -z ${seen[${BASH_REMATCH[1]}]+x} ]] ||
      die "'$1' is not a $2 record of $PROG"
    key=${BASH_REMATCH[1]}
    seen[$key]=${BASH_REMATCH[2]}
  done
  domain=${seen[domain]-}
  { [[ ${seen[format]-} == 1 ]] && check_domain "$domain"; } ||
    die "'$1' is not a $2 record of $PROG"
  printf '%s\n' "$domain"
}

# read_submit_endpoints: the public URLs of the Wallet Query and Base Node
# gRPC this tool set up, from their records, into SUBMIT_WQ_URL and
# SUBMIT_GRPC_URL (empty: not set up). Both are https://DOMAIN: the gRPC
# service is TLS and HTTP/2 on TCP 443, which the URL implies, so the
# default port is not written.
read_submit_endpoints() {
  local wq_domain grpc_domain
  wq_domain=$(endpoint_domain "$WQ_STATE" "Wallet Query") || exit 1
  grpc_domain=$(endpoint_domain "$GRPC_STATE" "Base Node gRPC") || exit 1
  SUBMIT_WQ_URL='' SUBMIT_GRPC_URL=''
  [[ -z $wq_domain ]] || SUBMIT_WQ_URL="https://$wq_domain"
  [[ -z $grpc_domain ]] || SUBMIT_GRPC_URL="https://$grpc_domain"
}

# ask_operator_name: the optional operator name, into OPERATOR_NAME (empty:
# none, which TariTalk shows as "Community registered"). Asked again after
# a name that cannot be used; Enter, or the end of input, means none.
ask_operator_name() {
  local answer
  OPERATOR_NAME=''
  while :; do
    printf 'Operator name (optional; press Enter to remain anonymous): '
    IFS= read -r answer || answer=''
    printf '\n'
    answer=${answer#"${answer%%[! $'\t\r']*}"}
    answer=${answer%"${answer##*[! $'\t\r']}"}
    [[ -n $answer ]] || return 0
    if operator_name_ok "$answer"; then
      OPERATOR_NAME=$answer
      return 0
    fi
    print_text <<TEXT
That name cannot be used. A name is 1 to $MAX_OPERATOR_NAME_CHARS letters, digits, punctuation
marks, symbols or spaces in any language, with at least one letter or digit
and no control or invisible characters.
TEXT
  done
}

# operator_name_ok NAME: NAME is valid UTF-8 of at most
# MAX_OPERATOR_NAME_CHARS printable characters, has a letter or digit, and
# has no invisible or text-reordering character (RE_INVISIBLE_UTF8). The
# service applies the same rule.
operator_name_ok() {
  (
    LC_ALL=C.UTF-8
    [[ $1 =~ ^[[:print:]]+$ && ${#1} -le $MAX_OPERATOR_NAME_CHARS && $1 =~ [[:alnum:]] ]]
  ) || return 1
  local LC_ALL=C
  [[ ! $1 =~ $RE_INVISIBLE_UTF8 ]]
}

# prepare_submission: every field that is sent, as a JSON object in
# SUBMIT_BODY and, in the same order, as "Label|value" lines in
# SUBMIT_FIELDS (what the user is shown comes from the same values). An
# endpoint that is not set up, or no operator name, is left out, never
# sent as a placeholder.
prepare_submission() {
  SUBMIT_FIELDS=("Schema version|$SUBMIT_SCHEMA_VERSION" "Network|$SUBMIT_NETWORK"
    "Public IPv4|$SUBMIT_PUBLIC_IP" "P2P port|$P2P_PORT" "Minotari version|$SUBMIT_VERSION"
    "Installer version|$VERSION")
  [[ -z $SUBMIT_WQ_URL ]] || SUBMIT_FIELDS+=("Wallet Query URL|$SUBMIT_WQ_URL")
  [[ -z $SUBMIT_GRPC_URL ]] || SUBMIT_FIELDS+=("Base Node gRPC URL|$SUBMIT_GRPC_URL")
  [[ -z $OPERATOR_NAME ]] || SUBMIT_FIELDS+=("Operator name|$OPERATOR_NAME")
  # shellcheck disable=SC2016 # jq variables, not shell.
  SUBMIT_BODY=$(jq -n -c --argjson schema "$SUBMIT_SCHEMA_VERSION" --arg network "$SUBMIT_NETWORK" \
    --arg ip "$SUBMIT_PUBLIC_IP" --argjson port "$P2P_PORT" --arg minotari "$SUBMIT_VERSION" \
    --arg installer "$VERSION" --arg wq "$SUBMIT_WQ_URL" --arg grpc "$SUBMIT_GRPC_URL" \
    --arg name "$OPERATOR_NAME" '
    {schema_version: $schema, network: $network, public_ip: $ip, p2p_port: $port,
      minotari_version: $minotari, installer_version: $installer}
    + (if $wq == "" then {} else {wallet_query_url: $wq} end)
    + (if $grpc == "" then {} else {grpc_url: $grpc} end)
    + (if $name == "" then {} else {operator_name: $name} end)') ||
    die "cannot prepare the submission"
}

print_submission() {
  local field
  printf 'Submit node to TariTalk Nodes\n'
  for field in "${SUBMIT_FIELDS[@]}"; do
    printf '  %-19s %s\n' "${field%%|*}:" "${field#*|}"
  done
  print_text <<TEXT
  These fields, and nothing else, are sent to TariTalk once, over HTTPS: no
  email address, key, Tor identity, log or configuration.
TEXT
  if [[ -n $OPERATOR_NAME ]]; then
    print_text <<TEXT
  The operator name is the display name you typed, nothing more: it creates
  no account, ownership proof, login or management token.
TEXT
  else
    print_text <<TEXT
  No name is sent: if TariTalk publishes the node, it is listed as
  "Community registered".
TEXT
  fi
  print_text <<TEXT
  TariTalk stores them privately as "pending". Nothing is published
  automatically: TariTalk checks every submission by hand first. No account
  and no management token is created; the node is not changed.
TEXT
}

# --- the request -------------------------------------------------------------

# submit_refused: a check failed before anything was sent.
submit_refused() {
  local rc=$?
  ((rc != 0)) || return 0
  printf 'Submission refused; nothing was sent to TariTalk.\n'
  ((!${MENU_MODE:-0})) || menu_outcome "The node was not submitted; nothing was sent to TariTalk."
  return "$rc"
}

# not_sent REASON: the request never reached TariTalk.
not_sent() {
  printf 'The submission was not sent; nothing reached TariTalk.\n'
  ((!${MENU_MODE:-0})) || menu_outcome "The node was not submitted; nothing reached TariTalk."
  die "$1"
}

# uncertain REASON: the request may have reached TariTalk, but no answer
# confirms it; the outcome is not known either way.
uncertain() {
  print_text <<TEXT
The result is uncertain: the submission may already have been received by
TariTalk, but no confirmation arrived. It was not necessarily lost. If it
was received, TariTalk sees it as pending. Submitting again later would at
worst add a second pending entry, which TariTalk sorts out by hand.
TEXT
  ((!${MENU_MODE:-0})) || menu_outcome "Whether the node was submitted is uncertain; see below."
  die "$1"
}

# refused CODE: TariTalk's service answered that it does not take the
# submission (an HTTP 4xx answer is given before anything is stored).
refused() {
  printf "TariTalk's service refused the submission (HTTP %s); it was not recorded.\\n" "$1"
  ((!${MENU_MODE:-0})) || menu_outcome "The node was not submitted: TariTalk's service refused it."
  die "the service refused the submission (HTTP $1)"
}

# send_submission: one bounded HTTPS POST of SUBMIT_BODY to SUBMIT_URL,
# with curl's usual certificate check and no retry. Prints the outcome.
send_submission() {
  local work rc=0 code='' id='' first=''
  work=$(mktemp -d "$(sysroot /tmp)/taritalk-submit.XXXXXXXX") || die "cannot create a temporary folder"
  # shellcheck disable=SC2064 # Expanded now: the folder is fixed.
  trap "rm -rf -- '$work'" EXIT
  printf '%s' "$SUBMIT_BODY" >"$work/body.json" || die "cannot write the submission"
  code=$(timeout --kill-after=2 $((SUBMIT_MAX_SECONDS + 10)) curl --disable --silent --show-error \
    --noproxy '*' --proto =https --tlsv1.2 --max-redirs 0 \
    --connect-timeout "$SUBMIT_CONNECT_SECONDS" --max-time "$SUBMIT_MAX_SECONDS" \
    --max-filesize "$MAX_SUBMIT_ANSWER_BYTES" --header 'Content-Type: application/json' \
    --header 'Accept: application/json' --data-binary "@$work/body.json" \
    --output "$work/answer" --write-out '%{http_code}' -- "$SUBMIT_URL" \
    2>"$work/curl.err" </dev/null) || rc=$?
  IFS= read -r first <"$work/curl.err" || true
  case "$rc" in
    0) ;;
    # Before any request: a URL curl refuses, no address, no connection, or
    # the certificate check (or anything else about TLS) failed during the
    # handshake.
    1 | 2 | 3 | 5 | 6 | 7 | 35 | 51 | 53 | 54 | 58 | 59 | 60 | 77 | 83)
      not_sent "could not connect securely to TariTalk (${first:-curl exit $rc})"
      ;;
    28 | 124 | 137) uncertain "the request timed out" ;;
    *) uncertain "the request failed (${first:-curl exit $rc})" ;;
  esac
  case "$code" in
    200) ;;
    4[0-9][0-9]) refused "$code" ;;
    *) uncertain "the service gave an unexpected answer (HTTP ${code:-none})" ;;
  esac
  [[ -f $work/answer && $(stat -c %s -- "$work/answer") -le $MAX_SUBMIT_ANSWER_BYTES ]] ||
    uncertain "the service gave an unexpected answer"
  id=$(jq -r 'if type == "object" and .ok == true and .status == "pending"
      and (.submission_id | type) == "string" then .submission_id else error("unexpected") end' \
    "$work/answer" 2>/dev/null) || uncertain "the service gave an unexpected answer"
  [[ $id =~ $RE_SUBMISSION_ID ]] || uncertain "the service gave an unexpected answer"
  print_text <<DONE
Success: Node submitted to TariTalk Nodes.
  Submission ID: $id
DONE
  save_submission_id "$id" || submission_id_not_saved
}

# --- the local record ------------------------------------------------------

# submission_id_path: SUBMISSION_ID_FILE next to deploy.sh, which
# load_install located (never the current directory).
submission_id_path() { printf '%s/%s\n' "$INSTALL_SOURCE_DIR" "$SUBMISSION_ID_FILE"; }

# save_submission_id ID: record ID and the UTC time as the latest confirmed
# submission, in a private file of root at submission_id_path. The file is
# replaced in one step: a complete temporary file in the same directory
# takes its place, so the record is never half-written and an earlier
# record survives any failure. Fails (and leaves everything as it was)
# when the path is not a plain file of ours or cannot be written.
save_submission_id() {
  local path tmp when
  [[ -n $INSTALL_SOURCE_DIR && -d $INSTALL_SOURCE_DIR ]] || return 1
  path=$(submission_id_path)
  if exists "$path"; then
    [[ -f $path && ! -L $path ]] || return 1
  fi
  when=$(date -u '+%Y-%m-%d %H:%M:%S UTC') || return 1
  tmp=$(mktemp -- "$INSTALL_SOURCE_DIR/.$SUBMISSION_ID_FILE.XXXXXXXX") || return 1
  if chmod 600 -- "$tmp" && printf 'Submission ID: %s\nSubmitted: %s\n' "$1" "$when" >"$tmp" &&
    mv -f -T -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# submission_id_not_saved: TariTalk has the submission, but the local
# record could not be written: say so, after the success, without taking
# anything back.
submission_id_not_saved() {
  printf '%s: warning: cannot save the submission ID to %s\n' "$PROG" "'$(submission_id_path)'" >&2
  print_text <<TEXT
Warning: the submission ID could not be saved to $SUBMISSION_ID_FILE next to
deploy.sh. Copy the Submission ID above now; TariTalk has the submission.
TEXT
}

# --- command -------------------------------------------------------------------

cmd_submit() {
  # The command takes no options: only a lone --help, anything else is
  # refused before any check of the host.
  if (($# > 0)); then
    if [[ $# == 1 && ($1 == --help || $1 == -h) ]]; then
      submit_usage
      return 0
    fi
    [[ $1 == --help || $1 == -h ]] && usage_error "submit takes no arguments besides --help"
    usage_error "unknown submit option '$1'"
  fi
  ops_prepare "${SUBMIT_DEPENDENCIES[@]}"
  # Every check is read-only; any failure refuses the submission unsent.
  trap submit_refused EXIT
  check_install_state
  read_submit_record
  check_submit_node
  read_submit_endpoints
  ask_operator_name
  prepare_submission
  trap - EXIT
  print_submission
  local answer=''
  printf 'Submit this node to TariTalk Nodes? [y/N]: '
  IFS= read -r answer || answer=''
  if [[ $answer != y && $answer != Y ]]; then
    printf '\nSubmission cancelled; nothing was sent.\n'
    return 0
  fi
  printf '\n'
  send_submission
}
