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

  (( $(wc -l < ./gh-repo-reset) < 260 ))
  [[ ! -e Makefile ]]
  [[ -f mise.toml ]]
  [[ -f gh-repo-reset.usage.kdl ]]
  [[ -x mise-tasks/test ]]
  grep -Fxq 'gh = "2.102.0"' mise.toml
  grep -Fxq 'usage = "6.12.1"' mise.toml
  grep -Fxq 'min_usage_version "6.12.1"' gh-repo-reset.usage.kdl
  grep -Fq 'uses: actions/checkout@v7' .github/workflows/check.yml
  grep -Fq 'uses: jdx/mise-action@v5' .github/workflows/check.yml
  grep -Fq 'run: mise run check' .github/workflows/check.yml
  grep -Fq '"org-bindings"' mise-tasks/test
  ! grep -q '// true' lib/snapshot.sh
  ! grep -q 'gh variable get' lib/snapshot.sh
  ! grep -q 'repos/\$REPO/labels/\$(urlencode' lib/snapshot.sh
  grep -q 'run_snapshot_jobs "\$BACKUP_DIR"' lib/main.sh
  grep -q 'snapshot_git_backup "\$BACKUP_DIR" &' lib/main.sh
  grep -q 'snapshot_history_metadata' lib/main.sh
  ! grep -q 'snapshot_git_and_metadata' lib/main.sh lib/git.sh
  grep -q 'run_bounded_items' lib/git.sh
  grep -q 'run_bounded_items' lib/snapshot.sh
  grep -q 'visible_to_repository=' lib/snapshot.sh
  ! grep -q 'runner-groups/\$group_id/repositories' lib/snapshot.sh
  ! grep -q 'snapshot_capture "\$envdir/environment.json"' lib/snapshot.sh
  grep -q 'GH_REPO_RESET_JOBS' gh-repo-reset
  grep -q 'GH_REPO_RESET_SOURCE_REPO' gh-repo-reset
  grep -q 'GH_REPO_RESET_SNAPSHOT_WORKER_DIR' lib/core.sh
  grep -q 'git_state="\$dir/git-state.sh"' lib/git.sh
  grep -q 'cat "\$BACKUP_DIR/git-state.sh" >> "\$BACKUP_DIR/repo-state.sh"' lib/main.sh
  ! grep -Fq 'issues?state=all&per_page=1' lib/safety.sh
  ! grep -Fq 'releases?per_page=1' lib/safety.sh
  ! grep -Fq 'repo_field' lib/safety.sh
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

test_legacy() (
  set -Eeuo pipefail
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

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
)

