#!/usr/bin/env bash
# Test contract for the framework repo itself (consumed by tools/run_tests.sh
# when THIS repo is the product-repo of a workspace — self-hosted development).
# Exit codes per SPEC §8: 0=pass, 1=fail, 2=cannot run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }

echo "== 1/6 syntax: compile all python + bash -n all shell scripts"
python3 -m compileall -q "$ROOT/tools" "$ROOT/orchestrator.py" || exit 1
for sh in "$ROOT"/tools/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$sh" || exit 1
done

CLEANUP_PATHS=()
cleanup() { rm -rf "${CLEANUP_PATHS[@]}"; }
trap cleanup EXIT

echo "== 2/6 hub.py smoke test against a scratch register"
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
cat > "$SC/i-github.json" <<'EOF'
{"insight_id":"insight_smoke002","category":"debt","severity":"low","source":"github#42",
 "subject_paths":["y"],"observation":"s","impact":"s","suggested_direction":"s"}
EOF

export AGENT_HUB_DIR="$SC" AGENT_CONFIG="$SC/config.json" AGENT_PRODUCT_DIR="$FAKE_PRODUCT"
HUB=(python3 "$ROOT/tools/hub.py" --agent-id smoke)

fail() { echo "SMOKE FAIL: $1" >&2; exit 1; }

"${HUB[@]}" add-insight --file "$SC/i.json" >/dev/null || fail "add-insight"
"${HUB[@]}" add-insight --file "$SC/i-github.json" >/dev/null || fail "add-insight (github-sourced)"
python3 - "$SC/status.json" <<'PYEOF' || fail "insight source field"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["insights"]["insight_smoke001"]["source"] is None, "insight without a source must default to null"
assert d["insights"]["insight_smoke002"]["source"] == "github#42", "github-sourced insight must record its source"
PYEOF
"${HUB[@]}" insight-verdict --insight insight_smoke001 --to rejected 2>/dev/null \
  && fail "verdict rejected without --reason must exit non-zero"
"${HUB[@]}" insight-verdict --insight insight_smoke001 --to accepted >/dev/null || fail "verdict"
"${HUB[@]}" add-task --file "$SC/t.json" >/dev/null || fail "add-task"
"${HUB[@]}" claim-task --persona developer | grep -q task_001 || fail "claim"
"${HUB[@]}" renew-lease --task task_001 >/dev/null || fail "renew-lease"
"${HUB[@]}" transition --task task_001 --to implemented >/dev/null || fail "->implemented"
"${HUB[@]}" transition --task task_001 --to review_failed --note n >/dev/null || fail "->review_failed"
"${HUB[@]}" show --task task_001 | grep -q '"status": "todo"' || fail "review_failed must cascade to todo"
# A --note transition's `detail` is the note text ("n"), not the task id --
# the log entry's separate `task` field must still identify task_001, or a
# per-task timeline built from `log` would silently miss this event.
python3 - "$SC/status.json" <<'PYEOF' || fail "log_event task field for a --note transition"
import json, sys
d = json.load(open(sys.argv[1]))
matches = [e for e in d["log"] if e.get("task") == "task_001" and e["action"] == "implemented->review_failed"]
assert matches, "review_failed transition's log entry must carry task='task_001' even though detail is just the note text"
PYEOF
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

echo "== 3/6 status.lock is NOT held during worktree/branch git cleanup (network I/O)"
SC_LOCK="$(mktemp -d)"
CLEANUP_PATHS+=("$SC_LOCK")
mkdir -p "$SC_LOCK/01_insights"
FAKE_PRODUCT2="$(mktemp -d)"
CLEANUP_PATHS+=("$FAKE_PRODUCT2")
git -C "$FAKE_PRODUCT2" init -q -b main
git -C "$FAKE_PRODUCT2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FAKE_PRODUCT2" checkout -q -b task-slow
git -C "$FAKE_PRODUCT2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed work"
git -C "$FAKE_PRODUCT2" checkout -q main
# A remote whose fetch takes several seconds. GIT_SSH_COMMAND intercepts the
# transport entirely (no real network egress -- ssh is never actually
# invoked, our script runs instead), so `git fetch origin task-slow` inside
# _reclaim_stale_branch is guaranteed to still be sleeping when we probe
# concurrently below.
git -C "$FAKE_PRODUCT2" remote add origin "ssh://slow-fake-host/repo.git"
SLOW_SSH="$SC_LOCK/slow-ssh.sh"
cat > "$SLOW_SSH" <<'EOF'
#!/usr/bin/env bash
sleep 5
exit 1
EOF
chmod +x "$SLOW_SSH"

