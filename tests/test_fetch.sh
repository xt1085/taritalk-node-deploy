# shellcheck shell=bash
# fetch: fixed-version, first-party release download and verification.
# The network is never used: a fake curl serves local fixtures.

readonly FIXTURE_VERSION=6.0.1-pre.2
readonly ASSET_ARM64=tari_suite-6.0.1-pre.2-mainnet-724c5f0-linux-arm64.zip
readonly ASSET_X86_64=tari_suite-6.0.1-pre.2-mainnet-724c5f0-linux-x86_64.zip
readonly MANIFEST_NAME=tari_suite-6.0.1-pre.2.sha256-unsigned.txt
readonly RELEASE_URL=https://github.com/tari-project/tari/releases/download/v6.0.1-pre.2
# Fake web root layout: $TEST_TMP/web/<host>/<path>.
readonly RELEASE_SUBDIR=web/github.com/tari-project/tari/releases/download/v6.0.1-pre.2
readonly API_SUBDIR=web/api.github.com/repos/tari-project/tari/releases
readonly API_URL=https://api.github.com/repos/tari-project/tari/releases

# write_fake_node FILE [VERSION_LINE]: a stand-in minotari_node that answers
# only --version and records every invocation in $TEST_TMP/node-trace.
write_fake_node() {
  local file=$1 line=${2-minotari_node $FIXTURE_VERSION}
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' "echo \"\$*\" >>'$TEST_TMP/node-trace'"
    printf '%s\n' "[ \"\$1\" = --version ] || exit 64"
    printf '%s\n' "echo '$line'"
  } >"$file"
  chmod 755 "$file"
}

# make_zip ZIP ENTRY...: zip ENTRY files from $TEST_TMP/zipsrc into ZIP.
make_zip() {
  local zip=$1
  shift
  command -v zip >/dev/null || fail "the 'zip' test tool is required"
  rm -f -- "$zip"
  (cd "$TEST_TMP/zipsrc" && zip -q -X "$zip" -- "$@") || fail "zip failed"
}

sha256_of() {
  local sum
  sum=$(sha256sum -- "$1") || fail "sha256sum failed"
  printf '%s\n' "${sum%% *}"
}

# refresh_hashes: rewrite both target assets' .sha256 sidecars and their
# manifest lines (in a copy of the real v6.0.1-pre.2 manifest) to match the
# current synthetic ZIPs.
refresh_hashes() {
  local rel=$TEST_TMP/$RELEASE_SUBDIR asset hash line out=''
  local -A hashes=()
  for asset in "$ASSET_ARM64" "$ASSET_X86_64"; do
    hash=$(sha256_of "$rel/$asset")
    hashes[$asset]=$hash
    printf '%s  %s\n' "$hash" "$asset" >"$rel/$asset.sha256"
  done
  while IFS= read -r line; do
    asset=${line:66}
    if [[ -n ${hashes[$asset]-} ]]; then
      line="${hashes[$asset]}  $asset"
    fi
    out+="$line"$'\n'
  done <"$FIXTURES/release/$MANIFEST_NAME"
  printf '%s' "$out" >"$rel/$MANIFEST_NAME"
  write_api_fixtures
}

# write_release_json FILE PRERELEASE: GitHub Releases API metadata for the
# fake release: every file in the release directory, plus the other assets
# the real manifest lists (with their real hashes and a nominal size).
write_release_json() {
  local file=$1 prerelease=$2 rel=$TEST_TMP/$RELEASE_SUBDIR f name line
  local assets='[]'
  local -A present=()
  for f in "$rel"/*; do
    name=${f##*/}
    present[$name]=1
    assets=$(jq -c --arg n "$name" --argjson s "$(stat -c %s "$f")" \
      --arg d "sha256:$(sha256_of "$f")" --arg u "$RELEASE_URL/$name" \
      '. + [{name: $n, size: $s, digest: $d, state: "uploaded",
        browser_download_url: $u}]' <<<"$assets") || fail "jq failed"
  done
  while IFS= read -r line; do
    name=${line:66}
    [[ -n ${present[$name]-} ]] && continue
    assets=$(jq -c --arg n "$name" --arg d "sha256:${line:0:64}" \
      --arg u "$RELEASE_URL/$name" '. + [{name: $n, size: 1000, digest: $d,
        state: "uploaded", browser_download_url: $u}]' <<<"$assets") ||
      fail "jq failed"
  done <"$FIXTURES/release/$MANIFEST_NAME"
  mkdir -p "$(dirname -- "$file")"
  jq -n --arg tag "v$FIXTURE_VERSION" --argjson pre "$prerelease" \
    --argjson assets "$assets" '{tag_name: $tag, name: $tag, draft: false,
      prerelease: $pre, assets: $assets}' >"$file" || fail "jq failed"
}

# write_api_fixtures: the tag endpoint (a pre-release, as on GitHub) and a
# "latest" endpoint (marked as a full release) for the fake release.
write_api_fixtures() {
  write_release_json "$TEST_TMP/$API_SUBDIR/tags/v$FIXTURE_VERSION" true
  write_release_json "$TEST_TMP/$API_SUBDIR/latest" false
}

# edit_api FILTER [ENDPOINT]: apply a jq FILTER to an API fixture
# (ENDPOINT: tags/v<version> by default, or latest).
edit_api() {
  local file=$TEST_TMP/$API_SUBDIR/${2:-tags/v$FIXTURE_VERSION} tmp
  tmp=$(jq "$1" "$file") || fail "jq filter failed: $1"
  printf '%s\n' "$tmp" >"$file"
}

# build_release: a fake release in $TEST_TMP/$RELEASE_SUBDIR whose two Mainnet Linux
# ZIPs contain minotari_node plus files that must never be executed.
build_release() {
  mkdir -p "$TEST_TMP/$RELEASE_SUBDIR" "$TEST_TMP/zipsrc" "$TEST_TMP/dest"
  write_fake_node "$TEST_TMP/zipsrc/minotari_node"
  write_fake_node "$TEST_TMP/zipsrc/minotari_console_wallet"
  printf 'readme\n' >"$TEST_TMP/zipsrc/README.md"
  make_zip "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64" minotari_node minotari_console_wallet README.md
  make_zip "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_X86_64" minotari_node minotari_console_wallet README.md
  refresh_hashes
}

# curl_call_count: number of fake curl invocations so far.
curl_call_count() {
  local n=0
  while [[ -e $TEST_TMP/curl-log/$((n + 1)) ]]; do n=$((n + 1)); done
  echo "$n"
}

# load_curl_call N: set CALL to invocation N's exact argv.
load_curl_call() {
  CALL=()
  mapfile -d '' -t CALL <"$TEST_TMP/curl-log/$1" || fail "no curl call $1"
}

# curl_requested URL: true if any fake curl invocation requested URL.
curl_requested() {
  local i n
  n=$(curl_call_count)
  for ((i = 1; i <= n; i++)); do
    load_curl_call "$i"
    [[ ${CALL[-1]} == "$1" ]] && return 0
  done
  return 1
}