test_git() (
  set -Eeuo pipefail
  local tmp source linked detached stale mirror remote backup tree root
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  source="$tmp/source"
  linked="$tmp/linked"
  detached="$tmp/detached"
  stale="$tmp/stale"
  mirror="$tmp/mirror.git"
  remote="$tmp/remote.git"
  backup="$tmp/backup"
  mkdir -p "$backup"

  git init -q -b main "$source"
  printf 'one\n' > "$source/file.txt"
  git -C "$source" add file.txt
  git -C "$source" -c user.name=Tester -c user.email=test@example.com commit -q -m one
  printf 'two\n' >> "$source/file.txt"
  git -C "$source" add file.txt
  git -C "$source" -c user.name=Tester -c user.email=test@example.com commit -q -m two
  git -C "$source" branch old-branch HEAD~1
  git -C "$source" tag old-tag HEAD~1
  git -C "$source" remote add origin https://github.com/owner/repo.git
  git -C "$source" config branch.old-branch.remote origin
  git -C "$source" config branch.old-branch.merge refs/heads/old-branch
  git -C "$source" config branch.ghost.remote origin
  git -C "$source" config branch.ghost.merge refs/heads/ghost
  git -C "$source" update-ref refs/remotes/origin/old-branch HEAD~1
  git -C "$source" update-ref refs/archive/old HEAD~1
  git -C "$source" update-ref refs/notes/review HEAD~1
  printf 'stash-only\n' >> "$source/file.txt"
  git -C "$source" stash push -q -m stale-reset-fixture
  git -C "$source" worktree add -q "$linked" old-branch
  git -C "$source" worktree add -q --detach "$detached" HEAD~1
  git -C "$source" worktree add -q --detach "$stale" HEAD~1
  rm -rf "$stale"
  [[ "$(git -C "$source" worktree list --porcelain | grep -c '^worktree ')" -eq 4 ]]

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  DRY_RUN=0
  REPO=owner/repo
  DEFAULT_BRANCH=main
  BACKUP_DIR="$backup"
  source ./lib/core.sh
  source ./lib/git.sh

  (cd "$source" && prepare_local_checkout_reset "$backup")
  [[ "$(cat "$backup/local-checkout.path")" == "$source" ]]
  [[ "$(git -C "$source" worktree list --porcelain | grep -c '^worktree ')" -eq 3 ]]
  ! grep -Fq "$stale" "$backup/local-worktrees.tsv"
  [[ "$(wc -l < "$backup/local-worktrees.tsv")" -eq 3 ]]
  grep -Fq "$linked" "$backup/local-worktrees.tsv"
  grep -Fq "$detached" "$backup/local-worktrees.tsv"
  [[ -d "$backup/local.git" ]]
  git -C "$backup/local.git" show-ref --verify --quiet refs/heads/old-branch
  git -C "$backup/local.git" show-ref --verify --quiet refs/tags/old-tag
  git -C "$backup/local.git" show-ref --verify --quiet refs/remotes/origin/old-branch
  git -C "$backup/local.git" show-ref --verify --quiet refs/archive/old
  git -C "$backup/local.git" show-ref --verify --quiet refs/notes/review
  git -C "$backup/local.git" show-ref --verify --quiet refs/stash
  [[ "$(git -C "$backup/local.git" for-each-ref --format='%(refname)' refs/gh-repo-reset/worktrees | wc -l)" -eq 3 ]]

  git clone -q --mirror "$source" "$mirror"
  git init -q --bare "$remote"
  tree="$(git -C "$mirror" rev-parse 'refs/heads/main^{tree}')"
  root="$(printf 'Initial commit\n' | GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=test@example.com git -C "$mirror" commit-tree "$tree")"
  git -C "$mirror" update-ref refs/gh-repo-reset/initial "$root"
  git -C "$mirror" remote set-url origin "$remote"
  git -C "$mirror" config --unset-all remote.origin.mirror >/dev/null 2>&1 || true
  git -C "$mirror" push -q origin 'refs/gh-repo-reset/initial:refs/heads/main'
  printf '%s\n' "$root" > "$backup/initial-commit.txt"
  cat > "$backup/repo-state.sh" <<'STATE_EOF'
REPO=owner/repo
DEFAULT_BRANCH=main
STATE_EOF

  git -C "$source" remote set-url origin "$remote"
  reset_local_checkout "$backup"

  [[ -d "$linked" && -d "$detached" ]]
  [[ "$(git -C "$source" worktree list --porcelain | grep -c '^worktree ')" -eq 3 ]]
  [[ "$(git -C "$remote" rev-parse refs/heads/main)" == "$root" ]]
  [[ "$(git -C "$remote" for-each-ref --format='%(refname)' refs/heads | wc -l)" -eq 1 ]]
  [[ "$(git -C "$remote" rev-list --parents -n1 "$root" | awk '{print NF-1}')" -eq 0 ]]
  [[ "$(git -C "$source" rev-parse HEAD)" == "$root" ]]
  [[ "$(git -C "$linked" rev-parse HEAD)" == "$root" ]]
  [[ "$(git -C "$detached" rev-parse HEAD)" == "$root" ]]
  [[ "$(git -C "$source" rev-list --count HEAD)" -eq 1 ]]
  [[ "$(git -C "$source" for-each-ref --format='%(refname)' refs/heads | wc -l)" -eq 1 ]]
  [[ -z "$(git -C "$source" for-each-ref --format='%(refname)' refs/tags)" ]]
  [[ "$(git -C "$source" for-each-ref --format='%(refname)' refs | wc -l)" -eq 2 ]]
  git -C "$source" show-ref --verify --quiet refs/heads/main
  git -C "$source" show-ref --verify --quiet refs/remotes/origin/main
  ! git -C "$source" show-ref --verify --quiet refs/remotes/origin/old-branch
  ! git -C "$source" show-ref --verify --quiet refs/archive/old
  ! git -C "$source" show-ref --verify --quiet refs/notes/review
  ! git -C "$source" show-ref --verify --quiet refs/stash
  ! git -C "$source" config --local --get-regexp '^branch\.old-branch\.' >/dev/null 2>&1
  ! git -C "$source" config --local --get-regexp '^branch\.ghost\.' >/dev/null 2>&1
  [[ "$(git -C "$source" config --local --name-only --get-regexp '^branch\.main\.' | wc -l)" -eq 2 ]]
  [[ -z "$(git -C "$source" status --porcelain=v1 --untracked-files=all)" ]]
  [[ -z "$(git -C "$linked" status --porcelain=v1 --untracked-files=all)" ]]
  [[ -z "$(git -C "$detached" status --porcelain=v1 --untracked-files=all)" ]]
  echo 'git: ok'
)

test_labels() (
  set -Eeuo pipefail
  local tmp test_gh_log
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  test_gh_log="$tmp/gh.log"

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
    printf '%s\n' "$*" >> "$test_gh_log"
    return 0
  }

  restore_labels "$tmp"

  ! grep -Fq 'label create bug' "$test_gh_log"
  grep -Fq 'label create custom -R owner/repo --force --color 123456 --description desired' "$test_gh_log"
  grep -Fq 'label delete extra -R owner/repo --yes' "$test_gh_log"
  ! grep -Fq 'label delete bug' "$test_gh_log"
  ! grep -Fq 'label delete custom' "$test_gh_log"
  echo 'labels: ok'
)


