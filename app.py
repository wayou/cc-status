#!/usr/bin/env python3
"""
cc-status — macOS menu bar app showing Claude Code session status.
Traffic light: 🟢 idle  🟡 working  🔴 waiting
"""
import sys
import fcntl
import rumps
import json
import time
from pathlib import Path

STATUS_FILE   = Path.home() / ".claude" / "cc-status.json"
LOCK_FILE     = "/tmp/cc-status.lock"
CRASH_TIMEOUT = 300  # treat session as gone if silent for 5 min (crash recovery)
POLL_INTERVAL = 1

ICON  = {"idle": "🟢", "working": "🟡", "waiting": "🔴"}
LABEL = {"idle": "Idle", "working": "Working", "waiting": "Waiting"}

# ── single-instance lock ──────────────────────────────────────────────────────
_lock_fh = open(LOCK_FILE, "w")
try:
    fcntl.flock(_lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)  # another instance is already running


def aggregate(sessions: dict, now: int) -> tuple[str, int]:
    active = {k: v for k, v in sessions.items()
              if now - v.get("updated_at", 0) < CRASH_TIMEOUT}
    if not active:
        return "idle", 0
    statuses = [v["status"] for v in active.values()]
    if "waiting"  in statuses: return "waiting",  len(active)
    if "working"  in statuses: return "working",  len(active)
    return "idle", len(active)


class CCStatusApp(rumps.App):
    def __init__(self):
        super().__init__(ICON["idle"], quit_button=None)
        self._row_status   = rumps.MenuItem("🟢  Idle")
        self._row_sessions = rumps.MenuItem("No active sessions")
        self._row_status._menuitem.setEnabled_(False)
        self._row_sessions._menuitem.setEnabled_(False)
        self.menu = [
            self._row_status,
            self._row_sessions,
            None,
            rumps.MenuItem("Quit", callback=lambda _: rumps.quit_application()),
        ]

    @rumps.timer(POLL_INTERVAL)
    def _poll(self, _):
        try:
            state    = json.loads(STATUS_FILE.read_text())
            sessions = state.get("sessions", {})
            now      = int(time.time())
            status, n = aggregate(sessions, now)
        except FileNotFoundError:
            status, n = "idle", 0
        except Exception:
            return

        self.title = ICON[status]
        self._row_status.title = f"{ICON[status]}  {LABEL[status]}"
        noun = "session" if n == 1 else "sessions"
        self._row_sessions.title = f"{n} active {noun}" if n else "No active sessions"


if __name__ == "__main__":
    CCStatusApp().run()
