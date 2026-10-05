#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

bash -n ./gh-repo-reset
for module in lib/*.sh; do
  bash -n "$module"
done

expected=(core.sh snapshot.sh git.sh safety.sh restore.sh integrations.sh followup.sh main.sh)
for module in "${expected[@]}"; do
  [[ -f "lib/$module" ]]
done

# Keep the launcher small; implementation belongs in modules.
(( $(wc -l < ./gh-repo-reset) < 150 ))

./gh-repo-reset --self-test | grep -q 'self-test: ok'
./gh-repo-reset --help | grep -q 'one fresh initial commit'
[[ "$(./gh-repo-reset --version)" == 'gh-repo-reset v0.0.0-1' ]]
./tests/mock-dry-run.sh
MOCK_OWNER_TYPE=Organization MOCK_NO_CODE_SECURITY=1 ./tests/mock-dry-run.sh
./tests/mock-reset.sh
./tests/mock-pipe.sh

# Local development is task-runner-only: no install target or Makefile.
[[ ! -e Makefile ]]
[[ -f mise.toml ]]
grep -q '^\[tasks\.test\]' mise.toml
grep -q 'run = "./tests/test.sh"' mise.toml

echo 'tests: ok' 
