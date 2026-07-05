# orapli agent-framework

Autonomous, parallel, cost-bounded optimization of a target GitHub repository by five
specialized AI personas (Explorer, Architect, Developer, QA Tester, Documenter), coordinated
exclusively through file-based artifacts and a lock-gated state register — no shared database,
no long-running service beyond a polling orchestrator.

The full behavioral contract is [`SPEC.md`](SPEC.md); it is normative. This README is an
entry point, not a substitute for it.

## What it does

1. **Explorer** reads a product repository and files *Insights* (observations, not
   instructions) into a state register.
2. **Architect** gives each Insight a verdict (accepted / rejected / duplicate) and decomposes
   accepted ones into atomic, independently mergeable *Tasks*.
3. **Developer** claims a Task, implements it in an isolated git worktree, and opens a PR.
4. **QA Tester** verifies the PR; **Documenter** finalizes docs and cost bookkeeping.
5. A human (or, once a task reaches `pending_human_build`, an agent — see SPEC §12.2) merges.

State transitions happen only through `tools/hub.py`, a lock-gated CLI — nothing mutates
`agent-hub/status.json` directly. `orchestrator.py` is the single launching authority: it
polls the register, decides what work is pending, and spawns persona agents as headless
Claude Code processes (`claude -p`), one model per persona role
(`config.json`'s `persona_model_mapping`).

## Three execution modes

- **`multi_process`**: one spawned process per persona-phase, each on its own model
  — best throughput and cost/quality matching. Pick this when budget is not the constraint.
- **`single_session`**: one process walks the *entire* pending pipeline in one continuous run,
  on one fixed model, narrating which persona role it adopts per item. Pays the fixed
  per-spawn overhead once per sweep instead of once per phase — the right choice when
  session/token budget (e.g. a subscription plan's time-boxed window), not latency or
  per-phase model specialization, is the binding constraint, *and* you accept the risk of
  the same context both authoring and approving its own code.
- **`hybrid`** (default): the same session/cache savings as `single_session` for
  Explorer/Architect-decomposition/Developer/Documenter, but Architect's diff review and QA
  always spawn as separate, freshly-started processes — so the code is never judged by the
  process that wrote it. The recommended choice on a subscription plan.

See `SPEC.md` §7.9 for the full trade-off.

See SPEC §7.9 for the full comparison; select with `system_settings.execution_mode` in
`config.json`, or override per-run with `orchestrator.py --mode`.

## Getting started

```bash
# From an empty workspace root:
git clone https://github.com/orapli/agent-framework agent-framework
agent-framework/tools/bootstrap.sh <product-repo-url> <product-name>

# Then, from the workspace root:
python3 agent-framework/orchestrator.py --once   # one pipeline sweep
python3 agent-framework/orchestrator.py          # continuous polling loop
python3 agent-framework/orchestrator.py --selftest  # verify per-persona model dispatch
```

`bootstrap.sh` is idempotent: it clones the product repo (if absent), creates `config.json`
from `config.template.json`, initializes the state register, and seeds workspace-local
knowledge files. See [`SPEC.md`](SPEC.md) §15 for multi-workspace deployment and
[`SPEC.md`](SPEC.md) §10 for the full `config.json` shape.

## Layout

```
agent-framework/
├── SPEC.md                # Normative specification — read this first
├── orchestrator.py        # Launching authority: polls, dispatches, spawns personas
├── config.template.json   # Seeds a workspace's config.json (persona→model mapping, limits)
├── personas/              # Behavioral contracts for the five persona roles
├── tools/
│   ├── hub.py              # The only sanctioned way to read/write the state register
│   ├── run_tests.sh        # Test-execution gate (delegates to the product's own runner)
│   ├── lint_check.sh       # Lint-execution gate
│   └── bootstrap.sh        # Workspace provisioning
├── templates/              # Files copied into a new workspace at bootstrap time
├── scripts/                 # This repo's own test/lint contract (for self-hosted development)
└── dashboard/index.html    # Dependency-free static viewer for orchestrator/persona state
```

Workspace-local state (`config.json`, the live register, `knowledge/`, caches, reports) is
gitignored — only code and templates are versioned here, so `git pull` cleanly propagates
framework updates to every workspace that uses it.

## License

MIT — see [LICENSE](LICENSE).
