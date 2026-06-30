#!/usr/bin/env bash
# Kill all cc-status instances, clear state, restart via LaunchAgent.

echo "Stopping all instances..."
pkill -f "cc-status/app.py" 2>/dev/null; true
pkill -f "cc-status/app.py" 2>/dev/null; true  # second pass for stragglers
rm -f /tmp/cc-status.lock

echo "Rebuilding session state from live sessions..."
python3 - <<'EOF'
import json, os
from pathlib import Path

sessions_dir = Path.home() / ".claude" / "sessions"
out = {"sessions": {}}
import time; now = int(time.time())

for f in sessions_dir.glob("*.json"):
    try:
        d = json.loads(f.read_text())
        pid = d.get("pid")
        sid = d.get("sessionId")
        if not pid or not sid:
            continue
        # Check process is alive
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        out["sessions"][sid] = {"status": "working", "updated_at": now}
    except Exception:
        pass

Path.home().joinpath(".claude", "cc-status.json").write_text(json.dumps(out))
print(f"  Found {len(out['sessions'])} live session(s)")
EOF

echo "Restarting via LaunchAgent..."
launchctl unload ~/Library/LaunchAgents/com.ccstatus.plist 2>/dev/null; true
launchctl load   ~/Library/LaunchAgents/com.ccstatus.plist

sleep 2
COUNT=$(pgrep -f "cc-status/app.py" | wc -l | tr -d ' ')
if [[ "$COUNT" -eq 1 ]]; then
    echo "✓ 1 instance running — tray should show 🟢"
else
    echo "✗ Expected 1 instance, got $COUNT — check: cat /tmp/cc-status.log"
fi
