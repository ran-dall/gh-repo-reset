#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/tmp" "$TMP/source"
/usr/bin/git -C "$TMP/source" init -b main >/dev/null
printf 'one\n' >"$TMP/source/file.txt"
/usr/bin/git -C "$TMP/source" add file.txt
/usr/bin/git -C "$TMP/source" -c user.name=Tester -c user.email=test@example.com commit -m one >/dev/null
printf 'two\n' >>"$TMP/source/file.txt"
/usr/bin/git -C "$TMP/source" add file.txt
/usr/bin/git -C "$TMP/source" -c user.name=Tester -c user.email=test@example.com commit -m two >/dev/null

cat >"$TMP/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=" $* "
[[ -n "${MOCK_GH_LOG:-}" ]] && printf '%s\n' "$*" >>"$MOCK_GH_LOG"

# Streamed launcher bootstrap: serve the GraphQL lib-tree fast path.
emit_tsv_body() {
  local file="$1"
  awk '
    BEGIN { first=1 }
    {
      gsub(/\\/, "\\\\")
      gsub(/\t/, "\\t")
      if (!first) printf "\\n"
      printf "%s", $0
      first=0
    }
    END { printf "\\n" }
  ' "$file"
}
if [[ "$args" == *" api graphql "* ]]; then
  for module in core.sh snapshot.sh git.sh report.sh safety.sh restore.sh integrations.sh followup.sh main.sh; do
    printf '%s\tfalse\t' "$module"
    emit_tsv_body "$MOCK_MODULE_DIR/$module"
    printf '\n'
  done
  exit 0
fi

# REST compatibility fallback.
for x in "$@"; do
  case "$x" in
    repos/ran-dall/gh-repo-reset/contents/lib/*)
      endpoint="${x%%\?*}"
      module="${endpoint##*/}"
      cat "$MOCK_MODULE_DIR/$module"
      exit 0
      ;;
  esac
done
if [[ "$args" == *" auth status "* || "$args" == *" auth setup-git "* ]]; then exit 0; fi
if [[ "$args" == *" repo view "* ]]; then printf 'owner/repo\n'; exit 0; fi
if [[ "$args" == *" repo deploy-key list "* ]]; then exit 0; fi
if [[ "$args" == *" variable list "* ]]; then exit 0; fi
if [[ "$args" == *" secret list "* ]]; then
  if [[ "$args" == *" --app codespaces "* && "${MOCK_CONFIG:-0}" == 1 ]]; then
    [[ "$args" == *" --jq "* ]] && printf 'CODE_SECRET\n' || printf '[{"name":"CODE_SECRET","updatedAt":"2026-01-01T00:00:00Z"}]\n'
  fi
  exit 0