test_packages() (
  set -Eeuo pipefail
  local tmp source mirror
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  source="$tmp/source"
  mirror="$tmp/git.git"

  git init -q -b main "$source"
  mkdir -p "$source/.github/workflows"
  cat > "$source/image.ts" <<'SRC_EOF'
const imageRepository = "ghcr.io/kaiju-ind/twenty";
const dependency = "ghcr.io/kaiju-ind/shared-base:latest";
SRC_EOF
  cat > "$source/.github/workflows/release.yml" <<'YAML_EOF'
permissions:
  contents: read
  packages: write
YAML_EOF
  git -C "$source" add .
  git -C "$source" -c user.name=Tester -c user.email=test@example.com commit -q -m one
  git clone -q --mirror "$source" "$mirror"

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  REPO=Kaiju-Ind/twenty
  BACKUP_DIR="$tmp"
  cat > "$tmp/repo-state.sh" <<'STATE_EOF'
REPO=Kaiju-Ind/twenty
OWNER=Kaiju-Ind
OWNER_TYPE=Organization
REPO_ID=123
DEFAULT_BRANCH=main
STATE_EOF

  source ./lib/core.sh
  source ./lib/report.sh
  source ./lib/git.sh

  snapshot_package_actions_access_hints "$tmp"
  grep -Fq $'container\ttwenty\t' "$tmp/package-actions-access.tsv"
  grep -Fq $'container\tshared-base\t' "$tmp/package-actions-access.tsv"

  DELETE_FAIL=0
  PACKAGE_LIST_FAIL=0
  PACKAGE_DETAIL_FAIL=0
  api() {
    local args=" $* "
    printf '%s\n' "$*" >> "$tmp/package-api.log"
    if [[ "$args" == *" --paginate orgs/Kaiju-Ind/packages?package_type=container&per_page=100 --jq .[].name "* ]]; then
      if (( PACKAGE_LIST_FAIL )); then
        printf 'HTTP 500: package enumeration failed\n' >&2
        return 1
      fi
      printf 'twenty\ntwenty-worker\nshared-base\n'
      return 0
    fi
    if [[ "$args" == *" orgs/Kaiju-Ind/packages/container/twenty --jq .repository.id // empty "* ]]; then
      sleep 0.05
      return 0
    fi
    if [[ "$args" == *" orgs/Kaiju-Ind/packages/container/twenty-worker --jq .repository.id // empty "* ]]; then
      if (( PACKAGE_DETAIL_FAIL )); then
        printf 'HTTP 500: package detail failed\n' >&2
        return 1
      fi
      printf '123\n'
      return 0
    fi
    if [[ "$args" == *" orgs/Kaiju-Ind/packages/container/shared-base --jq .repository.id // empty "* ]]; then
      printf '999\n'
      return 0
    fi
    if [[ "$args" == *" --method DELETE "* ]]; then
      if (( DELETE_FAIL )); then
        printf 'HTTP 403: package admin permission required\n' >&2
        return 1
      fi
      return 0
    fi
    printf 'unexpected package api invocation: %s\n' "$*" >&2
    return 99
  }

  GH_REPO_RESET_JOBS=2 snapshot_package_reset_targets "$tmp"
  grep -Fqx $'container package twenty repository association\tcaptured' "$tmp/snapshot-status.tsv"
  grep -Fqx $'container package twenty-worker repository association\tcaptured' "$tmp/snapshot-status.tsv"
  grep -Fqx $'container package shared-base repository association\tcaptured' "$tmp/snapshot-status.tsv"
  grep -Fqx $'GitHub package reset targets\tcaptured' "$tmp/snapshot-status.tsv"
  grep -Fxq $'container\ttwenty' "$tmp/package-reset-targets.tsv"
  grep -Fxq $'container\ttwenty-worker' "$tmp/package-reset-targets.tsv"
  ! grep -Fq 'shared-base' "$tmp/package-reset-targets.tsv"
  [[ "$(wc -l < "$tmp/package-reset-targets.tsv")" -eq 2 ]]

  delete_reset_packages "$tmp"
  grep -Fq -- '--method DELETE orgs/Kaiju-Ind/packages/container/twenty' "$tmp/package-api.log"
  grep -Fq -- '--method DELETE orgs/Kaiju-Ind/packages/container/twenty-worker' "$tmp/package-api.log"
  ! grep -Fq -- '--method DELETE orgs/Kaiju-Ind/packages/container/shared-base' "$tmp/package-api.log"
  [[ ! -s "$tmp/package-delete-failures.tsv" ]]

  DELETE_FAIL=1
  if delete_reset_packages "$tmp"; then
    printf 'package deletion should have failed\n' >&2
    return 1
  fi
  grep -Fxq $'container\ttwenty' "$tmp/package-delete-failures.tsv"
  grep -Fxq $'container\ttwenty-worker' "$tmp/package-delete-failures.tsv"
  grep -Fq 'HTTP 403' "$tmp/package-delete-errors.log"

  PACKAGE_LIST_FAIL=1
  : > "$tmp/snapshot-failures.txt"
  : > "$tmp/snapshot-errors.log"
  GH_REPO_RESET_JOBS=2 snapshot_package_reset_targets "$tmp"
  grep -Fxq 'owner container packages' "$tmp/snapshot-failures.txt"
  grep -Fqx $'owner container packages\tfailed' "$tmp/snapshot-status.tsv"
  grep -Fxq $'container\ttwenty' "$tmp/package-reset-targets.tsv"
  ! grep -Fq 'twenty-worker' "$tmp/package-reset-targets.tsv"

  PACKAGE_LIST_FAIL=0
  PACKAGE_DETAIL_FAIL=1
  : > "$tmp/snapshot-failures.txt"
  : > "$tmp/snapshot-errors.log"
  GH_REPO_RESET_JOBS=2 snapshot_package_reset_targets "$tmp"
  grep -Fxq 'container package twenty-worker repository association' "$tmp/snapshot-failures.txt"
  grep -Fqx $'container package twenty-worker repository association\tfailed' "$tmp/snapshot-status.tsv"
  grep -Fqx $'GitHub package reset targets\tfailed' "$tmp/snapshot-status.tsv"
  grep -Fxq $'container\ttwenty' "$tmp/package-reset-targets.tsv"
  ! grep -Fq 'twenty-worker' "$tmp/package-reset-targets.tsv"
  grep -Fq 'HTTP 500: package detail failed' "$tmp/snapshot-errors.log"

  : > "$tmp/manual-items.tsv"
  record_package_actions_access_followup "$tmp"
  grep -q '^package_actions_access[[:space:]]' "$tmp/manual-items.tsv"
  grep -Fq 'container/shared-base' "$tmp/manual-items.tsv"
  ! grep -Fq 'container/twenty' "$tmp/manual-items.tsv"
  echo 'packages: ok'
)

