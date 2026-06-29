#!/bin/bash
# TaskBeacon 一键安装器 —— 双击运行即可。
#
# 做四件事：
#   1. 把 TaskBeacon.app 装进 /Applications，并去掉 Gatekeeper 隔离属性
#   2. 装状态 hook 脚本 → ~/.claude/hooks/taskbeacon-status.sh
#   3. 把 hook 接线幂等合并进 ~/.claude/settings.json（不动你已有的其它 hook）
#   4. 若装了 VSCode，装伴生扩展 → ~/.vscode/extensions（用于精准聚焦终端）
set -uo pipefail

# .command 双击运行时 cwd 不在脚本目录，先定位到包根目录（installer 的上一级）。
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

CLAUDE_DIR="$HOME/.claude"
HOOK_SRC="$ROOT/hooks/taskbeacon-status.sh"
HOOK_DST="$CLAUDE_DIR/hooks/taskbeacon-status.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
APP_SRC="$ROOT/TaskBeacon.app"
APP_DST="/Applications/TaskBeacon.app"
EXT_SRC="$ROOT/vscode-extension"

echo ""
echo "  TaskBeacon 安装中…"
echo "  ───────────────────────────────"

# macOS 版本门槛（需要 13+）。
osver="$(sw_vers -productVersion 2>/dev/null)"
major="${osver%%.*}"
if [ "${major:-0}" -lt 13 ]; then
  echo "  ⚠️  需要 macOS 13 或更高（你的是 $osver），可能无法正常运行。"
fi

# 1) 安装 app + 去隔离 ----------------------------------------------------------
if [ ! -d "$APP_SRC" ]; then
  echo "  ✖ 找不到 $APP_SRC，安装包不完整。"
  exit 1
fi
# 退出可能正在跑的旧实例，避免覆盖时报忙。
osascript -e 'quit app "TaskBeacon"' >/dev/null 2>&1 || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
# 关键：去掉下载/拷贝带来的 com.apple.quarantine，免去「打不开/已损坏」拦截。
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
echo "  ✓ 已安装 TaskBeacon.app → /Applications"

# 2) 安装 hook 脚本 -------------------------------------------------------------
mkdir -p "$CLAUDE_DIR/hooks"
cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "  ✓ 已安装状态 hook"

# 3) 幂等合并 hook 接线进 settings.json ----------------------------------------
#    先删掉任何旧的 taskbeacon 接线，再写入这 4 条，避免重复 / 残留。
/usr/bin/python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

WIRING = {
    "Stop":             "done",
    "Notification":     "needs",
    "UserPromptSubmit": "working",
    "PreToolUse":       "working",
    # PostToolUse flips needs -> working the instant you answer an
    # AskUserQuestion / ExitPlanMode (or approve a permission prompt), so the
    # "需确认" banner clears on confirm instead of lingering until the next turn.
    "PostToolUse":      "working",
}
CMD = "~/.claude/hooks/taskbeacon-status.sh"

hooks = cfg.setdefault("hooks", {})
for event, action in WIRING.items():
    blocks = hooks.get(event, [])
    # 丢弃所有已存在的 taskbeacon 接线（无论 action 写的啥），保留其它 hook。
    cleaned = []
    for b in blocks:
        b = dict(b)
        b["hooks"] = [h for h in b.get("hooks", []) if "taskbeacon" not in h.get("command", "")]
        if b["hooks"]:
            cleaned.append(b)
    cleaned.append({"hooks": [{"type": "command", "command": f"{CMD} {action}"}]})
    hooks[event] = cleaned

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("  ✓ 已把 hook 接线写入 settings.json")
PY

# 4) 安装 VSCode 伴生扩展（可选，没装 VSCode 就跳过）---------------------------
if [ -d "$EXT_SRC" ]; then
  VER="$(/usr/bin/sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$EXT_SRC/package.json" | head -1)"
  EXT_BASE="$HOME/.vscode/extensions"
  EXT_DST="$EXT_BASE/taskbeacon.focus-${VER:-1.0.0}"
  if [ -d "$HOME/.vscode" ] || command -v code >/dev/null 2>&1; then
    mkdir -p "$EXT_BASE"
    rm -rf "$EXT_BASE/taskbeacon.focus-"*
    mkdir -p "$EXT_DST"
    cp "$EXT_SRC/package.json" "$EXT_SRC/extension.js" "$EXT_DST/"
    echo "  ✓ 已安装 VSCode 扩展（需在 VSCode 里执行一次 Developer: Reload Window）"
  else
    echo "  • 未检测到 VSCode，跳过扩展（精准聚焦终端功能不可用，其余正常）"
  fi
fi

# 5) 启动 -----------------------------------------------------------------------
open "$APP_DST"

echo "  ───────────────────────────────"
echo "  ✅ 完成！菜单栏右上角应已出现 TaskBeacon 图标。"
echo ""
echo "  后续要让「精准跳转终端」生效，请在 VSCode 里执行一次："
echo "      Command Palette → Developer: Reload Window"
echo ""
echo "  这个窗口可以关掉了。"
echo ""
