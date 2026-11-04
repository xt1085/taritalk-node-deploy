# shellcheck shell=bash
# Archive handling limits: zipinfo/unzip time limits, the declared and the
# actual size of the extracted minotari_node.

# fake_tool NAME SCRIPT: put an executable NAME with body SCRIPT first in
# $TEST_TMP/fakebin (used together with the fake curl).
fake_tool() {
  mkdir -p "$TEST_TMP/fakebin"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$TEST_TMP/fakebin/$1"
  chmod +x "$TEST_TMP/fakebin/$1"
}

# shellcheck disable=SC2034 # stdout/stderr are read by tests/lib.sh.
# run_archive_helper FUNCTION ARGS...: call an internal archive helper of
# lib/fetch.sh directly, in $TEST_TMP/work, with $TEST_TMP/fakebin first in
# PATH. Sets status/stdout/stderr and ELAPSED.
run_archive_helper() {
  mkdir -p "$TEST_TMP/work"
  local start=$SECONDS
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    cd "$TEST_TMP/work" || exit 1
    PATH="$TEST_TMP/fakebin:$PATH" "$@"
  ) >"$TEST_TMP/.stdout" 2>"$TEST_TMP/.stderr"
  status=$?
  ELAPSED=$((SECONDS - start))
  stdout=$(<"$TEST_TMP/.stdout")
  stderr=$(<"$TEST_TMP/.stderr")
}

test_fetch_times_out_a_hanging_archive_listing() {
  build_release
  fake_tool zipinfo 'exec sleep 120'
  local start=$SECONDS
  RUN_CLI_TIMEOUT=90 run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "timed out listing the contents of $ASSET_ARM64"
  ((SECONDS - start < 60)) || fail "listing was not time-limited"
  assert_dest_untouched
}

test_fetch_rejects_oversized_minotari_node_entry_metadata() {
  build_release
  # Report a 2 GiB uncompressed size for the entry (zipinfo -s format).
  # shellcheck disable=SC2016 # The fake script's own $ expansions.
  fake_tool zipinfo "$(printf '%s\n' \
    'real=$(type -aP zipinfo | sed -n 2p)' \
    'if [[ $1 == -s ]]; then' \
    '  "$real" "$@" | sed -E "s/^(\S+\s+\S+\s+\S+\s+)[0-9]+/\\12147483648/"' \
    'else exec "$real" "$@"; fi')"
  run_fetch --arch aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "minotari_node in $ASSET_ARM64 is larger than the 1073741824-byte limit"
  assert_dest_untouched
}

test_extract_entry_caps_output_and_time() {
  printf 'zip' >"$TEST_TMP/archive.zip"
  mkdir -p "$TEST_TMP/work"
  cp "$TEST_TMP/archive.zip" "$TEST_TMP/work/archive.zip"
  # Far more output than its metadata could claim.
  fake_tool unzip 'yes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  run_archive_helper extract_entry archive.zip minotari_node out 1000 30
  [[ $status == 1 ]] || fail "endless output: expected exit 1, got $status"
  assert_stderr_contains "minotari_node from archive.zip exceeds the 1000-byte limit"
  (($(stat -c %s "$TEST_TMP/work/out") <= 1001)) || fail "wrote more than the limit"
  ((ELAPSED < 15)) || fail "endless output took ${ELAPSED}s"

  fake_tool unzip 'exec sleep 120'
  run_archive_helper extract_entry archive.zip minotari_node out 1000 2
  [[ $status == 1 ]] || fail "hang: expected exit 1, got $status"
  assert_stderr_contains "timed out extracting minotari_node from archive.zip"
  ((ELAPSED < 15)) || fail "extraction was not time-limited (${ELAPSED}s)"
}

# fetch_with_node_script BODY: rebuild the release with a minotari_node whose
# shell body is BODY (it runs with an empty environment), then fetch.
fetch_with_node_script() {
  rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" "$TEST_TMP/curl-log"
  build_release
  printf '#!/bin/sh\n%s\n' "$1" >"$TEST_TMP/zipsrc/minotari_node"
  chmod 755 "$TEST_TMP/zipsrc/minotari_node"
  rezip minotari_node README.md
  run_fetch --arch aarch64
}