test_org_bindings() (
  set -Eeuo pipefail
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  REPO=acme/repo
  BACKUP_DIR="$tmp"
  GH_REPO_RESET_JOBS=2
  : > "$tmp/snapshot-status.tsv"
  : > "$tmp/snapshot-failures.txt"
  : > "$tmp/snapshot-errors.log"
  cat > "$tmp/repo-state.sh" <<'STATE_EOF'
REPO=acme/repo
OWNER=acme
OWNER_TYPE=Organization
REPO_ID=123
DEFAULT_BRANCH=main
STATE_EOF

  source ./lib/core.sh
  source ./lib/snapshot.sh

  api() {
    local args=" $* "
    printf '%s\n' "$*" >> "$tmp/org-api.log"
    case "$args" in
      *" --paginate orgs/acme/actions/secrets?per_page=100 "*) printf 'ACT_ONE\nACT_TWO\n' ;;
      *" --paginate orgs/acme/dependabot/secrets?per_page=100 "*) printf 'DEP_ONE\n' ;;
      *" --paginate orgs/acme/codespaces/secrets?per_page=100 "*) printf 'CODE_ONE\n' ;;
      *" --paginate orgs/acme/actions/variables?per_page=100 "*) printf 'VAR_ONE\n' ;;
      *" --paginate orgs/acme/actions/secrets/ACT_ONE/repositories?per_page=100 "*) printf '123\n' ;;
      *" --paginate orgs/acme/actions/secrets/ACT_TWO/repositories?per_page=100 "*) printf '999\n' ;;
      *" --paginate orgs/acme/dependabot/secrets/DEP_ONE/repositories?per_page=100 "*) printf '123\n' ;;
      *" --paginate orgs/acme/codespaces/secrets/CODE_ONE/repositories?per_page=100 "*) printf '999\n' ;;
      *" --paginate orgs/acme/actions/variables/VAR_ONE/repositories?per_page=100 "*) printf '123\n' ;;
      *" --paginate orgs/acme/actions/runner-groups?visible_to_repository=repo&per_page=100 "*) printf '77\n' ;;
      *" orgs/acme/actions/permissions --jq .enabled_repositories // \"\" "*) printf 'selected\n' ;;
      *" --paginate orgs/acme/actions/permissions/repositories?per_page=100 "*) printf '123\n' ;;
      *" repos/acme/repo/code-security-configuration "*) printf '456\n' ;;
      *) printf 'unexpected org binding api invocation: %s\n' "$*" >&2; return 99 ;;
    esac
  }

  snapshot_org_bindings "$tmp"

  grep -Fxq 'ACT_ONE' "$tmp/org-bindings/actions-secrets.txt"
  ! grep -Fxq 'ACT_TWO' "$tmp/org-bindings/actions-secrets.txt"
  grep -Fxq 'DEP_ONE' "$tmp/org-bindings/dependabot-secrets.txt"
  [[ ! -s "$tmp/org-bindings/codespaces-secrets.txt" ]]
  grep -Fxq 'VAR_ONE' "$tmp/org-bindings/actions-variables.txt"
  grep -Fxq '77' "$tmp/org-bindings/runner-groups.txt"
  [[ -f "$tmp/org-bindings/actions-enabled-selected" ]]
  grep -Fxq '456' "$tmp/org-bindings/code-security-configuration-id"
  grep -Fq 'visible_to_repository=repo' "$tmp/org-api.log"
  ! grep -Fq '/runner-groups/77/repositories' "$tmp/org-api.log"
  grep -Fqx 