# use_fake_curl: put the fake curl first in $TEST_TMP/fakebin, serving
# $TEST_TMP/web and logging to $TEST_TMP/curl-log.
use_fake_curl() {
  mkdir -p "$TEST_TMP/fakebin" "$TEST_TMP/curl-log"
  ln -sf "$TESTS_DIR/fakes/curl" "$TEST_TMP/fakebin/curl"
  export FAKE_WEB_ROOT=$TEST_TMP/web FAKE_CURL_LOG_DIR=$TEST_TMP/curl-log
}

# run_fetch [ARGS...]: fetch the fixture version into $TEST_TMP/dest using
# the fake curl. Extra ARGS (e.g. --arch) are appended.
run_fetch() {
  use_fake_curl
  PATH="$TEST_TMP/fakebin:$PATH" run_cli fetch --version "$FIXTURE_VERSION" \
    --destination "$TEST_TMP/dest" "$@"
}

test_fetch_help_exits_zero() {
  run_cli fetch --help
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "Usage: ./deploy.sh fetch"
  assert_stdout_contains "--arch ARCH"
  assert_stdout_contains "--dry-run"
  assert_stdout_contains "https://github.com/tari-project/tari/releases/download/"
  assert_stdout_contains "does not install"

  run_cli --help
  assert_stdout_contains "fetch"
}

test_fetch_requires_destination() {
  run_cli fetch --version 6.0.1-pre.2
  assert_status 2
  assert_stdout_empty
  assert_stderr_contains "fetch requires --destination"
}

test_fetch_normalizes_version_with_or_without_v_prefix() {
  local input
  build_release
  use_fake_curl
  for input in 6.0.1-pre.2 v6.0.1-pre.2; do
    PATH="$TEST_TMP/fakebin:$PATH" run_cli fetch --version "$input" \
      --destination "$TEST_TMP/dest" --arch aarch64 --dry-run
    assert_status 0
    assert_stderr_empty
    assert_stdout_has_line "tag: v6.0.1-pre.2"
    assert_stdout_has_line "version: 6.0.1-pre.2"
    assert_stdout_has_line "platform: linux-arm64"
    assert_stdout_has_line "manifest_url: https://github.com/tari-project/tari/releases/download/v6.0.1-pre.2/tari_suite-6.0.1-pre.2.sha256-unsigned.txt"
  done
}

test_fetch_rejects_malformed_versions() {
  local bad
  # shellcheck disable=SC2016 # Literal shell syntax is the malicious input.
  for bad in latest 6.0 6.0.1.2 vv6.0.1 V6.0.1 '6.0.1 ' '6.0.1 rc' 6.0.1/../x \
    ../6.0.1 6.0.1-pre..2 6.0.1-pre/2 'https://evil.example/6.0.1' \
    '6.0.1?x=1' 6.0.1%2F 6.0.1-pre.2%20 '6.0.1;id' '6.0.1$(id)' '6.0.1`id`' \
    '6.0.1|x' '6.0.1&' '6.0.1*' 6.0.1+build 06.0.1 6.0.1- ' 6.0.1'; do
    run_cli fetch --version "$bad" --destination "$TEST_TMP" --arch aarch64 --dry-run
    assert_status 2
    assert_stdout_empty
    assert_stderr_contains "invalid version"
  done
  # Empty value is a missing value.
  run_cli fetch --version '' --destination "$TEST_TMP" --dry-run
  assert_status 2
  assert_stderr_contains "--version requires a value"
}

# fetch_dry ARGS...: dry-run fetch of a valid version for aarch64.
fetch_dry() {
  [[ -d $TEST_TMP/$API_SUBDIR ]] || build_release
  use_fake_curl
  PATH="$TEST_TMP/fakebin:$PATH" run_cli fetch --version 6.0.1-pre.2 \
    --arch aarch64 --dry-run "$@"
}

test_fetch_rejects_missing_or_non_directory_destination() {
  fetch_dry --destination "$TEST_TMP/does-not-exist"
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "destination '$TEST_TMP/does-not-exist' is not an existing directory"

  : >"$TEST_TMP/a-file"
  fetch_dry --destination "$TEST_TMP/a-file"
  assert_status 1
  assert_stderr_contains "is not an existing directory"
}

test_fetch_rejects_unwritable_destination() {
  # The runner never runs ordinary tests as root.
  ((EUID != 0)) || fail "ordinary tests must not run as root"
  mkdir "$TEST_TMP/read-only"
  chmod 555 "$TEST_TMP/read-only"
  fetch_dry --destination "$TEST_TMP/read-only"
  assert_status 1
  assert_stderr_contains "is not writable"
}

test_fetch_rejects_system_destinations_and_symlinks_to_them() {
  local dir checked=0
  for dir in / /etc /opt /usr /usr/local /usr/local/bin /var /var/tmp /bin \
    /sbin /lib /lib64 /boot /root /etc/systemd; do
    [[ -d $dir ]] || continue
    checked=$((checked + 1))
    fetch_dry --destination "$dir"
    assert_status 1
    assert_stdout_empty
    assert_stderr_contains "refusing system location"

    ln -sfn "$dir" "$TEST_TMP/link"
    fetch_dry --destination "$TEST_TMP/link"
    assert_status 1
    assert_stderr_contains "refusing system location"
  done
  ((checked >= 5)) || fail "too few system directories present to test"
}

test_fetch_dry_run_reports_resolved_destination() {
  mkdir "$TEST_TMP/downloads"
  ln -s "$TEST_TMP/downloads" "$TEST_TMP/dl-link"
  fetch_dry --destination "$TEST_TMP/dl-link"
  assert_status 0
  local real
  real=$(realpath "$TEST_TMP/downloads")
  assert_stdout_has_line "destination: $real"
  assert_stdout_has_line "output_directory: $real/minotari-6.0.1-pre.2-linux-arm64"
}

test_fetch_dry_run_only_reads_release_metadata_and_writes_nothing() {
  build_release
  # Only bash, the fake curl, jq and read-only tools are usable; every file
  # writing, archive and privileged command is a tracing stub.
  # rm/rmdir are real: the dry-run removes its own private metadata file
  # (asserted below: TMPDIR ends up empty, the destination untouched).
  make_sandbox_path "$TEST_TMP/sandbox-bin" \
    unzip zipinfo sha256sum date
  rm -f "$TEST_TMP/sandbox-bin/curl" "$TEST_TMP/sandbox-bin/rm"
  local tool
  for tool in realpath stat jq timeout env mktemp cat rm rmdir head; do
    ln -s "$(command -v "$tool")" "$TEST_TMP/sandbox-bin/$tool"
  done
  ln -s "$TESTS_DIR/fakes/curl" "$TEST_TMP/sandbox-bin/curl"
  export TRACE_FILE=$TEST_TMP/trace FAKE_WEB_ROOT=$TEST_TMP/web
  export FAKE_CURL_LOG_DIR=$TEST_TMP/curl-log
  mkdir -p "$FAKE_CURL_LOG_DIR"
  : >"$TRACE_FILE"

  run_cli_with_path "$TEST_TMP/sandbox-bin" \
    fetch --version 6.0.1-pre.2 --destination "$TEST_TMP/dest" --dry-run
  assert_status 0
  assert_stderr_empty
  assert_stdout_has_line "platform: linux-arm64"
  assert_stdout_has_line "asset: $ASSET_ARM64"
  assert_stdout_has_line "fetch: dry-run (release metadata only; no assets downloaded, nothing written to the destination)"

  local trace
  trace=$(<"$TRACE_FILE")
  [[ $trace == "uname -m" ]] || fail "unexpected commands invoked: $trace"
  [[ $(curl_call_count) == 1 ]] || fail "dry-run made $(curl_call_count) requests"
  load_curl_call 1
  [[ ${CALL[-1]} == "$API_URL/tags/v$FIXTURE_VERSION" ]] || fail "requested ${CALL[-1]}"
  assert_dest_untouched
  [[ -z $(ls -A "$TMPDIR") ]] || fail "dry-run left temporary files: $(ls -A "$TMPDIR")"
}

