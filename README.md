# cc-status

A macOS menu bar app that shows the real-time status of your Claude Code sessions as a traffic light.

```
🟢  Idle          — no active sessions, or Claude finished responding
🟡  Working       — Claude is running tools or processing a prompt
🔴  Waiting — Claude is waiting for your permission or attention
```

Multiple concurrent sessions are tracked independently. The most urgent state wins (🔴 > 🟡 > 🟢).

---

## Quick install

```bash
git clone https://github.com/you/cc-status.git && bash cc-status/install.sh
```

That's it. The script installs dependencies, wires the Claude Code hooks, and starts the app via a LaunchAgent (auto-restarts on login).

---

## Requirements

- macOS
- Python 3.8+
- [Claude Code](https://claude.ai/code) CLI
- `rumps` Python package

---

## Installation

### 1. Install the Python dependency

```bash
pip3 install rumps
```

### 2. Clone / copy the files

```bash
git clone <repo> ~/code/cc-status
# or just place app.py anywhere you like and note its path
```

### 3. Install the hook script

Copy the hook script to your Claude Code hooks directory:

```bash
cp ~/.claude/hooks/cc-status.py ~/.claude/hooks/cc-status.py
chmod +x ~/.claude/hooks/cc-status.py
```

The script is already at `~/.claude/hooks/cc-status.py` if you followed the automated setup.

### 4. Wire the hooks into Claude Code

Add the following entries to `~/.claude/settings.json` under the `"hooks"` key.  
Replace `/Users/you/` with your actual home path.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py working",
          "async": true,
          "timeout": 5
        }]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py working",
          "async": true,
          "timeout": 5
        }]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py working",
          "async": true,
          "timeout": 5
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py idle",
          "async": true,
          "timeout": 5
        }]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py idle",
          "async": true,
          "timeout": 5
        }]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py waiting",
          "async": true,
          "timeout": 5
        }]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 ~/.claude/hooks/cc-status.py waiting",
          "async": true,
          "timeout": 5
        }]
      }
    ]
  }
}
```

> If your `settings.json` already has entries for these events, append the new hook object into the existing array — don't replace it.

### 5. Launch the menu bar app

**Run once manually to verify:**

```bash
python3 ~/code/cc-status/app.py
```

You should see 🟢 appear in your menu bar immediately.

**Auto-start on login (recommended):**

```bash
cat > ~/Library/LaunchAgents/com.ccstatus.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ccstatus</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/you/code/cc-status/app.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/cc-status.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/cc-status.log</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.ccstatus.plist
```

Replace `/usr/bin/python3` with the path from `which python3` if needed.

---

## How it works

Claude Code fires [hook events](https://docs.anthropic.com/en/docs/claude-code/hooks) at key points in the session lifecycle. The hook script (`cc-status.py`) receives each event via stdin (JSON) and writes the session's current status to a shared file at `~/.claude/cc-status.json`.

The menu bar app polls that file every second. If multiple sessions are running, it aggregates them — the most urgent state is shown.

Sessions that go silent for more than 2 minutes are automatically treated as idle (handles crashes or force-quits that skip the `SessionEnd` hook).

### State file

`~/.claude/cc-status.json` — human-readable, safe to inspect:

```json
{
  "sessions": {
    "abc123": { "status": "working", "updated_at": 1700000000 },
    "def456": { "status": "idle",    "updated_at": 1700000010 }
  }
}
```

---

## Troubleshooting

**Icon doesn't appear**  
macOS may require accessibility permission for menu bar apps the first time. Check System Settings → Privacy & Security → Accessibility.

**Status is stuck on 🟡 Working**  
The session may have been force-quit without firing `SessionEnd`. The icon will automatically revert to 🟢 after 2 minutes of inactivity. You can also reset manually:

```bash
echo '{"sessions":{}}' > ~/.claude/cc-status.json
```

**Check logs**

```bash
cat /tmp/cc-status.log
```

**Restart the app**

```bash
launchctl unload ~/Library/LaunchAgents/com.ccstatus.plist
launchctl load   ~/Library/LaunchAgents/com.ccstatus.plist
```
