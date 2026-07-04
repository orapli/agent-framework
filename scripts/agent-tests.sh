#!/usr/bin/env bash
# Test contract for the framework repo itself (consumed by tools/run_tests.sh
# when THIS repo is the product-repo of a workspace — self-hosted development).
# Exit codes per SPEC §8: 0=pass, 1=fail, 2=cannot run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }

echo "== 1/4 syntax: compile all python + bash -n all shell scripts"
python3 -m compileall -q "$ROOT/tools" "$ROOT/orchestrator.py" || exit 1
for sh in "$ROOT"/tools/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$sh" || exit 1
done

CLEANUP_PATHS=()
cleanup() { rm -rf "${CLEANUP_PATHS[@]}"; }
trap cleanup EXIT

echo "== 2/4 hub.py smoke test against a scratch register"
SC="$(mktemp -d)"
CLEANUP_PATHS+=("$SC")
mkdir -p "$SC/01_insights" "$SC/03_reports"
# Isolated fake product-repo: archive's merge-verification must never see the
# real workspace product-repo (which, in a dogfooding sandbox, may genuinely
# contain a merged PR from a coincidentally-matching branch name like
# "task-001" -- that would make this test's "unverifiable merge" assertion
# below pass for the wrong reason). No commits/no origin remote => both the
# ancestor check and the tree-hash check deterministically fail.
FAKE_PRODUCT="$(mktemp -d)"
CLEANUP_PATHS+=("$FAKE_PRODUCT")
git -C "$FAKE_PRODUCT" init -q
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

export AGENT_HUB_DIR="$SC" AGENT_CONFIG="$SC/config.json" AGENT_PRODUCT_DIR="$FAKE_PRODUCT"
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

echo "== 3/4 usage shape migration and --usd accumulation"
SC2="$(mktemp -d)"
CLEANUP_PATHS+=("$SC2")
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

echo "== 4/4 orchestrator.py smoke test (resolve_developer_cost_label, explorer_breaker_tripped)"
SC3="$(mktemp -d)"
CLEANUP_PATHS+=("$SC3")
mkdir -p "$SC3/01_insights"
cat > "$SC3/status.json" <<'EOF'
{"schema_version":1,"project_id":"smoke3","counters":{"insight_seq":0,"task_seq":0},
 "insights":{},"tasks":{},"agents":{},
 "log":[{"ts":"2026-01-01T00:00:00Z","agent":"developer-1-a","action":"claim","detail":"task_777"}]}
EOF
export AGENT_HUB_DIR="$SC3"
python3 - "$ROOT" <<'PYEOF' || fail "orchestrator.py resolve_developer_cost_label / explorer_breaker_tripped"
import sys, json
root = sys.argv[1]
sys.path.insert(0, root)
import orchestrator as o

class FakeRun:
    def __init__(self, persona, agent_id):
        self.persona, self.agent_id, self.cost_label = persona, agent_id, "developer_run"

r = FakeRun("developer", "developer-1-a")
got = o.resolve_developer_cost_label(r)
assert got == "task_777", f"expected task_777, got {got}"

r2 = FakeRun("developer", "developer-never-claimed")
got2 = o.resolve_developer_cost_label(r2)
assert got2 == "developer_run", f"never-claimed developer must fall back, got {got2}"

r3 = FakeRun("architect", "architect-1-x")
r3.cost_label = "architect_cycle"
got3 = o.resolve_developer_cost_label(r3)
assert got3 == "architect_cycle", f"non-developer persona must pass through unchanged, got {got3}"

cfg = {"system_settings": {}}
with open(o.INSIGHT_INDEX, "w") as f:
    json.dump([{"verdict": "rejected"}] * 8 + [{"verdict": "accepted"}] * 2, f)  # 10 entries, 20%
assert o.explorer_breaker_tripped(cfg) is False, "exactly-20% (boundary) must NOT trip"

with open(o.INSIGHT_INDEX, "w") as f:
    json.dump([{"verdict": "rejected"}] * 9 + [{"verdict": "accepted"}], f)  # 10%
assert o.explorer_breaker_tripped(cfg) is True, "10% acceptance must trip"

with open(o.INSIGHT_INDEX, "w") as f:
    json.dump([{"verdict": "accepted"}] * 3, f)  # below window (10), not enough history yet
assert o.explorer_breaker_tripped(cfg) is False, "under-window history must NOT trip"

print("orchestrator.py checks OK")
PYEOF
unset AGENT_HUB_DIR

echo "all smoke checks passed"
exit 0
