#!/usr/bin/env python3
"""
cc-status — macOS menu bar app showing Claude Code session status.
Traffic light: 🟢 idle  🟡 working  🔴 waiting

Tray icon  : winning (most urgent) session's status
Dropdown   : one row per session, sorted by urgency then start time
"""
import sys
import fcntl
import rumps
import json
import time
from pathlib import Path

STATUS_FILE   = Path.home() / ".claude" / "cc-status.json"
LOCK_FILE     = "/tmp/cc-status.lock"
CRASH_TIMEOUT = 300  # prune sessions silent for 5 min (crash recovery)
POLL_INTERVAL = 1

ICON  = {"idle": "🟢", "working": "🟡", "waiting": "🔴"}
LABEL = {"idle": "Idle", "working": "Working", "waiting": "Waiting"}
# Lower number = higher priority
URGENCY = {"waiting": 0, "working": 1, "idle": 2}

# ── single-instance lock ──────────────────────────────────────────────────────
_lock_fh = open(LOCK_FILE, "w")
try:
    fcntl.flock(_lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)


def winning_status(sessions: dict) -> str:
    if not sessions:
        return "idle"
    return min(sessions.values(), key=lambda v: URGENCY[v["status"]])["status"]


class CCStatusApp(rumps.App):
    def __init__(self):
        super().__init__(ICON["idle"], quit_button=None)
        self._quit_item = rumps.MenuItem("Quit", callback=lambda _: rumps.quit_application())
        self.menu = [self._quit_item]
        self._prev_sessions_key = None

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

        # Skip redraw if nothing changed
        cache_key = json.dumps(sessions, sort_keys=True)
        if cache_key == self._prev_sessions_key:
            return
        self._prev_sessions_key = cache_key

        # Tray icon = winning status
        self.title = ICON[winning_status(sessions)]

        # Rebuild dropdown
        self.menu.clear()

        if sessions:
            # Sort: urgency first, then oldest first (stable "first session" at top)
            ordered = sorted(
                sessions.items(),
                key=lambda kv: (URGENCY[kv[1]["status"]], kv[1].get("updated_at", 0))
            )
            for sid, info in ordered:
                status = info["status"]
                label  = f"{ICON[status]}  {sid[:8]}  {LABEL[status]}"
                item   = rumps.MenuItem(label)
                item._menuitem.setEnabled_(False)
                self.menu.add(item)
        else:
            empty = rumps.MenuItem("No active sessions")
            empty._menuitem.setEnabled_(False)
            self.menu.add(empty)

        self.menu.add(None)          # separator
        self.menu.add(self._quit_item)


if __name__ == "__main__":
    CCStatusApp().run()
