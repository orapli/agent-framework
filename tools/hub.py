#!/usr/bin/env python3
"""hub.py — lock-gated state register for the multi-agent framework.

The ONLY sanctioned way to read-modify-write agent-hub/status.json.
Implements the File-Lock Gating Mechanism from the framework specification:
acquire status.lock, verify state (the target may have been consumed by a
parallel node), transform, serialize, release.

Subcommands (SPEC §3):
  add-insight     --file <insight.json path>
  insight-verdict --insight <id> --to accepted|rejected|duplicate [--reason <text>]
  add-task        --file <task.json path> [--allow-unlinked]
  claim-task      --persona <name> [--agent-id <id>]
  renew-lease     --task <task_id>
  transition      --task <task_id> --to <state> [--note <text>] [--agent-id <id>]
  record-cost     --task <task_id> --tokens <n> [--usd <float>]
  archive         --task <task_id> [--force]
  show            [--task <task_id>]

Exit codes: 0 success, 1 invalid transition / not found / missing reason,
3 nothing to claim (not an error).

Env overrides (used by tests): AGENT_HUB_DIR, AGENT_CONFIG.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FRAMEWORK = os.path.normpath(os.path.join(HERE, ".."))
WORKSPACE = os.path.dirname(FRAMEWORK)
PRODUCT = os.path.join(WORKSPACE, "product-repo")
HUB = os.environ.get("AGENT_HUB_DIR") or os.path.join(FRAMEWORK, "agent-hub")
STATUS = os.path.join(HUB, "status.json")
LOCKFILE = os.path.join(HUB, "status.lock")
INSIGHT_INDEX = os.path.join(HUB, "01_insights", "index.json")
CONFIG = os.environ.get("AGENT_CONFIG") or os.path.join(FRAMEWORK, "config.json")

# Allowed transitions per the State Transitions Matrix in the specification
# (SPEC §4). `review_failed` is transitional: landing there immediately
# cascades to `todo` (or `blocked` at the retry limit) inside the same lock,
# implementing the "Automatic; attempts += 1" row of the matrix.
TRANSITIONS = {
    "todo": {"in_progress", "blocked"},
    "in_progress": {"implemented", "todo"},
    "implemented": {"approved_by_architect", "review_failed"},
    "approved_by_architect": {"qa_passed", "review_failed"},
    "qa_passed": {"pending_human_build"},
    "review_failed": {"todo"},
    "blocked": {"todo"},
    "pending_human_build": set(),  # terminal: PR merge + archive
}

INSIGHT_VERDICTS = {"accepted", "rejected", "duplicate"}


class _FcntlLock:
    """Deterministic binary lock; used when the filelock package is absent."""

    def __init__(self, path):
        self.path = path
        self.fd = None

    def __enter__(self):
        import fcntl
        self.fd = open(self.path, "a+")
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        import fcntl
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        self.fd.close()


def get_lock():
    try:
        from filelock import FileLock
        return FileLock(LOCKFILE)
    except ImportError:
        return _FcntlLock(LOCKFILE)


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def today():
    return now().strftime("%Y-%m-%d")


def load_config():
    with open(CONFIG) as f:
        return json.load(f)


def load_status():
    with open(STATUS) as f:
        return migrate(json.load(f))


def migrate(data):
    """Fill fields added after v2.2 with defaults so pre-existing registers
    keep working. Idempotent; runs on every load."""
    for ins in data.setdefault("insights", {}).values():
        if "status" not in ins:
            ins["status"] = "accepted" if ins.get("tasks_generated") else "proposed"
    for t in data.setdefault("tasks", {}).values():
        t.setdefault("attempts", 0)
        t.setdefault("target_files", [])
        t.setdefault("title", "")
        t.setdefault("lease_expires_at", None)
    data.setdefault("usage", {"per_task": {}, "per_day": {}})
    for bucket in ("per_task", "per_day"):
        for k, v in list(data["usage"][bucket].items()):
            if isinstance(v, int):
                data["usage"][bucket][k] = {"tokens": v, "usd": 0.0}
            elif isinstance(v, dict) and v.get("usd") is None:
                v["usd"] = 0.0
    data.setdefault("agents", {})
    data.setdefault("log", [])
    return data


def save_status(data):
    tmp = STATUS + ".tmp"
    cap = 500
    try:
        cap = int(load_config()["system_settings"].get("log_max_entries", 500))
    except Exception:
        pass
    data["log"] = data["log"][-cap:]
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, STATUS)


def log_event(data, agent_id, action, detail):
    data["log"].append(
        {"ts": iso(now()), "agent": agent_id, "action": action, "detail": detail}
    )


def sweep_expired_leases(data, agent_id):
    """Return expired in_progress tasks to todo (attempts += 1) — recovery is
    a side effect of normal claim operation (SPEC §6.1)."""
    cutoff = iso(now())
    for tid, t in data["tasks"].items():
        if t["status"] == "in_progress" and t.get("lease_expires_at") and t["lease_expires_at"] < cutoff:
            _return_to_todo(data, agent_id, tid, t, "lease-expired")


def _return_to_todo(data, agent_id, tid, t, reason):
    """attempts += 1; land in todo, or blocked once max_attempts is hit."""
    t["attempts"] = t.get("attempts", 0) + 1
    t["assignee"] = None
    t["lease_expires_at"] = None
    max_attempts = 3
    try:
        max_attempts = int(load_config()["system_settings"].get("max_attempts", 3))
    except Exception:
        pass
    if t["attempts"] >= max_attempts:
        t["status"] = "blocked"
        t["blocked_reason"] = "retry-limit"
        log_event(data, agent_id, "->blocked", f"{tid}: retry-limit ({reason})")
    else:
        t["status"] = "todo"
        log_event(data, agent_id, "->todo", f"{tid}: {reason} (attempt {t['attempts']})")


def cmd_add_insight(args):
    with open(args.file) as f:
        insight = json.load(f)
    iid = insight["insight_id"]
    with get_lock():
        data = load_status()
        if iid in data["insights"]:
            print(f"insight {iid} already registered", file=sys.stderr)
            return 0  # idempotent
        data["counters"]["insight_seq"] += 1
        data["insights"][iid] = {
            "category": insight.get("category"),
            "severity": insight.get("severity"),
            "status": "proposed",
            "tasks_generated": False,
        }
        log_event(data, args.agent_id, "add-insight", iid)
        save_status(data)
    print(iid)
    return 0


def cmd_insight_verdict(args):
    if args.to not in INSIGHT_VERDICTS:
        print(f"invalid verdict {args.to}", file=sys.stderr)
        return 1
    if args.to in ("rejected", "duplicate") and not args.reason:
        print(f"--reason is required for verdict '{args.to}'", file=sys.stderr)
        return 1
    with get_lock():
        data = load_status()
        ins = data["insights"].get(args.insight)
        if ins is None:
            print(f"unknown insight {args.insight}", file=sys.stderr)
            return 1
        if ins["status"] != "proposed":
            print(f"insight {args.insight} already has verdict {ins['status']}", file=sys.stderr)
            return 1
        ins["status"] = args.to
        if args.reason:
            ins["verdict_reason"] = args.reason
        log_event(data, args.agent_id, f"verdict:{args.to}", args.insight)
        save_status(data)
        # Compact verdict index for Explorer dedup / negative examples (SPEC §5)
        index = []
        if os.path.exists(INSIGHT_INDEX):
            try:
                with open(INSIGHT_INDEX) as f:
                    index = json.load(f)
            except Exception:
                index = []
        index.append({"id": args.insight, "verdict": args.to, "reason": args.reason or ""})
        os.makedirs(os.path.dirname(INSIGHT_INDEX), exist_ok=True)
        tmp = INSIGHT_INDEX + ".tmp"
        with open(tmp, "w") as f:
            json.dump(index, f, indent=2, ensure_ascii=False)
        os.replace(tmp, INSIGHT_INDEX)
    print(f"{args.insight}: {args.to}")
    return 0


def cmd_add_task(args):
    with open(args.file) as f:
        task = json.load(f)
    tid = task["task_id"]
    with get_lock():
        data = load_status()
        if tid in data["tasks"]:
            print(f"task {tid} already registered", file=sys.stderr)
            return 1
        iid = task.get("insight_id")
        if not iid and not args.allow_unlinked:
            print("task has no insight_id — run `add-insight` first, or pass "
                  "--allow-unlinked for a deliberate ad-hoc task", file=sys.stderr)
            return 1
        if iid and iid not in data["insights"] and not args.allow_unlinked:
            # A task referencing an insight_id that was never registered is
            # exactly how ungoverned work (e.g. an external tool bypassing
            # add-insight entirely) can masquerade as framework-tracked —
            # found via insight_06caade1. Reject unless explicitly overridden.
            print(f"insight_id '{iid}' is not registered (run `add-insight` "
                  f"first, or pass --allow-unlinked to override)", file=sys.stderr)
            return 1
        if iid and data["insights"].get(iid, {}).get("status") == "proposed":
            # Only accepted insights may be decomposed (SPEC §5); tolerate the
            # legacy human-sourced flow by auto-accepting on first task.
            data["insights"][iid]["status"] = "accepted"
            log_event(data, args.agent_id, "verdict:accepted", f"{iid} (implicit via add-task)")
        data["counters"]["task_seq"] += 1
        data["tasks"][tid] = {
            "insight_id": iid,
            "title": task.get("title", ""),
            "target_files": task.get("target_files", []),
            "status": "todo",
            "assignee": None,
            "branch": None,
            "attempts": 0,
            "lease_expires_at": None,
        }
        if iid in data["insights"]:
            data["insights"][iid]["tasks_generated"] = True
        log_event(data, args.agent_id, "add-task", tid)
        save_status(data)
    print(tid)
    return 0


def cmd_claim_task(args):
    cfg = load_config()["system_settings"]
    lease_minutes = int(cfg.get("lease_minutes", 30))
    with get_lock():
        data = load_status()
        sweep_expired_leases(data, args.agent_id)
        if args.persona == "developer":
            limit = int(cfg["concurrency_limit_developer"])
            active = sum(1 for t in data["tasks"].values() if t["status"] == "in_progress")
            if active >= limit:
                save_status(data)  # persist any lease sweep
                print("concurrency limit reached", file=sys.stderr)
                return 3
        # File-level exclusion (SPEC §6.2): skip candidates whose target_files
        # intersect any current in_progress task's target_files.
        busy_files = set()
        for t in data["tasks"].values():
            if t["status"] == "in_progress":
                busy_files.update(t.get("target_files", []))
        for tid in sorted(data["tasks"]):
            t = data["tasks"][tid]
            if t["status"] != "todo":
                continue
            if busy_files & set(t.get("target_files", [])):
                continue
            t["status"] = "in_progress"
            t["assignee"] = args.agent_id
            t["branch"] = f"task-{tid.removeprefix('task_')}"
            t["lease_expires_at"] = iso(now() + datetime.timedelta(minutes=lease_minutes))
            log_event(data, args.agent_id, "claim", tid)
            save_status(data)
            print(json.dumps({"task_id": tid, "branch": t["branch"],
                              "worktree": f"worktrees/{t['branch']}",
                              "lease_expires_at": t["lease_expires_at"]}))
            return 0
        save_status(data)  # persist any lease sweep
        return 3


def cmd_renew_lease(args):
    cfg = load_config()["system_settings"]
    lease_minutes = int(cfg.get("lease_minutes", 30))
    with get_lock():
        data = load_status()
        t = data["tasks"].get(args.task)
        if t is None or t["status"] != "in_progress":
            print(f"task {args.task} is not in_progress", file=sys.stderr)
            return 1
        t["lease_expires_at"] = iso(now() + datetime.timedelta(minutes=lease_minutes))
        log_event(data, args.agent_id, "renew-lease", args.task)
        save_status(data)
    print(t["lease_expires_at"])
    return 0


def cmd_release_task(args):
    """Return an in_progress task to todo WITHOUT incrementing attempts.
    For failures that are not the work's fault (e.g. the runner died to a
    billing/session limit) — a plain transition to todo counts as an attempt
    and three such deaths would auto-block a perfectly healthy task."""
    with get_lock():
        data = load_status()
        t = data["tasks"].get(args.task)
        if t is None or t["status"] != "in_progress":
            print(f"task {args.task} is not in_progress", file=sys.stderr)
            return 1
        t["status"] = "todo"
        t["assignee"] = None
        t["lease_expires_at"] = None
        log_event(data, args.agent_id, "release", f"{args.task}: {args.note or 'released'}")
        save_status(data)
    print(f"{args.task}: todo (attempts unchanged: {t['attempts']})")
    return 0


def cmd_transition(args):
    with get_lock():
        data = load_status()
        t = data["tasks"].get(args.task)
        if t is None:
            print(f"unknown task {args.task}", file=sys.stderr)
            return 1
        cur = t["status"]
        if args.to not in TRANSITIONS.get(cur, set()):
            print(f"illegal transition {cur} -> {args.to}", file=sys.stderr)
            return 1
        if args.to == "review_failed":
            if not args.note:
                print("--note (rejection reason) is required for review_failed", file=sys.stderr)
                return 1
            t.setdefault("review_notes", []).append(args.note)
            log_event(data, args.agent_id, f"{cur}->review_failed", args.note)
            # Automatic cascade (SPEC §4): review_failed → todo, attempts += 1
            _return_to_todo(data, args.agent_id, args.task, t, "review-failed")
        elif args.to == "todo" and cur == "in_progress":
            log_event(data, args.agent_id, "in_progress->todo", args.note or args.task)
            _return_to_todo(data, args.agent_id, args.task, t, args.note or "returned")
        else:
            t["status"] = args.to
            if args.to == "blocked":
                t["blocked_reason"] = args.note or "unspecified"
            if args.to == "todo":
                # blocked -> todo: re-evaluation is a fresh start — reset the
                # retry counter, otherwise the next single failure re-blocks
                # immediately (attempts would still be >= max_attempts).
                t["assignee"] = None
                t["blocked_reason"] = None
                t["attempts"] = 0
            if args.to in ("implemented", "pending_human_build"):
                t["lease_expires_at"] = None
            log_event(data, args.agent_id, f"{cur}->{args.to}", args.note or args.task)
        save_status(data)
    print(f"{args.task}: {t['status']}")
    return 0


def cmd_record_cost(args):
    n = int(args.tokens)
    usd = float(args.usd) if args.usd is not None else 0.0
    with get_lock():
        data = load_status()
        usage = data["usage"]
        slot = usage["per_task"].setdefault(args.task, {"tokens": 0, "usd": 0.0})
        slot["tokens"] += n
        slot["usd"] += usd
        day = today()
        day_slot = usage["per_day"].setdefault(day, {"tokens": 0, "usd": 0.0})
        day_slot["tokens"] += n
        day_slot["usd"] += usd
        log_event(data, args.agent_id, "record-cost", f"{args.task}: +{n} tokens, +{usd} usd")
        save_status(data)
    print(f"{args.task}: {slot['tokens']} tokens, {slot['usd']:.4f} usd "
          f"(today: {day_slot['tokens']} tokens, {day_slot['usd']:.4f} usd)")
    return 0


def _branch_merged_into_main(branch):
    """True only if `branch`'s tip commit is actually reachable from
    origin/main — i.e. a real merge happened, not just a closed PR or a
    self-reported state transition. Any ambiguity (branch gone, fetch
    failure, detached ref) returns False: "cannot verify" must never be
    treated as "verified"."""
    if not branch or not os.path.isdir(PRODUCT):
        return False
    subprocess.run(["git", "-C", PRODUCT, "fetch", "origin", "main", branch],
                   capture_output=True)
    for ref in (branch, f"origin/{branch}"):
        r = subprocess.run(["git", "-C", PRODUCT, "merge-base", "--is-ancestor",
                            ref, "origin/main"], capture_output=True)
        if r.returncode == 0:
            return True
    return False


def cmd_archive(args):
    archive_dir = os.path.join(HUB, "archive")
    reports_dir = os.path.join(HUB, "03_reports")
    os.makedirs(archive_dir, exist_ok=True)
    with get_lock():
        data = load_status()
        t = data["tasks"].get(args.task)
        if t is None:
            print(f"unknown task {args.task}", file=sys.stderr)
            return 1
        if t["status"] not in ("pending_human_build", "blocked") and not args.force:
            print(f"task {args.task} is {t['status']}; archive only terminal tasks (or --force)",
                  file=sys.stderr)
            return 1
        if t["status"] == "pending_human_build" and not args.force:
            # Real incident: a task reached pending_human_build, its PR was
            # opened then closed WITHOUT merging (branch deleted, so the PR
            # auto-closed), and archive ran anyway — the register showed
            # "done" while the code never reached main. Verify against git
            # history, not the task's own self-reported state.
            if not _branch_merged_into_main(t.get("branch")):
                print(f"task {args.task}: branch '{t.get('branch')}' is not merged into "
                      f"origin/main (or could not be verified) — refusing to archive. "
                      f"Merge the PR first, or pass --force if this task genuinely has "
                      f"no code to merge.", file=sys.stderr)
                return 1
        month = now().strftime("%Y-%m")
        arc_path = os.path.join(archive_dir, f"{month}.json")
        arc = {}
        if os.path.exists(arc_path):
            with open(arc_path) as f:
                arc = json.load(f)
        entry = dict(t)
        entry["archived_at"] = iso(now())
        raw = data["usage"]["per_task"].get(args.task, 0)
        entry["tokens"] = raw["tokens"] if isinstance(raw, dict) else raw
        # Move reports into the archive
        moved = []
        arc_reports = os.path.join(archive_dir, "reports")
        os.makedirs(arc_reports, exist_ok=True)
        if os.path.isdir(reports_dir):
            for name in os.listdir(reports_dir):
                if name.startswith(f"report_{args.task}_"):
                    os.replace(os.path.join(reports_dir, name), os.path.join(arc_reports, name))
                    moved.append(name)
        entry["reports"] = moved
        arc[args.task] = entry
        tmp = arc_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(arc, f, indent=2, ensure_ascii=False)
        os.replace(tmp, arc_path)
        # Digest line: task_id | title | files | final state | tokens (SPEC §11)
        digest = os.path.join(HUB, "digest.md")
        with open(digest, "a") as f:
            f.write(f"{args.task} | {t.get('title','')} | {','.join(t.get('target_files',[]))} "
                    f"| {t['status']} | {entry['tokens']}\n")
        del data["tasks"][args.task]
        log_event(data, args.agent_id, "archive", args.task)
        save_status(data)
    # Worktree + remote branch cleanup, best effort (outside the lock)
    branch = t.get("branch") or f"task-{args.task.removeprefix('task_')}"
    product = os.path.join(WORKSPACE, "product-repo")
    wt = os.path.join(WORKSPACE, "worktrees", branch)
    if os.path.isdir(wt):
        subprocess.run(["git", "-C", product, "worktree", "remove", "--force", wt],
                       capture_output=True)
    subprocess.run(["git", "-C", product, "push", "origin", "--delete", branch],
                   capture_output=True)
    print(f"{args.task}: archived to {arc_path}")
    return 0


def cmd_show(args):
    data = load_status()
    if args.task:
        print(json.dumps(data["tasks"].get(args.task), indent=2, ensure_ascii=False))
    else:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--agent-id", default=os.environ.get("AGENT_ID", "anonymous"))
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("add-insight")
    s.add_argument("--file", required=True)
    s = sub.add_parser("insight-verdict")
    s.add_argument("--insight", required=True)
    s.add_argument("--to", required=True, choices=sorted(INSIGHT_VERDICTS))
    s.add_argument("--reason")
    s = sub.add_parser("add-task")
    s.add_argument("--file", required=True)
    s.add_argument("--allow-unlinked", action="store_true",
                    help="permit a task with no insight_id, or one that "
                         "references an unregistered insight_id")
    s = sub.add_parser("claim-task")
    s.add_argument("--persona", required=True)
    s = sub.add_parser("renew-lease")
    s.add_argument("--task", required=True)
    s = sub.add_parser("release-task")
    s.add_argument("--task", required=True)
    s.add_argument("--note")
    s = sub.add_parser("transition")
    s.add_argument("--task", required=True)
    s.add_argument("--to", required=True, choices=sorted(TRANSITIONS))
    s.add_argument("--note")
    s = sub.add_parser("record-cost")
    s.add_argument("--task", required=True)
    s.add_argument("--tokens", required=True)
    s.add_argument("--usd", type=float, default=0.0)
    s = sub.add_parser("archive")
    s.add_argument("--task", required=True)
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("show")
    s.add_argument("--task")

    args = p.parse_args()
    return {
        "add-insight": cmd_add_insight,
        "insight-verdict": cmd_insight_verdict,
        "add-task": cmd_add_task,
        "claim-task": cmd_claim_task,
        "renew-lease": cmd_renew_lease,
        "release-task": cmd_release_task,
        "transition": cmd_transition,
        "record-cost": cmd_record_cost,
        "archive": cmd_archive,
        "show": cmd_show,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