test_fetch_refuses_existing_output_directory() {
  mkdir -p "$TEST_TMP/dest/minotari-6.0.1-pre.2-linux-arm64"
  fetch_dry --destination "$TEST_TMP/dest"
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "minotari-6.0.1-pre.2-linux-arm64' already exists; refusing to overwrite"
}

test_fetch_verifies_and_publishes_arm64_release() {
  build_release
  run_fetch --arch aarch64
  assert_status 0
  assert_stderr_empty
  local out=$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64
  assert_stdout_has_line "tag: v$FIXTURE_VERSION"
  assert_stdout_has_line "version: $FIXTURE_VERSION"
  assert_stdout_has_line "platform: linux-arm64"
  assert_stdout_has_line "asset: $ASSET_ARM64"
  assert_stdout_has_line "archive_sha256: $(sha256_of "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64")"
  assert_stdout_has_line "binary_sha256: $(sha256_of "$TEST_TMP/zipsrc/minotari_node")"
  assert_stdout_has_line "output_directory: $out"
  assert_stdout_has_line "fetch: verified"
  cmp -s "$out/minotari_node" "$TEST_TMP/zipsrc/minotari_node" ||
    fail "extracted minotari_node differs from the archive entry"
  cmp -s "$out/$ASSET_ARM64" "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64" ||
    fail "archive missing from output"
  [[ -f $out/$MANIFEST_NAME && -f $out/$ASSET_ARM64.sha256 ]] ||
    fail "checksum files missing from output"
}

test_fetch_selects_x86_64_mainnet_asset() {
  build_release
  run_fetch --arch amd64
  assert_status 0
  assert_stdout_has_line "platform: linux-x86_64"
  assert_stdout_has_line "asset: $ASSET_X86_64"
  assert_stdout_has_line "archive_sha256: $(sha256_of "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_X86_64")"
  [[ -d $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-x86_64 ]] ||
    fail "x86_64 output directory missing"
}

# prepend_manifest_line NAME: add a well-formed manifest entry for NAME at
# the top of the fake release manifest.
prepend_manifest_line() {
  local manifest=$TEST_TMP/$RELEASE_SUBDIR/$MANIFEST_NAME rest
  rest=$(<"$manifest")
  printf '%064d  %s\n%s\n' 0 "$1" "$rest" >"$manifest"
  write_api_fixtures
}

test_fetch_never_selects_near_miss_asset_names() {
  # The real fixture manifest already lists esme, RISC-V, macOS and Windows
  # assets; these are additional near misses placed before the real entry.
  local name
  for name in \
    tari_suite-6.0.1-pre.2-mainnet-724c5f0-esme-linux-arm64.zip \
    tari_suite-6.0.0-mainnet-724c5f0-linux-arm64.zip \
    tari_suite-6.0.1-pre.2.1-mainnet-724c5f0-linux-arm64.zip \
    evil-tari_suite-6.0.1-pre.2-mainnet-724c5f0-linux-arm64.zip \
    tari_suite-6.0.1-pre.2-mainnet-NOTHEX-linux-arm64.zip \
    tari_suite-6.0.1-pre.2-mainnet--linux-arm64.zip \
    tari_suite-6.0.1-pre.2-mainnet-724c5f0-linux-arm64.tar.zip; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc"
    build_release
    prepend_manifest_line "$name"
    run_fetch --arch aarch64
    assert_status 0
    assert_stdout_has_line "asset: $ASSET_ARM64"
  done
}

# drop_manifest_line NAME: remove NAME's entry from the fake manifest.
drop_manifest_line() {
  local manifest=$TEST_TMP/$RELEASE_SUBDIR/$MANIFEST_NAME line out=''
  while IFS= read -r line; do
    [[ ${line:66} == "$1" ]] || out+="$line"$'\n'
  done <"$manifest"
  printf '%s' "$out" >"$manifest"
  write_api_fixtures
}

test_fetch_fails_when_manifest_has_no_target_asset() {
  build_release
  # Only esme, RISC-V, macOS, Windows and x86_64 entries remain.
  drop_manifest_line "$ASSET_ARM64"
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "no Mainnet linux-arm64 asset for $FIXTURE_VERSION in $MANIFEST_NAME"
}

test_fetch_fails_when_manifest_has_multiple_target_assets() {
  build_release
  prepend_manifest_line tari_suite-6.0.1-pre.2-mainnet-abcdef0-linux-arm64.zip
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "multiple Mainnet linux-arm64 assets for $FIXTURE_VERSION in $MANIFEST_NAME"
}

# append_manifest_raw FORMAT [ARGS...]: append printf output (may contain
# binary bytes) to the fake manifest.
append_manifest_raw() {
  # shellcheck disable=SC2059 # FORMAT is the test's printf format.
  printf "$@" >>"$TEST_TMP/$RELEASE_SUBDIR/$MANIFEST_NAME"
  write_api_fixtures
}

test_fetch_rejects_malformed_manifests() {
  local h=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  local case_name
  local -a cases=(
    "single-space|$h x.zip\n"
    "three-spaces|$h   x.zip\n"
    "uppercase-hash|${h^^}  x.zip\n"
    "short-hash|${h:1}  x.zip\n"
    "absolute-path|$h  /etc/passwd\n"
    "traversal|$h  ../x.zip\n"
    "slash|$h  dir/x.zip\n"
    "dot-dot|$h  ..\n"
    "duplicate-name|$h  tari_suite-6.0.1-pre.2-esme-724c5f0-linux-arm64.zip\n"
    "nul|$h  x\0.zip\n"
    "crlf|$h  x.zip\r\n"
    "blank-line|\n"
    "leading-space| $h  x.zip\n"
    "shell-syntax|\$(touch pwned)\n"
  )
  for case_name in "${cases[@]}"; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc"
    build_release
    append_manifest_raw "${case_name#*|}"
    run_fetch --arch aarch64
    [[ $status == 1 ]] || fail "case ${case_name%%|*}: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "malformed release manifest $MANIFEST_NAME"
  done
  [[ ! -e pwned && ! -e $TEST_TMP/dest/pwned ]] || fail "manifest content was executed"

  rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc"
  build_release
  : >"$TEST_TMP/$RELEASE_SUBDIR/$MANIFEST_NAME"
  write_api_fixtures
  run_fetch --arch aarch64
  assert_status 1
  # GitHub would report size 0, which is refused before any download.
  assert_stderr_contains "release asset $MANIFEST_NAME: invalid size"
}