# start_fetch_in_background: run fetch (fake curl, $TEST_TMP/fakebin first)
# as a background job of this shell; sets FETCH_PID.
start_fetch_in_background() {
  use_fake_curl
  PATH="$TEST_TMP/fakebin:$PATH" "$CLI" fetch --version "$FIXTURE_VERSION" \
    --destination "$TEST_TMP/dest" --arch aarch64 >"$TEST_TMP/out" 2>&1 &
  FETCH_PID=$!
}

# wait_for_file FILE: wait up to 10 s for FILE to be non-empty.
wait_for_file() {
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -s $1 ]] && return 0
    sleep 0.1
  done
  fail "timed out waiting for $1"
}

# process_running PID: true if PID exists and is not a zombie (an exited
# process not yet reaped by its new parent runs no code).
process_running() {
  local stat state
  # The process may vanish at any moment; that just means "not running".
  { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
  state=${stat##*) }
  [[ ${state%% *} != Z ]]
}

# term_shell_only_and_check CHILD_PID_FILE: send TERM to the CLI shell PID
# only, then require a prompt 143 exit, the child gone, and a clean
# destination.
term_shell_only_and_check() {
  local child start=$SECONDS
  child=$(<"$1")
  process_running "$child" || fail "child $child is not running"
  kill -TERM "$FETCH_PID"
  wait "$FETCH_PID"
  status=$?
  ((SECONDS - start < 8)) || fail "fetch took $((SECONDS - start))s to stop"
  [[ $status == 143 ]] || fail "expected exit 143, got $status: $(<"$TEST_TMP/out")"
  sleep 0.5
  ! process_running "$child" || {
    kill -KILL "$child" 2>/dev/null
    fail "child $child kept running after the CLI was terminated"
  }
  assert_dest_untouched
}

test_fetch_forwards_term_to_active_download() {
  build_release
  export FAKE_CURL_SLEEP_NAME=$ASSET_ARM64
  start_fetch_in_background
  wait_for_file "$TEST_TMP/curl-log/sleep.pid"
  term_shell_only_and_check "$TEST_TMP/curl-log/sleep.pid"
}

# The CLI's status after TERM is 143 whatever status the `timeout` around
# the stopped child reports: GNU timeout reports 143 here, uutils timeout
# (Ubuntu 26.04's) 124. A wrapper with uutils' status stands in for the
# latter on any host; it still stops the child through the real timeout.
test_fetch_term_status_does_not_depend_on_timeouts_status() {
  build_release
  fake_tool timeout "$(command -v timeout) \"\$@\" & p=\$!
trap 'kill -TERM \$p; wait \$p; exit 124' TERM
wait \$p"
  fake_tool unzip "echo \$\$ >'$TEST_TMP/unzip.pid'; exec sleep 60"
  start_fetch_in_background
  wait_for_file "$TEST_TMP/unzip.pid"
  term_shell_only_and_check "$TEST_TMP/unzip.pid"
}

test_fetch_forwards_term_to_active_archive_extraction() {
  build_release
  fake_tool unzip "echo \$\$ >'$TEST_TMP/unzip.pid'; exec sleep 60"
  start_fetch_in_background
  wait_for_file "$TEST_TMP/unzip.pid"
  term_shell_only_and_check "$TEST_TMP/unzip.pid"
}

# expect_injected_failure LABEL MESSAGE [DEST_ENTRY]: after a fetch run with
# an injected failure, require exit 1, empty stdout, MESSAGE on stderr, no
# published output, and a destination holding only DEST_ENTRY (if given).
expect_injected_failure() {
  [[ $status == 1 ]] || fail "$1: expected exit 1, got $status ($stderr)"
  assert_stdout_empty
  assert_stderr_contains "$2"
  [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] ||
    fail "$1: unverified output was published"
  if [[ -z ${3-} ]]; then
    assert_dest_untouched
  fi
}

test_fetch_fails_closed_on_injected_tool_failures() {
  local -a cases=(
    "mktemp-meta@@mktemp@@[[ \$* == *taritalk-fetch* ]] && exit 1; exec /usr/bin/mktemp \"\$@\"@@cannot create a private temporary directory"
    "mktemp-stage@@mktemp@@[[ \$* == *.minotari-fetch* ]] && exit 1; exec /usr/bin/mktemp \"\$@\"@@cannot create a staging directory"
    "zipinfo@@zipinfo@@exit 2@@cannot list the contents of $ASSET_ARM64"
    "unzip@@unzip@@exit 3@@cannot extract minotari_node from $ASSET_ARM64"
    "chmod@@chmod@@exit 1@@cannot make minotari_node executable"
    "mv@@mv@@exit 1@@cannot move the staging directory to"
  )
  local c label tool body message
  for c in "${cases[@]}"; do
    label=${c%%@@*}
    c=${c#*@@}
    tool=${c%%@@*}
    c=${c#*@@}
    body=${c%%@@*}
    message=${c#*@@}
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/curl-log" "$TEST_TMP/fakebin"
    build_release
    fake_tool "$tool" "$body"
    run_fetch --arch aarch64
    expect_injected_failure "$label" "$message"
    [[ -z $(ls -A "$TMPDIR") ]] || fail "$label: temporary files left in TMPDIR"
  done

  # A partial download (connection closed early) is cleaned up.
  rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" "$TEST_TMP/curl-log" "$TEST_TMP/fakebin"
  build_release
  FAKE_CURL_PARTIAL_NAME=$ASSET_ARM64 run_fetch --arch aarch64
  expect_injected_failure partial "download ended early: $RELEASE_URL/$ASSET_ARM64"
}

test_fetch_cleanup_failures_warn_without_changing_the_outcome() {
  local tool body
  for tool in rm rmdir; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/curl-log" "$TEST_TMP/fakebin"
    build_release
    overwrite_last_byte "$TEST_TMP/$RELEASE_SUBDIR/$ASSET_ARM64"
    # Fail only where cleanup acts: removing the staged ZIP, or the staging
    # directory itself.
    if [[ $tool == rm ]]; then
      body="for a; do [[ \$a == $ASSET_ARM64 ]] && exit 1; done; exec /bin/rm \"\$@\""
    else
      body='[[ $* == *.minotari-fetch* ]] && exit 1; exec /bin/rmdir "$@"'
    fi
    fake_tool "$tool" "$body"
    run_fetch --arch aarch64
    expect_injected_failure "$tool" "SHA-256 mismatch for $ASSET_ARM64" leftovers
    assert_stderr_contains "warning: could not remove"
  done
}

# shellcheck disable=SC2016 # The fixture script's own $ expansions.
test_fetch_never_executes_the_downloaded_binary() {
  # If this binary ever ran it would leave a marker, alter itself, try the
  # network (the fake curl logs every call), and print the right version.
  fetch_with_node_script "$(printf '%s\n' \
    ": >'$TEST_TMP/EXECUTED'" \
    'echo tampered >>"$0"' \
    "curl --disable -- 'https://example.invalid/phone-home' >/dev/null 2>&1" \
    "echo 'minotari_node $FIXTURE_VERSION'")"
  [[ ! -e $TEST_TMP/EXECUTED ]] || fail "the downloaded minotari_node was executed"
  ! curl_requested https://example.invalid/phone-home || fail "binary reached the network"
  assert_status 0
  assert_stdout_has_line "fetch: verified"
  cmp -s "$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64/minotari_node" \
    "$TEST_TMP/zipsrc/minotari_node" || fail "published binary differs from the archive entry"
  [[ $stdout != *binary_version* ]] || fail "output still claims a binary version check"
  ! grep -q binary_version "$TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64/verification.txt" ||
    fail "record still claims a binary version check"
}

# install_hook_tool NAME WHEN ACTION: a fake NAME (stat or sha256sum) that
# runs the real tool and, once, runs ACTION in the caller's working
# directory (the staging directory). WHEN selects the moment:
#   stat:      at the first stat after the verification record exists,
#              i.e. when publishing starts;
#   sha256sum: right after minotari_node is hashed (before the record).
install_hook_tool() {
  local name=$1 action=$3 real
  real=$(type -aP "$name" | grep -v '/fakebin/' | head -n 1)
  printf '#!/usr/bin/env bash\n%s\n' "$action" >"$TEST_TMP/hook-action"
  chmod +x "$TEST_TMP/hook-action"
  mkdir -p "$TEST_TMP/fakebin"
  if [[ $name == stat ]]; then
    cat >"$TEST_TMP/fakebin/stat" <<HOOK
#!/usr/bin/env bash
if [[ -e verification.txt && ! -e '$TEST_TMP/hook.done' ]]; then
  : >'$TEST_TMP/hook.done'
  '$TEST_TMP/hook-action'
fi
exec '$real' "\$@"
HOOK
  else
    cat >"$TEST_TMP/fakebin/sha256sum" <<HOOK
#!/usr/bin/env bash
'$real' "\$@" || exit
if [[ \${*: -1} == minotari_node && ! -e '$TEST_TMP/hook.done' ]]; then
  : >'$TEST_TMP/hook.done'
  '$TEST_TMP/hook-action'
fi
HOOK
  fi
  chmod +x "$TEST_TMP/fakebin/$name"
}

test_fetch_reverifies_every_staged_file_before_publishing() {
  local zip=$ASSET_ARM64 m=$MANIFEST_NAME s=$ASSET_ARM64.sha256 c
  local -a cases=(
    "binary-symlink@@rm -f minotari_node && ln -s /etc/passwd minotari_node"
    "binary-modified@@printf x >>minotari_node"
    "binary-mode@@chmod 755 minotari_node"
    "zip-modified@@printf X | dd of='$zip' bs=1 seek=0 conv=notrunc 2>/dev/null"
    "manifest-modified@@sed -i 's/^b7188b4f/00000000/' '$m'"
    "sidecar-modified@@sed -i 's/  / */' '$s'"
    "record-modified@@printf 'x\\n' >>verification.txt"
    "record-symlink@@cp verification.txt ../record-copy && rm verification.txt && ln -s ../record-copy verification.txt"
    "manifest-directory@@rm -f '$m' && mkdir '$m'"
    "sidecar-fifo@@rm -f '$s' && mkfifo '$s'"
  )
  for c in "${cases[@]}"; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/curl-log" "$TEST_TMP/fakebin" "$TEST_TMP/hook.done"
    build_release
    install_hook_tool stat publish "${c#*@@}"
    run_fetch --arch aarch64
    [[ $status == 1 ]] || fail "${c%%@@*}: expected exit 1, got $status"
    assert_stdout_empty
    assert_stderr_contains "refusing to publish"
    [[ -e $TEST_TMP/hook.done ]] || fail "${c%%@@*}: hook did not run"
    [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] ||
      fail "${c%%@@*}: published"
    chmod -R u+w "$TEST_TMP/dest"
  done
}

test_fetch_record_is_never_written_through_a_planted_entry() {
  local c
  # Planted right before the record is written (while hashing the binary).
  for c in "symlink@@ln -s '$TEST_TMP/victim-record' verification.txt" \
    "directory@@mkdir verification.txt"; do
    rm -rf -- "${TEST_TMP:?}/web" "$TEST_TMP/dest" "$TEST_TMP/zipsrc" \
      "$TEST_TMP/curl-log" "$TEST_TMP/fakebin" "$TEST_TMP/hook.done"
    printf 'victim\n' >"$TEST_TMP/victim-record"
    build_release
    install_hook_tool sha256sum binary "${c#*@@}"
    run_fetch --arch aarch64
    [[ $status == 1 ]] || fail "${c%%@@*}: expected exit 1, got $status"
    assert_stderr_contains "cannot write verification record"
    [[ $(<"$TEST_TMP/victim-record") == victim ]] || fail "${c%%@@*}: wrote through the planted entry"
    [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] || fail "${c%%@@*}: published"
  done
}

test_fetch_never_publishes_unexpected_staging_entries() {
  build_release
  install_hook_tool sha256sum binary ': >.extra'
  run_fetch --arch aarch64
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "staging directory contains unexpected entries: .extra"
  [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] || fail "published"
}

test_fetch_warns_when_staging_becomes_read_only() {
  build_release
  install_hook_tool sha256sum binary 'chmod 500 .'
  run_fetch --arch aarch64
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "cannot write verification record"
  assert_stderr_contains "warning: could not remove"
  [[ ! -e $TEST_TMP/dest/minotari-$FIXTURE_VERSION-linux-arm64 ]] || fail "published"
  chmod -R u+w "$TEST_TMP/dest"
}

# write_dest_swap_hook MODE: a fake-curl hook that renames the destination
# to dest-moved and puts, at its pathname, a symlink to $TEST_TMP/replacement
# (MODE=symlink) or a new directory (MODE=dir). The replacement holds a
# victim file.
write_dest_swap_hook() {
  mkdir -p "$TEST_TMP/replacement"
  printf 'victim\n' >"$TEST_TMP/replacement/victim.txt"
  cat >"$TEST_TMP/hook" <<HOOK
#!/usr/bin/env bash
mv -- '$TEST_TMP/dest' '$TEST_TMP/dest-moved' || exit 1
if [[ $1 == symlink ]]; then
  ln -s -- '$TEST_TMP/replacement' '$TEST_TMP/dest'
else
  mkdir -- '$TEST_TMP/dest' && printf 'victim\n' >'$TEST_TMP/dest/victim.txt'
fi
# Identity of what now sits at the destination pathname (not followed).
stat -c '%d:%i:%F:%a:%u:%y' -- '$TEST_TMP/dest' >'$TEST_TMP/swap.id'
HOOK
  chmod +x "$TEST_TMP/hook"
}

# assert_only_victim DIR: DIR holds exactly the untouched victim.txt.
assert_only_victim() {
  [[ $(ls -A "$1") == victim.txt && $(<"$1/victim.txt") == victim ]] ||
    fail "$1 was written to: $(ls -A "$1")"
}

# assert_swap_untouched symlink|dir: the substitute the hook put at the
# destination pathname is exactly as the hook left it: the same symlink
# to the same replacement (or the same directory, unmodified) holding only
# the untouched victim; and the pinned (moved) directory holds nothing.
assert_swap_untouched() {
  local dest=$TEST_TMP/dest
  [[ -s $TEST_TMP/swap.id ]] || fail "the swap hook did not run"
  [[ $(stat -c '%d:%i:%F:%a:%u:%y' -- "$dest" 2>&1) == "$(<"$TEST_TMP/swap.id")" ]] ||
    fail "the substitute at $dest was changed or replaced"
  if [[ $1 == symlink ]]; then
    [[ -L $dest ]] || fail "$dest is no longer a symlink"
    [[ $(readlink -- "$dest") == "$TEST_TMP/replacement" ]] ||
      fail "$dest now points to $(readlink -- "$dest")"
    assert_only_victim "$TEST_TMP/replacement"
  else
    [[ -d $dest && ! -L $dest ]] || fail "$dest is no longer the substitute directory"
    assert_only_victim "$dest"
  fi
  [[ -z $(ls -A "$TEST_TMP/dest-moved") ]] ||
    fail "pinned destination left with: $(ls -A "$TEST_TMP/dest-moved")"
}

test_fetch_pins_destination_before_staging_against_symlink_swap() {
  build_release
  write_dest_swap_hook symlink
  # The swap happens while the release metadata is fetched: after the
  # destination was validated, before the staging directory is created.
  FAKE_CURL_HOOK_NAME=v$FIXTURE_VERSION FAKE_CURL_HOOK=$TEST_TMP/hook \
    run_fetch --arch aarch64
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "was moved or replaced"
  assert_swap_untouched symlink
}

test_fetch_pins_destination_before_staging_against_directory_swap() {
  build_release
  write_dest_swap_hook dir
  FAKE_CURL_HOOK_NAME=v$FIXTURE_VERSION FAKE_CURL_HOOK=$TEST_TMP/hook \
    run_fetch --arch aarch64
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "was moved or replaced"
  assert_swap_untouched dir
}

test_fetch_never_publishes_into_a_swapped_destination_pathname() {
  build_release
  write_dest_swap_hook symlink
  # The swap happens during the ZIP download, after staging started.
  FAKE_CURL_HOOK_NAME=$ASSET_ARM64 FAKE_CURL_HOOK=$TEST_TMP/hook \
    run_fetch --arch aarch64
  [[ $status == 1 ]] || fail "expected exit 1, got $status"
  assert_stdout_empty
  assert_stderr_contains "was moved or replaced"
  # Staging happened, and was cleaned up, only in the pinned directory.
  assert_swap_untouched symlink
}

# group_running PGID: true while any live (non-zombie) process is in PGID.
group_running() {
  local f stat rest
  for f in /proc/[0-9]*/stat; do
    { stat=$(<"$f"); } 2>/dev/null || continue
    rest=${stat##*) }
    read -r state _ pgrp _ <<<"$rest"
    [[ $pgrp == "$1" && $state != Z ]] && return 0
  done
  return 1
}

test_signal_arriving_while_a_child_starts_is_forwarded_to_it() {
  build_release
  use_fake_curl
  # The first download into the staging directory (the checksum manifest)
  # hangs until it is killed.
  export FAKE_CURL_SLEEP_NAME=$MANIFEST_NAME
  # Run the real fetch flow (cmd_fetch and its run_child) in this harness
  # shell, wrapping child_started so that TERM reaches the shell exactly
  # after run_child started the child and before its PID is registered.
  (
    # shellcheck source=deploy.sh
    source "$REPO_ROOT/deploy.sh"
    # shellcheck source=lib/fetch.sh
    source "$REPO_ROOT/lib/fetch.sh"
    eval "real_child_started() $(declare -f child_started | tail -n +2)"
    child_started() {
      if [[ -n $STAGE_NAME && ! -e $TEST_TMP/child.pid ]]; then
        printf '%s\n' "$1" >"$TEST_TMP/child.pid"
        printf '%s\n' "${ACTIVE_CHILD-}" >"$TEST_TMP/active-before"
        kill -TERM "$BASHPID"
        # The trap has run by now: a signal in the window must be pending.
        printf '%s\n' "${PENDING_SIGNAL-}" >"$TEST_TMP/pending"
      fi
      real_child_started "$@"
    }
    export PATH=$TEST_TMP/fakebin:$PATH
    cmd_fetch --version "$FIXTURE_VERSION" --destination "$TEST_TMP/dest" --arch aarch64
  ) >"$TEST_TMP/out" 2>&1 &
  local harness=$! i
  for ((i = 0; i < 100; i++)); do
    process_running "$harness" || break
    sleep 0.1
  done
  if process_running "$harness"; then
    [[ -s $TEST_TMP/child.pid ]] && kill -KILL -- "-$(<"$TEST_TMP/child.pid")" 2>/dev/null
    kill -KILL "$harness" 2>/dev/null
    fail "fetch did not stop within 10 s of TERM (pending signal never delivered)"
  fi
  wait "$harness"
  status=$?
  [[ -s $TEST_TMP/child.pid ]] || fail "run_child never started a child in the staging directory"
  local child
  child=$(<"$TEST_TMP/child.pid")
  [[ $status == 143 ]] || fail "expected exit 143, got $status: $(<"$TEST_TMP/out")"
  # The child (timeout leads its own process group) and everything it
  # started must be gone, not left running as orphans.
  for ((i = 0; i < 30; i++)); do
    group_running "$child" || break
    sleep 0.1
  done
  ! group_running "$child" || {
    kill -KILL -- "-$child" 2>/dev/null
    fail "the child started by run_child (process group $child) kept running"
  }
  assert_dest_untouched
  [[ -z $(ls -A "$TMPDIR") ]] || fail "temporary files left in TMPDIR: $(ls -A "$TMPDIR")"
  # And the signal really landed in the window: before registration, held
  # as pending by the trap.
  [[ -z $(<"$TEST_TMP/active-before") ]] || fail "TERM was sent after the PID was registered"
  [[ -s $TEST_TMP/pending && $(<"$TEST_TMP/pending") == "TERM 143" ]] ||
    fail "TERM in the start window was not held as pending"
}

test_fetch_stops_cleanly_when_term_arrives_as_a_child_starts() {
  build_release
  # A timeout that signals the CLI the moment it starts, then runs on.
  fake_tool timeout "echo \$\$ >'$TEST_TMP/timeout.pid'; kill -TERM \$PPID; exec $(type -aP timeout | head -n 1) \"\$@\""
  start_fetch_in_background
  wait "$FETCH_PID"
  status=$?
  [[ $status == 143 ]] || fail "expected exit 143, got $status: $(<"$TEST_TMP/out")"
  sleep 0.5
  ! process_running "$(<"$TEST_TMP/timeout.pid")" || fail "child kept running"
  assert_dest_untouched
  [[ -z $(ls -A "$TMPDIR") ]] || fail "temporary files left in TMPDIR: $(ls -A "$TMPDIR")"
}
