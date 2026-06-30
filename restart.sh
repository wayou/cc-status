#!/usr/bin/env bash
# Kill all cc-status instances, clear state, restart via LaunchAgent.

echo "Stopping all instances..."
pkill -f "cc-status/app.py" 2>/dev/null; true
pkill -f "cc-status/app.py" 2>/dev/null; true  # second pass for stragglers
rm -f /tmp/cc-status.lock

echo "Clearing session state..."
echo '{"sessions":{}}' > ~/.claude/cc-status.json

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
