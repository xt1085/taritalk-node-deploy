# shellcheck shell=bash
# Several tests check results inside ( ... ) blocks; status and friends are
# set by helpers there on purpose.
# shellcheck disable=SC2030,SC2031
# submit: one-time submission of a node installed by this tool to TariTalk
# Nodes. Never touches the real system or TariTalk: the node is the healthy
# sandbox of tests/test_status.sh (systemctl is tests/fakes/sys), the
# submission goes to tests/fakes/curl (which records the POST body) or,
# for the transport cases, to the real curl talking to
# tests/fakes/submit_server.py on 127.0.0.1 over TLS.

readonly SUBMIT_HOST=taritalk-nodes-submit.taritalk-status.workers.dev
readonly SUBMIT_URL_EXPECTED=https://taritalk-nodes-submit.taritalk-status.workers.dev/submit
readonly SUBMIT_ANSWER='{"ok":true,"submission_id":"sub_0123456789abcdef","status":"pending"}'
readonly SUBMIT_EXPECTED_BODY='{"installer_version":"0.1.0","minotari_version":"6.0.0","network":"mainnet","p2p_port":18189,"public_ip":"1.2.3.4","schema_version":2}'
readonly SUBMIT_SUCCESS="Success: Node submitted to TariTalk Nodes."
readonly SUBMIT_NAME_PROMPT="Operator name (optional; press Enter to remain anonymous): "
readonly SUBMIT_NAME_REFUSED="That name cannot be used. A name is 1 to 64 letters, digits, punctuation"
readonly GRPC_SUBMIT_DOMAIN=grpc-test.nodes.taritalk.xyz
readonly SUBMIT_CANCELLED="Submission cancelled; nothing was sent."
readonly SUBMIT_REFUSED="Submission refused; nothing was sent to TariTalk."
readonly SUBMIT_NOT_SENT="The submission was not sent; nothing reached TariTalk."
readonly SUBMIT_UNCERTAIN="The result is uncertain: the submission may already have been received by"
readonly SUBMIT_NOT_SAVED="Warning: the submission ID could not be saved to submission-id.txt next to"

# setup_submit: the healthy node of setup_status, the fake service
# answering a submission, and $TOOL_DIR as the directory of deploy.sh
# (where the submission ID is saved; empty at first).
setup_submit() {
  setup_status
  TOOL_DIR=$TEST_TMP/tool
  mkdir -p "$SB/tmp" "$TEST_TMP/web/$SUBMIT_HOST" "$TOOL_DIR"
  chmod 1777 "$SB/tmp"
  printf '%s' "$SUBMIT_ANSWER" >"$TEST_TMP/web/$SUBMIT_HOST/submit"
}

# shellcheck disable=SC2034 # status/stdout/stderr are read by tests/lib.sh.
# run_submit [ARGS...]: lib/submit.sh's cmd_submit as "root" against the
# sandbox. Stdin is the answer to the operator name, $SUBMIT_NAME (unset:
# an empty line, no name; it may hold several lines), then $SUBMIT_INPUT
# for the confirmation; with both unset, the end of input comes at once.
# SUBMIT_TEST_URL, SUBMIT_TEST_PATH and SUBMIT_TEST_SECONDS point the
# internal settings at a test stand-in. The submission ID is saved in
# $TOOL_DIR, standing for the directory of deploy.sh; with SUBMIT_DEPLOY
# (a path to a copy of deploy.sh, relative to SUBMIT_CWD) the real
# deploy.sh is sourced from that working directory and locates its own
# directory itself. Sets status/stdout/stderr.
run_submit() {
  {
    if [[ -n ${SUBMIT_NAME+x} || -n ${SUBMIT_INPUT+x} ]]; then printf '%s\n' "${SUBMIT_NAME-}"; fi
    if [[ -n ${SUBMIT_INPUT+x} ]]; then printf '%s\n' "$SUBMIT_INPUT"; fi
  } >"$TEST_TMP/.stdin"
  (
    if [[ -n ${SUBMIT_DEPLOY-} ]]; then
      cd -- "$SUBMIT_CWD" || exit 99
      # shellcheck source=deploy.sh
      source "$SUBMIT_DEPLOY"
      load_submit
    else
      # shellcheck source=deploy.sh
      source "$REPO_ROOT/deploy.sh"
      # shellcheck source=lib/fetch.sh
      source "$REPO_ROOT/lib/fetch.sh"
      # shellcheck source=lib/install.sh
      source "$REPO_ROOT/lib/install.sh"
      # shellcheck source=lib/status.sh
      source "$REPO_ROOT/lib/status.sh"
      # shellcheck source=lib/wallet-query.sh
      source "$REPO_ROOT/lib/wallet-query.sh"
      # shellcheck source=lib/grpc.sh
      source "$REPO_ROOT/lib/grpc.sh"
      # shellcheck source=lib/submit.sh
      source "$REPO_ROOT/lib/submit.sh"
      INSTALL_SOURCE_DIR=$TOOL_DIR
    fi
    # shellcheck disable=SC2317,SC2329 # Called by lib/submit.sh.
    is_root() { return 0; }
    SYSROOT=$SB
    ROOT_IDS=${OPS_ROOT_IDS:-"$(id -u):$(id -g)"}
    OPS_PATH=${SUBMIT_TEST_PATH:-$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin}
    [[ -z ${SUBMIT_TEST_URL-} ]] || SUBMIT_URL=$SUBMIT_TEST_URL
    SUBMIT_MAX_SECONDS=${SUBMIT_TEST_SECONDS-30}
    SUBMIT_CONNECT_SECONDS=${SUBMIT_TEST_SECONDS-10}
    cmd_submit "$@"
  ) <"$TEST_TMP/.stdin" >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# displayed_json: the fields the user was shown before confirming, as the
# JSON object they stand for (sorted keys), built from stdout alone.
displayed_json() {
  local line label value key number json='{}'
  while IFS= read -r line; do
    [[ $line =~ ^\ \ ([A-Za-z0-9\ ]+):\ +(.+)$ ]] || continue
    label=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]} number=0
    case "$label" in
      "Schema version") key=schema_version number=1 ;;
      Network) key=network ;;
      "Public IPv4") key=public_ip ;;
      "P2P port") key=p2p_port number=1 ;;
      "Minotari version") key=minotari_version ;;
      "Installer version") key=installer_version ;;
      "Wallet Query URL") key=wallet_query_url ;;
      "Base Node gRPC URL") key=grpc_url ;;
      "Operator name") key=operator_name ;;
      *) continue ;;
    esac
    if ((number)); then
      json=$(jq -c --arg k "$key" --argjson v "$value" '. + {($k): $v}' <<<"$json")
    else
      json=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$json")
    fi
  done <<<"$stdout"
  jq -S -c . <<<"$json"
}

# posted_json N: the body the fake curl recorded for its call N, sorted.
posted_json() {
  [[ -f $TEST_TMP/curl-log/$1.body ]] || fail "curl call $1 sent no body"
  jq -S -c . <"$TEST_TMP/curl-log/$1.body" || fail "the body is not JSON: $(<"$TEST_TMP/curl-log/$1.body")"
}

# tool_copy DIR: a copy of the tool (deploy.sh, lib, templates) at DIR, as
# a user has it after unpacking it.
tool_copy() {
  mkdir -p "$1"
  cp -R -- "$REPO_ROOT/deploy.sh" "$REPO_ROOT/lib" "$REPO_ROOT/templates" "$1/"
}

# dir_listing DIR: every path under DIR (not DIR itself) with type, mode and size.
dir_listing() {
  find "$1" -mindepth 1 -printf '%P %y %m %s\n' | LC_ALL=C sort
}

# file_identity PATH: inode, modification time, size and content hash.
file_identity() {
  printf '%s %s\n' "$(stat -c '%i %Y %s' -- "$1")" "$(sha256sum <"$1")"
}