cat > "$SC_LOCK/status.json" <<'EOF'
{"schema_version":1,"project_id":"lock-test","counters":{"insight_seq":0,"task_seq":0},
 "insights":{},
 "tasks":{
   "task_slow":{"insight_id":null,"title":"x","status":"in_progress","target_files":[],"assignee":"dev-1","branch":"task-slow","attempts":0,"lease_expires_at":"2099-01-01T00:00:00Z"},
   "task_other":{"insight_id":null,"title":"y","status":"todo","target_files":[],"assignee":null,"branch":null,"attempts":0,"lease_expires_at":null}
 },
 "agents":{},"log":[]}
EOF
cat > "$SC_LOCK/config.json" <<'EOF'
{"system_settings":{"project_id":"lock-test","concurrency_limit_developer":2,
 "lease_minutes":30,"max_attempts":3,"daily_token_budget":1000,"log_max_entries":100},
 "persona_model_mapping":{}}
EOF

export AGENT_HUB_DIR="$SC_LOCK" AGENT_CONFIG="$SC_LOCK/config.json" AGENT_PRODUCT_DIR="$FAKE_PRODUCT2"
GIT_SSH_COMMAND="$SLOW_SSH" python3 "$ROOT/tools/hub.py" --agent-id dev-1 transition --task task_slow --to todo >/dev/null 2>&1 &
SLOW_PID=$!

sleep 1   # let the background transition acquire+release status.lock and reach the slow git fetch
# python3 for timing, not `date +%s%3N` -- this system's uutils/coreutils
# `date` doesn't truncate %N to milliseconds the way GNU date does, so
# %s%3N silently prints (wrong-width) nanoseconds instead.
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
# claim-task DOES acquire status.lock (unlike `show`, which reads directly
# and would pass this test even if the lock were still held) -- a real
# probe of lock contention, not a no-op.
python3 "$ROOT/tools/hub.py" --agent-id prober claim-task --persona documenter >/dev/null 2>&1
END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
ELAPSED_MS=$((END_MS - START_MS))

wait "$SLOW_PID"
echo "concurrent claim-task took ${ELAPSED_MS}ms while task-slow's git fetch was sleeping in the background"
if [ "$ELAPSED_MS" -gt 2000 ]; then
  fail "status.lock appears to still be held during worktree/branch git cleanup (took ${ELAPSED_MS}ms, expected well under the 5s fetch sleep -- regression of change 42)"
fi
unset AGENT_HUB_DIR AGENT_CONFIG AGENT_PRODUCT_DIR

echo "== 4/6 usage shape migration and --usd accumulation"
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

echo "== 5/6 orchestrator.py smoke test (resolve_developer_cost_label, explorer_breaker_tripped)"
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

# hybrid mode: Mode B review / QA must dispatch separately and never appear
# in the hybrid session's own queue -- the whole point is the reviewer is
# never the same context as the implementer.
data = {
    "insights": {"insight_a": {"status": "proposed"}},
    "tasks": {
        "task_001": {"status": "implemented"},
        "task_002": {"status": "approved_by_architect"},
        "task_003": {"status": "todo"},
    },
}
cfg2 = {"persona_model_mapping": {
    "architect": {"model": "m-architect"}, "architect_review": {"model": "m-review"},
    "qa_tester": {"model": "m-qa"}, "developer": {"model": "m-dev"},
}}
review_dispatch = o.compute_hybrid_review_dispatch(data, [], cfg2)
personas_dispatched = {item[0] for item in review_dispatch}
assert personas_dispatched == {"architect", "qa_tester"}, \
    f"expected architect+qa_tester dispatched separately, got {personas_dispatched}"
architect_item = next(i for i in review_dispatch if i[0] == "architect")
assert architect_item[3] == "architect_review", \
    f"Mode B review must use the architect_review model key, got {architect_item[3]}"

hybrid_prompt = o.build_hybrid_session_prompt(data, cfg2)
assert "task_001" not in hybrid_prompt, "hybrid session must NOT queue the implemented task itself"
assert "task_002" not in hybrid_prompt, "hybrid session must NOT queue the approved task itself"
assert "insight_a" in hybrid_prompt and "task_003" in hybrid_prompt, \
    "hybrid session must still queue proposed insights and todo tasks"

