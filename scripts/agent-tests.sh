#!/usr/bin/env bash
# Test contract for the framework repo itself (consumed by tools/run_tests.sh
# when THIS repo is the product-repo of a workspace — self-hosted development).
# Exit codes per SPEC §8: 0=pass, 1=fail, 2=cannot run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }

echo "== 1/3 syntax: compile all python + bash -n all shell scripts"
python3 -m compileall -q "$ROOT/tools" "$ROOT/orchestrator.py" || exit 1
for sh in "$ROOT"/tools/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$sh" || exit 1
done

echo "== 2/3 hub.py smoke test against a scratch register"
SC="$(mktemp -d)"
trap 'rm -rf "$SC"' EXIT
mkdir -p "$SC/01_insights" "$SC/03_reports"
cat > "$SC/status.json" <<'EOF'
{"schema_version":1,"project_id":"smoke","counters":{"insight_seq":0,"task_seq":0},
 "insights":{},"tasks":{},"agents":{},"log":[]}
EOF
cat > "$SC/config.json" <<'EOF'
{"system_settings":{"project_id":"smoke","concurrency_limit_developer":2,
 "lease_minutes":30,"max_attempts":3,"daily_token_budget":1000,"log_max_entries":100},
 "persona_model_mapping":{}}
EOF
cat > "$SC/i.json" <<'EOF'
{"insight_id":"insight_smoke001","category":"debt","severity":"low",
 "subject_paths":["x"],"observation":"s","impact":"s","suggested_direction":"s"}
EOF
cat > "$SC/t.json" <<'EOF'
{"task_id":"task_001","insight_id":"insight_smoke001","title":"smoke",
 "target_files":["x"],"status":"todo"}
EOF

export AGENT_HUB_DIR="$SC" AGENT_CONFIG="$SC/config.json"
HUB=(python3 "$ROOT/tools/hub.py" --agent-id smoke)

fail() { echo "SMOKE FAIL: $1" >&2; exit 1; }

"${HUB[@]}" add-insight --file "$SC/i.json" >/dev/null || fail "add-insight"
"${HUB[@]}" insight-verdict --insight insight_smoke001 --to rejected 2>/dev/null \
  && fail "verdict rejected without --reason must exit non-zero"
"${HUB[@]}" insight-verdict --insight insight_smoke001 --to accepted >/dev/null || fail "verdict"
"${HUB[@]}" add-task --file "$SC/t.json" >/dev/null || fail "add-task"
"${HUB[@]}" claim-task --persona developer | grep -q task_001 || fail "claim"
"${HUB[@]}" renew-lease --task task_001 >/dev/null || fail "renew-lease"
"${HUB[@]}" transition --task task_001 --to implemented >/dev/null || fail "->implemented"
"${HUB[@]}" transition --task task_001 --to review_failed --note n >/dev/null || fail "->review_failed"
"${HUB[@]}" show --task task_001 | grep -q '"status": "todo"' || fail "review_failed must cascade to todo"
"${HUB[@]}" claim-task --persona developer >/dev/null || fail "reclaim"
"${HUB[@]}" transition --task task_001 --to implemented >/dev/null || fail "->implemented(2)"
"${HUB[@]}" transition --task task_001 --to approved_by_architect >/dev/null || fail "->approved"
"${HUB[@]}" transition --task task_001 --to qa_passed >/dev/null || fail "->qa_passed"
"${HUB[@]}" transition --task task_001 --to pending_human_build >/dev/null || fail "->pending"
"${HUB[@]}" record-cost --task task_001 --tokens 42 >/dev/null || fail "record-cost"
echo "--- archive without --force must refuse: no real product-repo to verify a merge against ---"
"${HUB[@]}" archive --task task_001 2>/dev/null && fail "archive must refuse an unverifiable merge without --force"
"${HUB[@]}" archive --task task_001 --force >/dev/null || fail "archive --force"
grep -q "task_001" "$SC/digest.md" || fail "digest line"

echo "== 3/3 usage shape migration and --usd accumulation"
SC2="$(mktemp -d)"
trap 'rm -rf "$SC2"' EXIT
mkdir -p "$SC2/01_insights" "$SC2/03_reports"
# Seed a register with bare-int usage values to test int->object migration
cat > "$SC2/status.json" <<'EOF'
{"schema_version":1,"project_id":"smoke2","counters":{"insight_seq":0,"task_seq":0},
 "insights":{},"tasks":{},"agents":{},"log":[],
 "usage":{"per_task":{"task_x":7},"per_day":{"2026-01-01":3}}}
EOF
cat > "$SC2/config.json" <<'EOF'
{"system_settings":{"project_id":"smoke2","concurrency_limit_developer":2,
 "lease_minutes":30,"max_attempts":3,"daily_token_budget":1000,"log_max_entries":100},
 "persona_model_mapping":{}}
EOF
export AGENT_HUB_DIR="$SC2" AGENT_CONFIG="$SC2/config.json"
HUB2=(python3 "$ROOT/tools/hub.py" --agent-id smoke2)

# Trigger a load+save cycle via record-cost to exercise migration
"${HUB2[@]}" record-cost --task task_x --tokens 0 >/dev/null || fail "migration trigger"
# Verify bare ints were promoted to objects
python3 - "$SC2/status.json" <<'PYEOF' || fail "int->object migration"
import json, sys
d = json.load(open(sys.argv[1]))
u = d["usage"]
assert isinstance(u["per_task"]["task_x"], dict), "per_task value not migrated to dict"
assert u["per_task"]["task_x"]["tokens"] == 7, "per_task tokens wrong after migration"
assert u["per_task"]["task_x"].get("usd") == 0.0, "per_task usd not defaulted to 0.0"
assert isinstance(u["per_day"]["2026-01-01"], dict), "per_day value not migrated to dict"
assert u["per_day"]["2026-01-01"]["tokens"] == 3, "per_day tokens wrong after migration"
PYEOF
# Verify migration is idempotent (second load+save must not corrupt values)
"${HUB2[@]}" record-cost --task task_x --tokens 0 >/dev/null || fail "migration idempotency trigger"
python3 - "$SC2/status.json" <<'PYEOF' || fail "migration idempotency"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["usage"]["per_task"]["task_x"]["tokens"] == 7, "tokens changed on second migrate"
PYEOF

# Test --usd accumulation: two calls; verify cumulative totals
export AGENT_HUB_DIR="$SC2" AGENT_CONFIG="$SC2/config.json"
"${HUB2[@]}" record-cost --task task_acc --tokens 100 --usd 0.42 >/dev/null || fail "record-cost --usd first"
"${HUB2[@]}" record-cost --task task_acc --tokens 50 --usd 0.08 >/dev/null || fail "record-cost --usd second"
python3 - "$SC2/status.json" <<'PYEOF' || fail "--usd accumulation"
import json, sys
d = json.load(open(sys.argv[1]))
slot = d["usage"]["per_task"]["task_acc"]
assert slot["tokens"] == 150, f"tokens expected 150 got {slot['tokens']}"
assert abs(slot["usd"] - 0.5) < 1e-9, f"usd expected 0.5 got {slot['usd']}"
PYEOF
# Verify --usd omission is backward-compatible (exit 0, no crash)
"${HUB2[@]}" record-cost --task task_acc --tokens 10 >/dev/null || fail "record-cost omit --usd"

echo "all smoke checks passed"
exit 0