# assert_saved_id DIR ID FROM: DIR/submission-id.txt is the private file the
# tool writes (mode 600, owned by the user running the tool, here the test
# user), with exactly ID and a UTC time between FROM and now.
assert_saved_id() {
  local path=$1/submission-id.txt now when leftovers
  local record=$'^Submission ID: ([A-Za-z0-9_-]+)\nSubmitted: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC)$'
  [[ -f $path && ! -L $path ]] || fail "no file at $path"
  [[ $(stat -c '%u %a' -- "$path") == "$(id -u) 600" ]] || fail "$path is not a private file: $(stat -c '%u %a' -- "$path")"
  now=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  [[ $(<"$path") =~ $record ]] || fail "unexpected content of $path: $(<"$path")"
  [[ ${BASH_REMATCH[1]} == "$2" ]] || fail "$path holds ${BASH_REMATCH[1]}, not $2"
  when=${BASH_REMATCH[2]}
  [[ ! $when < "$3" && ! $now < "$when" ]] || fail "$path says $when, outside $3 .. $now"
  leftovers=("$1"/.submission-id*)
  [[ ! -e ${leftovers[0]} ]] || fail "temporary files left in $1: $(ls -A -- "$1")"
}

# sandbox_snapshot: every path in the sandbox with type, mode and size.
sandbox_snapshot() {
  find "$SB" -printf '%P %y %m %s\n' | LC_ALL=C sort
}

# assert_nothing_sent: the fake curl was never called and no file of the
# submission is left behind.
assert_nothing_sent() {
  [[ $(curl_call_count) == 0 ]] || fail "a request was made: $(tr '\0' ' ' <"$TEST_TMP/curl-log/1")"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
}

# assert_read_only_system_calls: only the two systemctl queries were made.
assert_read_only_system_calls() {
  local want
  printf -v want '%s\n' "systemctl is-active minotari-mainnet.service" \
    "systemctl is-enabled minotari-mainnet.service"
  [[ $(<"$FAKE_SYS/calls") == "${want%$'\n'}" ]] || fail "unexpected system calls: $(<"$FAKE_SYS/calls")"
}

# write_endpoint_record PATH DOMAIN [LINE...]: a Wallet Query or gRPC record
# as this tool writes it (format=1, tool_version, domain), plus LINEs.
write_endpoint_record() {
  local path=$SB$1
  mkdir -p "${path%/*}"
  chmod 755 "${path%/*}"
  printf '%s\n' format=1 tool_version=0.1.0 "domain=$2" "${@:3}" >"$path"
  chmod 600 "$path"
}

# --- command line ------------------------------------------------------------

test_submit_help_works_without_root_or_dependencies() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/bare-bin" submit --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh submit"
  assert_stdout_contains "Must be run as root"
  assert_stdout_contains "$SUBMIT_URL_EXPECTED"
  assert_stdout_contains "once"
  assert_stdout_contains '"pending"'
  assert_stdout_contains "nothing is published automatically"
  assert_stdout_contains "no account or management token is created"
  assert_stdout_contains "asks for an optional operator name"
  assert_stdout_contains "Base Node gRPC URL (https://DOMAIN)"
  assert_stdout_contains '"Community registered"'
  [[ $stdout != *"email address, name,"* ]] || fail "the help still claims that no name is sent"
  [[ -z $(<"$TRACE_FILE") ]] || fail "help ran commands: $(<"$TRACE_FILE")"
  run_cli --help
  assert_status 0
  assert_stdout_contains "submit      Offer the installed node to TariTalk Nodes, once, after"
}

test_submit_usage_errors_exit_2_before_root_checks() {
  make_sandbox_path "$TEST_TMP/bare-bin"
  export TRACE_FILE=$TEST_TMP/trace
  : >"$TRACE_FILE"
  local c
  for c in "--bogus" "extra" "--yes" "-v" "--help x" "x --help"; do
    # shellcheck disable=SC2086 # Split each case into arguments.
    run_cli_with_path "$TEST_TMP/bare-bin" submit $c
    [[ $status == 2 ]] || fail "[$c]: expected exit 2, got $status"
    assert_stdout_empty
    [[ $stderr == *"taritalk-node-deploy: error: "* ]] || fail "[$c]: $stderr"
    [[ $stderr != *"Please run as root"* ]] || fail "[$c]: checked root before the arguments"
  done
  [[ -z $(<"$TRACE_FILE") ]] || fail "usage errors ran commands: $(<"$TRACE_FILE")"
}

test_submit_as_non_root_says_please_run_as_root() {
  run_cli submit </dev/null
  assert_status 1
  assert_stdout_empty
  [[ $stderr == "Please run as root." ]] || fail "unexpected stderr: $stderr"
}

# --- what is shown and sent --------------------------------------------------------

test_submit_shows_every_field_then_sends_exactly_them_once() {
  setup_submit
  local before started
  before=$(sandbox_snapshot)
  started=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stderr_empty
  local line
  for line in "Submit node to TariTalk Nodes" "  Schema version:     2" "  Network:            mainnet" \
    "  Public IPv4:        1.2.3.4" "  P2P port:           18189" "  Minotari version:   6.0.0" \
    "  Installer version:  0.1.0" "  Submission ID: sub_0123456789abcdef" "$SUBMIT_SUCCESS"; do
    assert_stdout_has_line "$line"
  done
  [[ $stdout != *"Status:"* ]] || fail "showed a status line after success"
  [[ $stdout != *"Wallet Query URL"* && $stdout != *"Base Node gRPC"* ]] || fail "showed endpoints that are not set up"
  # The name was asked for, before the fields; none was given, and the
  # explanation says so, without a placeholder.
  [[ $stdout == *"$SUBMIT_NAME_PROMPT"*"Submit node to TariTalk Nodes"* ]] || fail "did not ask for the operator name first: $stdout"
  [[ $stdout != *"  Operator name:"* && $stdout != *Anonymous* ]] || fail "showed a name that was not given: $stdout"
  assert_stdout_contains "These fields, and nothing else, are sent to TariTalk once, over HTTPS: no"
  assert_stdout_contains "email address, key, Tor identity, log or configuration."
  assert_stdout_contains "No name is sent: if TariTalk publishes the node, it is listed as"
  assert_stdout_contains '"Community registered".'
  [[ $stdout != *"display name you typed"* ]] || fail "explained a name that was not given"
  assert_stdout_contains 'TariTalk stores them privately as "pending". Nothing is published'
  assert_stdout_contains "automatically: TariTalk checks every submission by hand first. No account"
  assert_stdout_contains "and no management token is created; the node is not changed."
  assert_stdout_contains "Submit this node to TariTalk Nodes? [y/N]: "
  # The answer is shown as the ID and status only.
  [[ $stdout != *'"ok"'* && $stdout != *"{"* ]] || fail "showed the raw answer"
  # Exactly one request, of exactly the fields shown, to the fixed URL.
  [[ $(curl_call_count) == 1 ]] || fail "expected one request, got $(curl_call_count)"
  [[ $(posted_json 1) == "$SUBMIT_EXPECTED_BODY" ]] || fail "unexpected body: $(posted_json 1)"
  [[ $(displayed_json) == "$(posted_json 1)" ]] ||
    fail "shown $(displayed_json) but sent $(posted_json 1)"
  load_curl_call 1
  [[ ${CALL[-1]} == "$SUBMIT_URL_EXPECTED" && ${CALL[-2]} == -- ]] || fail "unexpected URL: ${CALL[-1]}"
  local joined=" ${CALL[*]} "
  [[ $joined == *" --proto =https "* && $joined == *" --tlsv1.2 "* && $joined == *" --max-redirs 0 "* &&
    $joined == *" --max-time 30 "* && $joined == *" --connect-timeout 10 "* && $joined == *" --max-filesize 4096 "* &&
    $joined == *" --noproxy * "* && $joined == *" --disable "* && $joined == *" --header Content-Type: application/json "* ]] ||
    fail "the request lacks a safety option: $joined"
  [[ $joined != *" --insecure "* && $joined != *" -k "* && $joined != *" --retry"* && $joined != *"--proxy-insecure"* &&
    $joined != *" --cacert "* && $joined != *" --capath "* ]] || fail "the request weakens TLS or retries: $joined"
  # Nothing on the host changed but the saved ID next to deploy.sh, and
  # only read-only queries were made.
  [[ $(sandbox_snapshot) == "$before" ]] || fail "the sandbox changed"
  assert_read_only_system_calls
  assert_saved_id "$TOOL_DIR" sub_0123456789abcdef "$started"
  [[ $(ls -A -- "$TOOL_DIR") == submission-id.txt ]] || fail "unexpected files next to deploy.sh: $(ls -A -- "$TOOL_DIR")"
}

