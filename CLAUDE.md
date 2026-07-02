# TaskBeacon

macOS 菜单栏 App，实时显示每个 Claude Code 会话（终端）的状态：运行中 / 完成 / 需确认 / 闲置。
纯 Swift + Cocoa，无依赖。构建：`./build.sh`（产出 `TaskBeacon.app`）。

---

## 🧠 核心机制：会话状态判定（改这块前必读）

> 这是本 App 的心脏。判定错了整个产品就没意义。排查状态相关 bug 一律先回到这里。

### 状态从哪来

不读 transcript（Claude Code v2.1 daemon 架构不再为活跃终端会话写可发现的 `<session>.jsonl`，transcript-mtime 会让所有会话都显示成「运行中」）。
**状态来自 hook 写的按 tty 命名的文件**：`~/.claude/taskbeacon/state-<tty>`，内容是 `working` / `done` / `needs` / `idle` 之一。

- hook 脚本：`hooks/taskbeacon-status.sh`（真身在 `~/.claude/hooks/taskbeacon-status.sh`，由全局 `~/.claude/settings.json` 注册）
- App 读取：`main.swift` 的 `sessionStatus(tty:)`
- 按 **tty** 键控，不用 env——`CLAUDE_CODE_SESSION_ID` / `SSE_PORT` 会被同一 VSCode 窗口的所有终端继承共享，会把兄弟会话塌缩成一个；tty 每个终端唯一。

### hook → 状态 映射

| Claude Code hook | 写入状态 | 颜色 | 含义 |
|---|---|---|---|
| `UserPromptSubmit` / `PreToolUse` | working | 蓝 | 模型在忙 |
| `Stop` | done | 绿 | 轮次结束，该你了 |
| `PermissionRequest` | needs | 红 | 权限弹窗出现（实时） |
| `PreToolUse` 且 tool=`AskUserQuestion`/`ExitPlanMode` | needs | 红 | 停下等你答/批准 |
| `Notification` | needs | 红 | 仅老版 Claude Code 的兜底（会 debounce ~2-4s，还兼「等待输入」idle ping，需过滤） |
| `SessionStart`(clear/startup) | idle | 灰 | 会话清空/新开 |

### ★ 关键难点：「确认」盲区（这是最容易出 bug 的地方）

实测事件顺序：

```
PreToolUse        → working(蓝)     命令准备跑
PermissionRequest → needs(红)       权限弹窗出现
   ★ 用户点「确认」★                ← Claude Code 在这一刻【不发任何 hook】！
PostToolUse       → working(蓝)     命令【跑完】才发
```

**Claude Code 在承认的瞬间没有 hook。** 承认后唯一能把红改回蓝的是这条命令的 `PostToolUse`，而它只在命令**结束**时发。
→ 后果：`npx expo start` 这类**前台长命令**，跑多久 state 文件就红多久（「确认过了还是红」的 bug）。

### 解法：App 侧「忙碌探测 + 时刻守卫」

真相在进程树里。Claude Code 跑 Bash 工具 = 在 `claude` 进程下 spawn 一个命令外壳 `zsh -c '...eval 命令...'`（常驻的 `sourcekit-lsp` / `caffeinate` **不带 `-c`**，天然区分开）。

`main.swift` 的 `runningToolCommand(claudePid:since:)`：**当某行是 `needs` 时**，去 `claude` 的直接子进程里找命令外壳（`zsh`/`bash`/`sh` 且含 `-c`）。找到 → 说明弹窗已消失、命令在跑 → 渲染成蓝，而不是红。

**但只有外壳还不够**——会踩「残留进程」误判：一个 session 可能有个**以前的 dev server 外壳还活着**（残留），同时又弹了个**新的、真在等你确认的**弹窗；光看有没有外壳会把红误判成蓝。

**时刻守卫（决定性判据）**：
- 刚承认跑起来的命令，其外壳一定在 **`needs` 写入之后**才 spawn。
- 残留 dev server 在 `needs` **之前**就存在。
- → **只认「进程启动时刻 > state 文件 mtime（= needs 写入时刻）」的外壳。** 残留进程时刻更早，自动排除。

实现：`processStartEpoch(pid)`（进程启动 epoch，来自 `proc_bsdinfo.pbi_start_tv*`）对比 `fileMTime(state 文件)`。

### 最终判定表（回归时对照这张表）

| 情况 | 命令外壳 | 应显示 |
|---|---|---|
| 确认后长命令在跑 | 启动**晚于** needs | 运行中(蓝) |
| 残留 dev server + 新弹窗待确认 | 启动**早于** needs | 需确认(红) |
| AskUserQuestion / ExitPlanMode 等你答 | 无外壳 | 需确认(红) |
| 弹窗刚出、还没确认 | 无（命令未 spawn）| 需确认(红) |

### 相关代码位置（`main.swift`）

- `sessionStatus(tty:)` — 读 state 文件
- `fetchRows()` — 组装每行；`needs` 行在此调用探测覆盖为 working
- `runningToolCommand(claudePid:since:)` — 忙碌探测 + 时刻守卫（核心）
- `childPIDs(_:)` — libproc `PROC_PPID_ONLY` 取直接子进程
- `processStartEpoch(_:)` / `fileMTime(_:)` — 时刻对比两端
- `discoverSessions()` — 枚举活跃 `claude` 进程，`LiveSession.claudePid` 供探测用

### 配套约定

长命令（dev server / build / watch / `expo start`）**优先 `run_in_background`**（已写进全局 `~/.claude/CLAUDE.md`）：后台命令 Bash 立即返回 → `PostToolUse` 秒发 → 状态马上正确，从源头绕开前台阻塞盲区。

### 调试手法（状态又出错时）

1. 看真实事件顺序：在 hook 的 `atomic_write "$dir/state-$tty" "$state"` 之后临时加一行 append trace（`时间 tty action state hook_event_name` → `$dir/trace.log`），触发一次后 `cat` 看序列，**排查完删掉**。
2. 看进程树印证：
   ```bash
   CP=$(ps -Ao pid,tty,command | awk '$2=="ttysNNN" && /[c]laude$/{print $1;exit}')
   ps -Ao pid,ppid,stat,command | awk -v P="$CP" '$2==P'   # 看有无 zsh -c 外壳
   stat -f '%m' ~/.claude/taskbeacon/state-ttysNNN          # needs 写入时刻
   ps -o lstart= -p <外壳pid>                                # 外壳启动时刻，比大小
   ```

---

## 其它

- 跳转机制：点击行 → 跳 VSCode 窗口 = `switchToSpace` + AX raise + activate；同 Space 多窗靠 AXRaise 定位（见 `HotKey.swift` / `MainWindow.swift`）。
- 状态文件目录：`~/.claude/taskbeacon/`（`state-<tty>` / `title-<tty>` / `active-terminal` / `focus-request`）。
- 语言：代码/注释/commit 英文；本 md 文档中文。
