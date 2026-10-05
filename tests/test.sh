#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

suite="${1:-all}"

test_syntax() {
  bash -n ./gh-repo-reset
  for module in lib/*.sh; do
    bash -n "$module"
  done

  local expected=(core.sh snapshot.sh git.sh safety.sh restore.sh integrations.sh followup.sh main.sh)
  local module
  for module in "${expected[@]}"; do
    [[ -f "lib/$module" ]]
  done

  (( $(wc -l < ./gh-repo-reset) < 170 ))
  [[ ! -e Makefile ]]
  [[ -f mise.toml ]]
  [[ -f gh-repo-reset.usage.kdl ]]
  [[ -x mise-tasks/test ]]
  grep -q '^gh = "2.101.0"$' mise.toml
  grep -q '^usage = "6.12.0"$' mise.toml
  echo 'syntax: ok'
}

test_self() {
  ./gh-repo-reset --self-test | grep -q 'self-test: ok'
  ./gh-repo-reset --help | grep -q 'one fresh initial commit'
  [[ "$(./gh-repo-reset --version)" == 'gh-repo-reset v0.0.0-1' ]]
  ./gh-repo-reset __usage_spec__ | grep -q '^bin "gh-repo-reset"$'
  echo 'self: ok'
}

test_dry_run() {
  ./tests/mock-dry-run.sh
}

test_org() {
  MOCK_OWNER_TYPE=Organization MOCK_NO_CODE_SECURITY=1 ./tests/mock-dry-run.sh
  echo 'org: ok'
}

test_reset() {
  ./tests/mock-reset.sh
}

test_pipe() {
  ./tests/mock-pipe.sh
}

run_suite() {
  case "$1" in
    syntax) test_syntax ;;
    self) test_self ;;
    dry-run) test_dry_run ;;
    org) test_org ;;
    reset) test_reset ;;
    pipe) test_pipe ;;
    *)
      printf 'unknown test suite: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

case "$suite" in
  all)
    for name in syntax self dry-run org reset pipe; do
      run_suite "$name"
    done
    echo 'tests: ok'
    ;;
  syntax|self|dry-run|org|reset|pipe)
    run_suite "$suite"
    ;;
  *)
    printf 'usage: %s [all|syntax|self|dry-run|org|reset|pipe]\n' "$0" >&2
    exit 2
    ;;
esac