test_submit_default_or_no_cancels_without_sending() {
  setup_submit
  local answer
  for answer in "" n N no yes Y_ " y"; do
    SUBMIT_INPUT=$answer run_submit
    [[ $status == 0 ]] || fail "[$answer]: expected exit 0, got $status"
    assert_stderr_empty
    assert_stdout_contains "Submit this node to TariTalk Nodes? [y/N]: "
    [[ $stdout == *"$SUBMIT_CANCELLED"* ]] || fail "[$answer]: not cancelled: $stdout"
    [[ $stdout != *"Success:"* && $stdout != *"Submission ID"* ]] || fail "[$answer]: claimed success"
    assert_nothing_sent
  done
  # End of input at the question also cancels, with or without a name.
  unset SUBMIT_INPUT
  run_submit
  assert_status 0
  assert_stdout_contains "$SUBMIT_CANCELLED"
  assert_nothing_sent
  SUBMIT_NAME="Test Node" run_submit
  assert_status 0
  assert_stdout_has_line "  Operator name:      Test Node"
  assert_stdout_contains "$SUBMIT_CANCELLED"
  assert_nothing_sent
  [[ -z $(ls -A -- "$TOOL_DIR") ]] || fail "a cancelled submission wrote next to deploy.sh: $(ls -A -- "$TOOL_DIR")"
}

test_submit_sends_only_with_an_explicit_yes() {
  setup_submit
  SUBMIT_INPUT=Y run_submit
  assert_status 0
  assert_stdout_contains "$SUBMIT_SUCCESS"
  [[ $(curl_call_count) == 1 ]] || fail "expected one request, got $(curl_call_count)"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
}

# --- the saved submission ID -----------------------------------------------------

test_submit_saves_the_latest_id_next_to_deploy_sh_from_any_directory() {
  setup_submit
  local started first
  started=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  # The first success creates the file; a second replaces it with the new ID.
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stderr_empty
  assert_saved_id "$TOOL_DIR" sub_0123456789abcdef "$started"
  first=$(file_identity "$TOOL_DIR/submission-id.txt")
  printf '%s' '{"ok":true,"submission_id":"sub_second0000000","status":"pending"}' >"$TEST_TMP/web/$SUBMIT_HOST/submit"
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stderr_empty
  assert_stdout_has_line "  Submission ID: sub_second0000000"
  assert_saved_id "$TOOL_DIR" sub_second0000000 "$started"
  [[ $(file_identity "$TOOL_DIR/submission-id.txt") != "$first" ]] || fail "the record was not replaced"
  [[ $(ls -A -- "$TOOL_DIR") == submission-id.txt ]] || fail "unexpected files next to deploy.sh: $(ls -A -- "$TOOL_DIR")"
  # The real deploy.sh, run from another directory as /path/to/deploy.sh or
  # through a symlink, saves next to itself, never in the working directory.
  local tool=$TEST_TMP/unpacked/taritalk-node-deploy cwd=$TEST_TMP/home listing
  tool_copy "$tool"
  mkdir -p "$cwd"
  ln -s "$tool/deploy.sh" "$cwd/deploy-link.sh"
  listing=$(dir_listing "$tool")
  SUBMIT_CWD=$cwd SUBMIT_DEPLOY=../unpacked/taritalk-node-deploy/deploy.sh SUBMIT_INPUT=y run_submit
  [[ $status == 0 ]] || fail "expected exit 0, got $status: $stderr"
  assert_stderr_empty
  assert_stdout_has_line "$SUBMIT_SUCCESS"
  assert_saved_id "$tool" sub_second0000000 "$started"
  [[ $(ls -A -- "$cwd") == deploy-link.sh ]] || fail "wrote into the working directory: $(ls -A -- "$cwd")"
  [[ $(dir_listing "$tool" | grep -v '^submission-id.txt ') == "$listing" ]] || fail "the tool's directory changed beyond the record"
  rm -- "$tool/submission-id.txt"
  SUBMIT_CWD=$cwd SUBMIT_DEPLOY=./deploy-link.sh SUBMIT_INPUT=y run_submit
  [[ $status == 0 ]] || fail "expected exit 0, got $status: $stderr"
  assert_saved_id "$tool" sub_second0000000 "$started"
  [[ $(ls -A -- "$cwd") == deploy-link.sh ]] || fail "wrote into the working directory: $(ls -A -- "$cwd")"
}

