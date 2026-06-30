# cc-status

A macOS menu bar app that shows the real-time status of your Claude Code sessions as a traffic light.

```
🟢  Idle     — no active sessions, or Claude finished responding
🟡  Working  — Claude is running tools or processing a prompt
🔴  Waiting  — Claude is waiting for your permission or attention
```

Multiple concurrent sessions are tracked independently. The most urgent state wins (🔴 > 🟡 > 🟢).

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/you/cc-status/main/install.sh)
```

That's it. The script will:

- Install the `rumps` Python dependency
- Place the app and hook script in the right locations
- Patch `~/.claude/settings.json` to wire the Claude Code hooks
- Install a LaunchAgent so the app auto-starts on login
- Start the app immediately — look for 🟢 in your menu bar

**Requirements:** macOS, Python 3.8+, [Claude Code](https://claude.ai/code) CLI

---

## How it works

Claude Code fires [hook events](https://docs.anthropic.com/en/docs/claude-code/hooks) at key points in the session lifecycle. The hook script receives each event via stdin and writes the session status to `~/.claude/cc-status.json`. The menu bar app polls that file every second and updates the icon.

| Hook event | Status |
|---|---|
| `PreToolUse`, `UserPromptSubmit`, `SessionStart` | 🟡 Working |
| `Stop`, `SessionEnd` | 🟢 Idle |
| `PermissionRequest`, `Notification` | 🔴 Waiting |

Sessions silent for more than 2 minutes are automatically treated as idle — this handles crashes or force-quits that skip `SessionEnd`.

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
macOS may require accessibility permission the first time. Check System Settings → Privacy & Security → Accessibility.

**Status is stuck on 🟡 Working**  
Reset manually:
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

**Uninstall**
```bash
launchctl unload ~/Library/LaunchAgents/com.ccstatus.plist
rm -rf ~/.cc-status ~/.claude/hooks/cc-status.py ~/Library/LaunchAgents/com.ccstatus.plist
```