test_environment() (
  set -Eeuo pipefail
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  API_VERSION=2026-03-10
  VERBOSE=0
  REPO=owner/repo
  BACKUP_DIR="$tmp"
  mkdir -p "$tmp/environments/1/variables"
  cat > "$tmp/environments/1/state.sh" <<'STATE_EOF'
ENV_NAME=copilot
ENV_KEY=copilot
STATE_EOF
  cat > "$tmp/environments/1/environment-restore.json" <<'JSON_EOF'
{"wait_timer":0,"prevent_self_review":false,"reviewers":[],"deployment_branch_policy":null}
JSON_EOF
  cat > "$tmp/environments/1/environment.json" <<'JSON_EOF'
{"name":"copilot","protection_rules":[],"deployment_branch_policy":null}
JSON_EOF

  source ./lib/core.sh
  source ./lib/report.sh
  source ./lib/restore.sh

  gh() {
    local args=" $* " input="" prev=""
    printf '%s\n' "$*" >> "$tmp/gh.log"
    for x in "$@"; do
      if [[ "$prev" == --input ]]; then input="$x"; prev=""; continue; fi
      [[ "$x" == --input ]] && prev=--input
    done
    if [[ "$args" == *" --method PUT repos/owner/repo/environments/copilot "* ]]; then
      if [[ -n "$input" && -f "$input" ]] && grep -q '"reviewers"' "$input"; then
        printf 'protection rules unavailable for private repository\n' >&2
        return 1
      fi
      return 0
    fi
    return 0
  }

  restore_environments "$tmp"

  [[ "$(grep -c -- '--method PUT repos/owner/repo/environments/copilot' "$tmp/gh.log")" -eq 2 ]]
  [[ ! -s "$tmp/restore-failures.txt" || ! -f "$tmp/restore-failures.txt" ]]
  [[ ! -f "$tmp/manual-items.tsv" || ! -s "$tmp/manual-items.tsv" ]]

  rm -f "$tmp/environments/1/environment.json"
  cat > "$tmp/environments/1/environment-restore.json" <<'JSON_EOF'
{"prevent_self_review":false,"reviewers":[{"type":"User","id":42}],"deployment_branch_policy":null}
JSON_EOF
  : > "$tmp/gh.log"
  restore_environments "$tmp"
  grep -q '^environment_policy[[:space:]]' "$tmp/manual-items.tsv"
  [[ ! -s "$tmp/restore-failures.txt" || ! -f "$tmp/restore-failures.txt" ]]
  echo 'environment: ok'
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

test_snapshot_guard() (
  set -Eeuo pipefail
  local tmp rc=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  BACKUP_DIR="$tmp"
  : > "$tmp/snapshot-status.tsv"
  : > "$tmp/snapshot-failures.txt"
  : > "$tmp/snapshot-errors.log"
  source ./lib/core.sh

  succeed() { printf '{"ok":true}\n'; }
  fail_500() { printf 'HTTP 500: transient failure\n' >&2; return 1; }
  fail_404() { printf 'HTTP 404: Not Found\n' >&2; return 1; }
  fail_conflict() { printf 'HTTP 409: Conflict\n' >&2; return 1; }

  snapshot_capture "$tmp/repository.json" "repository settings" succeed
  grep -Fqx $'repository settings\tcaptured' "$tmp/snapshot-status.tsv"
  [[ -s "$tmp/repository.json" ]]

  pool_slow() {
    local dir="$1" i
    record_snapshot_status "pool slow" captured
    : > "$dir/pool-slow.started"
    for ((i=0; i<200; i++)); do
      [[ -e "$dir/pool.release" ]] && return 0
      sleep 0.01
    done
    return 1
  }
  pool_fast() {
    record_snapshot_status "pool fast" captured
    : > "$1/pool-fast.started"
  }
  pool_release() {
    record_snapshot_status "pool release" captured
    : > "$1/pool-third.started"
    : > "$1/pool.release"
  }
  GH_REPO_RESET_JOBS=2 run_snapshot_jobs "$tmp" pool_slow pool_fast pool_release
  [[ -e "$tmp/pool-slow.started" && -e "$tmp/pool-fast.started" && -e "$tmp/pool-third.started" && -e "$tmp/pool.release" ]]
  grep -Fqx 

  snapshot_stream "labels" fail_500 >/dev/null
  grep -Fxq 'labels' "$tmp/snapshot-failures.txt"
  grep -Fqx $'labels\tfailed' "$tmp/snapshot-status.tsv"
  grep -q 'HTTP 500' "$tmp/snapshot-errors.log"

  snapshot_capture_optional_404 "$tmp/pages.json" "Pages configuration" fail_404 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -Fqx $'Pages configuration\tabsent' "$tmp/snapshot-status.tsv"
  ! grep -Fq 'Pages configuration' "$tmp/snapshot-failures.txt"
  [[ ! -e "$tmp/pages.json" ]]

  rc=0
  snapshot_capture_optional_404 "$tmp/deployment-branch-policies.tsv" "environment Preview deployment branch policies" fail_404 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -Fqx $'environment Preview deployment branch policies\tabsent' "$tmp/snapshot-status.tsv"
  ! grep -Fq 'environment Preview deployment branch policies' "$tmp/snapshot-failures.txt"
  [[ ! -e "$tmp/deployment-branch-policies.tsv" ]]

  snapshot_capture_optional_pattern "$tmp/selected-actions.json" "selected Actions" 'Conflict' fail_conflict
  grep -Fqx $'selected Actions\tabsent' "$tmp/snapshot-status.tsv"
  [[ ! -e "$tmp/selected-actions.json" ]]

  grep -Fq 'snapshot_capture_optional_404 "$envdir/deployment-branch-policies.tsv"' ./lib/snapshot.sh
  grep -q 'snapshot-status.tsv' ./lib/main.sh
  grep -Fq "[[:space:]]failed$" ./lib/main.sh
  echo 'snapshot-guard: ok'
)

test_resume_journal() (
  set -Eeuo pipefail
  local tmp calls
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  REPO=owner/repo
  BACKUP_DIR="$tmp"
  SECRETS_DIR=""
  : > "$tmp/restore-failures.txt"
  : > "$tmp/restore-errors.log"
  source ./lib/core.sh
  source ./lib/integrations.sh

  create_once() { printf 'create\n' >> "$tmp/create.log"; }
  restore_once "ruleset:42" "restoring test ruleset" create_once
  restore_once "ruleset:42" "restoring test ruleset" create_once
  [[ "$(wc -l < "$tmp/create.log")" -eq 1 ]]
  [[ "$(grep -Fxc 'ruleset:42' "$tmp/restore-completed.txt")" -eq 1 ]]
  [[ ! -f "$tmp/restore-pending.txt" || ! -s "$tmp/restore-pending.txt" ]]

  printf 'ruleset:99\n' > "$tmp/restore-pending.txt"
  restore_once "ruleset:99" "restoring interrupted test ruleset" create_once
  [[ "$(wc -l < "$tmp/create.log")" -eq 1 ]]
  grep -Fq 'restoring interrupted test ruleset (unfinished prior attempt)' "$tmp/restore-failures.txt"

  mkdir -p "$tmp/webhooks/1"
  cat > "$tmp/webhooks/1/state.sh" <<'STATE_EOF'
OLD_HOOK_ID=1234
HOOK_SECRET_STATUS=unsigned
STATE_EOF
  printf '{"name":"web","active":true,"events":["push"],"config":{"url":"https://example.test/hook","content_type":"json","insecure_ssl":"0"}}\n' > "$tmp/webhooks/1/create.json"

  api() {
    local args=" $* "
    if [[ "$args" == *" --method POST repos/owner/repo/hooks "* ]]; then
      printf 'post\n' >> "$tmp/webhook-posts.log"
      printf '9001\n'
      return 0
    fi
    return 0
  }

  restore_webhooks "$tmp"
  restore_webhooks "$tmp"
  [[ "$(wc -l < "$tmp/webhook-posts.log")" -eq 1 ]]
  [[ "$(cat "$tmp/webhooks/1/restored-id")" == 9001 ]]

  mkdir -p "$tmp/webhooks/2"
  cat > "$tmp/webhooks/2/state.sh" <<'STATE_EOF'
OLD_HOOK_ID=5678
HOOK_SECRET_STATUS=unsigned
STATE_EOF
  cp "$tmp/webhooks/1/create.json" "$tmp/webhooks/2/create.json"
  printf 'webhook:5678\n' >> "$tmp/restore-pending.txt"
  restore_webhooks "$tmp"
  [[ "$(wc -l < "$tmp/webhook-posts.log")" -eq 1 ]]
  grep -Fq 'webhook 5678 (unfinished prior attempt)' "$tmp/restore-failures.txt"
  echo 'resume-journal: ok'
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
    packages) test_packages ;;
    org-bindings) test_org_bindings ;;
    environment) test_environment ;;
    deploy-key) test_deploy_key ;;
    snapshot-guard) test_snapshot_guard ;;
    resume-journal) test_resume_journal ;;
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
    for name in syntax self legacy git labels packages org-bindings environment deploy-key snapshot-guard resume-journal dry-run org reset pipe; do
      run_suite "$name"
    done
    echo 'tests: ok'
    ;;
  syntax|self|legacy|git|labels|packages|org-bindings|environment|deploy-key|snapshot-guard|resume-journal|dry-run|org|reset|pipe)
    run_suite "$suite"
    ;;
  *)
    printf 'usage: %s [all|syntax|self|legacy|git|labels|packages|org-bindings|environment|deploy-key|snapshot-guard|resume-journal|dry-run|org|reset|pipe]\n' "$0" >&2
    exit 2
    ;;