test_fetch_accepts_binary_mode_marker_in_manifest() {
  # sha256sum's " *" binary-mode separator is used by real Tari manifests.
  build_release
  local manifest=$TEST_TMP/$RELEASE_SUBDIR/$MANIFEST_NAME line out=''
  while IFS= read -r line; do
    [[ ${line:66} == "$ASSET_ARM64" ]] && line="${line:0:64} *$ASSET_ARM64"
    out+="$line"$'\n'
  done <"$manifest"
  printf '%s' "$out" >"$manifest"
  write_api_fixtures
  grep -qF " *$ASSET_ARM64" "$manifest" || fail "fixture not rewritten"
  run_fetch --arch aarch64
  assert_status 0
  assert_stdout_has_line "asset: $ASSET_ARM64"
}

test_fetch_rejects_sidecar_that_disagrees_or_is_malformed() {
  local h=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  local case_name sidecar
  local -a cases=(
    "different-hash|$h  $ASSET_ARM64\n|disagrees with the release manifest"
    "other-file|HASH  $ASSET_X86_64\n|does not describe $ASSET_ARM64"
    "two-lines|HASH  $ASSET_ARM64\nHASH  $ASSET_ARM64.bak\n|exactly one entry"
    "bad-hash|${h:1}  $ASSET_ARM64\n|malformed $ASSET_ARM64.sha256"
    "empty||release asset $ASSET_ARM64.sha256: invalid size"
  )
  for case_name in "${cases[@]}"; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" "$TEST_TMP/curl-log"
    build_release
    sidecar=${case_name#*|}
    sidecar=${sidecar%|*}
    sidecar=${sidecar//HASH/$(sha256_of "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64")}
    # shellcheck disable=SC2059 # The case defines the printf format.
    printf "$sidecar" >"$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64.sha256"
    write_api_fixtures
    run_fetch --arch aarch64
    [[ $status == 1 ]] || fail "case ${case_name%%|*}: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "${case_name##*|}"
    # The archive itself must not be downloaded before the records agree.
    ! curl_requested "$RELEASE_URL/$ASSET_ARM64" ||
      fail "case ${case_name%%|*}: ZIP downloaded before checksums agreed"
  done
}

test_fetch_rejects_archive_with_wrong_sha256() {
  build_release
  # Records agree with each other, but the served ZIP was altered in place.
  overwrite_last_byte "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64"
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "SHA-256 mismatch for $ASSET_ARM64"
  [[ ! -e $TEST_TMP/node-trace ]] || fail "binary from an unverified archive was executed"

  # A longer file is cut off at the size GitHub reported.
  rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" "$TEST_TMP/curl-log"
  build_release
  local size
  size=$(stat -c %s "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64")
  printf 'tampered' >>"$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64"
  run_fetch --arch aarch64
  assert_status 1
  assert_stderr_contains "download exceeds the $size-byte limit: $RELEASE_URL/$ASSET_ARM64"
  assert_dest_untouched
}

# check_request N MAX_TIME MAX_BYTES URL HEADERS_FILE [EXTRA...]: fake curl
# call N had exactly the expected argv. --max-time is the time left of the
# download's budget, so MAX_TIME or one second less (a clock tick) is fine.
check_request() {
  local n=$1 secs=$2 bytes=$3 url=$4 headers=$5
  shift 5
  load_curl_call "$n"
  local got_time=${CALL[9]-}
  [[ $got_time == "$secs" || $got_time == $((secs - 1)) ]] ||
    fail "request $n: --max-time $got_time, expected $secs"
  local -a want=(--disable --fail --silent --show-error --proto "=https"
    --connect-timeout 30 --max-time "$got_time" --max-filesize "$bytes"
    --dump-header "$headers" --write-out '%{stderr}%{http_code}\n' "$@" -- "$url")
  [[ ${CALL[*]@Q} == "${want[*]@Q}" ]] || fail "request $n argv: ${CALL[*]@Q}"
}

test_fetch_requests_only_fixed_first_party_urls_with_safe_curl_options() {
  build_release
  run_fetch --arch aarch64
  assert_status 0
  [[ $(curl_call_count) == 4 ]] || fail "expected 4 requests, got $(curl_call_count)"
  # No redirect following by curl (each hop is checked first), no
  # credentials, only the two GitHub API headers on the API request.
  check_request 1 60 2097152 "$API_URL/tags/v$FIXTURE_VERSION" release.json.headers \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'
  # Each asset is capped at exactly the size the API reported for it.
  local rel=$TEST_TMP/$RELEASE_SUBDIR
  check_request 2 120 "$(stat -c %s "$rel/$MANIFEST_NAME")" \
    "$RELEASE_URL/$MANIFEST_NAME" "$MANIFEST_NAME.headers"
  check_request 3 120 "$(stat -c %s "$rel/$ASSET_ARM64.sha256")" \
    "$RELEASE_URL/$ASSET_ARM64.sha256" "$ASSET_ARM64.sha256.headers"
  check_request 4 1800 "$(stat -c %s "$rel/$ASSET_ARM64")" \
    "$RELEASE_URL/$ASSET_ARM64" "$ASSET_ARM64.headers"
}

test_fetch_fails_cleanly_on_http_error_or_timeout() {
  local name code
  for name in "$MANIFEST_NAME" "$ASSET_ARM64.sha256" "$ASSET_ARM64"; do
    for code in 22 28 6; do
      rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc"
      build_release
      FAKE_CURL_FAIL_NAME=$name FAKE_CURL_FAIL_CODE=$code run_fetch --arch aarch64
      [[ $status == 1 ]] || fail "$name/$code: expected exit 1, got $status"
      assert_stdout_empty
      case "$code" in
        22) assert_stderr_contains "download failed with an HTTP error: $RELEASE_URL/$name" ;;
        28) assert_stderr_contains "download timed out: $RELEASE_URL/$name" ;;
        *) assert_stderr_contains "download failed (curl exit $code): $RELEASE_URL/$name" ;;
      esac
    done
  done
}

# rezip ENTRY...: rebuild the arm64 ZIP from $TEST_TMP/zipsrc ENTRY files and
# refresh both checksum records, so only the ZIP layout is under test.
rezip() {
  make_zip "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64" "$@"
  refresh_hashes
}

test_fetch_rejects_archive_without_exact_minotari_node_entry() {
  local layout
  for layout in none subdir exe-suffix wrong-case; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc"
    build_release
    mkdir -p "$TEST_TMP/zipsrc/tari"
    write_fake_node "$TEST_TMP/zipsrc/tari/minotari_node"
    write_fake_node "$TEST_TMP/zipsrc/minotari_node.exe"
    write_fake_node "$TEST_TMP/zipsrc/Minotari_node"
    case "$layout" in
      none) rezip README.md minotari_console_wallet ;;
      subdir) rezip README.md tari/minotari_node ;;
      exe-suffix) rezip README.md minotari_node.exe ;;
      wrong-case) rezip README.md Minotari_node ;;
    esac
    run_fetch --arch aarch64
    [[ $status == 1 ]] || fail "$layout: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "$ASSET_ARM64 has no 'minotari_node' entry at its root"
    [[ ! -e $TEST_TMP/node-trace ]] || fail "$layout: something was executed"
  done
}

test_fetch_rejects_archive_with_duplicate_minotari_node_entries() {
  build_release
  write_fake_node "$TEST_TMP/zipsrc/minotari_nodX" "minotari_node evil"
  make_zip "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64" minotari_node minotari_nodX
  # Rename the second entry in place (same length, CRCs unaffected).
  LC_ALL=C sed -i 's/minotari_nodX/minotari_node/g' "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64"
  refresh_hashes
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "$ASSET_ARM64 has 2 'minotari_node' entries"
  [[ ! -e $TEST_TMP/node-trace ]] || fail "binary was executed"
}

