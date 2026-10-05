#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

suite="${1:-all}"

test_syntax() {
  bash -n ./gh-repo-reset
  for module in lib/*.sh; do
    bash -n "$module"
  done

  local expected=(core.sh snapshot.sh git.sh report.sh safety.sh restore.sh integrations.sh followup.sh main.sh)
  local module
  for module in "${expected[@]}"; do
    [[ -f "lib/$module" ]]
  done

  (
    PROGRAM=gh-repo-reset-test
    VERSION=v0.0.0-1
    for module in "${expected[@]}"; do
      # shellcheck source=/dev/null
      source "lib/$module"
    done
    declare -F gh_repo_reset_main >/dev/null
    declare -F build_restore_plan >/dev/null
    declare -F deploy_key_attached_to_target >/dev/null
  )

  (( $(wc -l < ./gh-repo-reset) < 220 ))
  [[ ! -e Makefile ]]
  [[ -f mise.toml ]]
  [[ -f gh-repo-reset.usage.kdl ]]
  [[ -x mise-tasks/test ]]
  grep -q '^gh = "2.101.0"$' mise.toml
  grep -q '^usage = "6.12.0"$' mise.toml
  ! grep -q '// true' lib/snapshot.sh
  ! grep -q 'gh variable get' lib/snapshot.sh
  ! grep -q 'repos/\$REPO/labels/\$(urlencode' lib/snapshot.sh
  grep -q 'run_snapshot_jobs "\$BACKUP_DIR"' lib/main.sh
  grep -q 'GH_REPO_RESET_JOBS' gh-repo-reset
  echo 'syntax: ok'
}

test_self() {
  ./gh-repo-reset --self-test | grep -q 'self-test: ok'
  ./gh-repo-reset --help | grep -q 'one fresh initial commit'
  ./gh-repo-reset --help | grep -q -- '--resume-from DIR'
  [[ "$(./gh-repo-reset --version)" == 'gh-repo-reset v0.0.0-1' ]]
  ./gh-repo-reset __usage_spec__ | grep -q '^bin "gh-repo-reset"$'
  ./gh-repo-reset __usage_spec__ | grep -q -- '--resume-from <dir>'
  echo 'self: ok'
}

test_legacy() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  BACKUP_DIR="$tmp"
  source ./lib/core.sh
  source ./lib/report.sh

  cat > "$tmp/repo-state.sh" <<'STATE_EOF'
ALLOW_SQUASH=true
ALLOW_MERGE=true
ALLOW_REBASE=true
ALLOW_FORKING=true
HAS_DOWNLOADS=true
HAS_PULL_REQUESTS=true
STATE_EOF
  cat > "$tmp/repository.json" <<'JSON_EOF'
{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true,"allow_forking":false,"has_downloads":false,"has_pull_requests":true}
JSON_EOF

  repair_legacy_repo_booleans "$tmp"
  # shellcheck disable=SC1090
  source "$tmp/repo-state.sh"
  [[ "$ALLOW_FORKING" == false ]]
  [[ "$HAS_DOWNLOADS" == false ]]
  [[ "$HAS_PULL_REQUESTS" == true ]]
  [[ "$LEGACY_REPO_BOOLEANS_REPAIRED" == true ]]
  echo 'legacy: ok'
}

test_git() {
  local tmp source mirror remote tree root
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  source="$tmp/source"
  mirror="$tmp/mirror.git"
  remote="$tmp/remote.git"

  git init -q -b main "$source"
  printf 'one\n' > "$source/file.txt"
  git -C "$source" add file.txt
  git -C "$source" -c user.name=Tester -c user.email=test@example.com commit -q -m one
  git clone -q --mirror "$source" "$mirror"
  git init -q --bare "$remote"

  tree="$(git -C "$mirror" rev-parse 'refs/heads/main^{tree}')"
  root="$(printf 'Initial commit\n' | GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=test@example.com git -C "$mirror" commit-tree "$tree")"
  git -C "$mirror" update-ref refs/gh-repo-reset/initial "$root"
  git -C "$mirror" remote set-url origin "$remote"
  git -C "$mirror" config --unset-all remote.origin.mirror >/dev/null 2>&1 || true
  git -C "$mirror" push -q origin 'refs/gh-repo-reset/initial:refs/heads/main'

  [[ "$(git -C "$remote" rev-parse refs/heads/main)" == "$root" ]]
  [[ "$(git -C "$remote" for-each-ref --format='%(refname)' refs/heads | wc -l)" -eq 1 ]]
  [[ "$(git -C "$remote" rev-list --parents -n1 "$root" | awk '{print NF-1}')" -eq 0 ]]
  echo 'git: ok'
}

test_labels() (
  set -Eeuo pipefail
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  REPO=owner/repo
  BACKUP_DIR="$tmp"
  mkdir -p "$tmp/labels/1" "$tmp/labels/2"
  cat > "$tmp/labels/1/state.sh" <<'STATE_EOF'
LABEL_NAME=bug
LABEL_COLOR=d73a4a
LABEL_DESCRIPTION=broken
STATE_EOF
  cat > "$tmp/labels/2/state.sh" <<'STATE_EOF'
LABEL_NAME=custom
LABEL_COLOR=123456
LABEL_DESCRIPTION=desired
STATE_EOF

  source ./lib/core.sh
  source ./lib/restore.sh

  gh() {
    local args=" $* "
    if [[ "$args" == *" label list "* ]]; then
      printf 'bug\td73a4a\tbroken\n'
      printf 'custom\tabcdef\told\n'
      printf 'extra\tffffff\tremove\n'
      return 0
    fi
    printf '%s\n' "$*" >> "$tmp/gh.log"
    return 0
  }

  restore_labels "$tmp"

  ! grep -Fq 'label create bug' "$tmp/gh.log"
  grep -Fq 'label create custom -R owner/repo --force --color 123456 --description desired' "$tmp/gh.log"
  grep -Fq 'label delete extra -R owner/repo --yes' "$tmp/gh.log"
  ! grep -Fq 'label delete bug' "$tmp/gh.log"
  ! grep -Fq 'label delete custom' "$tmp/gh.log"
  echo 'labels: ok'
)

test_deploy_key() (
  set -Eeuo pipefail
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  REPO=owner/repo
  BACKUP_DIR="$tmp"
  mkdir -p "$tmp/deploy-keys/1"
  cat > "$tmp/deploy-keys/1/state.sh" <<'STATE_EOF'
TITLE='Repo Public Access'
READ_ONLY=true
STATE_EOF
  printf 'ssh-ed25519 AAAATEST comment\n' > "$tmp/deploy-keys/1/key.pub"
  printf 'deploy_keys\tstale warning\n' > "$tmp/manual-items.tsv"

  source ./lib/core.sh
  source ./lib/report.sh
  source ./lib/restore.sh

  gh() {
    local args=" $* "
    if [[ "$args" == *" repo deploy-key list "* ]]; then
      printf 'ssh-ed25519 AAAATEST\ttrue\n'
      return 0
    fi
    if [[ "$args" == *" repo deploy-key add "* ]]; then
      printf 'deploy-key add should not be called\n' >&2
      return 99
    fi
    return 0
  }

  restore_deploy_keys "$tmp"
  ! grep -q '^deploy_keys[[:space:]]' "$tmp/manual-items.tsv"
  [[ ! -s "${tmp}/restore-failures.txt" || ! -f "${tmp}/restore-failures.txt" ]]
  echo 'deploy-key: ok'
)

test_dry_run() {
  ./tests/mock-dry-run.sh
  ./tests/mock-dry-run.sh --verbose
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
    legacy) test_legacy ;;
    git) test_git ;;
    labels) test_labels ;;
    deploy-key) test_deploy_key ;;
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
    for name in syntax self legacy git labels deploy-key dry-run org reset pipe; do
      run_suite "$name"
    done
    echo 'tests: ok'
    ;;
  syntax|self|legacy|git|labels|deploy-key|dry-run|org|reset|pipe)
    run_suite "$suite"
    ;;
  *)
    printf 'usage: %s [all|syntax|self|legacy|git|labels|deploy-key|dry-run|org|reset|pipe]\n' "$0" >&2
    exit 2
    ;;
esac