test_submit_keeps_the_saved_id_unless_a_new_submission_is_confirmed() {
  setup_submit
  local record=$TOOL_DIR/submission-id.txt before code answer path
  printf 'Submission ID: sub_previous000000\nSubmitted: 2026-01-02 03:04:05 UTC\n' >"$record"
  chmod 600 "$record"
  before=$(file_identity "$record")
  # Cancelled.
  SUBMIT_INPUT=n run_submit
  assert_status 0
  assert_stdout_contains "$SUBMIT_CANCELLED"
  [[ $(file_identity "$record") == "$before" ]] || fail "[cancel]: the record changed"
  # Not sent (7), and uncertain: a timeout (28), a lost connection (52).
  for code in 7 28 52; do
    rm -f -- "$TEST_TMP"/curl-log/*
    FAKE_CURL_FAIL_NAME=submit FAKE_CURL_FAIL_CODE=$code SUBMIT_INPUT=y run_submit
    [[ $status == 1 ]] || fail "[curl $code]: expected exit 1, got $status"
    [[ $(file_identity "$record") == "$before" ]] || fail "[curl $code]: the record changed"
  done
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  # An unexpected answer.
  for answer in '' 'not json' '{"ok":true,"status":"pending","submission_id":"short"}'; do
    rm -f -- "$TEST_TMP"/curl-log/*
    printf '%s' "$answer" >"$TEST_TMP/web/$SUBMIT_HOST/submit"
    SUBMIT_INPUT=y run_submit
    [[ $status == 1 ]] || fail "[$answer]: expected exit 1, got $status"
    assert_stdout_contains "$SUBMIT_UNCERTAIN"
    [[ $(file_identity "$record") == "$before" ]] || fail "[$answer]: the record changed"
  done
  # Over a real connection: refused with HTTP 400 and 429, and HTTP 500.
  start_submit_server
  for path in reject limited; do
    SUBMIT_TEST_URL=$SUBMIT_SERVER/$path SUBMIT_INPUT=y run_submit
    [[ $status == 1 ]] || fail "[$path]: expected exit 1, got $status"
    [[ $stdout == *"TariTalk's service refused the submission (HTTP 4"* ]] || fail "[$path]: not refused: $stdout"
    [[ $(file_identity "$record") == "$before" ]] || fail "[$path]: the record changed"
  done
  assert_stdout_contains "TariTalk's service refused the submission (HTTP 429); it was not recorded."
  SUBMIT_TEST_URL=$SUBMIT_SERVER/error SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  [[ $(file_identity "$record") == "$before" ]] || fail "[HTTP 500]: the record changed"
  [[ $(ls -A -- "$TOOL_DIR") == submission-id.txt ]] || fail "unexpected files next to deploy.sh: $(ls -A -- "$TOOL_DIR")"
}

test_submit_says_so_when_the_id_cannot_be_saved() {
  setup_submit
  local record=$TOOL_DIR/submission-id.txt before
  printf 'Submission ID: sub_previous000000\nSubmitted: 2026-01-02 03:04:05 UTC\n' >"$record"
  chmod 600 "$record"
  before=$(file_identity "$record")
  # The directory of deploy.sh cannot be written to: the submission stands
  # and its ID is shown, then the warning; the old record is untouched.
  chmod 555 "$TOOL_DIR"
  SUBMIT_INPUT=y run_submit
  chmod 755 "$TOOL_DIR"
  assert_status 0
  assert_stdout_has_line "$SUBMIT_SUCCESS"
  assert_stdout_has_line "  Submission ID: sub_0123456789abcdef"
  assert_stdout_has_line "$SUBMIT_NOT_SAVED"
  assert_stdout_has_line "deploy.sh. Copy the Submission ID above now; TariTalk has the submission."
  [[ $stdout == *"$SUBMIT_SUCCESS"*"$SUBMIT_NOT_SAVED"* ]] || fail "the warning does not follow the success"
  [[ $stdout != *uncertain* && $stdout != *"not sent"* && $stdout != *refused* ]] || fail "took the success back: $stdout"
  assert_stderr_contains "warning: cannot save the submission ID to '$record'"
  [[ $(curl_call_count) == 1 ]] || fail "expected one request, got $(curl_call_count)"
  [[ $(file_identity "$record") == "$before" ]] || fail "the old record changed"
  [[ $(ls -A -- "$TOOL_DIR") == submission-id.txt ]] || fail "temporary files left: $(ls -A -- "$TOOL_DIR")"
  # Something else at the path (a directory, a symlink) is never replaced.
  rm -- "$record"
  mkdir -- "$record"
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_has_line "$SUBMIT_SUCCESS"
  assert_stdout_has_line "$SUBMIT_NOT_SAVED"
  [[ -d $record && -z $(ls -A -- "$record") ]] || fail "the directory at the path was replaced"
  rmdir -- "$record"
  printf 'other\n' >"$TEST_TMP/other"
  ln -s "$TEST_TMP/other" "$record"
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_has_line "$SUBMIT_NOT_SAVED"
  [[ -L $record && $(<"$TEST_TMP/other") == other ]] || fail "the symlink or its target was replaced"
  [[ $(ls -A -- "$TOOL_DIR") == submission-id.txt ]] || fail "temporary files left: $(ls -A -- "$TOOL_DIR")"
}

# --- refusals: a stale, invalid or foreign record ---------------------------------

# expect_submit_refusal NAME MESSAGE: even with "y" ready on stdin, submit
# exits 1 with MESSAGE before asking anything, and sends nothing.
expect_submit_refusal() {
  SUBMIT_INPUT=y run_submit
  [[ $status == 1 ]] || fail "[$1]: expected exit 1, got $status"
  [[ $stderr == *"$2"* ]] || fail "[$1]: stderr lacks '$2': $stderr"
  [[ $stdout == *"$SUBMIT_REFUSED"* ]] || fail "[$1]: did not say that nothing was sent: $stdout"
  [[ $stdout != *"[y/N]"* && $stdout != *"Schema version"* && $stdout != *"Operator name"* ]] ||
    fail "[$1]: showed the submission or asked"
  [[ $stdout != *uncertain* ]] || fail "[$1]: called a refusal uncertain"
  assert_nothing_sent
  [[ ! -e $TEST_TMP/pwned ]] || fail "[$1]: the record was executed"
}

test_submit_refuses_a_record_whose_node_is_gone_or_not_running() {
  setup_submit
  local bin=$SB/opt/tari/releases/$STATUS_RELEASE/minotari_node
  cp -a -- "$SB" "$TEST_TMP/sysroot.saved"
  reset() {
    rm -rf -- "${SB:?}"
    cp -a -- "$TEST_TMP/sysroot.saved" "$SB"
    rm -f -- "$TEST_TMP"/curl-log/*
    : >"$FAKE_SYS/calls"
  }
  rm -- "$bin"
  expect_submit_refusal "binary gone" "minotari_node' is missing or not an executable file"
  reset
  chmod 644 -- "$bin"
  expect_submit_refusal "binary not executable" "minotari_node' is missing or not an executable file"
  reset
  rm -- "$SB/opt/tari/current"
  expect_submit_refusal "current gone" "'/opt/tari/current' is missing or not a symlink"
  reset
  ln -sfn releases/minotari-9.9.9-linux-arm64-ffffffffffffffff "$SB/opt/tari/current"
  expect_submit_refusal "current elsewhere" "'/opt/tari/current' does not point to the installed release"
  reset
  rm -- "$SB/etc/systemd/system/minotari-mainnet.service"
  expect_submit_refusal "unit gone" "'/etc/systemd/system/minotari-mainnet.service' is missing"
  reset
  rm -- "$FAKE_SYS/active.minotari-mainnet.service"
  expect_submit_refusal "not running" "minotari-mainnet.service is not active (inactive); only a running node can be submitted"
  touch "$FAKE_SYS/active.minotari-mainnet.service"
  rm -- "$FAKE_SYS/enabled.minotari-mainnet.service"
  expect_submit_refusal "not enabled" "minotari-mainnet.service is not enabled (disabled)"
  touch "$FAKE_SYS/enabled.minotari-mainnet.service"
  set_listeners 127.0.0.1:18189 127.0.0.1:9000
  expect_submit_refusal "p2p not public" "nothing listens on TCP 18189 on 0.0.0.0 or [::]"
  set_listeners 127.0.0.1:9000
  expect_submit_refusal "p2p closed" "nothing listens on TCP 18189 on 0.0.0.0 or [::]"
  # Back to the healthy node: it submits.
  # shellcheck disable=SC2086 # Space-separated address list.
  set_listeners $HEALTHY_LISTENERS
  reset
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_contains "$SUBMIT_SUCCESS"
}

test_submit_refuses_a_missing_unsafe_or_invalid_record() {
  setup_submit
  local state=$SB/var/lib/tari/taritalk-install-state record
  record=$(<"$state")
  reset_state() {
    rm -f -- "$state"
    printf '%s\n' "$record" >"$state"
    chmod 600 "$state"
    rm -f -- "$TEST_TMP"/curl-log/*
  }
  rm -- "$state"
  expect_submit_refusal "missing" "no node installed by taritalk-node-deploy was found"
  reset_state
  chmod 644 "$state"
  expect_submit_refusal "readable by others" "is not a private file of root"
  reset_state
  OPS_ROOT_IDS=0:0 expect_submit_refusal "another owner" "is not a private file of root"
  reset_state
  mv -- "$state" "$state.real"
  ln -s "$state.real" "$state"
  expect_submit_refusal "symlink" "is not a regular file"
  rm -f -- "$state" "$state.real"
  reset_state
  local name line
  for name in "public_ip=10.0.0.1|invalid public_ip" "public_ip=1.2.3|invalid public_ip" \
    "public_ip=|invalid public_ip" "version=v6.0.0|invalid version" "version=6.0|invalid version" \
    "version=6.0.1|invalid version" "tag=v6.0.1|invalid version" "format=2|not an install record" \
    'release_dir=/tmp/x|not an install record'; do
    line=${name%%|*}
    reset_state
    sed -i "s|^${line%%=*}=.*|$line|" "$state"
    expect_submit_refusal "$line" "${name#*|}"
  done
  for line in "public_ip=5.6.7.8" "version=6.0.0" "format=1"; do
    reset_state
    printf '%s\n' "$line" >>"$state"
    expect_submit_refusal "duplicate $line" "duplicate ${line%%=*}"
  done
  reset_state
  printf 'note=\x24(touch %s)\n' "$TEST_TMP/pwned" >>"$state"
  expect_submit_refusal "command substitution" "unexpected line"
  reset_state
  printf 'bad line\n' >>"$state"
  expect_submit_refusal "no equals sign" "unexpected line"
  reset_state
  sed -i '/^public_ip=/d' "$state"
  expect_submit_refusal "no public_ip" "invalid public_ip"
  reset_state
  sed -i '/^version=/d' "$state"
  expect_submit_refusal "no version" "invalid version"
  reset_state
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_contains "$SUBMIT_SUCCESS"
}

# --- optional endpoints, only from this tool's records -----------------------------

test_submit_adds_wallet_query_and_grpc_only_from_valid_records() {
  setup_submit
  write_endpoint_record /var/lib/taritalk-wallet-query/state wallet.example.com \
    acme_sh_version=3.1.1 installed_at=2026-10-01T00:00:00Z packages_installed=nginx
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_has_line "  Wallet Query URL:   https://wallet.example.com"
  [[ $stdout != *"Base Node gRPC"* ]] || fail "showed a gRPC endpoint that is not set up"
  [[ $(posted_json 1) == '{"installer_version":"0.1.0","minotari_version":"6.0.0","network":"mainnet","p2p_port":18189,"public_ip":"1.2.3.4","schema_version":2,"wallet_query_url":"https://wallet.example.com"}' ]] ||
    fail "unexpected body: $(posted_json 1)"
  [[ $(displayed_json) == "$(posted_json 1)" ]] || fail "shown $(displayed_json) but sent $(posted_json 1)"
  rm -f -- "$TEST_TMP"/curl-log/*
  # The gRPC service is given as its public URL: https://DOMAIN, the port
  # (443, implied) not written; the record's internals stay private.
  write_endpoint_record /var/lib/taritalk-grpc/state "$GRPC_SUBMIT_DOMAIN" with_wallet_query=1 \
    grpc_address=127.0.0.1:18142 allowed_methods=get_version,get_tip_info
  SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_has_line "  Wallet Query URL:   https://wallet.example.com"
  assert_stdout_has_line "  Base Node gRPC URL: https://$GRPC_SUBMIT_DOMAIN"
  [[ $(posted_json 1) == *"\"grpc_url\":\"https://$GRPC_SUBMIT_DOMAIN\""* && $(posted_json 1) == *'"wallet_query_url":"https://wallet.example.com"'* ]] ||
    fail "unexpected body: $(posted_json 1)"
  [[ $(posted_json 1) != *"127.0.0.1"* && $(posted_json 1) != *"18142"* && $(posted_json 1) != *allowed* ]] ||
    fail "sent internals: $(posted_json 1)"
  [[ $stdout != *":443"* && $(posted_json 1) != *":443"* && $(posted_json 1) != *grpc_address* ]] ||
    fail "the gRPC service is not given as https://DOMAIN: $(posted_json 1)"
  [[ $(displayed_json) == "$(posted_json 1)" ]] || fail "shown $(displayed_json) but sent $(posted_json 1)"
  rm -f -- "$TEST_TMP"/curl-log/*
  # A record that is not valid, or not this tool's, refuses the whole
  # submission rather than guessing.
  local wq=$SB/var/lib/taritalk-wallet-query/state grpc=$SB/var/lib/taritalk-grpc/state
  chmod 644 "$wq"
  expect_submit_refusal "wq readable" "'/var/lib/taritalk-wallet-query/state' is not a private file of root"
  chmod 600 "$wq"
  sed -i 's/^domain=.*/domain=Wallet.Example.com/' "$wq"
  expect_submit_refusal "wq bad domain" "is not a Wallet Query record of taritalk-node-deploy"
  sed -i 's/^domain=.*/domain=wallet.example.com/' "$wq"
  sed -i 's/^format=1/format=2/' "$grpc"
  expect_submit_refusal "grpc format" "is not a Base Node gRPC record of taritalk-node-deploy"
  sed -i 's/^format=2/format=1/' "$grpc"
  printf 'x=a b\n' >>"$grpc"
  expect_submit_refusal "grpc bad line" "is not a Base Node gRPC record of taritalk-node-deploy"
  rm -- "$grpc"
  mv -- "$wq" "$wq.real"
  ln -s "$wq.real" "$wq"
  expect_submit_refusal "wq symlink" "'/var/lib/taritalk-wallet-query/state' is not a regular file"
  rm -- "$wq" "$wq.real"
  OPS_ROOT_IDS=0:0 write_endpoint_record /var/lib/taritalk-wallet-query/state wallet.example.com
  OPS_ROOT_IDS=0:0 expect_submit_refusal "wq other owner" "is not a private file of root"
}