# already-running architect/qa_tester must not be double-dispatched
already_running = [type("R", (), {"persona": "architect"})(), type("R", (), {"persona": "qa_tester"})()]
assert o.compute_hybrid_review_dispatch(data, already_running, cfg2) == [], \
    "must not re-dispatch architect/qa_tester while one is already running"

# github-issue-derived insights (SPEC 12.1) must sort ahead of self-generated
# ones in the Architect's verdict queue -- a confirmed user report outranks
# speculative exploration.
insights_mixed = {
    "insight_zzz_selfgen": {"status": "proposed", "source": None},
    "insight_aaa_selfgen": {"status": "proposed", "source": None},
    "insight_mmm_github":  {"status": "proposed", "source": "github#7"},
    "insight_done_already": {"status": "accepted", "source": None},
}
order = o._prioritize_proposed_insights(insights_mixed)
assert order == ["insight_mmm_github", "insight_aaa_selfgen", "insight_zzz_selfgen"], \
    f"github-sourced insight must come first despite losing alphabetically, got {order}"

# adaptive session pacing (compute_pace) -- opt-in, ground-truthed against
# the CLI's own rate_limit_event rather than a heuristic
import time as _time
_now = _time.time()
_window_s = 300 * 60
_resets_at = _now + _window_s * 0.5  # halfway through a 5h window
_cfg_on = {"system_settings": {"session_token_budget": 1000000, "session_window_minutes": 300}}
_rate_info = {"resetsAt": _resets_at, "status": "allowed", "rateLimitType": "five_hour"}
def _ts(offset_s):
    import datetime
    return datetime.datetime.fromtimestamp(_now + offset_s, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

balanced = o.compute_pace(_cfg_on, _rate_info, [{"started_at": _ts(-_window_s*0.4), "tokens": 500000}])
assert balanced["throttle"] is False, "spending in proportion to elapsed window time must not throttle"

ahead = o.compute_pace(_cfg_on, _rate_info, [{"started_at": _ts(-_window_s*0.4), "tokens": 950000}])
assert ahead["throttle"] is True, "spending 95% of budget at 50% elapsed must throttle"

assert o.compute_pace({"system_settings": {}}, _rate_info, [{"started_at": _ts(0), "tokens": 1}]) is None, \
    "pacing must be a no-op (opt-in) when session_token_budget is unset"
assert o.compute_pace(_cfg_on, None, []) is None, \
    "pacing must be a no-op with no rate_limit_event observed yet"

stale = o.compute_pace(_cfg_on, _rate_info, [{"started_at": _ts(-_window_s*2), "tokens": 999999}])
assert stale["spent_tokens"] == 0, "tokens spent in a PRIOR window must not count toward this one"

# _extract_rate_limit_info parses a real-shaped stream-json rate_limit_event
class _FakeRun:
    stdout_lines = [
        '{"type":"system","subtype":"init"}',
        '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1783174200,"rateLimitType":"five_hour"}}',
        '{"type":"result","subtype":"success"}',
    ]
info = o._extract_rate_limit_info(_FakeRun())
assert info == {"status": "allowed", "resetsAt": 1783174200, "rateLimitType": "five_hour"}, \
    f"must extract the rate_limit_info dict from the last matching stream-json line, got {info}"

# The Explorer circuit breaker must also gate single_session/hybrid's own
# empty-backlog fallback, not just multi_process's compute_dispatch -- both
# are the modes this framework actually recommends for subscription use, so
# a breaker that only covers multi_process protects the wrong mode.
empty_data = {"insights": {}, "tasks": {}}
cfg3 = {"system_settings": {}, "persona_model_mapping": {"developer": {"model": "m"}}}
with open(o.INSIGHT_INDEX, "w") as f:
    json.dump([{"verdict": "rejected"}] * 9 + [{"verdict": "accepted"}], f)  # 10%, trips
assert o.build_single_session_prompt(empty_data, cfg3) is None, \
    "single_session must return None (skip spawning) when backlog is empty and the breaker is tripped"
assert o.build_hybrid_session_prompt(empty_data, cfg3) is None, \
    "hybrid session must return None (skip spawning) when backlog is empty and the breaker is tripped"

with open(o.INSIGHT_INDEX, "w") as f:
    json.dump([], f)  # no history -- breaker must NOT trip, normal Explorer fallback applies
assert o.build_single_session_prompt(empty_data, cfg3) is not None, \
    "single_session must still fall back to exploring when there is no acceptance history yet"
assert o.build_hybrid_session_prompt(empty_data, cfg3) is not None, \
    "hybrid session must still fall back to exploring when there is no acceptance history yet"

# stderr must be drained continuously, same as stdout, or a chatty child
# (debug output, a warning storm) blocks forever on a full OS pipe buffer
# once nothing is reading it. Reproduces with a real subprocess -- this
# actually hung indefinitely before _drain_stderr existed.
import subprocess as _sp
_child = r"""
import sys
for i in range(4096):
    sys.stderr.write("x" * 64 + "\n")
sys.stderr.flush()
print("CHILD-DONE")
"""
_proc = _sp.Popen(["python3", "-c", _child], stdout=_sp.PIPE, stderr=_sp.PIPE, text=True)

# Use the real Run class, not a hand-rolled duplicate -- a fake with its own
# field list silently drifts from Run's real attributes (this happened: an
# earlier version of this test predated `stream_events` and crashed
# _drain_stdout in its background thread the moment that field was added,
# invisibly, since a thread's exception doesn't fail the main thread or this
# test's exit code).
_run = o.Run("t", "t-1", "c", _proc, _time.time(), "m")
o._start_reader(_run)
_deadline = _time.time() + 8
while _time.time() < _deadline and _proc.poll() is None:
    _time.sleep(0.2)
if _proc.poll() is None:
    _proc.kill()
    raise AssertionError("child still alive after 8s -- stderr pipe deadlock regressed")
_run.reader_thread.join(timeout=5)
_run.stderr_thread.join(timeout=5)
assert _run.stdout_lines == ["CHILD-DONE"], f"stdout capture broke, got {_run.stdout_lines}"
assert len(_run.stderr_lines) == 4096, f"expected 4096 drained stderr lines, got {len(_run.stderr_lines)}"

# _session_per_task_costs: single_session/hybrid_session must split tokens
# across the tasks they actually touched (using claim events tagged with
# `task`, change 36), not lump everything into the generic session
# cost_label -- and must dedupe repeated content blocks from the same
# assistant message id, and never leak another agent's claims into this
# run's bucketing.
class _CostRun:
    def __init__(self):
        self.agent_id, self.cost_label, self.stream_events = "hybrid-1-a", "hybrid_session_cycle", []

def _msg_event(recv_ts, mid, in_t, out_t):
    return (recv_ts, {"type": "assistant", "message": {"id": mid,
            "usage": {"input_tokens": in_t, "output_tokens": out_t, "cache_creation_input_tokens": 0}}})

_cost_run = _CostRun()
_base = _time.time() - 1000
_cost_data = {"log": [
    {"ts": _ts(-990), "agent": "hybrid-1-a", "action": "claim", "task": "task_A"},
    {"ts": _ts(-500), "agent": "hybrid-1-a", "action": "claim", "task": "task_B"},
    {"ts": _ts(-995), "agent": "OTHER-AGENT", "action": "claim", "task": "task_ignored"},
]}
_cost_run.stream_events = [
    _msg_event(_base - 50, "msg_pre", 100, 50),      # before any claim -> generic cost_label
    _msg_event(_base + 100, "msg_a1", 200, 100),      # task_A window
    _msg_event(_base + 200, "msg_a2", 300, 150),      # task_A window
    (_base + 200.1, {"type": "assistant", "message": {"id": "msg_a2",  # duplicate content block, same id
        "usage": {"input_tokens": 300, "output_tokens": 150, "cache_creation_input_tokens": 0}}}),
    _msg_event(_base + 600, "msg_b1", 400, 200),      # task_B window
    (_base + 700, {"type": "result", "subtype": "success"}),  # non-assistant, ignored
    (_base + 710, None),  # unparsed line, ignored without crashing
]
buckets = o._session_per_task_costs(_cost_run, _cost_data)
assert buckets["hybrid_session_cycle"]["tokens"] == 150, \
    f"pre-claim overhead must fall back to the generic cost_label, got {buckets}"
assert buckets["task_A"]["tokens"] == 750, f"task_A must be 750 (deduped msg_a2), got {buckets}"
assert buckets["task_B"]["tokens"] == 600, f"task_B must be 600, got {buckets}"
assert "task_ignored" not in buckets, "a claim by a DIFFERENT agent must never leak into this run's bucketing"

print("orchestrator.py checks OK")
PYEOF
unset AGENT_HUB_DIR

echo "== 6/6 orphan-process reconciliation (survives an orchestrator crash/restart)"
SC4="$(mktemp -d)"
CLEANUP_PATHS+=("$SC4")
mkdir -p "$SC4/01_insights"
cat > "$SC4/status.json" <<'EOF'
{"schema_version":1,"project_id":"orphan-smoke","counters":{"insight_seq":0,"task_seq":0},
 "insights":{},
 "tasks":{
   "task_a":{"insight_id":null,"title":"alive orphan","status":"in_progress","target_files":[],"assignee":"developer-a","branch":"task-a","attempts":0,"lease_expires_at":"2099-01-01T00:00:00Z"},
   "task_b":{"insight_id":null,"title":"dead orphan","status":"in_progress","target_files":[],"assignee":"developer-b","branch":"task-b","attempts":0,"lease_expires_at":"2099-01-01T00:00:00Z"},
   "task_c":{"insight_id":null,"title":"unrelated PID reuse","status":"in_progress","target_files":[],"assignee":"developer-c","branch":"task-c","attempts":0,"lease_expires_at":"2099-01-01T00:00:00Z"}
 },
 "agents":{},"log":[]}
EOF
cat > "$SC4/config.json" <<'EOF'
{"system_settings":{"project_id":"orphan-smoke","concurrency_limit_developer":2,
 "lease_minutes":30,"max_attempts":3,"daily_token_budget":1000,"log_max_entries":100},
 "persona_model_mapping":{}}
EOF
# alive orphan: cmdline must look like a claude spawn (exec -a fakes argv[0])
bash -c 'exec -a claude-fake-alive sleep 20' &
ALIVE_PID=$!
# dead orphan: exits immediately, PID reused-but-gone by the time we check
bash -c 'exec -a claude-fake-dead true' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
# unrelated alive process whose cmdline does NOT contain "claude" (PID-reuse guard)
sleep 20 &
UNRELATED_PID=$!
sleep 0.3
cat > "$SC4/.running-registry.json" <<EOF
[
  {"pid": $ALIVE_PID, "persona": "developer", "agent_id": "developer-a", "cost_label": "task_a", "model": "m", "started_at": 0},
  {"pid": $DEAD_PID, "persona": "developer", "agent_id": "developer-b", "cost_label": "task_b", "model": "m", "started_at": 0},
  {"pid": $UNRELATED_PID, "persona": "developer", "agent_id": "developer-c", "cost_label": "task_c", "model": "m", "started_at": 0}
]
EOF
export AGENT_HUB_DIR="$SC4" AGENT_CONFIG="$SC4/config.json"
python3 - "$SC4" "$ALIVE_PID" <<'PYEOF' || fail "orphan reconciliation"
import sys, json
sc, alive_pid = sys.argv[1], int(sys.argv[2])
sys.path.insert(0, ".")
import orchestrator as o

orphans = o.reconcile_orphans_from_previous_run()
ids = {e["agent_id"] for e in orphans}
assert ids == {"developer-a"}, f"only the genuinely-alive claude orphan should still be tracked, got {ids}"

d = json.load(open(f"{sc}/status.json"))
assert d["tasks"]["task_a"]["status"] == "in_progress", "alive orphan's task must NOT be released yet"
assert d["tasks"]["task_b"]["status"] == "todo", "dead orphan's task must be released immediately"
assert d["tasks"]["task_c"]["status"] == "todo", \
    "PID-reuse guard: an unrelated non-claude process must not be mistaken for our orphan"
print("reconcile_orphans_from_previous_run OK")
PYEOF
kill "$ALIVE_PID" "$UNRELATED_PID" 2>/dev/null || true
sleep 0.3
python3 - "$SC4" "$ALIVE_PID" <<'PYEOF' || fail "orphan reap after exit"
import sys, json
sc, alive_pid = sys.argv[1], int(sys.argv[2])
sys.path.insert(0, ".")
import orchestrator as o

remaining = o._reap_orphans([{"pid": alive_pid, "persona": "developer", "agent_id": "developer-a",
                              "cost_label": "task_a", "model": "m", "started_at": 0}])
assert remaining == [], f"orphan must be dropped from tracking once its process exits, got {remaining}"
d = json.load(open(f"{sc}/status.json"))
assert d["tasks"]["task_a"]["status"] == "todo", "task_a must be released once its orphan process exits"
print("_reap_orphans OK")
PYEOF
unset AGENT_HUB_DIR AGENT_CONFIG

echo "all smoke checks passed"
exit 0