test_fetch_extracts_only_the_root_minotari_node_entry() {
  build_release
  mkdir -p "$TEST_TMP/zipsrc/tari"
  write_fake_node "$TEST_TMP/zipsrc/tari/minotari_node" "minotari_node decoy"
  rezip tari/minotari_node minotari_node README.md
  run_fetch --arch aarch64
  assert_status 0
  local out=$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64
  cmp -s "$out/minotari_node" "$TEST_TMP/zipsrc/minotari_node" ||
    fail "did not extract exactly the root minotari_node entry"
  [[ ! -e $out/tari && ! -e $out/README.md && ! -e $out/minotari_console_wallet ]] ||
    fail "other archive entries were extracted"
}

test_fetch_rejects_empty_minotari_node() {
  build_release
  : >"$TEST_TMP/zipsrc/minotari_node"
  rezip minotari_node README.md
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "extracted minotari_node is empty"
}

test_fetch_publishes_exact_files_with_private_permissions_and_record() {
  build_release
  GITHUB_TOKEN=secret-token-value run_fetch --arch aarch64
  assert_status 0
  local out=$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64
  local listing expected
  listing=$(cd "$out" && LC_ALL=C ls -A)
  expected=$(printf '%s\n' "$ASSET_ARM64" "$ASSET_ARM64.sha256" minotari_node \
    "$MANIFEST_NAME" verification.txt | LC_ALL=C sort)
  [[ $listing == "$expected" ]] || fail "unexpected output files: $listing"

  [[ $(stat -c %a "$out") == 700 ]] || fail "output dir mode $(stat -c %a "$out")"
  [[ $(stat -c %a "$out/minotari_node") == 700 ]] || fail "binary not 700"
  local f
  for f in "$ASSET_ARM64" "$ASSET_ARM64.sha256" "$MANIFEST_NAME" verification.txt; do
    [[ $(stat -c %a "$out/$f") == 600 ]] || fail "$f mode $(stat -c %a "$out/$f")"
  done

  local record
  record=$(<"$out/verification.txt")
  local line
  for line in "tag: v$FIXTURE_VERSION" "version: $FIXTURE_VERSION" \
    "platform: linux-arm64" "asset: $ASSET_ARM64" \
    "archive_sha256: $(sha256_of "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64")" \
    "binary_sha256: $(sha256_of "$TEST_TMP/zipsrc/minotari_node")" \
    "manifest_url: $RELEASE_URL/$MANIFEST_NAME" \
    "asset_url: $RELEASE_URL/$ASSET_ARM64"; do
    [[ $'\n'$record$'\n' == *$'\n'"$line"$'\n'* ]] || fail "record lacks: $line"
  done
  [[ $record != *secret-token-value* && $record != *PATH=* ]] ||
    fail "record contains environment data"
}

# overwrite_last_byte FILE: change FILE's content without changing its size.
overwrite_last_byte() {
  local size
  size=$(stat -c %s "$1")
  printf 'X' | dd of="$1" bs=1 seek=$((size - 1)) conv=notrunc 2>/dev/null ||
    fail "cannot modify $1"
}

# assert_dest_untouched: $TEST_TMP/dest holds only what the test put there.
assert_dest_untouched() {
  local left
  left=$(ls -A "$TEST_TMP/dest")
  [[ $left == "${1-}" ]] || fail "destination left with: $left"
}

test_fetch_failures_leave_no_temporary_or_output_directory() {
  local mode
  for mode in curl-error bad-manifest sidecar-mismatch zip-tampered no-entry; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc"
    build_release
    case "$mode" in
      curl-error) export FAKE_CURL_FAIL_NAME=$ASSET_ARM64 ;;
      bad-manifest) append_manifest_raw 'garbage\n' ;;
      sidecar-mismatch) printf '%064d  %s\n' 0 "$ASSET_ARM64" >"$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64.sha256" ;;
      zip-tampered) printf 'x' >>"$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64" ;;
      no-entry) rezip README.md ;;
    esac
    run_fetch --arch aarch64
    unset FAKE_CURL_FAIL_NAME
    [[ $status == 1 ]] || fail "$mode: expected exit 1, got $status"
    assert_stdout_empty
    assert_dest_untouched
  done
}

test_fetch_cleans_up_when_interrupted() {
  build_release
  mkdir -p "$TEST_TMP/fakebin"
  ln -sf "$TESTS_DIR/fakes/curl" "$TEST_TMP/fakebin/curl"
  export FAKE_WEB_ROOT=$TEST_TMP/web FAKE_CURL_LOG_DIR=$TEST_TMP/curl-log
  mkdir -p "$FAKE_CURL_LOG_DIR"
  export FAKE_CURL_SLEEP_NAME=$ASSET_ARM64
  # Own process group, like a terminal job, so the signal reaches curl too.
  PATH="$TEST_TMP/fakebin:$PATH" setsid "$CLI" fetch --version "$FIXTURE_VERSION" \
    --destination "$TEST_TMP/dest" --arch aarch64 >"$TEST_TMP/out" 2>&1 &
  local pid=$! i
  for ((i = 0; i < 100; i++)); do
    [[ -s $TEST_TMP/curl-log/sleep.pid ]] && break
    sleep 0.1
  done
  ((i < 100)) || fail "ZIP download never started"
  kill -TERM -- "-$pid"
  wait "$pid"
  status=$?
  ((status != 0)) || fail "interrupted fetch reported success"
  assert_dest_untouched
}

test_fetch_never_overwrites_output_directory_created_during_fetch() {
  build_release
  local out=$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64
  printf '#!/bin/sh\nmkdir -p "%s/existing"\n' "$out" >"$TEST_TMP/hook"
  chmod +x "$TEST_TMP/hook"
  FAKE_CURL_HOOK_NAME=$ASSET_ARM64 FAKE_CURL_HOOK=$TEST_TMP/hook \
    run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "already exists; refusing to overwrite"
  [[ $(ls -A "$out") == existing ]] || fail "existing output directory was modified"
  assert_dest_untouched "minotari-$FIXTURE_VERSION-linux-arm64"
}

test_fetch_reports_missing_runtime_dependencies_before_any_download() {
  # Every dependency fetch declares, read from the product itself.
  local -a deps
  mapfile -t deps < <(
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    printf '%s\n' "${FETCH_DEPENDENCIES[@]}"
  )
  local dep
  for dep in curl jq sha256sum unzip zipinfo mktemp realpath mv chmod rm rmdir \
    timeout env uname stat head; do
    [[ " ${deps[*]} " == *" $dep "* ]] || fail "$dep is not a declared dependency"
  done
  local missing tool
  for missing in "${deps[@]}"; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/curl-log" "$TEST_TMP/minimal-bin"
    build_release
    # A PATH holding only the tools fetch needs (plus bash and the fake
    # curl's cat), minus one.
    mkdir "$TEST_TMP/minimal-bin" "$TEST_TMP/curl-log"
    for tool in bash cat "${deps[@]}"; do
      [[ $tool == "$missing" || $tool == curl ]] && continue
      ln -s "$(command -v "$tool")" "$TEST_TMP/minimal-bin/$tool"
    done
    [[ $missing == curl ]] ||
      ln -s "$TESTS_DIR/fakes/curl" "$TEST_TMP/minimal-bin/curl"
    export FAKE_WEB_ROOT=$TEST_TMP/web FAKE_CURL_LOG_DIR=$TEST_TMP/curl-log
    run_cli_with_path "$TEST_TMP/minimal-bin" fetch --version "$FIXTURE_VERSION" \
      --destination "$TEST_TMP/dest" --arch aarch64
    [[ $status == 1 ]] || fail "missing $missing: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "missing required command: $missing"
    [[ ! -e $TEST_TMP/curl-log/1 ]] || fail "missing $missing: download attempted"
    assert_dest_untouched
  done
}