test_submit_sends_each_endpoint_combination_as_set_up() {
  setup_submit
  local wq=/var/lib/taritalk-wallet-query/state grpc=/var/lib/taritalk-grpc/state combo body
  local wq_json='"wallet_query_url":"https://wallet.example.com"' grpc_json="\"grpc_url\":\"https://$GRPC_SUBMIT_DOMAIN\""
  for combo in none wq grpc both; do
    rm -rf -- "$SB$wq" "$SB$grpc" "$TEST_TMP"/curl-log/*
    [[ $combo != wq && $combo != both ]] || write_endpoint_record "$wq" wallet.example.com
    [[ $combo != grpc && $combo != both ]] || write_endpoint_record "$grpc" "$GRPC_SUBMIT_DOMAIN"
    SUBMIT_INPUT=y run_submit
    [[ $status == 0 ]] || fail "[$combo]: expected exit 0, got $status: $stderr"
    body=$(posted_json 1)
    case "$combo" in
      none) [[ $body != *wallet_query_url* && $body != *grpc_url* ]] ;;
      wq) [[ $body == *"$wq_json"* && $body != *grpc_url* ]] ;;
      grpc) [[ $body != *wallet_query_url* && $body == *"$grpc_json"* ]] ;;
      both) [[ $body == *"$wq_json"* && $body == *"$grpc_json"* ]] ;;
    esac || fail "[$combo]: unexpected body: $body"
    [[ $body != *":443"* && $body != *grpc_address* && $stdout != *":443"* ]] || fail "[$combo]: a port or the old field: $body"
    [[ $(displayed_json) == "$body" ]] || fail "[$combo]: shown $(displayed_json) but sent $body"
    [[ $(curl_call_count) == 1 ]] || fail "[$combo]: expected one request, got $(curl_call_count)"
    assert_stdout_contains "$SUBMIT_SUCCESS"
  done
}

# --- the optional operator name -------------------------------------------------

test_submit_operator_name_is_shown_sent_and_explained_only_when_given() {
  setup_submit
  write_endpoint_record /var/lib/taritalk-grpc/state "$GRPC_SUBMIT_DOMAIN"
  local name
  for name in "Test Node" "测试" "Émile Zola" "Ярослав" "日本語ノード" "@TariFans" "Ünïcode Ltd." "😀 Tari fan" \
    "$(printf 'x%.0s' {1..64})" "$(printf '测%.0s' {1..64})"; do
    rm -f -- "$TEST_TMP"/curl-log/*
    SUBMIT_NAME=$name SUBMIT_INPUT=y run_submit
    [[ $status == 0 ]] || fail "[$name]: expected exit 0, got $status: $stderr"
    assert_stderr_empty
    [[ $stdout == *"$SUBMIT_NAME_PROMPT"* && $stdout != *"$SUBMIT_NAME_REFUSED"* ]] || fail "[$name]: refused: $stdout"
    assert_stdout_has_line "  Operator name:      $name"
    assert_stdout_has_line "  Base Node gRPC URL: https://$GRPC_SUBMIT_DOMAIN"
    [[ $(posted_json 1) == "$(jq -S -c --arg n "$name" --arg g "https://$GRPC_SUBMIT_DOMAIN" '. + {operator_name: $n, grpc_url: $g}' <<<"$SUBMIT_EXPECTED_BODY")" ]] ||
      fail "[$name]: unexpected body: $(posted_json 1)"
    [[ $(displayed_json) == "$(posted_json 1)" ]] || fail "[$name]: shown $(displayed_json) but sent $(posted_json 1)"
    # The explanation does not claim that no name is sent.
    assert_stdout_contains "The operator name is the display name you typed, nothing more: it creates"
    assert_stdout_contains "no account, ownership proof, login or management token."
    [[ $stdout != *"No name is sent"* && $stdout != *"email address, name,"* && $stdout != *"Community registered"* ]] ||
      fail "[$name]: claimed that no name is sent: $stdout"
    assert_stdout_contains "$SUBMIT_SUCCESS"
  done
  # Surrounding spaces and tabs are not part of the name.
  rm -f -- "$TEST_TMP"/curl-log/*
  SUBMIT_NAME=$'  \tTest Node \t ' SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stdout_has_line "  Operator name:      Test Node"
  [[ $(posted_json 1) == *'"operator_name":"Test Node"'* ]] || fail "unexpected body: $(posted_json 1)"
  # Enter, or only blanks: no name field anywhere, and no placeholder.
  for name in "" " " $'\t'; do
    rm -f -- "$TEST_TMP"/curl-log/*
    SUBMIT_NAME=$name SUBMIT_INPUT=y run_submit
    [[ $status == 0 ]] || fail "[blank]: expected exit 0, got $status: $stderr"
    [[ $stdout != *"  Operator name:"* && $stdout != *Anonymous* ]] || fail "[blank]: showed a name: $stdout"
    [[ $(posted_json 1) == "$(jq -S -c --arg g "https://$GRPC_SUBMIT_DOMAIN" '. + {grpc_url: $g}' <<<"$SUBMIT_EXPECTED_BODY")" ]] ||
      fail "[blank]: unexpected body: $(posted_json 1)"
    [[ $(posted_json 1) != *operator* && $(posted_json 1) != *nonymous* ]] || fail "[blank]: sent a name: $(posted_json 1)"
    assert_stdout_contains "No name is sent: if TariTalk publishes the node, it is listed as"
    assert_stdout_contains '"Community registered".'
    [[ $stdout != *"display name you typed"* ]] || fail "[blank]: explained a name that was not given"
    assert_stdout_contains "$SUBMIT_SUCCESS"
  done
}

test_submit_asks_again_after_a_name_that_cannot_be_used() {
  setup_submit
  local bad
  # Unusable: no letter or digit, too long (65 characters), a left-to-right
  # mark, a right-to-left override, a no-break space, an ideographic space, a
  # soft hyphen, a byte order mark, a line separator, a private-use
  # character, a tag character, bytes that are not UTF-8, and controls.
  local -a rejected=("---" "😀" "$(printf 'x%.0s' {1..65})" "$(printf '测%.0s' {1..65})" $'a\xe2\x80\x8eb' $'a\xe2\x80\xaeb'
  $'a\xc2\xa0b' $'a\xe3\x80\x80b' $'a\xc2\xadb' $'\xef\xbb\xbfTest' $'a\xe2\x80\xa8b' $'a\xee\x80\x80b' $'a\xf3\xa0\x80\x81b'
  $'a\xffb' $'a\xc3b' $'a\tb' $'a\x01b' $'a\x7fb')
  # Every unusable name is refused with the reason, then asked again; the
  # name finally given is the one sent.
  printf -v bad '%s\n' "${rejected[@]}"
  SUBMIT_NAME="${bad}Test Node" SUBMIT_INPUT=y run_submit
  assert_status 0
  assert_stderr_empty
  [[ $(grep -c -F "$SUBMIT_NAME_PROMPT" <<<"$stdout") == $((${#rejected[@]} + 1)) ]] ||
    fail "expected $((${#rejected[@]} + 1)) prompts: $stdout"
  [[ $(grep -c -F "$SUBMIT_NAME_REFUSED" <<<"$stdout") == "${#rejected[@]}" ]] || fail "expected ${#rejected[@]} refusals: $stdout"
  assert_stdout_contains "marks, symbols or spaces in any language, with at least one letter or digit"
  assert_stdout_contains "and no control or invisible characters."
  assert_stdout_has_line "  Operator name:      Test Node"
  [[ $(posted_json 1) == *'"operator_name":"Test Node"'* ]] || fail "unexpected body: $(posted_json 1)"
  for bad in "${rejected[@]}"; do
    [[ $(posted_json 1) != *"$bad"* ]] || fail "sent a refused name: $(posted_json 1)"
  done
  [[ $(curl_call_count) == 1 ]] || fail "expected one request, got $(curl_call_count)"
  # A refused name, then Enter: no name. Then the end of input: no name,
  # and the confirmation is not reached, so nothing is sent.
  rm -f -- "$TEST_TMP"/curl-log/*
  SUBMIT_NAME=$'---\n' SUBMIT_INPUT=y run_submit
  assert_status 0
  [[ $stdout != *"  Operator name:"* && $(posted_json 1) != *operator* ]] || fail "sent a name: $(posted_json 1)"
  assert_stdout_contains "No name is sent"
  rm -f -- "$TEST_TMP"/curl-log/*
  SUBMIT_NAME="---" run_submit
  assert_status 0
  assert_stdout_contains "$SUBMIT_NAME_REFUSED"
  assert_stdout_contains "$SUBMIT_CANCELLED"
  assert_nothing_sent
}

test_submit_judges_names_the_same_in_any_locale() {
  setup_submit
  # C.UTF-8 is built into glibc; en_US.UTF-8 only if this host has it.
  local locale
  for locale in C POSIX C.UTF-8 $(locale -a 2>/dev/null | grep -m 1 -x -e en_US.utf8 -e en_US.UTF-8); do
    rm -f -- "$TEST_TMP"/curl-log/*
    LC_ALL=$locale LANG=$locale SUBMIT_NAME=$'a\xe2\x80\x8eb\n'"$(printf '测%.0s' {1..65})"$'\nTest Node 测试' SUBMIT_INPUT=y run_submit
    [[ $status == 0 ]] || fail "[$locale]: expected exit 0, got $status: $stderr"
    [[ $stderr != *locale* ]] || fail "[$locale]: $stderr"
    [[ $(grep -c -F "$SUBMIT_NAME_REFUSED" <<<"$stdout") == 2 ]] || fail "[$locale]: expected 2 refusals: $stdout"
    assert_stdout_has_line "  Operator name:      Test Node 测试"
    [[ $(posted_json 1) == *'"operator_name":"Test Node 测试"'* ]] || fail "[$locale]: unexpected body: $(posted_json 1)"
  done
}

# --- the request: one, bounded, with TLS, and honest about failures ----------------

test_submit_failures_before_the_request_say_nothing_reached_taritalk() {
  setup_submit
  local code
  # curl's "could not resolve", "could not connect" and certificate errors
  # all happen before any request is sent.
  for code in 6 7 35 60; do
    rm -f -- "$TEST_TMP"/curl-log/*
    FAKE_CURL_FAIL_NAME=submit FAKE_CURL_FAIL_CODE=$code SUBMIT_INPUT=y run_submit
    [[ $status == 1 ]] || fail "[$code]: expected exit 1, got $status"
    [[ $stdout == *"$SUBMIT_NOT_SENT"* ]] || fail "[$code]: did not say that nothing reached TariTalk: $stdout"
    [[ $stdout != *uncertain* && $stdout != *"Success:"* ]] || fail "[$code]: wrong outcome: $stdout"
    assert_stderr_contains "could not connect securely to TariTalk (curl: ($code) simulated failure)"
    [[ $(curl_call_count) == 1 ]] || fail "[$code]: retried: $(curl_call_count) requests"
    [[ -z $(ls -A "$SB/tmp") ]] || fail "[$code]: temporary files left"
  done
}

test_submit_failures_after_the_request_may_have_started_are_uncertain() {
  setup_submit
  local code
  # A timeout, an empty or broken answer, a connection lost mid-way: the
  # request may have been received, so the outcome is not claimed.
  for code in 28 52 56 18 55 22; do
    rm -f -- "$TEST_TMP"/curl-log/*
    FAKE_CURL_FAIL_NAME=submit FAKE_CURL_FAIL_CODE=$code SUBMIT_INPUT=y run_submit
    [[ $status == 1 ]] || fail "[$code]: expected exit 1, got $status"
    [[ $stdout == *"$SUBMIT_UNCERTAIN"* ]] || fail "[$code]: not uncertain: $stdout"
    [[ $stdout == *"TariTalk, but no confirmation arrived. It was not necessarily lost."* ]] || fail "[$code]: $stdout"
    [[ $stdout != *"nothing was sent"* && $stdout != *"nothing reached"* && $stdout != *"not recorded"* &&
      $stdout != *"Success:"* ]] || fail "[$code]: claimed an outcome: $stdout"
    [[ $(curl_call_count) == 1 ]] || fail "[$code]: retried: $(curl_call_count) requests"
  done
  assert_stderr_contains "the request failed (curl: (22) simulated failure)"
  # A hanging curl is ended by the time limit, and that too is uncertain.
  rm -f -- "$TEST_TMP"/curl-log/*
  local start=$SECONDS
  FAKE_CURL_SLEEP_NAME=submit SUBMIT_TEST_SECONDS=1 SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  assert_stderr_contains "the request timed out"
  ((SECONDS - start < 25)) || fail "the hanging request was not ended in time"
  [[ $(curl_call_count) == 1 ]] || fail "retried: $(curl_call_count) requests"
  ! kill -0 "$(<"$TEST_TMP/curl-log/sleep.pid")" 2>/dev/null || fail "the hanging request was left running"
}

test_submit_treats_an_unexpected_answer_as_uncertain() {
  setup_submit
  local answer
  for answer in '' 'not json' '{"ok":true}' '{"ok":true,"status":"approved","submission_id":"sub_1"}' \
    '{"ok":false,"submission_id":"sub_0123456789abcdef","status":"pending"}' \
    '{"ok":true,"status":"pending","submission_id":"../x"}' '{"ok":true,"status":"pending","submission_id":"short"}'; do
    rm -f -- "$TEST_TMP"/curl-log/*
    printf '%s' "$answer" >"$TEST_TMP/web/$SUBMIT_HOST/submit"
    SUBMIT_INPUT=y run_submit
    [[ $status == 1 ]] || fail "[$answer]: expected exit 1, got $status"
    [[ $stdout == *"$SUBMIT_UNCERTAIN"* ]] || fail "[$answer]: not uncertain: $stdout"
    [[ $stdout != *"Success:"* && $stdout != *"Submission ID"* ]] || fail "[$answer]: claimed success"
    assert_stderr_contains "the service gave an unexpected answer"
    [[ $(curl_call_count) == 1 ]] || fail "[$answer]: retried"
  done
}

# start_submit_server: a throwaway certificate for 127.0.0.1 and the
# stand-in service (tests/fakes/submit_server.py) behind it. Sets
# SUBMIT_SERVER (https://127.0.0.1:PORT) and puts the real curl, which
# trusts only that certificate, first in SUBMIT_TEST_PATH. Stopped on exit.
start_submit_server() {
  local tool real
  for tool in python3 openssl; do
    command -v "$tool" >/dev/null || fail "test tool '$tool' is required"
  done
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
    -addext "subjectAltName=IP:127.0.0.1" -keyout "$TEST_TMP/key.pem" -out "$TEST_TMP/cert.pem" 2>/dev/null ||
    fail "cannot create a test certificate"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=other \
    -keyout "$TEST_TMP/other-key.pem" -out "$TEST_TMP/other.pem" 2>/dev/null || fail "cannot create a test certificate"
  : >"$TEST_TMP/access.log"
  python3 "$TESTS_DIR/fakes/submit_server.py" "$TEST_TMP/cert.pem" "$TEST_TMP/key.pem" \
    "$TEST_TMP/port" "$TEST_TMP/access.log" &
  SUBMIT_SERVER_PID=$!
  trap 'kill "$SUBMIT_SERVER_PID" 2>/dev/null; wait "$SUBMIT_SERVER_PID" 2>/dev/null' EXIT
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -s $TEST_TMP/port ]] && break
    sleep 0.1
  done
  [[ -s $TEST_TMP/port ]] || fail "the test service did not start"
  SUBMIT_SERVER=https://127.0.0.1:$(<"$TEST_TMP/port")
  real=$(type -aP curl | grep -v '/guard/' | head -n 1)
  mkdir -p "$TEST_TMP/realcurl"
  ln -sf "$real" "$TEST_TMP/realcurl/curl"
  SUBMIT_TEST_PATH="$TEST_TMP/realcurl:$TEST_TMP/fakebin:$TESTS_DIR/guard:/usr/bin:/bin"
  export SUBMIT_TEST_PATH CURL_CA_BUNDLE=$TEST_TMP/cert.pem
  unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy
}

# server_count KIND [PATH]: lines "KIND ..." (or "KIND POST PATH") in the
# service's log so far.
server_count() {
  local n=0 kind method path
  while read -r kind method path; do
    if [[ -z ${2-} ]]; then
      [[ $kind == "$1" ]] && n=$((n + 1))
    else
      [[ $kind == "$1" && $method == POST && $path == "$2" ]] && n=$((n + 1))
    fi
  done <"$TEST_TMP/access.log"
  echo "$n"
}

# server_body: the last body the service read.
server_body() {
  sed -n 's/^BODY //p' "$TEST_TMP/access.log" | tail -n 1 | jq -S -c . || fail "the service read no JSON body"
}

test_submit_over_a_real_https_connection() {
  setup_submit
  start_submit_server
  # Success: the body the service read is exactly what was shown.
  local started
  started=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  SUBMIT_TEST_URL=$SUBMIT_SERVER/submit SUBMIT_INPUT=y run_submit
  [[ $status == 0 ]] || fail "expected exit 0, got $status: $stderr"
  assert_stderr_empty
  assert_stdout_has_line "$SUBMIT_SUCCESS"
  assert_stdout_has_line "  Submission ID: sub_test0001"
  assert_saved_id "$TOOL_DIR" sub_test0001 "$started"
  [[ $stdout != *"Status:"* ]] || fail "showed a status line after success"
  [[ $(server_count REQUEST /submit) == 1 ]] || fail "expected one request, the service saw $(server_count REQUEST /submit)"
  [[ $(server_body) == "$SUBMIT_EXPECTED_BODY" ]] || fail "the service read: $(server_body)"
  [[ $(displayed_json) == "$(server_body)" ]] || fail "shown $(displayed_json) but the service read $(server_body)"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
  # The service refuses: not recorded.
  SUBMIT_TEST_URL=$SUBMIT_SERVER/reject SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "TariTalk's service refused the submission (HTTP 400); it was not recorded."
  [[ $stdout != *uncertain* && $stdout != *"Success:"* ]] || fail "called a refusal uncertain or a success"
  assert_stderr_contains "the service refused the submission (HTTP 400)"
  [[ $(server_count REQUEST /reject) == 1 ]] || fail "retried after a refusal"
  # The service fails, or answers something else: uncertain.
  SUBMIT_TEST_URL=$SUBMIT_SERVER/error SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  assert_stderr_contains "the service gave an unexpected answer (HTTP 500)"
  SUBMIT_TEST_URL=$SUBMIT_SERVER/garbage SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  assert_stderr_contains "the service gave an unexpected answer"
  [[ $(server_count REQUEST /error) == 1 && $(server_count REQUEST /garbage) == 1 ]] || fail "retried"
}

test_submit_says_uncertain_when_the_service_reads_the_request_but_never_answers() {
  setup_submit
  start_submit_server
  # The service reads the whole request, then drops the connection.
  SUBMIT_TEST_URL=$SUBMIT_SERVER/drop SUBMIT_INPUT=y run_submit
  assert_status 1
  [[ $(server_count REQUEST /drop) == 1 && $(server_body) == "$SUBMIT_EXPECTED_BODY" ]] ||
    fail "the service did not read the request: $(<"$TEST_TMP/access.log")"
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  assert_stdout_contains "TariTalk, but no confirmation arrived. It was not necessarily lost."
  [[ $stdout != *"nothing was sent"* && $stdout != *"nothing reached"* && $stdout != *"not recorded"* ]] ||
    fail "claimed that nothing was submitted: $stdout"
  # curl reports the dropped connection as an empty reply (52) or an
  # unexpected end of the TLS stream (56); both are transport failures.
  [[ $stderr == *"the request failed (curl: (52)"* || $stderr == *"the request failed (curl: (56)"* ]] ||
    fail "unexpected reason: $stderr"
  # The service reads the request, then never answers: the time limit ends
  # the wait, and that is uncertain too.
  SUBMIT_TEST_URL=$SUBMIT_SERVER/stall SUBMIT_TEST_SECONDS=2 SUBMIT_INPUT=y run_submit
  assert_status 1
  [[ $(server_count REQUEST /stall) == 1 ]] || fail "the service did not read the request"
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  [[ $stdout != *"nothing was sent"* && $stdout != *"nothing reached"* ]] || fail "claimed that nothing was submitted"
  assert_stderr_contains "the request timed out"
  [[ $(server_count REQUEST /drop) == 1 && $(server_count REQUEST /stall) == 1 ]] || fail "retried"
}

test_submit_verifies_the_certificate_and_sends_nothing_to_an_untrusted_service() {
  setup_submit
  start_submit_server
  local accepted
  accepted=$(server_count ACCEPT)
  # The service's certificate is not trusted: the TLS handshake fails and
  # no request is ever sent.
  CURL_CA_BUNDLE=$TEST_TMP/other.pem SUBMIT_TEST_URL=$SUBMIT_SERVER/submit SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "$SUBMIT_NOT_SENT"
  [[ $stdout != *uncertain* ]] || fail "called a certificate failure uncertain"
  assert_stderr_contains "could not connect securely to TariTalk (curl: (60)"
  [[ $(server_count ACCEPT) == $((accepted + 1)) ]] || fail "expected one connection, got $(($(server_count ACCEPT) - accepted))"
  [[ $(server_count REQUEST) == 0 ]] || fail "a request reached the untrusted service: $(<"$TEST_TMP/access.log")"
  # A plain-HTTP URL is never used (only HTTPS is allowed).
  SUBMIT_TEST_URL=http://127.0.0.1:1/submit SUBMIT_INPUT=y run_submit
  assert_status 1
  assert_stdout_contains "$SUBMIT_NOT_SENT"
  assert_stderr_contains "could not connect securely to TariTalk (curl: (1)"
}

# --- the menu --------------------------------------------------------------------

# menu_submit_ready: the installed node of setup_upgrade, and the fake
# service answering a submission.
menu_submit_ready() {
  setup_upgrade
  TOOL_DIR=$TEST_TMP/tool
  # shellcheck disable=SC2034 # Read by menu_session (tests/test_menu.sh).
  MENU_TOOL_DIR=$TOOL_DIR
  mkdir -p "$TEST_TMP/web/$SUBMIT_HOST" "$TOOL_DIR"
  printf '%s' "$SUBMIT_ANSWER" >"$TEST_TMP/web/$SUBMIT_HOST/submit"
}

test_menu_submit_shows_the_fields_and_sends_only_on_yes() {
  menu_submit_ready
  # Each time: the name (Enter, Enter, then a name), the confirmation
  # (Enter, n, y) and Enter back to the menu.
  local started
  started=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  run_menu 7 "" "" "" 7 "" n "" 7 "Test Node" y "" 0
  assert_status 0
  assert_stderr_empty
  [[ $stdout != *arning* ]] || fail "the menu reported a warning: $stdout"
  assert_saved_id "$TOOL_DIR" sub_0123456789abcdef "$started"
  [[ $(menu_count "$SUBMIT_NAME_PROMPT") == 3 ]] || fail "the operator name was not asked each time"
  [[ $(menu_count $'\nSubmit node to TariTalk Nodes\n') == 3 ]] || fail "the submission was not shown each time"
  [[ $(menu_count "  Public IPv4:        $INSTALL_IP") == 3 ]] || fail "the public address was not shown"
  assert_stdout_has_line "  Minotari version:   $FIXTURE_VERSION"
  [[ $(menu_count "  Operator name:      Test Node") == 1 && $(menu_count "No name is sent") == 2 ]] ||
    fail "the name was not shown exactly when given: $stdout"
  [[ $(menu_count "$SUBMIT_CANCELLED") == 2 ]] || fail "Enter and n did not both cancel"
  [[ $(menu_count "$SUBMIT_SUCCESS") == 1 ]] || fail "y did not submit"
  assert_stdout_has_line "  Submission ID: sub_0123456789abcdef"
  [[ $stdout != *"Status:"* ]] || fail "showed a status line after success"
  local n=0 log
  for log in "$TEST_TMP"/curl-log/[0-9]*; do
    [[ $(tr '\0' ' ' <"$log") == *"$SUBMIT_HOST"* ]] || continue
    n=$((n + 1))
    [[ $(jq -S -c . <"$log.body") == *'"operator_name":"Test Node"'* ]] || fail "unexpected body: $(<"$log.body")"
  done
  ((n == 1)) || fail "expected one request to TariTalk, got $n"
  [[ ${stdout##*TariTalk Node Tool} == *"Node: Minotari $FIXTURE_VERSION, running"* ]] || fail "the node is not as before"
  [[ -z $(ls -A "$SB/tmp") ]] || fail "temporary files left: $(ls -A "$SB/tmp")"
}

test_menu_submit_failures_say_first_whether_anything_reached_taritalk() {
  menu_submit_ready
  FAKE_CURL_FAIL_NAME=submit FAKE_CURL_FAIL_CODE=7 run_menu 7 "" y "" 0
  assert_status 0
  assert_stdout_contains "The node was not submitted; nothing reached TariTalk."
  assert_stdout_contains "Reason: could not connect securely to TariTalk (curl: (7) simulated failure)."
  [[ $stdout != *"did not complete"* ]] || fail "said it did not complete instead of the outcome"
  assert_stderr_empty
  FAKE_CURL_FAIL_NAME=submit FAKE_CURL_FAIL_CODE=28 run_menu 7 "" y "" 0
  assert_status 0
  assert_stdout_contains "$SUBMIT_UNCERTAIN"
  assert_stdout_contains "Whether the node was submitted is uncertain; see below."
  assert_stdout_contains "Reason: the request timed out."
  [[ $stdout != *"nothing reached"* && $stdout != *"nothing was sent"* && $stdout != *"Success:"* ]] ||
    fail "claimed an outcome"
  # A check fails: the node is not running.
  "$TEST_TMP/fakebin/systemctl" stop minotari-mainnet.service
  run_menu 7 "" 0
  assert_status 0
  assert_stdout_contains "The node was not submitted; nothing was sent to TariTalk."
  assert_stdout_contains "Reason: it stopped at one of its checks, before changing anything."
  [[ $stdout != *"[y/N]"* && $stdout != *"Operator name"* ]] || fail "asked although the node is not running"
  assert_stderr_empty
}

test_menu_submit_in_a_real_terminal() {
  menu_submit_ready
  TERM=xterm pty_menu --expect "Please choose: " --send '7\r' --expect "$SUBMIT_NAME_PROMPT" --send 'Test Node\r' \
    --expect "  Operator name:      Test Node" --expect "Submit this node to TariTalk Nodes? [y/N]: " \
    --send 'y\r' --expect "$SUBMIT_SUCCESS" --expect "Press Enter to return to the menu." \
    --send '\r' --expect "Please choose: " --send '0\r'
  assert_status 0
  assert_stdout_contains "  Submission ID: sub_0123456789abcdef"
  [[ -s $TEST_TMP/curl-log/1.body ]] || fail "no request was made"
  [[ $(posted_json 1) == *'"public_ip":"1.2.3.4"'* && $(posted_json 1) == *'"operator_name":"Test Node"'* ]] ||
    fail "unexpected body: $(posted_json 1)"
}

# --- no other command submits ------------------------------------------------------

test_submit_runs_only_when_chosen() {
  # Only deploy.sh (to load and dispatch it) and the menu (to list it) know
  # the submission; no other module can reach it.
  local hits
  hits=$(grep -lE 'cmd_submit|menu_run submit|send_submission|SUBMIT_URL|lib/submit\.sh' "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/deploy.sh |
    LC_ALL=C sort | tr '\n' ' ')
  [[ $hits == "$REPO_ROOT/deploy.sh $REPO_ROOT/lib/menu.sh $REPO_ROOT/lib/submit.sh " ]] ||
    fail "submission reachable from: $hits"
  grep -q '7) menu_run submit ;;' "$REPO_ROOT/lib/menu.sh" || fail "menu item 7 is not the submission"
  grep -q '8) menu_run uninstall ;;' "$REPO_ROOT/lib/menu.sh" || fail "menu item 8 is not uninstall"
  # Status, logs, Wallet Query and gRPC in the sandbox make no request to
  # TariTalk (install and upgrade are covered by their own request tests).
  setup_submit
  run_ops status
  assert_status 0
  run_ops logs --lines 1
  assert_status 0
  local log
  for log in "$TEST_TMP"/curl-log/[0-9]*; do
    [[ -e $log ]] || continue
    [[ $(tr '\0' ' ' <"$log") != *"$SUBMIT_HOST"* ]] || fail "status or logs contacted TariTalk"
  done
}

test_readme_describes_the_submission_as_implemented() {
  local readme=$REPO_ROOT/README.md section menu_block
  # The menu in the README is the menu the tool prints.
  setup_install
  run_menu 0
  assert_status 0
  # shellcheck disable=SC2016 # awk anchors, not shell.
  menu_block=$(awk '/^```text$/ { block = 1; next } block && /^```$/ { exit } block' "$readme")
  [[ $menu_block == "$(grep -E '^[0-9]\. ' <<<"$stdout")" ]] || fail "README menu differs from the tool's"
  # Feature 7 is the command and menu item, with the flow as implemented.
  # shellcheck disable=SC2016 # awk anchors, not shell.
  section=$(awk '/^### Feature 7: Submit node to TariTalk Nodes$/ { on = 1 } /^### Feature 8/ { exit } on' "$readme")
  [[ $section == *$'```bash\n./deploy.sh submit\n```'* ]] || fail "README lacks the submit command"
  local phrase
  # shellcheck disable=SC2016 # Markdown code spans, not shell.
  for phrase in 'Tari Global Node Lighting Initiative' 'optional operator name' 'pressing Enter keeps the node anonymous' \
    'Community registered' 'no account, login or management token' 'pressing Enter cancels and sends nothing' \
    'manual verification by TariTalk' 'not automatically listed' "$SUBMIT_SUCCESS" 'submission ID' \
    'may be temporarily rate limited' 'HTTP 429' 'wait a minute and try again' \
    'saves that ID with the time to `submission-id.txt`' 'next to `deploy.sh`' 'replaces it with the newest ID'; do
    [[ $section == *"$phrase"* ]] || fail "README Feature 7 lacks: $phrase"
  done
  [[ $section != *Anonymous* && $section != *":443"* ]] || fail "README Feature 7 names a placeholder or a port"
  # The refusal and success wording is the tool's own.
  grep -qF 'refused the submission (HTTP %s); it was not recorded.' "$REPO_ROOT/lib/submit.sh" || fail "refusal differs"
  grep -qxF "$SUBMIT_SUCCESS" "$REPO_ROOT/lib/submit.sh" || fail "success text differs"
  # The service's configured rule behind "may be rate limited", and the
  # public text keeps the service's internals to itself.
  grep -qxF 'simple = { limit = 1, period = 60 }' "$REPO_ROOT/worker/taritalk-nodes-submit/wrangler.toml" ||
    fail "the service's rate limit is not one per 60 seconds"
  for phrase in namespace wrangler D1 Cloudflare Worker; do
    [[ $section != *"$phrase"* ]] || fail "README Feature 7 exposes: $phrase"
  done
}
