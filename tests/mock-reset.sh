#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/source"
/usr/bin/git -C "$TMP/source" init -b main >/dev/null
printf 'first\n' >"$TMP/source/app.txt"
printf 'FROM ghcr.io/owner/repo:latest\n' >"$TMP/source/Dockerfile"
/usr/bin/git -C "$TMP/source" add app.txt Dockerfile
/usr/bin/git -C "$TMP/source" -c user.name=Tester -c user.email=test@example.com commit -m first >/dev/null
printf 'second\n' >>"$TMP/source/app.txt"
/usr/bin/git -C "$TMP/source" add app.txt
/usr/bin/git -C "$TMP/source" -c user.name=Tester -c user.email=test@example.com commit -m second >/dev/null
export MOCK_CONFIG=1
# Reuse the dry-run mock gh by extracting the heredoc body from that test.
awk '/^cat >"\$TMP\/bin\/gh" <<'\''GH_EOF'\''/{f=1;next}/^GH_EOF$/{if(f){exit}}f' tests/mock-dry-run.sh >"$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
cat >"$TMP/bin/git" <<'GIT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == clone && "${2:-}" == --mirror ]]; then exit 1; fi
if [[ "${1:-}" == lfs ]]; then exit 1; fi
args=" $* "
if [[ "$args" == *" ls-remote origin refs/heads/main "* ]]; then
  [[ -n "${MOCK_REMOTE_SHA:-}" ]] && printf '%s\trefs/heads/main\n' "$MOCK_REMOTE_SHA"
  exit 0
fi
if [[ "$args" == *" push "* ]]; then
  [[ "$args" != *" --mirror "* ]] || { echo 'unexpected main mirror push' >&2; exit 90; }
  repo=""; prev=""
  for x in "$@"; do
    if [[ "$prev" == -C ]]; then repo="$x"; prev=""; continue; fi
    [[ "$x" == -C ]] && prev=-C
  done
  commit="$(/usr/bin/git -C "$repo" rev-parse refs/gh-repo-reset/initial)"
  [[ "$(/usr/bin/git -C "$repo" rev-list --parents -n1 "$commit" | awk '{print NF-1}')" -eq 0 ]]
  [[ "$(/usr/bin/git -C "$repo" log -1 --format=%s "$commit")" == 'Initial commit' ]]
  [[ "$(/usr/bin/git -C "$repo" rev-parse "$commit^{tree}")" == "$(/usr/bin/git -C "$repo" rev-parse 'refs/heads/main^{tree}')" ]]
  printf 'root-push-ok\n' >>"$MOCK_GIT_LOG"; exit 0
fi
exec /usr/bin/git "$@"
GIT_EOF
chmod +x "$TMP/bin/git"
export MOCK_SOURCE="$TMP/source" MOCK_GH_LOG="$TMP/gh.log" MOCK_GIT_LOG="$TMP/git.log"
PATH="$TMP/bin:$PATH" XDG_STATE_HOME="$TMP/state" MOCK_CONFIG=1 ./gh-repo-reset owner/repo --yes --allow-metadata-loss --no-open >"$TMP/out" 2>"$TMP/err"
grep -q 'repo delete owner/repo --yes' "$TMP/gh.log"
grep -q -- '--method DELETE users/owner/packages/container/repo' "$TMP/gh.log"
package_delete_line="$(grep -n -- '--method DELETE users/owner/packages/container/repo' "$TMP/gh.log" | head -1 | cut -d: -f1)"
repo_delete_line="$(grep -n 'repo delete owner/repo --yes' "$TMP/gh.log" | head -1 | cut -d: -f1)"
(( package_delete_line < repo_delete_line ))
grep -q 'repo create owner/repo --private' "$TMP/gh.log"
grep -q 'root-push-ok' "$TMP/git.log"
grep -q 'actions/permissions' "$TMP/gh.log"
grep -q 'properties/values' "$TMP/gh.log"
grep -q 'user/installations/77/repositories/123' "$TMP/gh.log"
[[ "$(grep -Fc -- '--jq .id' "$TMP/gh.log")" -eq 1 ]]
! grep -q 'Deleting 1 GitHub package(s)...' "$TMP/err"
! grep -q 'Deleting GitHub package container/repo' "$TMP/err"
grep -q 'Preparing reset: owner/repo' "$TMP/err"
! grep -q 'Snapshotting repository state' "$TMP/err"
grep -q 'Plan:' "$TMP/err"
grep -q 'Recreating owner/repo' "$TMP/err"
grep -q 'Restoring repository state' "$TMP/err"
grep -q 'Done. Backup:' "$TMP/err"

BACKUP="$(find "$TMP/state/gh-repo-reset/owner__repo" -mindepth 1 -maxdepth 1 -type d | head -1)"
ROOT="$(cat "$BACKUP/initial-commit.txt")"
PATH="$TMP/bin:$PATH" XDG_STATE_HOME="$TMP/state" MOCK_CONFIG=1 MOCK_REMOTE_SHA="$ROOT" ./gh-repo-reset --resume-from "$BACKUP" --no-open >"$TMP/resume.out" 2>"$TMP/resume.err"
grep -q 'Resuming reset: owner/repo' "$TMP/resume.err"
! grep -q 'Detected configuration restore completed.' "$TMP/resume.err"
grep -q 'Done. Backup:' "$TMP/resume.err"

echo 'mock reset: ok'