# make_fetch_sandbox DIR: PATH dir with the real tools fetch is allowed to
# use, the fake curl, and tracing stubs for every other forbidden command.
make_fetch_sandbox() {
  local dir=$1 cmd tool
  local -a stubs=()
  for cmd in "${FORBIDDEN_COMMANDS[@]}"; do
    case "$cmd" in curl | mv | chmod | rm) ;; *) stubs+=("$cmd") ;; esac
  done
  mkdir -p "$dir"
  for cmd in "${stubs[@]}"; do
    cat >"$dir/$cmd" <<'STUB'
#!/usr/bin/env bash
printf 'FORBIDDEN %s %s\n' "${0##*/}" "$*" >>"$TRACE_FILE"
exit 99
STUB
    chmod +x "$dir/$cmd"
  done
  for tool in bash sha256sum unzip zipinfo mktemp realpath mv chmod rm \
    rmdir timeout env uname stat jq head cat; do
    ln -s "$(command -v "$tool")" "$dir/$tool"
  done
  ln -s "$TESTS_DIR/fakes/curl" "$dir/curl"
}

test_fetch_runs_no_privileged_service_or_unexpected_commands() {
  build_release
  make_fetch_sandbox "$TEST_TMP/fetch-bin"
  export TRACE_FILE=$TEST_TMP/trace FAKE_WEB_ROOT=$TEST_TMP/web
  export FAKE_CURL_LOG_DIR=$TEST_TMP/curl-log
  mkdir -p "$FAKE_CURL_LOG_DIR"
  : >"$TRACE_FILE"
  run_cli_with_path "$TEST_TMP/fetch-bin" fetch --version "$FIXTURE_VERSION" \
    --destination "$TEST_TMP/dest" --arch aarch64
  assert_status 0
  assert_stdout_has_line "fetch: verified"

  # A failing run (tampered archive) must not reach for them either.
  rm -rf -- "$TEST_TMP/dest" && mkdir "$TEST_TMP/dest"
  printf 'x' >>"$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64"
  run_cli_with_path "$TEST_TMP/fetch-bin" fetch --version "$FIXTURE_VERSION" \
    --destination "$TEST_TMP/dest" --arch aarch64
  assert_status 1

  [[ -z $(<"$TRACE_FILE") ]] || fail "forbidden commands invoked: $(<"$TRACE_FILE")"
}

test_fetch_source_has_single_fixed_download_path_and_no_forbidden_operations() {
  local lib=$REPO_ROOT/lib/fetch.sh code
  code=$(grep -vE '^[[:space:]]*#' "$lib")
  local pattern='/dev/(tcp|udp)/|(^|[^A-Za-z_-])(sudo|apt-get|apt|systemctl|useradd|usermod|wget|ssh|iptables|nft|ufw|eval|source)([^A-Za-z_-]|$)|rm -[a-zA-Z]*r|\| *(ba)?sh|id -u|GITHUB_TOKEN|GH_TOKEN'
  local hits
  hits=$(grep -nE "$pattern" <<<"$code") || true
  [[ -z $hits ]] || fail "forbidden operation in lib/fetch.sh: $hits"

  # EUID may only refuse root or compare ownership against the current user.
  # shellcheck disable=SC2016 # \$EUID is matched literally by grep.
  hits=$(grep -n 'EUID' <<<"$code" | grep -vE '\(\(EUID != 0\)\) \|\| die "fetch must not run as root"|[!=]= "?\$EUID"?|== \*":\$EUID:directory"|\|\$EUID\|1"') || true
  [[ -z $hits ]] || fail "unexpected EUID use in lib/fetch.sh: $hits"

  local curl_lines url_lines
  # curl in command position: line start, $(...), or after | & ;
  curl_lines=$(grep -cE '(^[[:space:]]*|\$\([[:space:]]*|[|&;][[:space:]]*)curl([[:space:]]|$)' <<<"$code") || true
  [[ $curl_lines == 1 ]] || fail "curl must be invoked from exactly one place, found $curl_lines"
  url_lines=$(grep -oE 'https?://[A-Za-z0-9.-]+[^ "]*' <<<"$code") || true
  [[ $url_lines == $'https://github.com/tari-project/tari/releases/download\nhttps://api.github.com/repos/tari-project/tari/releases' ]] ||
    fail "unexpected URLs in lib/fetch.sh: $url_lines"
  grep -qE '^readonly RELEASE_BASE_URL=https://github.com/tari-project/tari/releases/download$' "$lib" ||
    fail "RELEASE_BASE_URL is not the fixed first-party prefix"
  grep -qE '^readonly RELEASE_API_URL=https://api.github.com/repos/tari-project/tari/releases$' "$lib" ||
    fail "RELEASE_API_URL is not the fixed first-party API prefix"
}

test_fetch_ignores_unzip_and_zipinfo_environment_options() {
  build_release
  UNZIP=-Z ZIPINFO=-v run_fetch --arch aarch64
  assert_status 0
  assert_stdout_has_line "fetch: verified"
  cmp -s "$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64/minotari_node" \
    "$TEST_TMP/zipsrc/minotari_node" || fail "extracted binary was altered"
}

test_fetch_reports_checksum_tool_failure() {
  build_release
  mkdir -p "$TEST_TMP/fakebin"
  printf '#!/bin/sh\necho "sha256sum: simulated failure" >&2\nexit 1\n' \
    >"$TEST_TMP/fakebin/sha256sum"
  chmod +x "$TEST_TMP/fakebin/sha256sum"
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "cannot compute SHA-256 of"
  assert_dest_untouched
}

test_fetch_usage_errors_take_precedence_over_missing_dependencies() {
  # Only bash and realpath: every fetch runtime dependency is missing.
  mkdir "$TEST_TMP/bare-bin"
  ln -s "$(command -v bash)" "$TEST_TMP/bare-bin/bash"
  ln -s "$(command -v realpath)" "$TEST_TMP/bare-bin/realpath"
  mkdir -p "$TEST_TMP/dest"

  run_cli_with_path "$TEST_TMP/bare-bin" fetch --version latest --destination "$TEST_TMP/dest"
  assert_status 2
  assert_stderr_contains "invalid version"

  run_cli_with_path "$TEST_TMP/bare-bin" fetch --destination "$TEST_TMP/dest" --bogus
  assert_status 2
  assert_stderr_contains "unknown fetch option '--bogus'"

  run_cli_with_path "$TEST_TMP/bare-bin" fetch --help
  assert_status 0
  assert_stdout_contains "Usage: ./deploy.sh fetch"
}

