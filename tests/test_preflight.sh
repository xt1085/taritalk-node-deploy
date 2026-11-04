# shellcheck shell=bash
# preflight: deterministic platform detection from injected OS metadata
# (--os-release FILE) and architecture (--arch ARCH).

# preflight_with FIXTURE ARCH: run preflight against a fixture os-release file.
preflight_with() {
  run_cli preflight --os-release "$FIXTURES/os-release/$1" --arch "$2"
}

test_preflight_accepts_debian_12_aarch64() {
  preflight_with debian-12 aarch64
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "os: debian 12"
  assert_stdout_contains "arch: aarch64"
  assert_stdout_contains "tari_asset_platform: linux-arm64"
  assert_stdout_contains "preflight: supported"
}

test_preflight_accepts_debian_13_aarch64() {
  preflight_with debian-13 aarch64
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "os: debian 13"
  assert_stdout_contains "tari_asset_platform: linux-arm64"
  assert_stdout_contains "preflight: supported"
}

test_preflight_accepts_debian_12_x86_64() {
  preflight_with debian-12 x86_64
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "os: debian 12"
  assert_stdout_contains "arch: x86_64"
  assert_stdout_contains "tari_asset_platform: linux-x86_64"
  assert_stdout_contains "preflight: supported"
}

test_preflight_accepts_debian_13_x86_64() {
  preflight_with debian-13 x86_64
  assert_status 0
  assert_stderr_empty
  assert_stdout_contains "os: debian 13"
  assert_stdout_contains "tari_asset_platform: linux-x86_64"
  assert_stdout_contains "preflight: supported"
}

test_preflight_maps_arm64_alias_to_linux_arm64() {
  preflight_with debian-12 arm64
  assert_status 0
  assert_stdout_contains "arch: arm64"
  assert_stdout_contains "tari_asset_platform: linux-arm64"
}

test_preflight_maps_amd64_alias_to_linux_x86_64() {
  preflight_with debian-13 amd64
  assert_status 0
  assert_stdout_contains "arch: amd64"
  assert_stdout_contains "tari_asset_platform: linux-x86_64"
}

test_preflight_accepts_supported_ubuntu_releases_on_both_architectures() {
  local version pair
  for version in 24.04 26.04; do
    for pair in aarch64:linux-arm64 arm64:linux-arm64 x86_64:linux-x86_64 amd64:linux-x86_64; do
      preflight_with "ubuntu-$version" "${pair%%:*}"
      assert_status 0
      assert_stderr_empty
      assert_stdout_contains "os: ubuntu $version"
      assert_stdout_contains "arch: ${pair%%:*}"
      assert_stdout_contains "tari_asset_platform: ${pair#*:}"
      assert_stdout_contains "preflight: supported"
    done
  done
  preflight_with ubuntu-24.04 armv7l
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "unsupported architecture 'armv7l'"
}

test_help_names_the_supported_platforms() {
  run_cli preflight --help
  assert_status 0
  assert_stdout_contains "Supported: Debian 12 or 13, or Ubuntu 24.04 or 26.04, on aarch64/arm64 or x86_64/amd64."
  run_cli --help
  assert_stdout_contains "Debian 12/13 or Ubuntu 24.04/26.04 host; run as root"
  run_cli install --help
  assert_status 0
  assert_stdout_contains "Install a Minotari Mainnet full node on a clean Debian 12 or 13, or"
  assert_stdout_contains "Ubuntu 24.04 or 26.04, host (aarch64/arm64 or x86_64/amd64)."
  assert_stdout_contains "It installs the APT packages ca-certificates, curl, jq, unzip and tor from"
  assert_stdout_contains "Ubuntu, tor is in Universe, which those sources must already provide: no"
  # shellcheck disable=SC2154 # Set by run_cli (tests/lib.sh).
  [[ $stdout != *"Debian packages"* ]] || fail "install help still says Debian packages"
}

test_preflight_rejects_unsupported_ubuntu_versions() {
  preflight_with ubuntu-25.10 x86_64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "unsupported Ubuntu version '25.10' in '$FIXTURES/os-release/ubuntu-25.10' (supported: 24.04, 26.04)"
}

test_preflight_rejects_unsupported_distribution() {
  preflight_with fedora-42 x86_64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "unsupported Linux distribution 'fedora'"
  assert_stderr_contains "(supported: debian, ubuntu)"
}

test_preflight_rejects_unsupported_debian_version() {
  preflight_with debian-11 aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "unsupported Debian version '11'"
  assert_stderr_contains "supported: 12, 13"
}

test_preflight_rejects_unsupported_architecture() {
  local arch
  for arch in armv7l i686 riscv64 ppc64le; do
    preflight_with debian-12 "$arch"
    assert_status 1
    assert_stdout_empty
    assert_stderr_contains "unsupported architecture '$arch'"
    assert_stderr_contains "supported: aarch64, arm64, x86_64, amd64"
  done
}

test_preflight_rejects_missing_os_release_file() {
  preflight_with does-not-exist aarch64
  assert_status 1
  assert_stdout_empty
  assert_stderr_contains "missing OS metadata"
  assert_stderr_contains "does-not-exist"
}

test_preflight_rejects_missing_os_metadata_fields() {
  local fixture field
  for fixture in empty:ID missing-id:ID missing-version-id:VERSION_ID; do
    field=${fixture#*:}
    preflight_with "${fixture%%:*}" aarch64
    assert_status 1
    assert_stdout_empty
    assert_stderr_contains "missing OS metadata: no $field"
  done
}

test_preflight_rejects_malformed_os_metadata() {
  local fixture
  for fixture in no-equals unterminated-quote duplicate-id \
    command-substitution invalid-id invalid-version-id empty-version-id; do
    preflight_with "malformed-$fixture" aarch64
    assert_status 1
    assert_stdout_empty
    assert_stderr_contains "malformed OS metadata"
    assert_stderr_contains "malformed-$fixture"
  done
  # The file is parsed, never sourced: the command substitution must not run.
  [[ ! -e pwned ]] || fail "os-release content was executed"
}

test_preflight_rejects_os_metadata_containing_nul_bytes() {
  # Bash variables cannot hold NUL, so a naive reader silently drops it and
  # whatever hides behind it. Generate real binary NUL bytes here.
  local name file
  printf 'ID=debian\0ubuntu\nVERSION_ID="12"\n' >"$TEST_TMP/nul-in-id"
  printf 'ID=debian\nVERSION_ID=12\0garbage\n' >"$TEST_TMP/nul-in-version-id"
  printf 'ID=debian\0not-debian\nVERSION_ID=12\0garbage\n' >"$TEST_TMP/nul-in-both"
  for name in nul-in-id nul-in-version-id nul-in-both; do
    file=$TEST_TMP/$name
    [[ $(od -An -c "$file") == *'\0'* ]] || fail "fixture $name has no NUL byte"
    run_cli preflight --os-release "$file" --arch aarch64
    assert_status 1
    assert_stdout_empty
    assert_stderr_contains "malformed OS metadata in '$file'"
    assert_stderr_contains "NUL"
  done
}
