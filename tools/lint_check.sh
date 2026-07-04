#!/usr/bin/env bash
# Static Code Analyzer & Linter Wrapper — the ONLY sanctioned lint entry point.
set -uo pipefail

FRAMEWORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$FRAMEWORK_DIR/.." && pwd)"

# Target directory resolution (highest to lowest precedence): --dir flag,
# WORKTREE env var, default to the read-only product-repo clone. This lets
# Developer/QA agents point the runner at worktrees/task-{id}/ instead.
TARGET_DIR="${WORKTREE:-}"
if [ "${1:-}" = "--dir" ]; then
  TARGET_DIR="$2"
  shift 2
fi
REPO_DIR="${TARGET_DIR:-$WORKSPACE_DIR/product-repo}"
case "$REPO_DIR" in
  /*) : ;;
  *) REPO_DIR="$WORKSPACE_DIR/$REPO_DIR" ;;
esac

if [ ! -d "$REPO_DIR" ]; then
  echo "lint_check.sh: target directory not found at $REPO_DIR." >&2
  exit 2
fi

cd "$REPO_DIR"

# Project-specific override takes absolute precedence.
if [ -x "./scripts/agent-lint.sh" ]; then
  exec ./scripts/agent-lint.sh "$@"
fi

if [ -f "package.json" ] && grep -q '"lint"' package.json; then
  exec npm run lint -- "$@"
elif [ -f "pyproject.toml" ] && command -v ruff >/dev/null 2>&1; then
  exec ruff check . "$@"
elif ls ./*.py >/dev/null 2>&1 && command -v ruff >/dev/null 2>&1; then
  exec ruff check . "$@"
elif [ -f "go.mod" ]; then
  gofmt -l . | tee /dev/stderr | (! grep -q .) && exec go vet ./...
  exit 1
elif [ -f "Cargo.toml" ]; then
  exec cargo clippy -- -D warnings
fi

echo "lint_check.sh: could not detect a linter for product-repo." >&2
echo "Add an executable scripts/agent-lint.sh to product-repo, or extend this wrapper." >&2
exit 2
