# Architecture — System Topography & Dependency Guidelines

> STATUS: BOOTSTRAP TEMPLATE. The Explorer's first mandate after `product-repo/`
> is cloned is to produce an Insight proposing the real topography for this file;
> the Architect ratifies it and replaces this template.

## Framework Topography (fixed — do not modify)
```
workspace/
├── product-repo/          # The ONLY tree agents may mutate (Developer/Documenter, on task branches)
└── agent-framework/       # Orchestration plane — code changes here are out of scope for Tasks
```

## Dependency Direction Rules
1. `agent-framework/` never imports from or depends on `product-repo/` code.
2. Agents never assume state outside the artifacts listed in the framework spec
   (`status.json`, `01_insights/`, `02_tasks/`, `03_reports/`).
3. Inside `product-repo/`, respect the dependency direction the codebase already
   exhibits; inverting a dependency requires its own dedicated Task.

## Branch Topology
- Default branch (`main`/`master`): read-only for all agents.
- `task-{id}`: one branch per task, created from the default branch head,
  pushed to `origin`, merged only by a human (`pending_human_build`).

## Product Topography
_To be filled by Explorer → Architect ratification._
