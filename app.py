#!/usr/bin/env python3
"""
cc-status — macOS menu bar app showing Claude Code session status.
Traffic light: 🟢 idle  🟡 working  🔴 waiting

Tray icon  : winning (most urgent) session's status
Dropdown   : one row per session, sorted by urgency then start time

Status sources (merged each poll):
  1. JSONL transcripts  — authoritative for idle vs working
  2. cc-status.json     — hooks overlay "waiting" on top (PermissionRequest)
"""
import sys
import fcntl
import rumps
import json
import time
import threading
import subprocess
import urllib.request
from pathlib import Path

STATUS_FILE   = Path.home() / ".claude" / "cc-status.json"
SESSIONS_DIR  = Path.home() / ".claude" / "sessions"
PROJECTS_DIR  = Path.home() / ".claude" / "projects"
VERSION_FILE  = Path.home() / ".cc-status" / "VERSION"
LOCK_FILE     = "/tmp/cc-status.lock"
CRASH_TIMEOUT = 300  # prune sessions silent for 5 min
POLL_INTERVAL = 1
UPDATE_CHECK_INTERVAL = 3600

REPO  = "wayou/cc-status"
ICON  = {"idle": "🟢", "working": "🟡", "waiting": "🔴"}
LABEL = {"idle": "Idle", "working": "Working", "waiting": "Waiting"}
URGENCY = {"waiting": 0, "working": 1, "idle": 2}

# ── single-instance lock ──────────────────────────────────────────────────────
_lock_fh = open(LOCK_FILE, "w")
try:
    fcntl.flock(_lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)


# ── JSONL-based session inference ─────────────────────────────────────────────

def _jsonl_tail(path: Path, n: int = 15) -> list:
    """Read last n lines from a JSONL file without loading the whole thing."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            pos, buf = f.tell(), b""
            while pos > 0 and buf.count(b"\n") < n + 1:
                chunk = min(4096, pos)
                pos -= chunk
                f.seek(pos)
                buf = f.read(chunk) + buf
        lines = [l for l in buf.split(b"\n") if l.strip()][-n:]
        return [json.loads(l) for l in lines if l]
    except Exception:
        return []


def _infer_status(entries: list) -> str:
    """Derive idle/working from the tail of a session transcript."""
    for entry in reversed(entries):
        t   = entry.get("type")
        msg = entry.get("message", {})
        if t == "assistant":
            sr = msg.get("stop_reason")
            if sr == "end_turn":
                return "idle"
            if sr == "tool_use":
                return "working"
        elif t == "user":
            content = msg.get("content", [])
            if isinstance(content, list) and content:
                if isinstance(content[0], dict) and content[0].get("type") == "tool_result":
                    return "working"
            # Plain human turn — session is idle, awaiting next prompt
            return "idle"
    return "idle"


def sessions_from_jsonl() -> dict:
    """Scan ~/.claude/projects/ and infer {session_id: {status, updated_at}}."""
    result = {}
    now = int(time.time())
    try:
        for project_dir in PROJECTS_DIR.iterdir():
            if not project_dir.is_dir():
                continue
            for jsonl in project_dir.glob("*.jsonl"):
                try:
                    mtime = jsonl.stat().st_mtime
                except OSError:
                    continue
                if now - mtime > CRASH_TIMEOUT:
                    continue
                sid     = jsonl.stem
                entries = _jsonl_tail(jsonl)
                if not entries:
                    continue
                result[sid] = {
                    "status":     _infer_status(entries),
                    "updated_at": int(mtime),
                }
    except Exception:
        pass
    return result


# ── helpers ───────────────────────────────────────────────────────────────────

def load_session_names() -> dict:
    names = {}
    try:
        for f in SESSIONS_DIR.glob("*.json"):
            try:
                data = json.loads(f.read_text())
                sid  = data.get("sessionId")
                name = data.get("name")
                if sid and name:
                    names[sid] = name
            except Exception:
                pass
    except Exception:
        pass
    return names


def winning_status(sessions: dict) -> str:
    if not sessions:
        return "idle"
    return min(sessions.values(), key=lambda v: URGENCY[v["status"]])["status"]


def installed_version() -> str:
    try:
        return VERSION_FILE.read_text().strip()
    except Exception:
        return ""


def fetch_latest_version() -> str:
    url = f"https://api.github.com/repos/{REPO}/releases/latest"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cc-status"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("tag_name", "")
    except Exception:
        return ""


# ── app ───────────────────────────────────────────────────────────────────────

class CCStatusApp(rumps.App):
    def __init__(self):
        super().__init__(ICON["idle"], quit_button=None)
        self._quit_item   = rumps.MenuItem("Quit", callback=lambda _: rumps.quit_application())
        self._update_item = None
        self._latest_version = ""
        self.menu = [self._quit_item]
        self._prev_sessions_key = None
        threading.Thread(target=self._update_check_loop, daemon=True).start()

    # ── update checker ────────────────────────────────────────────────────────

    def _update_check_loop(self):
        while True:
            latest  = fetch_latest_version()
            current = installed_version()
            if latest and latest != current:
                self._latest_version = latest
                self._update_item = rumps.MenuItem(
                    f"⬆️  Update to {latest}",
                    callback=self._on_install_update,
                )
            else:
                self._latest_version = latest
                self._update_item = None
            time.sleep(UPDATE_CHECK_INTERVAL)

    def _on_install_update(self, _):
        self._run_update(self._latest_version)

    def _run_update(self, version: str):
        script = (
            f'tell application "Terminal"\n'
            f'    activate\n'
            f'    do script "bash <(curl -fsSL https://github.com/{REPO}/releases/download/{version}/install.sh) {version}"\n'
            f'end tell'
        )
        subprocess.Popen(["osascript", "-e", script])

    # ── session poller ────────────────────────────────────────────────────────

    @rumps.timer(POLL_INTERVAL)
    def _poll(self, _):
        # 1. Ground truth: infer idle/working from JSONL transcripts
        sessions = sessions_from_jsonl()

        # 2. Overlay: trust "waiting" from hook file when the session is still active
        now = int(time.time())
        try:
            hook_state = json.loads(STATUS_FILE.read_text())
            for sid, info in hook_state.get("sessions", {}).items():
                if (info.get("status") == "waiting"
                        and now - info.get("updated_at", 0) < CRASH_TIMEOUT
                        and sessions.get(sid, {}).get("status") == "working"):
                    sessions[sid] = info
        except Exception:
            pass

        # Skip redraw if nothing changed
        cache_key = json.dumps(sessions, sort_keys=True)
        if cache_key == self._prev_sessions_key:
            return
        self._prev_sessions_key = cache_key

        self.title = ICON[winning_status(sessions)]

        self.menu.clear()

        if sessions:
            names   = load_session_names()
            ordered = sorted(
                sessions.items(),
                key=lambda kv: (URGENCY[kv[1]["status"]], kv[1].get("updated_at", 0))
            )
            for sid, info in ordered:
                status = info["status"]
                title  = names.get(sid, sid[:8])
                label  = f"{ICON[status]}  {title}  {LABEL[status]}"
                item   = rumps.MenuItem(label)
                item._menuitem.setEnabled_(False)
                self.menu.add(item)
        else:
            empty = rumps.MenuItem("No active sessions")
            empty._menuitem.setEnabled_(False)
            self.menu.add(empty)

        self.menu.add(None)
        if self._update_item:
            self.menu.add(self._update_item)
            self.menu.add(None)
        self.menu.add(self._quit_item)


if __name__ == "__main__":
    CCStatusApp().run()
