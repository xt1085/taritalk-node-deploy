# shellcheck shell=bash
# Download helper behavior against a real local HTTPS server (127.0.0.1
# only). These call the internal http_get directly; the CLI itself only
# ever builds first-party Tari URLs.

# start_https_server: throwaway certificate for 127.0.0.1/localhost and the
# test server; sets HTTPS_BASE and HTTPS_AUTHORITY, and HTTP_PORT and
# PROBE_PORT for its plain HTTP and TCP-accept-only listeners. Stopped (and
# waited for) on test exit.
start_https_server() {
  local tool
  for tool in python3 openssl; do
    command -v "$tool" >/dev/null || fail "test tool '$tool' is required"
  done
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
    -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \
    -keyout "$TEST_TMP/key.pem" -out "$TEST_TMP/cert.pem" 2>/dev/null ||
    fail "cannot create a test certificate"
  : >"$TEST_TMP/access.log"
  python3 "$TESTS_DIR/fakes/https_server.py" "$TEST_TMP/cert.pem" \
    "$TEST_TMP/key.pem" "$TEST_TMP/port" "$TEST_TMP/access.log" &
  HTTPS_SERVER_PID=$!
  trap 'kill "$HTTPS_SERVER_PID" 2>/dev/null; wait "$HTTPS_SERVER_PID" 2>/dev/null' EXIT
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -s $TEST_TMP/port ]] && break
    sleep 0.1
  done
  [[ -s $TEST_TMP/port ]] || fail "test HTTPS server did not start"
  local tls_port
  read -r tls_port HTTP_PORT PROBE_PORT <"$TEST_TMP/port"
  HTTPS_AUTHORITY=127.0.0.1:$tls_port
  HTTPS_BASE=https://$HTTPS_AUTHORITY
}

# accepts_on TLS|HTTP|PROBE: TCP connections the test server accepted on
# that listener so far (counted at accept, before TLS or HTTP parsing).
accepts_on() {
  local n=0 kind name
  while read -r kind name; do
    [[ $kind == ACCEPT && $name == "$1" ]] && n=$((n + 1))
  done <"$TEST_TMP/access.log"
  echo "$n"
}

# requests_for PATH: how many requests the test server received for PATH.
requests_for() {
  local n=0 path
  while read -r _ path; do
    [[ $path == "$1" ]] && n=$((n + 1))
  done <"$TEST_TMP/access.log"
  echo "$n"
}

# use_curl_without_streaming_limit: put a curl wrapper first in PATH that
# drops --max-filesize, like curl before 8.4 (Debian 12 ships 7.88), which
# cannot enforce it without a Content-Length.
use_curl_without_streaming_limit() {
  local real
  real=$(type -aP curl | grep -v '/guard/' | head -n 1)
  mkdir -p "$TEST_TMP/oldcurl"
  # shellcheck disable=SC2016 # Writes a script; its $ are for that script.
  {
    printf '#!/usr/bin/env bash\nargs=()\n'
    printf 'while (($#)); do\n  if [[ $1 == --max-filesize ]]; then shift 2; continue; fi\n'
    printf '  args+=("$1"); shift\ndone\nexec %q "${args[@]}"\n' "$real"
  } >"$TEST_TMP/oldcurl/curl"
  chmod +x "$TEST_TMP/oldcurl/curl"
  HTTP_TEST_PATH="$TEST_TMP/oldcurl:$PATH"
}

# use_real_curl: the system curl (not the network guard), for 127.0.0.1.
use_real_curl() {
  local real
  real=$(type -aP curl | grep -v '/guard/' | head -n 1)
  mkdir -p "$TEST_TMP/realcurl"
  ln -sf "$real" "$TEST_TMP/realcurl/curl"
  HTTP_TEST_PATH="$TEST_TMP/realcurl:$PATH"
}

# shellcheck disable=SC2034 # stdout is read by tests/lib.sh assertions.
# run_http_get PATH_SUFFIX MAX_BYTES MAX_SECONDS: the product's http_get on
# $HTTPS_BASE/PATH_SUFFIX into $TEST_TMP/dl/out, allowing only the test
# server's authority. Sets status/stdout/stderr and ELAPSED (seconds).
run_http_get() {
  mkdir -p "$TEST_TMP/dl"
  rm -f "$TEST_TMP/dl/out"
  local start=$SECONDS
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy SSL_CERT_FILE SSL_CERT_DIR
    export NO_PROXY='*' no_proxy='*' CURL_CA_BUNDLE=$TEST_TMP/cert.pem
    export PATH=$HTTP_TEST_PATH
    cd "$TEST_TMP/dl" || exit 1
    http_get "$HTTPS_BASE/$1" out "$3" "$2" "$HTTPS_AUTHORITY"
  ) >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  ELAPSED=$((SECONDS - start))
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

# out_size: bytes written to the download target (0 if absent).
out_size() {
  if [[ -e $TEST_TMP/dl/out ]]; then stat -c %s "$TEST_TMP/dl/out"; else echo 0; fi
}

