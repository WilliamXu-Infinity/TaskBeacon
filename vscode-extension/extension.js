const vscode = require('vscode');
const os = require('os');
const path = require('path');

// TaskBeacon focuses the exact integrated terminal of a Claude session.
//
// The app writes the target shell pid to ~/.claude/taskbeacon/focus-request. EVERY
// open VSCode window runs this extension and watches that one file, so a single
// write wakes all windows; only the window that actually owns a terminal whose
// `processId` == pid reveals it — and revealing a terminal brings its window to
// the front. This is why focus works across multiple windows.
//
// The old `vscode://taskbeacon.focus/focus?pid=<pid>` URI is delivered to
// only the last-active window, so it can't reach a terminal living in another
// window. It's still handled here for backward compatibility with older app
// builds, but the app now uses the file-watch path above.

const FOCUS_DIR = path.join(os.homedir(), '.claude', 'taskbeacon');
const FOCUS_FILE = 'focus-request';
const ACTIVE_FILE = 'active-terminal';

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      handleUri(uri) {
        if (uri.path !== '/focus') return;
        const pid = parseInt(new URLSearchParams(uri.query).get('pid') || '', 10);
        if (Number.isInteger(pid)) focusByPid(pid);
      },
    })
  );

  // Watch the request file. RelativePattern with an absolute base lets us watch a
  // path outside the workspace; the watcher lives in every window's extension
  // host, so all windows react to a single write.
  const watcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(vscode.Uri.file(FOCUS_DIR), FOCUS_FILE)
  );
  watcher.onDidCreate(handleFocusRequest);
  watcher.onDidChange(handleFocusRequest);
  context.subscriptions.push(watcher);

  // Report the terminal the user just focused, so the app can auto-dismiss that
  // session's toast — going to the terminal yourself is the same as clicking the
  // banner. Fires when the active terminal changes, and when this window regains
  // focus (the user switched back to it to deal with its Claude session).
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTerminal((term) => reportActiveTerminal(term)),
    vscode.window.onDidChangeWindowState((state) => {
      if (state.focused) reportActiveTerminal(vscode.window.activeTerminal);
    })
  );
}

// Write "<shellPid>:<nonce>" to active-terminal. The nonce (a timestamp) makes
// every focus a distinct write so the app acts only on genuine new focus events,
// never on a stale value re-read when some other file in the dir changes.
async function reportActiveTerminal(term) {
  if (!term) return;
  let pid;
  try {
    pid = await term.processId;
  } catch {
    return;
  }
  if (!Number.isInteger(pid)) return;
  try {
    await vscode.workspace.fs.writeFile(
      vscode.Uri.file(path.join(FOCUS_DIR, ACTIVE_FILE)),
      Buffer.from(`${pid}:${Date.now()}`, 'utf8')
    );
  } catch {
    /* best-effort */
  }
}

async function handleFocusRequest() {
  let text;
  try {
    const bytes = await vscode.workspace.fs.readFile(
      vscode.Uri.file(path.join(FOCUS_DIR, FOCUS_FILE))
    );
    text = Buffer.from(bytes).toString('utf8');
  } catch {
    return;
  }
  // Content is "<pid>:<nonce>"; the nonce only exists to force a distinct write
  // so the watcher fires even when the same session is focused twice in a row.
  const pid = parseInt(text.split(':')[0].trim(), 10);
  if (Number.isInteger(pid)) focusByPid(pid);
}

async function focusByPid(pid) {
  for (const term of vscode.window.terminals) {
    let tpid;
    try {
      tpid = await term.processId;
    } catch {
      continue;
    }
    if (tpid === pid) {
      term.show(false); // preserveFocus=false → terminal takes keyboard focus
      // Report the focus directly rather than relying on onDidChangeActiveTerminal:
      // when this terminal is ALREADY the window's active terminal (the common case —
      // you were just there, or it's the only terminal), term.show() fires no change
      // event, so the app would never learn the session was focused and a "done" row
      // would stay green forever. A direct write (fresh nonce) always reaches the app.
      reportActiveTerminal(term);
      return;
    }
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
