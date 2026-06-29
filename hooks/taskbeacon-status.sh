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

# Write atomically: a temp file in the same dir + mv (rename(2)). This changes the
# directory entry, which fires the app's watchers (FSEvents *and* the kqueue dir
# source) instantly and reliably — a plain `>` truncates in place (same inode), and
# some watch paths miss or delay that, which is what made the row lag the prompt.
atomic_write() { # $1=dest  $2=content
  local tmp="$1.$$.tmp"
  printf '%s' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

# Read the hook payload once. UserPromptSubmit carries .prompt; Notification carries
# .message; Pre/PostToolUse carry neither. We branch on what's present below.
input=$(cat)

# Locate the controlling tty by climbing to the ancestor that owns a terminal.
tty=""
p=$PPID
while [ "${p:-0}" -gt 1 ]; do
  t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
  case "$t" in ttys*) tty="$t"; break ;; esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
[ -z "$tty" ] && exit 0

mkdir -p "$dir"

# SessionStart fires on startup/resume/clear/compact. On a /clear the conversation
# is wiped but the title-<tty> file still advertises the previous task, so the app's
# row keeps the stale label until the next prompt. Reset it here: drop the title so
# the row falls back to the folder name, and mark the session idle (灰「闲置」). A
# fresh startup (or just-cleared conversation) has run nothing yet, so it's idle —
# not "done/绿", which means a turn finished and is waiting on you, something a
# brand-new terminal never did. Only
# "clear" (and "startup" — a fresh claude on a tty a prior session left a title on)
# should reset; "resume"/"compact" keep working on the same conversation, so their
# title is still meaningful.
if [ "$action" = "session-start" ]; then
  source=$(printf '%s' "$input" | /usr/bin/python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('source', ''))
except Exception: pass
" 2>/dev/null)
  case "$source" in
    clear|startup)
      rm -f "$dir/title-$tty"
      atomic_write "$dir/state-$tty" "idle"
      ;;
  esac
  exit 0
fi

# Resolve the state and write it FIRST — before the (slow) title derivation below —
# so the menu-bar app's FSEvents watcher flips the row the instant Claude asks. The
# title step spins up python (~hundreds of ms cold); doing it before the state write
# is what made the red "needs" lag behind the actual prompt.
state="$action"
if [ "$action" = "needs" ]; then
  # Only a permission/confirmation notification is red; the idle "waiting for your
  # input" notification means the turn is over → done. grep -i keeps this off the
  # python path so the latency-critical "needs" write isn't delayed by a cold start.
  if printf '%s' "$input" | grep -qi "waiting for your input"; then
    state="done"
  else
    state="needs"
  fi
elif [ "$action" = "working" ]; then
  # PreToolUse for a tool that STOPS and waits on you — AskUserQuestion (confirm a
  # direction) or ExitPlanMode (approve a plan) — means it's your turn the instant the
  # tool fires, long before Claude Code's delayed idle notification would say so. Flip
  # straight to needs (红) so "等你确认" is real-time, not just permission prompts.
  # Gate on hook_event_name=PreToolUse: the matching PostToolUse fires with the same
  # tool_name once you've answered, and that one must fall through to working (蓝).
  # Fast string match on the raw payload — no python on this every-tool-call path.
  case "$input" in
    *'"hook_event_name":"PreToolUse"'*|*'"hook_event_name": "PreToolUse"'*)
      case "$input" in
        *'"tool_name":"AskUserQuestion"'*|*'"tool_name": "AskUserQuestion"'* \
        |*'"tool_name":"ExitPlanMode"'*|*'"tool_name": "ExitPlanMode"'*)
          state="needs" ;;
      esac ;;
  esac
fi

atomic_write "$dir/state-$tty" "$state"

# Play a distinct sound on the two states the user cares about — but NO visual
# notification. The TaskBeacon app already shows its own clickable Toast banner
# on these same transitions; a second macOS notification here would double up.
# done → Glass (清亮，完成); needs → Funk (低沉，提醒). Backgrounded so afplay
# never blocks the hook's 5s timeout.
case "$state" in
  done)  afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 & ;;
  needs) afplay /System/Library/Sounds/Funk.aiff  >/dev/null 2>&1 & ;;
esac

# Derive a human-readable session title from the user's prompt so the app can label the
# row with "what this session is doing" instead of the bare ttysNNN. Deferred to here
# (after the state write) so its python cold start never delays the row's color flip.
# Only UserPromptSubmit carries .prompt, so skip the python spin-up entirely when the
# payload has none (Pre/PostToolUse "working", Notification "needs") — the last title
# persists across the turn. Collapse whitespace, cap at 24 chars (unicode-safe) so the
# row label stays short enough to leave room for the status pill.
case "$input" in
  *'"prompt"'*)
    title=$(printf '%s' "$input" | /usr/bin/python3 -c "
import sys, json
try: p = (json.load(sys.stdin).get('prompt', '') or '').strip()
except Exception: p = ''
print(' '.join(p.split())[:24])
" 2>/dev/null)
    [ -n "$title" ] && atomic_write "$dir/title-$tty" "$title"
    ;;
esac

exit 0