fi
if [[ "$args" == *" label list "* ]]; then exit 0; fi
if [[ "$args" == *" repo autolink list "* ]]; then exit 0; fi
if [[ "$args" == *" repo clone "* ]]; then /usr/bin/git clone --mirror "$MOCK_SOURCE" "$4" >/dev/null 2>&1; exit 0; fi
if [[ "$args" == *" repo delete "* || "$args" == *" repo create "* || "$args" == *" repo edit "* || "$args" == *" repo archive "* || "$args" == *" repo deploy-key add "* || "$args" == *" variable set "* || "$args" == *" secret set "* || "$args" == *" label delete "* || "$args" == *" label create "* ]]; then exit 0; fi
if [[ "$args" == *" api "* ]]; then
  endpoint=""; jqexpr=""; prev=""
  for x in "$@"; do
    if [[ "$prev" == "--jq" ]]; then jqexpr="$x"; prev=""; continue; fi
    if [[ "$x" == "--jq" ]]; then prev="--jq"; continue; fi
    case "$x" in repos/*|users/*|user|user/*|orgs/*) endpoint="$x" ;; esac
  done
  if [[ "$endpoint" == user ]]; then printf 'tester\n'; exit 0; fi
  if [[ "$endpoint" == users/* ]]; then printf '%s\n' "${MOCK_OWNER_TYPE:-User}"; exit 0; fi
  if [[ "$endpoint" == repos/*/code-security-configuration && "${MOCK_NO_CODE_SECURITY:-0}" == 1 ]]; then exit 0; fi
  if [[ "$endpoint" == user/installations\?per_page=100 && "${MOCK_CONFIG:-0}" == 1 && "$jqexpr" == *'.installations[]?'* ]]; then
    printf '77\tselected\tdemo-app\n'; exit 0
  fi
  if [[ "$endpoint" == user/installations/77/repositories\?per_page=100 && "${MOCK_CONFIG:-0}" == 1 && "$jqexpr" == *'.repositories[]?.id'* ]]; then
    printf '123\n'; exit 0
  fi
  if [[ "$endpoint" == repos/* && "$jqexpr" == *'assign("OWNER_TYPE"'* ]]; then
    cat <<'STATE_EOF'
OWNER_TYPE='User'
REPO_ID='123'
DESCRIPTION='demo'
HOMEPAGE=''
VISIBILITY='private'
DEFAULT_BRANCH='main'
HAS_ISSUES='true'
HAS_PROJECTS='true'
HAS_WIKI='false'
HAS_DISCUSSIONS='false'
ALLOW_SQUASH='true'
ALLOW_MERGE='true'
ALLOW_REBASE='true'
ALLOW_AUTO_MERGE='false'
DELETE_BRANCH_ON_MERGE='false'
ALLOW_UPDATE_BRANCH='false'
ALLOW_FORKING='false'
HAS_DOWNLOADS='false'
HAS_PULL_REQUESTS='true'
PULL_REQUEST_CREATION_POLICY='all'
SQUASH_MERGE_COMMIT_TITLE='COMMIT_OR_PR_TITLE'
SQUASH_MERGE_COMMIT_MESSAGE='COMMIT_MESSAGES'
MERGE_COMMIT_TITLE='MERGE_MESSAGE'
MERGE_COMMIT_MESSAGE='PR_TITLE'
WEB_COMMIT_SIGNOFF='false'
IS_TEMPLATE='false'
ARCHIVED='false'
IS_FORK='false'
STARGAZERS='0'
FORKS='0'
ADVANCED_SECURITY='unknown'
CODE_SECURITY='unknown'
SECRET_SCANNING='unknown'
PUSH_PROTECTION='unknown'
SECRET_SCANNING_AI='unknown'
SECRET_SCANNING_NON_PROVIDER='unknown'
SECRET_SCANNING_DELEGATED_DISMISSAL='unknown'
SECRET_SCANNING_DELEGATED_BYPASS='unknown'
STATE_EOF
    exit 0
  fi
  if [[ "$endpoint" == repos/*/pages ]]; then printf 'HTTP 404: Not Found\n' >&2; exit 1; fi
  case "$jqexpr" in
    *'.id'*) printf '123\n' ;;
    *'.description'*) printf 'demo\n' ;;
    *'.homepage'*) printf '\n' ;;
    *'.visibility'*) printf 'private\n' ;;
    *'.default_branch'*) printf 'main\n' ;;
    *'.has_issues'*) printf 'true\n' ;;
    *'.has_projects'*) printf 'true\n' ;;
    *'.has_wiki'*) printf 'false\n' ;;
    *'.has_discussions'*) printf 'false\n' ;;
    *'.allow_squash_merge'*) printf 'true\n' ;;
    *'.allow_merge_commit'*) printf 'true\n' ;;
    *'.allow_rebase_merge'*) printf 'true\n' ;;
    *'.allow_auto_merge'*) printf 'false\n' ;;
    *'.delete_branch_on_merge'*) printf 'false\n' ;;
    *'.allow_update_branch'*) printf 'false\n' ;;
    *'.allow_forking'*) printf 'false\n' ;;
    *'.has_downloads'*) printf 'false\n' ;;
    *'.has_pull_requests'*) printf 'true\n' ;;
    *'.web_commit_signoff_required'*) printf 'false\n' ;;
    *'.is_template'*) printf 'false\n' ;;
    *'.archived'*) printf 'false\n' ;;
    *'.fork // false'*) printf 'false\n' ;;
    *'.stargazers_count'*) printf '0\n' ;;
    *'.forks_count'*) printf '0\n' ;;
    *'.security_and_analysis'*) printf 'unknown\n' ;;
    *'.names[]?'*|*'.environments[].name'*|*'.[].name'*|*'.[].id'*|*'.policies[]?'*|*'@tsv'*|*'.[0].'*) : ;;
    *'.total_count'*) printf '0\n' ;;
    '') printf '{}\n' ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi
