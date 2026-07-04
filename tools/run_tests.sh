#!/usr/bin/env bash
# Decoupled Local Test Executor — the ONLY sanctioned way for agents to run tests.
# Detects the product-repo project type and delegates to its native runner.
# Extra CLI args are passed through to the underlying runner (used by QA permutation testing).
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
  echo "run_tests.sh: target directory not found at $REPO_DIR." >&2
  exit 2
fi

cd "$REPO_DIR"

# Project-specific override: if the product repo ships its own contract script, defer to it.
if [ -x "./scripts/agent-tests.sh" ]; then
  exec ./scripts/agent-tests.sh "$@"
fi

if [ -f "package.json" ]; then
  if grep -q '"test"' package.json; then
    exec npm test -- "$@"
  fi
  echo "run_tests.sh: package.json has no test script." >&2
  exit 2
elif [ -f "pyproject.toml" ] || [ -f "pytest.ini" ] || [ -d "tests" ] && ls ./*.py >/dev/null 2>&1; then
  exec python3 -m pytest "$@"
elif [ -f "go.mod" ]; then
  exec go test ./... "$@"
elif [ -f "Cargo.toml" ]; then
  exec cargo test "$@"
elif [ -f "Gemfile" ]; then
  exec bundle exec rake test "$@"
elif [ -f "pom.xml" ]; then
  exec mvn -q test "$@"
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  exec ./gradlew test "$@"
fi

echo "run_tests.sh: could not detect a test runner for product-repo." >&2
echo "Add an executable scripts/agent-tests.sh to product-repo, or extend this wrapper." >&2
exit 2
