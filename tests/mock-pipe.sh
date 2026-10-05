#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
PIPE_MODE=1 ./tests/mock-dry-run.sh | grep -q 'mock dry-run: ok'
echo 'mock pipe: ok'