printf 'unexpected mock gh invocation:' >&2; printf ' %q' "$@" >&2; printf '\n' >&2; exit 99
GH_EOF
chmod +x "$TMP/bin/gh"
cat >"$TMP/bin/git" <<'GIT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --mirror ]]; then exit 1; fi
if [[ "${1:-}" == lfs ]]; then exit 1; fi
exec /usr/bin/git "$@"
GIT_EOF
chmod +x "$TMP/bin/git"
cat >"$TMP/bin/xdg-open" <<'OPEN_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$MOCK_OPEN_LOG"
OPEN_EOF
chmod +x "$TMP/bin/xdg-open"
cat >"$TMP/bin/date" <<'DATE_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == "-u +%Y%m%dT%H%M%SZ" ]]; then
  printf '20261006T000000Z\n'
else
  exec /usr/bin/date "$@"
fi
DATE_EOF
chmod +x "$TMP/bin/date"
mkdir -p "$TMP/tmp/gh-repo-reset/owner__repo/20261006T000000Z"
export MOCK_SOURCE="$TMP/source" MOCK_GH_LOG="$TMP/gh.log" MOCK_MODULE_DIR="$PWD/lib" MOCK_OPEN_LOG="$TMP/open.log"
if [[ "${PIPE_MODE:-0}" == 1 ]]; then
  cat ./gh-repo-reset | PATH="$TMP/bin:$PATH" XDG_STATE_HOME="$TMP/state" TMPDIR="$TMP/tmp" MOCK_SOURCE="$MOCK_SOURCE" MOCK_GH_LOG="$MOCK_GH_LOG" MOCK_MODULE_DIR="$MOCK_MODULE_DIR" MOCK_OPEN_LOG="$MOCK_OPEN_LOG" bash -s -- owner/repo --dry-run "$@" >"$TMP/out" 2>"$TMP/err"
else
  PATH="$TMP/bin:$PATH" XDG_STATE_HOME="$TMP/state" TMPDIR="$TMP/tmp" MOCK_OPEN_LOG="$MOCK_OPEN_LOG" ./gh-repo-reset owner/repo --dry-run "$@" >"$TMP/out" 2>"$TMP/err"
fi
grep -q 'Dry run complete' "$TMP/err"
grep -q 'Plan:' "$TMP/err"
if [[ "${MOCK_CONFIG:-0}" == 1 ]]; then
  if [[ " $* " == *" --allow-metadata-loss "* ]]; then
    ! grep -q 'A real reset requires --allow-metadata-loss' "$TMP/err"
  else
    grep -q 'A real reset requires --allow-metadata-loss' "$TMP/err"
  fi
fi
! grep -q 'Automatically handled when GitHub exposes enough information' "$TMP/err"
if [[ " $* " == *" --verbose "* ]]; then
  grep -q 'Detected:' "$TMP/err"
  grep -q 'Prepared fresh root commit' "$TMP/err"
  grep -q 'Plan \[auto\]' "$TMP/err"
else
  ! grep -q 'Detected:' "$TMP/err"
  ! grep -q 'Prepared fresh root commit' "$TMP/err"
  ! grep -q 'Plan \[auto\]' "$TMP/err"
fi
! grep -q 'Deleting owner/repo' "$TMP/err"
BACKUP="$(find "$TMP/tmp/gh-repo-reset/owner__repo" -mindepth 1 -maxdepth 1 -type d ! -name '20261006T000000Z' | head -1)"
[[ -n "$BACKUP" && "${BACKUP##*/}" == 20261006T000000Z.* ]]
[[ -d "$BACKUP/git.git" && -f "$BACKUP/initial-commit.txt" && -f "$BACKUP/repo-state.sh" ]]
# shellcheck disable=SC1090
source "$BACKUP/repo-state.sh"
[[ "$ALLOW_FORKING" == false ]]
[[ "$HAS_DOWNLOADS" == false ]]
[[ "$HAS_PULL_REQUESTS" == true ]]
ROOT="$(cat "$BACKUP/initial-commit.txt")"
[[ "$(/usr/bin/git -C "$BACKUP/git.git" rev-list --parents -n1 "$ROOT" | awk '{print NF-1}')" -eq 0 ]]
[[ "$(/usr/bin/git -C "$BACKUP/git.git" rev-parse "$ROOT^{tree}")" == "$(/usr/bin/git -C "$BACKUP/git.git" rev-parse 'refs/heads/main^{tree}')" ]]
grep -q -- '--app codespaces' "$TMP/gh.log"
[[ ! -s "$TMP/open.log" ]]
echo 'mock dry-run: ok'