test_fetch_rejects_group_or_world_writable_destination() {
  local mode
  for mode in 775 757 777 1777; do
    rm -rf -- "${TEST_TMP:?}/shared"
    mkdir "$TEST_TMP/shared"
    chmod "$mode" "$TEST_TMP/shared"
    fetch_dry --destination "$TEST_TMP/shared"
    [[ $status == 1 ]] || fail "mode $mode: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "is group- or world-writable"
  done
}

test_fetch_rejects_destination_owned_by_another_user() {
  # A non-system, non-shared-writable directory owned by someone else.
  local dir other=''
  for dir in /home /srv /mnt /media; do
    [[ -d $dir && ! -L $dir ]] || continue
    [[ $(stat -c %u "$dir") != "$EUID" ]] || continue
    ((8#$(stat -c %a "$dir") & 8#022)) && continue
    other=$dir
    break
  done
  [[ -n $other ]] || fail "no directory owned by another user to test with"
  fetch_dry --destination "$other"
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "is not owned by the current user"
}

test_system_path_rule_matches_lib_dirs_exactly() {
  # Pure path rule; no real directories are created or touched.
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    local p
    for p in / /lib /lib/x86_64-linux-gnu /lib64 /lib64/ld-linux.so /etc /usr/lib \
      /var/tmp /root/x /run/user; do
      is_system_path "$p" || fail "'$p' should be a system path"
    done
    for p in /liberty /library /library/x /lib32x /home/user/lib /srv/lib64 /tmp; do
      ! is_system_path "$p" || fail "'$p' wrongly treated as a system path"
    done
  ) || exit 1
}

test_fetch_explicit_version_uses_tag_release_metadata() {
  build_release
  run_fetch --arch aarch64 --dry-run
  assert_status 0
  assert_stderr_empty
  assert_stdout_has_line "version_source: explicit"
  assert_stdout_has_line "tag: v$FIXTURE_VERSION"
  assert_stdout_has_line "release_api_url: $API_URL/tags/v$FIXTURE_VERSION"
  assert_stdout_has_line "asset: $ASSET_ARM64"
  assert_stdout_has_line "asset_url: $RELEASE_URL/$ASSET_ARM64"
  # Only the metadata request; no release asset downloaded, nothing written.
  [[ $(curl_call_count) == 1 ]] || fail "expected 1 request, got $(curl_call_count)"
  load_curl_call 1
  [[ ${CALL[-1]} == "$API_URL/tags/v$FIXTURE_VERSION" ]] || fail "requested ${CALL[-1]}"
  assert_dest_untouched

  run_fetch --arch aarch64
  assert_status 0
  assert_stdout_has_line "version_source: explicit"
}

# run_fetch_latest [ARGS...]: fetch without --version (GitHub latest release).
run_fetch_latest() {
  use_fake_curl
  PATH="$TEST_TMP/fakebin:$PATH" run_cli fetch --destination "$TEST_TMP/dest" "$@"
}

test_fetch_defaults_to_github_latest_full_release() {
  build_release
  run_fetch_latest --arch aarch64 --dry-run
  assert_status 0
  assert_stderr_empty
  assert_stdout_has_line "version_source: github-latest"
  assert_stdout_has_line "tag: v$FIXTURE_VERSION"
  assert_stdout_has_line "release_api_url: $API_URL/latest"
  assert_stdout_has_line "asset: $ASSET_ARM64"
  [[ $(curl_call_count) == 1 ]] || fail "expected 1 request, got $(curl_call_count)"
  load_curl_call 1
  [[ ${CALL[-1]} == "$API_URL/latest" ]] || fail "requested ${CALL[-1]}"
  assert_dest_untouched

  run_fetch_latest --arch aarch64
  assert_status 0
  assert_stdout_has_line "version_source: github-latest"
  assert_stdout_has_line "fetch: verified"
  [[ -d $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] || fail "not published"
}

test_fetch_help_documents_version_default() {
  run_cli fetch --help
  assert_status 0
  assert_stdout_contains "Usage: ./deploy.sh fetch --destination DIR [--version VERSION] [--arch ARCH] [--dry-run]"
  assert_stdout_contains "latest full (non-pre-release) release"
  assert_stdout_contains "https://api.github.com/repos/tari-project/tari/releases"
}

# expect_metadata_rejected ENDPOINT FILTER MESSAGE [FETCH_ARGS...]: rebuild
# the fixture release, apply jq FILTER to the API ENDPOINT, and expect a
# dry-run to fail with MESSAGE before anything is downloaded.
expect_metadata_rejected() {
  local endpoint=$1 filter=$2 message=$3
  shift 3
  rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" "$TEST_TMP/curl-log"
  build_release
  edit_api "$filter" "$endpoint"
  use_fake_curl
  PATH="$TEST_TMP/fakebin:$PATH" run_cli fetch --destination "$TEST_TMP/dest" \
    --arch aarch64 "$@"
  [[ $status == 1 ]] || fail "[$filter]: expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "$message"
  [[ $(curl_call_count) == 1 ]] || fail "[$filter]: assets were downloaded"
  assert_dest_untouched
}

test_fetch_rejects_unacceptable_release_metadata() {
  local tags=tags/v$FIXTURE_VERSION
  # Latest must be a published full release; the metadata decides.
  expect_metadata_rejected latest '.prerelease = true' "is a pre-release" --dry-run
  expect_metadata_rejected latest '.draft = true' "is a draft" --dry-run
  expect_metadata_rejected latest '.tag_name = "latest"' "invalid tag_name" --dry-run
  expect_metadata_rejected latest '.tag_name = "v6.0.1/../../x"' "invalid tag_name" --dry-run
  expect_metadata_rejected latest '.tag_name = 6' "malformed release metadata" --dry-run
  expect_metadata_rejected latest 'del(.prerelease)' "malformed release metadata" --dry-run
  expect_metadata_rejected latest '.draft = "false"' "malformed release metadata" --dry-run
  expect_metadata_rejected latest '[.]' "malformed release metadata" --dry-run
  # An explicit version may be a pre-release, but never a draft or another tag.
  expect_metadata_rejected "$tags" '.draft = true' "is a draft" --version "$FIXTURE_VERSION" --dry-run
  expect_metadata_rejected "$tags" '.tag_name = "v6.0.0"' "metadata is for tag v6.0.0, not v$FIXTURE_VERSION" \
    --version "$FIXTURE_VERSION" --dry-run
  expect_metadata_rejected "$tags" 'del(.assets)' "malformed release metadata" --version "$FIXTURE_VERSION" --dry-run
}

test_fetch_rejects_empty_or_non_string_asset_names() {
  local filter
  # Every asset name must be a non-empty string; an empty one used to reach
  # a Bash associative array as a key ("bad array subscript").
  for filter in '.assets[0].name = ""' '.assets[0].name = null' \
    '.assets[0].name = 5' '.assets += [{"name": "", "size": 1, "digest": null,
      "browser_download_url": "https://github.com/x"}]'; do
    expect_metadata_rejected latest "$filter" "malformed release metadata" --dry-run
    # shellcheck disable=SC2154 # Set by run_cli (tests/lib.sh).
    [[ $stderr == "taritalk-node-deploy: error: malformed release metadata from the GitHub Releases API" ]] ||
      fail "[$filter]: unexpected stderr: $stderr"
  done
}

