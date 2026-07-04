#!/usr/bin/env bash
# Workspace bootstrap — makes a fresh framework clone immediately usable.
# Run from the WORKSPACE ROOT (the folder that contains agent-framework/):
#   git clone https://github.com/orapli/agent-framework agent-framework
#   agent-framework/tools/bootstrap.sh <product-repo-url> <product-name>
# Idempotent: safe to re-run; never overwrites existing files or clones.
set -euo pipefail

REPO_URL="${1:?usage: bootstrap.sh <product-repo-url> <product-name>}"
PRODUCT="${2:?usage: bootstrap.sh <product-repo-url> <product-name>}"
ROOT="$(pwd)"
FW="$ROOT/agent-framework"
SHARED_URL="https://github.com/tas6/orapli-shared"

if [ ! -d "$FW" ]; then
  echo "bootstrap.sh: run from the workspace root (agent-framework/ not found in $ROOT)" >&2
  exit 2
fi

echo "== 1/6 product-repo"
if [ -d "$ROOT/product-repo/.git" ]; then
  echo "   already present — skipping clone"
else
  git clone "$REPO_URL" "$ROOT/product-repo"
fi

echo "== 2/6 worktrees/ and state directories"
mkdir -p "$ROOT/worktrees" \
         "$FW/agent-hub/github-cache" "$FW/agent-hub/archive" \
         "$FW/agent-hub/01_insights" "$FW/agent-hub/02_tasks" "$FW/agent-hub/03_reports"
touch "$FW/agent-hub/status.lock"

echo "== 3/6 config.json / status register"
python3 - "$FW" "$PRODUCT" <<'EOF'
import json, os, shutil, sys
fw, product = sys.argv[1], sys.argv[2]
pid = f"sbx-{product}-optimization-v1"

cfg = os.path.join(fw, "config.json")
if not os.path.exists(cfg):
    shutil.copy(os.path.join(fw, "config.template.json"), cfg)
with open(cfg) as f:
    d = json.load(f)
d["system_settings"]["project_id"] = pid
with open(cfg, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")

reg = os.path.join(fw, "agent-hub", "status.json")
if os.path.exists(reg):
    with open(reg) as f:
        r = json.load(f)
    r["project_id"] = pid
    if r.get("tasks") or r.get("insights"):
        print(f"   WARNING: register is not empty ({len(r.get('tasks', {}))} tasks, "
              f"{len(r.get('insights', {}))} insights) — review before operating.")
else:
    r = {"schema_version": 1, "project_id": pid,
         "counters": {"insight_seq": 0, "task_seq": 0},
         "insights": {}, "tasks": {}, "agents": {}, "log": []}
with open(reg, "w") as f:
    json.dump(r, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"   project_id = {pid}")
EOF

echo "== 4/6 knowledge/ (workspace-local, seeded from templates)"
mkdir -p "$FW/knowledge"
for f in coding_style.md architecture.md; do
  if [ ! -f "$FW/knowledge/$f" ]; then
    cp "$FW/templates/$f" "$FW/knowledge/$f"
    echo "   seeded $f"
  fi
done

echo "== 5/6 shared knowledge (orapli-shared)"
if [ -d "$FW/shared-cache/.git" ]; then
  git -C "$FW/shared-cache" pull --ff-only
else
  rm -rf "$FW/shared-cache"
  git clone "$SHARED_URL" "$FW/shared-cache"
fi
cp "$FW/shared-cache/design-system.md" "$FW/shared-cache/related-products.md" "$FW/knowledge/"
echo "   knowledge/ synced (design-system.md, related-products.md)"

echo "== 6/6 workspace CLAUDE.md"
if [ -f "$ROOT/CLAUDE.md" ]; then
  echo "   already present — not overwriting"
else
  sed -e "s|{{PRODUCT}}|$PRODUCT|g" -e "s|{{REPO_URL}}|$REPO_URL|g" \
    "$FW/templates/CLAUDE.workspace.md" > "$ROOT/CLAUDE.md"
  echo "   generated from template"
fi

echo
echo "Bootstrap complete. Workspace layout:"
ls -d "$ROOT"/* | sed "s|$ROOT/|  |"
echo
echo "Framework updates later: git -C agent-framework pull && re-run this script (idempotent)."
echo "If this is a fresh sandbox, make sure the GitHub secret is set on the host:"
echo '  sbx secret set -g github -t "$(gh auth token)"   # or per-sandbox'
