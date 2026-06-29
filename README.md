# TaskBeacon

> 一个 macOS 菜单栏小程序：在一个地方盯住所有正在跑的 Claude Code 会话，一眼看清每个会话「在干嘛 / 要不要管」，点一下精准跳回对应的**终端**（焦点直接落到它的输入框）—— 同一个 VSCode 窗口里的两个 AI 也能分别定位。

纯 Swift + Cocoa，单文件二进制，**不需要 Xcode**，`./build.sh` 直接出 `.app`。

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-black)
![language](https://img.shields.io/badge/swift-Cocoa-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

---

## 目录

- [是什么](#是什么)
- [安装](#安装)
- [快速开始（从源码构建）](#快速开始从源码构建)
- [工作原理](#工作原理)
- [状态含义](#状态含义菜单栏--列表--toast-三处一致)
- [依赖](#依赖)
- [开机自启（可选）](#开机自启可选)
- [文件结构](#文件结构)
- [已知限制](#已知限制)
- [License](#license)

---

## 是什么

- **菜单栏图标**：彩色汇总各状态的会话数，如 `●2 ⠙1 ●1`（红 2 需确认 / 蓝 1 运行中 / 绿 1 完成）。运行中的会转圈圈（Braille spinner）。
- **下拉菜单**：**每行一个会话**（一个活的 `claude` 进程），点行 → 跳到那个终端；底部有「打开主界面 / 刷新 / 退出」。
- **主窗口**（Liquid Glass 毛玻璃面板）：顶部 wordmark + 汇总 + 刷新按钮，下面是状态 chips 和**按 VSCode 窗口分组**的会话列表，hover 卡片会发光、出现跳转箭头。

  ```
  🔴  miner                                    ·  ttys004 · 需确认   ← 单会话文件夹 = 一张卡

  fleet-bar                            🔴1  🔵1  🟢1   ← 多会话文件夹 = 组标题 + 聚合徽标
    │ 🔴  ttys008                         · 需确认       ← 下挂各 tty 子行（缩进 + 状态轨）
    │ 🔵  ttys006                         · 运行中
    │ 🟢  ttys005                         · 完成
  ```

  **单会话文件夹**直接渲染成一张卡（点 → 精准跳那个终端）。**多会话文件夹**渲染成「组标题 + 子列表」：标题右侧用彩色徽标聚合各状态数量（🔴N 需确认 / 🔵N 运行中 / 🟢N 完成 / ⚪N 已确认+闲置，nonzero only，最紧急排前），一眼看清整个窗口状态；点组标题 → 抬起该文件夹窗口，点某条子行 → 精准跳那个终端。
- **Toast 浮窗**：某会话刚进入「需确认 / 完成」时，右上角弹一张 Apple 通知样式的卡片，点一下 → 跳到该终端 + 标记已看；8 秒自动消失。**你自己切到对应终端时，这张卡片也会自动消失**（伴生扩展上报当前聚焦的终端 → App 等价于帮你点了一下；没装扩展时退化为「会话一离开需确认/完成就消失」）。
- **点过即变灰（仅「完成」）**：点开过的「完成」行立刻回落成灰色「已确认」，表示你已经看过；直到该会话有新动静才恢复彩色。菜单、主窗口、toast 三处点击都生效。
  - **「需确认」不会因点击而变灰**：点行只是跳到终端，你**还没真的批准/确认**。所以它保持红色，直到你在终端里真正操作、hook 删除状态标记（权威信号）后才自然变色。避免「点了就显示已确认，但其实没确认」的误报。
- **排序**：需确认 → 运行中 → 完成 → 已确认 / 闲置（最该管的永远在最上）。

---

## 安装

### 方式 A：一键安装包（给最终用户）

`package.sh` 会把 app + hook + VSCode 扩展 + 安装器打成一个 `.dmg`（hdiutil 不可用时退化为 `.zip`）：

```bash
./package.sh          # 产出 TaskBeacon-1.0-installer.dmg
```

把 `.dmg` 发给别人后，对方只需：

1. 打开 `.dmg`，**双击 `install.command`**（首次被 Gatekeeper 拦截 → 右键 `install.command` → 「打开」→ 再点一次「打开」）。
   安装器会自动：装 app 到 `/Applications`（并去 quarantine）、装 hook、幂等合并 hook 接线进 `~/.claude/settings.json`、装 VSCode 扩展。
2. 回到 VSCode，`Cmd+Shift+P` → **Developer: Reload Window**（让「精准跳转终端」生效，只需一次）。

卸载：双击安装包里的 `uninstall.command`，干净移除 app + hook + 配置 + 扩展。

> 这个 app 没做 Apple 公证，首次打开需上面的右键「打开」步骤，属正常现象。安装器只往 `~/.claude` 和 `~/.vscode/extensions` 写文件。

### 方式 B：从源码构建（开发者）

见下一节。`build.sh` 出 `.app`，hook 和扩展需手动接线（[工作原理](#工作原理) 里有完整 hook 配置和 `vscode-extension/install.sh`）。

---

## 快速开始（从源码构建）

```bash
./build.sh            # swiftc 编译 + 打包 + 生成图标 + ad-hoc 签名
open TaskBeacon.app
```

改完代码重新构建并重启：

```bash
./build.sh && osascript -e 'quit app "TaskBeacon"' 2>/dev/null; open TaskBeacon.app
```

> 要求 macOS 13+。app 是 `.regular` 模式，菜单栏图标 + Dock 图标 + 主窗口同时存在；关掉主窗口不会退出，仍驻留菜单栏。
> `UNIVERSAL=1 ./build.sh` 构建同时支持 Apple Silicon (arm64) 与 Intel (x86_64) 的 fat binary（`package.sh` 用它）。

---

## 工作原理

### 1. 会话发现（libproc，不依赖 c9watch）

Claude Code v2.1 的 daemon / bg-pty-host 架构不再把 `--session-id` 写进交互式终端会话的 argv，任何「扒 argv」的工具都会漏掉这些会话。所以 TaskBeacon 自己用 libproc 枚举，**每个活 `claude` 进程就是一行**：

1. `proc_listpids` 列出所有进程
2. 经 `KERN_PROCARGS2` 读 argv，只留 arg0 basename 为 `claude` 的；跳过 `daemon` / `--bg-pty-host` / `--bg-spare` / `--type=*` 这些非用户终端的辅助进程
3. `proc_pidinfo(PROC_PIDVNODEPATHINFO)` 读 cwd；`proc_pidinfo(PROC_PIDTBSDINFO)` 读 **ppid（= 终端的 shell pid）** 和 **控制 tty**（如 `ttys006`）
4. 同一 `KERN_PROCARGS2` buffer 里 argv 之后紧跟 env，从中取 `CLAUDE_CODE_SSE_PORT`（每进程唯一）→ 用它解析出**真实 session id**（见下）

### 2. 真实 session id ＝ SSE 端口 → hook 映射

`CLAUDE_CODE_SESSION_ID` 在 env 里是**继承来的**：从另一个会话里敲命令起的终端，会带上那个祖先会话的 id —— 不可信。可信的是 `CLAUDE_CODE_SSE_PORT`，它每进程唯一。

于是 hook 在每次触发时把 `端口 → 真实 session id` 写进 `~/.claude/taskbeacon/sse-<port>`（hook 拿到的 `session_id` 是 Claude 注入的真实值，且它继承了同一个 `CLAUDE_CODE_SSE_PORT`）。App 读每个活进程的 SSE 端口，在这张表里 join 出真实 session id —— 这样同一文件夹的两个会话也能各认各的 transcript。

### 3. 状态判定（逐会话）

拿到真实 session id 后，直接定位它**那一个** transcript 来判定：

| 内部状态 | 判据 | 来源 |
|---------|------|------|
| `needs` 红 | 存在 `~/.claude/taskbeacon/<session_id>.needs` 标记 | **hook**（权威信号） |
| `working` 蓝 | 该会话 transcript 在 **8 秒内**有写入 | `~/.claude/projects/<编码cwd>/<sid>.jsonl` 的 mtime |
| `done` 绿 | 有活会话但 transcript 已静默 | 同上 |
| `working` 蓝 | 还没解析出 session id（hook 未触发过）/ transcript 还没落盘 | 兜底当作运行中 |
| `seen` 灰 | `needs`/`done` 被点开确认，真实状态还没变 | App 内存 ack 记录 |

cwd → 目录名编码：把每个非字母数字字符替换成 `-`（与 `~/.claude/projects` 命名一致），如 `/Users/me/.claude/WX` → `-Users-me--claude-WX`。

### 4. 为什么「需确认」必须靠 hook

transcript JSONL 在「工具执行中」和「卡在权限确认弹窗」时长得一模一样，App 无法从文件区分。所以用 hook 做权威信号，同时它也维护上面的 SSE 端口映射：

- `~/.claude/hooks/taskbeacon-status.sh` 接收一个动作参数 `needs` / `clear`，从 stdin 的 JSON 取 `session_id` 和 `message`，并把 `sse-<CLAUDE_CODE_SSE_PORT> → session_id` 落盘
- **`needs`**（`Notification` 事件触发）：若 `message` 含 `waiting for your input`（空闲提醒）→ 清标记当 done/idle；否则（权限/确认）→ 写 `~/.claude/taskbeacon/<sid>.needs`
- **`clear`**（`Stop` / `UserPromptSubmit` / `PreToolUse` 触发）：删标记

挂进 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh needs" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh clear" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh clear" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/taskbeacon-status.sh clear" }] }]
  }
}
```

> 一键安装包（`install.command`）会**幂等地**帮你合并这段接线，不动你已有的其它 hook。从源码跑则需手动加。hook 只对**装好之后新开 / 之后有活动的**会话生效。

### 5. 跳转到精确终端（伴生 VSCode 扩展）

VSCode 是 Electron/Chromium，终端 tab 默认不进 macOS 辅助功能树，进程树也看不出某终端属于哪个窗口 / panel 第几个 —— 所以「点哪个就聚焦哪个终端」靠一个极小的伴生扩展：

```
/usr/bin/open "vscode://taskbeacon.focus/focus?pid=<shellPid>"
```

扩展（`vscode-extension/`）注册 URI handler，遍历 `vscode.window.terminals`，找到 `processId === shellPid` 的那个，调 `terminal.show(false)` —— 用稳定公开 API 把对应终端在它所在窗口里聚焦，光标落到输入框，跨窗口可靠、不怕 VSCode 升级。

反向通道：扩展监听 `onDidChangeActiveTerminal` / `onDidChangeWindowState`，把**用户当前聚焦的终端** shell pid 写到 `~/.claude/taskbeacon/active-terminal`（带时间戳 nonce）。App 每轮轮询（2.5s）读这个文件，发现**新** token 就 dismiss 该会话的 toast 并标记已看 —— 你自己去终端 = 你已经看过了，不用再手动点卡片。nonce 保证只对真正的新焦点动作生效，同一终端再次聚焦也算一次新动作。

**手动安装一次**：`./vscode-extension/install.sh` → 在 VSCode 里执行一次 `Developer: Reload Window`（一键安装包已自动装好，仍需 Reload 一次）。没装扩展时，App 退化为 `open -b com.microsoft.VSCode <cwd>` 只聚焦该文件夹的窗口。

### 6. 刷新节奏

- 数据轮询：每 **2.5s** 重新发现 + 判定
- spinner 动画：每 **0.1s** 推进一帧（仅当有 working 项目时）

---

## 状态含义（菜单栏 + 列表 + toast 三处一致）

| 颜色 | 状态 | 含义 | 该不该管 |
|------|------|------|---------|
| 🔴 珊瑚红 | 需确认 | Claude 在等你批权限/确认 | ✅ 立刻去看 |
| 🔵 天蓝（呼吸/转圈） | 运行中 | 正在执行 | 等着就行 |
| 🟢 薄荷绿 | 完成 | 跑完了等你输入 | ✅ 去看 |
| ⚪️ 灰 | 已确认 | 红/绿已被你点开看过，回落成灰直到有新动静 | 已处理 |
| ⚪️ 冷灰 | 闲置 | 没有活动的 transcript | 不用管 |

---

## 依赖

- **macOS 13+**，VSCode（bundle id `com.microsoft.VSCode`）
- **伴生扩展 `vscode-extension/`**（精确聚焦终端；`install.sh` 安装后 Reload Window）
- **`~/.claude/hooks/taskbeacon-status.sh`** + `~/.claude/settings.json` 里的 hook 接线（提供「需确认」权威信号 + SSE 端口→session id 映射）
- 读取 **`~/.claude/projects/<编码cwd>/<sid>.jsonl`** 的 mtime 判 working/done
- 读取/创建 **`~/.claude/taskbeacon/`** 下的 `.needs` 标记和 `sse-<port>` 映射
- 构建期：`swiftc`、`iconutil`、`codesign`（随 Xcode Command Line Tools 提供）

---

## 开机自启（可选）

```bash
# 开启
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/TaskBeacon.app", hidden:true}'

# 取消
osascript -e 'tell application "System Events" to delete login item "TaskBeacon"'
```

---

## 文件结构

| 路径 | 作用 |
|------|------|
| `main.swift` | 入口 + `AppController`（会话发现 / session id 解析 / 状态判定 / 菜单栏 / 终端聚焦 / ack）+ `Status` 枚举 + `ToastManager` 浮窗 |
| `MainWindow.swift` | 毛玻璃主窗口 `MainWindowController` + 会话卡片 `RowCell` |
| `Components.swift` | 复用控件：`StatusDot`（发光状态点）、`CapsuleLabel`（状态 pill / 数量 chip）、`GlassButton` |
| `Theme.swift` | 设计 token（间距/圆角/字体/毛玻璃）+ 语义状态配色 |
| `hooks/taskbeacon-status.sh` | 状态 hook：写 `needs` 标记 + 维护 SSE 端口→session id 映射（安装时拷到 `~/.claude/hooks/`） |
| `vscode-extension/` | 伴生 VSCode 扩展（`package.json` + `extension.js` + `install.sh`）：按 shell pid 精确聚焦终端 |
| `installer/` | 一键安装包内容：`install.command` / `uninstall.command` / `先看我.txt` |
| `tools/make-icon.swift` | 用 Core Graphics 生成 app 图标 iconset |
| `tools/setup-signing-cert.sh` | 生成本地自签名证书（可选） |
| `build.sh` | `swiftc -O *.swift` 编译 → 生成图标 → 写 Info.plist → ad-hoc 签名 → 打包 `.app` |
| `package.sh` | 调 `build.sh`（UNIVERSAL）→ 把 app + hook + 扩展 + 安装器打成 `.dmg` / `.zip` |

> `TaskBeacon.app` 与各 `*.zip` / `*.dmg` 都是构建产物，已 `.gitignore`，由 `build.sh` / `package.sh` 重新生成。

---

## 已知限制

- 逐会话状态依赖 hook 写过 `sse-<port>` 映射。一个会话从装好 hook 起还没触发过任何事件时（极少见），暂时解析不出真实 session id，状态兜底显示「运行中」蓝色，直到它有一次活动。
- `working` 判据是「transcript 8 秒内有写入」。Claude 的 transcript 是突发写入（执行工具/等待时不落盘），一个 turn 中途若静默超过 8 秒，运行中的会话会短暂显示成绿色「完成」。
- 精确终端聚焦要求装好伴生扩展并 Reload 过窗口；没装时退化为只聚焦文件夹窗口（不区分该窗口里的哪个终端）。
- 终端必须有控制 tty（VSCode/iTerm/Terminal 集成终端都有）；`terminal.processId` 取的是 shell pid，即 `claude` 进程的父进程。

---

## License

[MIT](./LICENSE) © 2026 William Xu
