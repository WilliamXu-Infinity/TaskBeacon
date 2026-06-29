#!/bin/bash
# TaskBeacon status hook — records each session's live state for the menu bar app.
#
# Why a hook instead of reading transcripts: Claude Code v2.1's daemon architecture
# stopped writing a discoverable ~/.claude/projects/<cwd>/<session>.jsonl for live
# terminal sessions (and the hook's session_id no longer matches any jsonl on disk),
# so transcript-mtime can't tell "working" from "done" anymore — everything looked
# blue. The hooks themselves are the reliable signal; they fire on exactly the
# transitions we care about:
#   $1 = working -> UserPromptSubmit / PreToolUse  (model is busy)        蓝
#   $1 = done    -> Stop                           (turn ended, your turn) 绿
#   $1 = needs   -> Notification                   (permission prompt)     红
#                   the idle "waiting for your input" notification is just done.
#
# State is keyed by the session's controlling tty, not env: both CLAUDE_CODE_SESSION_ID
# and CLAUDE_CODE_SSE_PORT are inherited and shared by every terminal in the same
# VSCode window, so they'd collapse sibling sessions into one. The tty is unique per
# terminal. This hook runs piped (no tty of its own), so we walk up the parent chain
# to the `claude` process that owns the terminal. The app joins each live process on
# its own tty (~/.claude/taskbeacon/state-<tty>) to read its state.
action="$1"
dir="$HOME/.claude/taskbeacon"

# Locate the controlling tty by climbing to the ancestor that owns a terminal.
tty=""
p=$PPID
while [ "${p:-0}" -gt 1 ]; do
  t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
  case "$t" in ttys*) tty="$t"; break ;; esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
[ -z "$tty" ] && exit 0

state="$action"
if [ "$action" = "needs" ]; then
  # Only a permission/confirmation notification is red; the idle "waiting for your
  # input" notification means the turn is over → done.
  msg=$(cat | /usr/bin/python3 -c "import sys,json; print((json.load(sys.stdin).get('message','') or '').lower())" 2>/dev/null)
  case "$msg" in
    *"waiting for your input"*) state="done" ;;
    *)                          state="needs" ;;
  esac
fi

mkdir -p "$dir"
printf '%s' "$state" > "$dir/state-$tty"

# Play a distinct sound on the two states the user cares about — but NO visual
# notification. The TaskBeacon app already shows its own clickable Toast banner
# on these same transitions; a second macOS notification here would double up.
# done → Glass (清亮，完成); needs → Funk (低沉，提醒). Backgrounded so afplay
# never blocks the hook's 5s timeout.
case "$state" in
  done)  afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 & ;;
  needs) afplay /System/Library/Sounds/Funk.aiff  >/dev/null 2>&1 & ;;
esac
exit 0
