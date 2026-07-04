#!/usr/bin/env bash
# Lint contract for the framework repo itself (consumed by tools/lint_check.sh
# when THIS repo is the product-repo of a workspace).
# Exit codes per SPEC §8: 0=pass, 1=fail, 2=cannot run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }

python3 -m compileall -q "$ROOT/tools" "$ROOT/orchestrator.py" || exit 1
for sh in "$ROOT"/tools/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$sh" || exit 1
done
# pyflakes when available (not required — sandbox may not have it)
if python3 -c "import pyflakes" 2>/dev/null; then
  python3 -m pyflakes "$ROOT/tools"/*.py "$ROOT/orchestrator.py" || exit 1
fi
echo "lint OK"
exit 0