test_fetch_rejects_invalid_json_and_missing_release() {
  build_release
  printf '{"tag_name": "v6.0.1-pre.2", ' >"$TEST_TMP/$API_SUBDIR/latest"
  run_fetch_latest --arch aarch64 --dry-run
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "malformed release metadata"

  run_fetch --arch aarch64 --dry-run --version 9.9.9
  assert_status 1
  assert_stderr_contains "download failed with an HTTP error: $API_URL/tags/v9.9.9"
  assert_dest_untouched
}

test_fetch_rejects_bad_release_asset_metadata() {
  local t=tags/v$FIXTURE_VERSION v=$FIXTURE_VERSION zip=$ASSET_ARM64
  local m=$MANIFEST_NAME s=$ASSET_ARM64.sha256
  local sel_zip=".assets[] | select(.name == \"$zip\")"
  local sel_m=".assets[] | select(.name == \"$m\")"
  local sel_s=".assets[] | select(.name == \"$s\")"
  local -a cases=(
    "del($sel_m)@@release asset $m: missing"
    "del($sel_s)@@release asset $s: missing"
    ".assets += [$sel_zip]@@release asset $zip: listed more than once"
    ".assets += [$sel_m]@@release asset $m: listed more than once"
    "($sel_zip).digest = null@@release asset $zip: missing or invalid digest"
    "($sel_m) |= del(.digest)@@release asset $m: missing or invalid digest"
    "($sel_zip).digest = \"md5:0123\"@@release asset $zip: missing or invalid digest"
    "($sel_s).digest |= ascii_upcase@@release asset $s: missing or invalid digest"
    "($sel_zip).size = 0@@release asset $zip: invalid size"
    "($sel_zip).size = -5@@release asset $zip: invalid size"
    "($sel_zip).size = 1.5@@release asset $zip: invalid size"
    "($sel_m).size = 65537@@release asset $m: invalid size"
    "($sel_zip).size = 2147483649@@release asset $zip: invalid size"
    "($sel_zip).browser_download_url = \"https://github.com/evil/tari/releases/download/v$v/$zip\"@@release asset $zip: unexpected download URL"
    "($sel_zip).browser_download_url = \"http://github.com/tari-project/tari/releases/download/v$v/$zip\"@@release asset $zip: unexpected download URL"
    "($sel_m).browser_download_url |= . + \"?x=1\"@@release asset $m: unexpected download URL"
    "($sel_s).browser_download_url = \"https://github.com/tari-project/tari/releases/download/v6.0.0/$s\"@@release asset $s: unexpected download URL"
  )
  local c
  for c in "${cases[@]}"; do
    expect_metadata_rejected "$t" "${c%%@@*}" "${c#*@@}" --version "$v" --dry-run
  done
}

test_fetch_requires_github_api_digest_for_every_downloaded_file() {
  local h=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

  # Manifest altered in place (same size, still well-formed) after GitHub
  # computed its digest: the esme RISC-V line gets a different hash.
  build_release
  local manifest=$TEST_TMP/$RELEASE_SUBDIR/$MANIFEST_NAME
  sed -i "s/^b7188b4f/${h:0:8}/" "$manifest"
  grep -q "^${h:0:8}" "$manifest" || fail "fixture not altered"
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "$MANIFEST_NAME does not match its SHA-256 digest from the GitHub API"
  ! curl_requested "$RELEASE_URL/$ASSET_ARM64.sha256" || fail "continued after manifest mismatch"
  assert_dest_untouched

  # Sidecar altered (same hash, binary-mode separator) after GitHub's digest.
  rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" "$TEST_TMP/curl-log"
  build_release
  local sidecar=$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64.sha256 line
  line=$(<"$sidecar")
  printf '%s *%s\n' "${line:0:64}" "$ASSET_ARM64" >"$sidecar"
  run_fetch --arch aarch64
  assert_status 1
  assert_stderr_contains "$ASSET_ARM64.sha256 does not match its SHA-256 digest from the GitHub API"
  ! curl_requested "$RELEASE_URL/$ASSET_ARM64" || fail "ZIP downloaded after sidecar mismatch"
  assert_dest_untouched
}

test_fetch_requires_three_way_archive_hash_agreement_before_download() {
  build_release
  local sel=".assets[] | select(.name == \"$ASSET_ARM64\")"
  edit_api "($sel).digest = \"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "$ASSET_ARM64: the GitHub API digest disagrees with the release checksum files"
  ! curl_requested "$RELEASE_URL/$ASSET_ARM64" || fail "ZIP downloaded without three-way agreement"
  assert_dest_untouched
}

# write_swap_hook MODE: a fake-curl hook that, during the sidecar request,
# renames the staging directory away and puts either a symlink to
# $TEST_TMP/victim (MODE=symlink) or a different directory (MODE=dir) at
# its path. $TEST_TMP/victim holds files named like everything fetch writes.
write_swap_hook() {
  local name
  mkdir -p "$TEST_TMP/victim"
  for name in "$MANIFEST_NAME" "$ASSET_ARM64.sha256" "$ASSET_ARM64" \
    "$ASSET_ARM64.sha256.stderr" minotari_node verification.txt victim.txt; do
    printf 'victim\n' >"$TEST_TMP/victim/$name"
  done
  cat >"$TEST_TMP/hook" <<HOOK
#!/usr/bin/env bash
stage=\$(echo "$TEST_TMP"/dest/.minotari-fetch.*)
[[ -d \$stage ]] || exit 1
mv -- "\$stage" "$TEST_TMP/moved-stage"
if [[ $1 == symlink ]]; then
  ln -s -- "$TEST_TMP/victim" "\$stage"
else
  mkdir -- "\$stage" && printf 'victim\n' >"\$stage/victim.txt"
fi
HOOK
  chmod +x "$TEST_TMP/hook"
}

# assert_victim_untouched DIR: every file in DIR still reads "victim" and
# no file was added.
assert_victim_untouched() {
  local f count=0
  for f in "$1"/* "$1"/.[!.]*; do
    [[ -e $f ]] || continue
    count=$((count + 1))
    [[ $(<"$f") == victim ]] || fail "victim file ${f##*/} was modified"
  done
  [[ $count == "$2" ]] || fail "expected $2 files in $1, found $count"
}

test_fetch_detects_staging_directory_replaced_by_symlink() {
  build_release
  write_swap_hook symlink
  FAKE_CURL_HOOK_NAME=$ASSET_ARM64.sha256 FAKE_CURL_HOOK=$TEST_TMP/hook \
    run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "was moved or replaced"
  # Nothing written through, or deleted behind, the substituted symlink.
  assert_victim_untouched "$TEST_TMP/victim" 7
  [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] ||
    fail "published despite the substitution"
}

test_fetch_detects_staging_directory_replaced_by_other_directory() {
  build_release
  write_swap_hook dir
  FAKE_CURL_HOOK_NAME=$ASSET_ARM64.sha256 FAKE_CURL_HOOK=$TEST_TMP/hook \
    run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "was moved or replaced"
  local stage
  stage=$(echo "$TEST_TMP"/dest/.minotari-fetch.*)
  assert_victim_untouched "$stage" 1
  [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] ||
    fail "published despite the substitution"
}
