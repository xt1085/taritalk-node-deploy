# shellcheck shell=bash
# shell_files: print the repository's shell sources, relative to the repo root.
shell_files() {
  printf '%s\n' deploy.sh lib/*.sh scripts/*.sh tests/*.sh \
    tests/fakes/curl tests/fakes/sys tests/guard/curl tests/guard/system-command
}
