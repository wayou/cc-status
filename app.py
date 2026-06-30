#!/usr/bin/env python3
"""
cc-status — macOS menu bar app showing Claude Code session status.
Traffic light: 🟢 idle  🟡 working  🔴 waiting

Status is driven entirely by hook events written to ~/.claude/cc-status.json.
Sessions not updated within CRASH_TIMEOUT are silently pruned.
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

STATUS_FILE  = Path.home() / ".claude" / "cc-status.json"
SESSIONS_DIR = Path.home() / ".claude" / "sessions"
VERSION_FILE = Path.home() / ".cc-status" / "VERSION"
LOCK_FILE    = "/tmp/cc-status.lock"
CRASH_TIMEOUT    = 300   # seconds before a silent session is pruned
POLL_INTERVAL    = 1
UPDATE_CHECK_INTERVAL = 3600

REPO    = "wayou/cc-status"
ICON    = {"idle": "🟢", "working": "🟡", "waiting": "🔴"}
LABEL   = {"idle": "Idle", "working": "Working", "waiting": "Waiting"}
URGENCY = {"waiting": 0, "working": 1, "idle": 2}

# ── single-instance lock ──────────────────────────────────────────────────────
_lock_fh = open(LOCK_FILE, "w")
try:
    fcntl.flock(_lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)


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
        try:
            state = json.loads(STATUS_FILE.read_text())
            raw   = state.get("sessions", {})
            now   = int(time.time())
            sessions = {k: v for k, v in raw.items()
                        if now - v.get("updated_at", 0) < CRASH_TIMEOUT}
        except FileNotFoundError:
            sessions = {}
        except Exception:
            return

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
        ver = installed_version()
        if ver:
            ver_item = rumps.MenuItem(f"cc-status {ver}")
            ver_item._menuitem.setEnabled_(False)
            self.menu.add(ver_item)
        self.menu.add(self._quit_item)


if __name__ == "__main__":
    CCStatusApp().run()