test_http_get_enforces_byte_limit_while_streaming() {
  start_https_server
  local mode
  for mode in real old; do
    if [[ $mode == real ]]; then use_real_curl; else use_curl_without_streaming_limit; fi
    run_http_get known/1000 1000 30
    [[ $status == 0 ]] || fail "$mode: exact-size download failed: $stderr"
    [[ $(out_size) == 1000 ]] || fail "$mode: wrong size $(out_size)"

    local path
    for path in known/5000 chunked/5000; do
      run_http_get "$path" 1000 30
      [[ $status == 1 ]] || fail "$mode $path: expected exit 1, got $status"
      assert_stderr_contains "download exceeds the 1000-byte limit: $HTTPS_BASE/$path"
      (($(out_size) <= 1001)) || fail "$mode $path: wrote $(out_size) bytes"
    done

    # An endless body is cut off at the limit, not downloaded until timeout.
    run_http_get chunked/-1 100000 60
    [[ $status == 1 ]] || fail "$mode endless: expected exit 1, got $status"
    assert_stderr_contains "download exceeds the 100000-byte limit"
    ((ELAPSED < 15)) || fail "$mode endless: took ${ELAPSED}s"
    (($(out_size) <= 100001)) || fail "$mode endless: wrote $(out_size) bytes"
  done
}

test_http_get_classifies_timeouts_and_http_errors() {
  start_https_server
  use_real_curl
  run_http_get stall 1000 2
  [[ $status == 1 ]] || fail "stall: expected exit 1, got $status"
  assert_stderr_contains "download timed out: $HTTPS_BASE/stall"
  ((ELAPSED < 15)) || fail "stall: took ${ELAPSED}s"

  run_http_get missing 1000 30
  [[ $status == 1 ]] || fail "404: expected exit 1, got $status"
  assert_stderr_contains "download failed with an HTTP error: $HTTPS_BASE/missing"
}

# expect_refused_redirect PATH MESSAGE: http_get on PATH fails with
# MESSAGE after exactly one connection (to the test server's TLS port, for
# PATH itself), and no connection at all reaches the plain HTTP or the
# probe listener, even one that never completes TLS or a request.
expect_refused_redirect() {
  : >"$TEST_TMP/access.log"
  run_http_get "$1" 1000 30
  [[ $status == 1 ]] || fail "$1: expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "$2"
  # Let any stray connection land in the log before counting.
  sleep 0.3
  [[ $(accepts_on HTTP) == 0 ]] || fail "$1: the plain HTTP target was connected to"
  [[ $(accepts_on PROBE) == 0 ]] || fail "$1: the disallowed authority was connected to"
  [[ $(accepts_on TLS) == 1 ]] || fail "$1: expected 1 TLS connection, got $(accepts_on TLS)"
  [[ $(requests_for "/$1") == 1 ]] || fail "$1: expected 1 request for /$1"
}

test_http_get_validates_each_redirect_before_requesting_it() {
  start_https_server
  use_real_curl
  # The listeners count connections (control: a direct connection to each
  # is seen, even one that sends nothing).
  : >"$TEST_TMP/access.log"
  "$TEST_TMP/realcurl/curl" --disable --silent --max-time 5 -o /dev/null "http://127.0.0.1:$HTTP_PORT/x" || true
  "$TEST_TMP/realcurl/curl" --disable --silent --max-time 5 -o /dev/null "http://127.0.0.1:$PROBE_PORT/x" || true
  sleep 0.3
  [[ $(accepts_on HTTP) == 1 && $(accepts_on PROBE) == 1 ]] ||
    fail "listener control failed: HTTP=$(accepts_on HTTP) PROBE=$(accepts_on PROBE)"

  # Allowed redirects are followed, including a relative Location: each
  # hop and the final target are requested exactly once.
  : >"$TEST_TMP/access.log"
  run_http_get redirect/five/5 1000 30
  [[ $status == 0 ]] || fail "5 redirects should be allowed: $stderr"
  [[ $(requests_for /landing/chain-five) == 1 ]] || fail "5th redirect target not fetched once"
  [[ $(accepts_on TLS) == 6 ]] || fail "5 redirects: expected 6 connections, got $(accepts_on TLS)"
  : >"$TEST_TMP/access.log"
  run_http_get relative 1000 30
  [[ $status == 0 ]] || fail "relative redirect should be allowed: $stderr"
  [[ $(requests_for /landing/relative) == 1 ]] || fail "relative target not fetched once"
  [[ $(accepts_on TLS) == 2 ]] || fail "relative: expected 2 connections, got $(accepts_on TLS)"

  # The 6th redirect is refused before it is requested.
  : >"$TEST_TMP/access.log"
  run_http_get redirect/six/6 1000 30
  [[ $status == 1 ]] || fail "6 redirects: expected exit 1, got $status"
  assert_stderr_contains "too many redirects: $HTTPS_BASE/redirect/six/6"
  [[ $(requests_for /landing/chain-six) == 0 ]] || fail "6th redirect target was requested"
  [[ $(accepts_on TLS) == 6 ]] || fail "6 redirects: expected 6 connections, got $(accepts_on TLS)"

  # Disallowed and malformed targets are refused before any connection.
  expect_refused_redirect to-http "redirected to a non-HTTPS URL: $HTTPS_BASE/to-http"
  expect_refused_redirect to-host "redirected to a disallowed host (localhost:$PROBE_PORT)"
  expect_refused_redirect to-port "redirected to a disallowed host (127.0.0.1:$PROBE_PORT)"
  local bad
  for bad in loc-empty loc-userinfo loc-port loc-ctrl loc-space; do
    expect_refused_redirect "$bad" "invalid redirect location: $HTTPS_BASE/$bad"
  done
}

test_http_get_rejects_responses_that_end_early() {
  start_https_server
  use_real_curl
  run_http_get short 1000 30
  [[ $status == 1 ]] || fail "short: expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "download ended early: $HTTPS_BASE/short"
}
