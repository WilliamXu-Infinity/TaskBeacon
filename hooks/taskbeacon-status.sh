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
#   $1 = needs   -> PermissionRequest              (permission dialog)     红
#                   PermissionRequest fires the instant the dialog appears — the
#                   real-time needs signal. Notification is ALSO mapped to "needs"
#                   as a fallback, but Claude Code debounces it (~2-4s lag), and it
#                   double-duties as the idle "waiting for your input" ping, which is
#                   NOT done: it fires while a session merely sits waiting, so it must
#                   not repaint an idle row green 完成 — Stop already owns "done".
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
      # Stamp a fresh usage boundary: the menu app counts this session's time/tokens
      # only from here on, so a /clear (or a reopened terminal) resets its counters.
      atomic_write "$dir/session-$tty" "$(date +%s)"
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
  # Two events map to this action, and they differ in latency by SECONDS:
  #
  #   PermissionRequest — fires the instant the permission dialog appears. This is
  #     the real-time, ground-truth "needs" signal and the one we prefer. Its payload
  #     carries no .message to grep; by definition it IS a permission request, so flip
  #     to needs (红) unconditionally. Fast `case` match on the raw payload — no python,
  #     no grep, on this latency-critical path.
  #
  #   Notification — Claude Code DEBOUNCES this (it lags the on-screen prompt by ~2-4s),
  #     so it's only a FALLBACK for older Claude Code that lacks PermissionRequest. It
  #     also double-duties as the idle "waiting for your input" ping, which is NOT a
  #     completion: it fires while a session merely sits idle, so writing "done" here
  #     would repaint a quiet row green 完成 out of nowhere (the "闲置突然变绿" bug).
  #     Stop already owns "done", so on the idle ping we preserve the current state and
  #     exit before the state write below. Only an explicit permission/approval message
  #     becomes needs.
  case "$input" in
    *'"hook_event_name":"PermissionRequest"'*|*'"hook_event_name": "PermissionRequest"'*)
      state="needs" ;;
    *)
      if printf '%s' "$input" | grep -qiE 'needs your (permission|approval)'; then
        state="needs"
      else
        exit 0
      fi ;;
  esac
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

# --- Usage log (append-only, off the critical path) --------------------------
# Append one JSONL line per event worth counting to events.jsonl, so the app's
# stats window can tally — per day and per project — how many task runs you
# kicked off and how many decisions you had to make. Placed dead last so it never
# delays the row's color flip. `state` was already resolved above; map it:
#   state = needs                          -> "decision" (each permission/plan/question)
#   action = working + event=UserPrompt... -> "run"      (one per new user turn = one task)
#   action = done                          -> "done"     (turn completed)
# The run gate matches hook_event_name, NOT a bare "prompt" substring: a PreToolUse
# for a tool that carries its own tool_input.prompt (e.g. Task/Agent) also fires as
# "working" and would over-count runs. Idle pings already exited; a plain PreToolUse
# working logs nothing. O_APPEND makes each one-line write atomic across ttys.
log_event=""
case "$state" in
  needs) log_event="decision" ;;
  *)
    if [ "$action" = "done" ]; then
      log_event="done"
    elif [ "$action" = "working" ]; then
      case "$input" in
        *'"hook_event_name":"UserPromptSubmit"'*|*'"hook_event_name": "UserPromptSubmit"'*)
          log_event="run" ;;
      esac
    fi ;;
esac

if [ -n "$log_event" ]; then
  printf '%s' "$input" | EV="$log_event" TTY="$tty" DIR="$dir" /usr/bin/python3 -c '
import sys, json, os, time
try: d = json.load(sys.stdin)
except Exception: d = {}
cwd = (d.get("cwd") or "").rstrip("/")
project = cwd.rsplit("/", 1)[-1] if cwd else "unknown"
title = " ".join((d.get("prompt") or "").split())[:80]
rec = {"ts": int(time.time()), "date": time.strftime("%Y-%m-%d"),
       "event": os.environ["EV"], "project": project or "unknown",
       "cwd": cwd, "tty": os.environ["TTY"], "title": title}

# On turn completion, tally THIS turn'"'"'s token usage from the transcript. The Stop
# payload carries transcript_path; it points at a real file only when the session
# actually saves one (sessions that inherit CLAUDE_CODE_CHILD_SESSION are treated as
# children and skip the write — unset it to get transcripts back). One pass over the
# file, resetting at every genuine user prompt, leaves the last turn standing.
# Defensive throughout: a missing transcript just omits the token fields.
if os.environ["EV"] == "done":
    tp = d.get("transcript_path") or ""
    if tp and os.path.exists(tp):
        try:
            turn = {}   # requestId -> usage (the one with the largest output_tokens)
            model = ""  # last assistant model seen this turn — drives cost estimation
            with open(tp) as tf:
                for line in tf:
                    line = line.strip()
                    if not line: continue
                    try: e = json.loads(line)
                    except Exception: continue
                    t = e.get("type")
                    if t == "user":
                        # A genuine prompt (a string, or a list with a text block) starts a
                        # new turn; a tool_result-only user turn does not. Reset on the former.
                        c = (e.get("message") or {}).get("content")
                        if isinstance(c, str) or (isinstance(c, list) and any(
                                isinstance(x, dict) and x.get("type") == "text" for x in c)):
                            turn = {}
                            model = ""
                    elif t == "assistant":
                        m = (e.get("message") or {}).get("model")
                        if m: model = m   # keep the turn'"'"'s model for the cost table
                        u = (e.get("message") or {}).get("usage") or {}
                        if not u: continue
                        # One API call streams as several assistant events sharing a
                        # requestId; only the last carries the final output_tokens. Keep the
                        # max per requestId so each call counts once (matches /stats, which
                        # otherwise over-counts 3-10x).
                        rid = e.get("requestId") or e.get("uuid") or len(turn)
                        prev = turn.get(rid)
                        if prev is None or u.get("output_tokens", 0) >= prev.get("output_tokens", 0):
                            turn[rid] = u
            us = turn.values()
            rec.update(
                tok_in=sum(u.get("input_tokens", 0) for u in us),
                tok_out=sum(u.get("output_tokens", 0) for u in us),
                tok_cache_w=sum(u.get("cache_creation_input_tokens", 0) for u in us),
                tok_cache_r=sum(u.get("cache_read_input_tokens", 0) for u in us),
                api_calls=len(turn))
            if model: rec["model"] = model
        except Exception: pass

with open(os.path.join(os.environ["DIR"], "events.jsonl"), "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
' 2>/dev/null
fi

exit 0