esac
organization selected-repository bindings\tcaptured' "$tmp/snapshot-status.tsv"
  [[ ! -s "$tmp/snapshot-failures.txt" ]]
  echo 'org-bindings: ok'
)

test_environment() (
  set -Eeuo pipefail
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  API_VERSION=2026-03-10
  VERBOSE=0
  REPO=owner/repo
  BACKUP_DIR="$tmp"
  mkdir -p "$tmp/environments/1/variables"
  cat > "$tmp/environments/1/state.sh" <<'STATE_EOF'
ENV_NAME=copilot
ENV_KEY=copilot
STATE_EOF
  cat > "$tmp/environments/1/environment-restore.json" <<'JSON_EOF'
{"wait_timer":0,"prevent_self_review":false,"reviewers":[],"deployment_branch_policy":null}
JSON_EOF
  cat > "$tmp/environments/1/environment.json" <<'JSON_EOF'
{"name":"copilot","protection_rules":[],"deployment_branch_policy":null}
JSON_EOF

  source ./lib/core.sh
  source ./lib/report.sh
  source ./lib/restore.sh

  gh() {
    local args=" $* " input="" prev=""
    printf '%s\n' "$*" >> "$tmp/gh.log"
    for x in "$@"; do
      if [[ "$prev" == --input ]]; then input="$x"; prev=""; continue; fi
      [[ "$x" == --input ]] && prev=--input
    done
    if [[ "$args" == *" --method PUT repos/owner/repo/environments/copilot "* ]]; then
      if [[ -n "$input" && -f "$input" ]] && grep -q '"reviewers"' "$input"; then
        printf 'protection rules unavailable for private repository\n' >&2
        return 1
      fi
      return 0
    fi
    return 0
  }

  restore_environments "$tmp"

  [[ "$(grep -c -- '--method PUT repos/owner/repo/environments/copilot' "$tmp/gh.log")" -eq 2 ]]
  [[ ! -s "$tmp/restore-failures.txt" || ! -f "$tmp/restore-failures.txt" ]]
  [[ ! -f "$tmp/manual-items.tsv" || ! -s "$tmp/manual-items.tsv" ]]

  rm -f "$tmp/environments/1/environment.json"
  cat > "$tmp/environments/1/environment-restore.json" <<'JSON_EOF'
{"prevent_self_review":false,"reviewers":[{"type":"User","id":42}],"deployment_branch_policy":null}
JSON_EOF
  : > "$tmp/gh.log"
  restore_environments "$tmp"
  grep -q '^environment_policy[[:space:]]' "$tmp/manual-items.tsv"
  [[ ! -s "$tmp/restore-failures.txt" || ! -f "$tmp/restore-failures.txt" ]]
  echo 'environment: ok'
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

test_snapshot_guard() (
  set -Eeuo pipefail
  local tmp rc=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  BACKUP_DIR="$tmp"
  : > "$tmp/snapshot-status.tsv"
  : > "$tmp/snapshot-failures.txt"
  : > "$tmp/snapshot-errors.log"
  source ./lib/core.sh

  succeed() { printf '{"ok":true}\n'; }
  fail_500() { printf 'HTTP 500: transient failure\n' >&2; return 1; }
  fail_404() { printf 'HTTP 404: Not Found\n' >&2; return 1; }
  fail_conflict() { printf 'HTTP 409: Conflict\n' >&2; return 1; }

  snapshot_capture "$tmp/repository.json" "repository settings" succeed
  grep -Fqx $'repository settings\tcaptured' "$tmp/snapshot-status.tsv"
  [[ -s "$tmp/repository.json" ]]

  pool_slow() {
    local dir="$1" i
    record_snapshot_status "pool slow" captured
    : > "$dir/pool-slow.started"
    for ((i=0; i<200; i++)); do
      [[ -e "$dir/pool.release" ]] && return 0
      sleep 0.01
    done
    return 1
  }
  pool_fast() {
    record_snapshot_status "pool fast" captured
    : > "$1/pool-fast.started"
  }
  pool_release() {
    record_snapshot_status "pool release" captured
    : > "$1/pool-third.started"
    : > "$1/pool.release"
  }
  GH_REPO_RESET_JOBS=2 run_snapshot_jobs "$tmp" pool_slow pool_fast pool_release
  [[ -e "$tmp/pool-slow.started" && -e "$tmp/pool-fast.started" && -e "$tmp/pool-third.started" && -e "$tmp/pool.release" ]]
  grep -Fqx 

  snapshot_stream "labels" fail_500 >/dev/null
  grep -Fxq 'labels' "$tmp/snapshot-failures.txt"
  grep -Fqx $'labels\tfailed' "$tmp/snapshot-status.tsv"
  grep -q 'HTTP 500' "$tmp/snapshot-errors.log"

  snapshot_capture_optional_404 "$tmp/pages.json" "Pages configuration" fail_404 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -Fqx $'Pages configuration\tabsent' "$tmp/snapshot-status.tsv"
  ! grep -Fq 'Pages configuration' "$tmp/snapshot-failures.txt"
  [[ ! -e "$tmp/pages.json" ]]

  rc=0
  snapshot_capture_optional_404 "$tmp/deployment-branch-policies.tsv" "environment Preview deployment branch policies" fail_404 || rc=$?
  [[ "$rc" -eq 2 ]]
  grep -Fqx $'environment Preview deployment branch policies\tabsent' "$tmp/snapshot-status.tsv"
  ! grep -Fq 'environment Preview deployment branch policies' "$tmp/snapshot-failures.txt"
  [[ ! -e "$tmp/deployment-branch-policies.tsv" ]]

  snapshot_capture_optional_pattern "$tmp/selected-actions.json" "selected Actions" 'Conflict' fail_conflict
  grep -Fqx $'selected Actions\tabsent' "$tmp/snapshot-status.tsv"
  [[ ! -e "$tmp/selected-actions.json" ]]

  grep -Fq 'snapshot_capture_optional_404 "$envdir/deployment-branch-policies.tsv"' ./lib/snapshot.sh
  grep -q 'snapshot-status.tsv' ./lib/main.sh
  grep -Fq "[[:space:]]failed$" ./lib/main.sh
  echo 'snapshot-guard: ok'
)

test_resume_journal() (
  set -Eeuo pipefail
  local tmp calls
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  PROGRAM=gh-repo-reset-test
  VERBOSE=0
  REPO=owner/repo
  BACKUP_DIR="$tmp"
  SECRETS_DIR=""
  : > "$tmp/restore-failures.txt"
  : > "$tmp/restore-errors.log"
  source ./lib/core.sh
  source ./lib/integrations.sh

  create_once() { printf 'create\n' >> "$tmp/create.log"; }
  restore_once "ruleset:42" "restoring test ruleset" create_once
  restore_once "ruleset:42" "restoring test ruleset" create_once
  [[ "$(wc -l < "$tmp/create.log")" -eq 1 ]]
  [[ "$(grep -Fxc 'ruleset:42' "$tmp/restore-completed.txt")" -eq 1 ]]
  [[ ! -f "$tmp/restore-pending.txt" || ! -s "$tmp/restore-pending.txt" ]]

  printf 'ruleset:99\n' > "$tmp/restore-pending.txt"
  restore_once "ruleset:99" "restoring interrupted test ruleset" create_once
  [[ "$(wc -l < "$tmp/create.log")" -eq 1 ]]
  grep -Fq 'restoring interrupted test ruleset (unfinished prior attempt)' "$tmp/restore-failures.txt"

  mkdir -p "$tmp/webhooks/1"
  cat > "$tmp/webhooks/1/state.sh" <<'STATE_EOF'
OLD_HOOK_ID=1234
HOOK_SECRET_STATUS=unsigned
STATE_EOF
  printf '{"name":"web","active":true,"events":["push"],"config":{"url":"https://example.test/hook","content_type":"json","insecure_ssl":"0"}}\n' > "$tmp/webhooks/1/create.json"

  api() {
    local args=" $* "
    if [[ "$args" == *" --method POST repos/owner/repo/hooks "* ]]; then
      printf 'post\n' >> "$tmp/webhook-posts.log"
      printf '9001\n'
      return 0
    fi
    return 0
  }

  restore_webhooks "$tmp"
  restore_webhooks "$tmp"
  [[ "$(wc -l < "$tmp/webhook-posts.log")" -eq 1 ]]
  [[ "$(cat "$tmp/webhooks/1/restored-id")" == 9001 ]]

  mkdir -p "$tmp/webhooks/2"
  cat > "$tmp/webhooks/2/state.sh" <<'STATE_EOF'
OLD_HOOK_ID=5678
HOOK_SECRET_STATUS=unsigned
STATE_EOF
  cp "$tmp/webhooks/1/create.json" "$tmp/webhooks/2/create.json"
  printf 'webhook:5678\n' >> "$tmp/restore-pending.txt"
  restore_webhooks "$tmp"
  [[ "$(wc -l < "$tmp/webhook-posts.log")" -eq 1 ]]
  grep -Fq 'webhook 5678 (unfinished prior attempt)' "$tmp/restore-failures.txt"
  echo 'resume-journal: ok'
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
    packages) test_packages ;;
    org-bindings) test_org_bindings ;;
    environment) test_environment ;;
    deploy-key) test_deploy_key ;;
    snapshot-guard) test_snapshot_guard ;;
    resume-journal) test_resume_journal ;;
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
    for name in syntax self legacy git labels packages org-bindings environment deploy-key snapshot-guard resume-journal dry-run org reset pipe; do
      run_suite "$name"
    done
    echo 'tests: ok'
    ;;
  syntax|self|legacy|git|labels|packages|org-bindings|environment|deploy-key|snapshot-guard|resume-journal|dry-run|org|reset|pipe)
    run_suite "$suite"
    ;;
  *)
    printf 'usage: %s [all|syntax|self|legacy|git|labels|packages|org-bindings|environment|deploy-key|snapshot-guard|resume-journal|dry-run|org|reset|pipe]\n' "$0" >&2
    exit 2
    ;;
esac
