#!/bin/bash
# TaskBeacon 卸载器 —— 双击运行。移除 app、hook、settings.json 接线、VSCode 扩展。
set -uo pipefail
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo ""
echo "  卸载 TaskBeacon…"
osascript -e 'quit app "TaskBeacon"' >/dev/null 2>&1 || true
rm -rf "/Applications/TaskBeacon.app"
rm -f "$CLAUDE_DIR/hooks/taskbeacon-status.sh"
rm -rf "$CLAUDE_DIR/taskbeacon"
rm -rf "$HOME/.vscode/extensions/taskbeacon.focus-"*

# 从 settings.json 里摘掉 taskbeacon 接线，保留其它 hook。
if [ -f "$SETTINGS" ]; then
/usr/bin/python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(0)
hooks = cfg.get("hooks", {})
for event in list(hooks.keys()):
    cleaned = []
    for b in hooks[event]:
        b = dict(b)
        b["hooks"] = [h for h in b.get("hooks", []) if "taskbeacon" not in h.get("command", "")]
        if b["hooks"]:
            cleaned.append(b)
    if cleaned:
        hooks[event] = cleaned
    else:
        del hooks[event]
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
fi

echo "  ✅ 已卸载。这个窗口可以关掉了。"
echo ""
