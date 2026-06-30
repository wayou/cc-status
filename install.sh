#!/usr/bin/env bash
set -euo pipefail

# ── cc-status installer ────────────────────────────────────────────────────────
# Installs the Claude Code status menu bar app on macOS.
# Usage: bash install.sh
# ──────────────────────────────────────────────────────────────────────────────

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.cc-status"
HOOK_SCRIPT="$HOME/.claude/hooks/cc-status.py"
STATUS_FILE="$HOME/.claude/cc-status.json"
SETTINGS_FILE="$HOME/.claude/settings.json"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/com.ccstatus.plist"
LAUNCH_AGENT_LABEL="com.ccstatus"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}▶${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✗${NC}  $*"; exit 1; }
step()  { echo; echo -e "${GREEN}── $* ──${NC}"; }

# ── 1. preflight ──────────────────────────────────────────────────────────────
step "Checking requirements"

[[ "$(uname)" == "Darwin" ]] || error "macOS required."

PYTHON=$(command -v python3 || true)
[[ -n "$PYTHON" ]] || error "python3 not found. Install it via 'brew install python'."
info "Python: $($PYTHON --version)"

PIP=$(command -v pip3 || true)
[[ -n "$PIP" ]] || error "pip3 not found."

[[ -d "$HOME/.claude" ]] || error "~/.claude not found — is Claude Code installed?"

# ── 2. install rumps ──────────────────────────────────────────────────────────
step "Installing Python dependencies"

if $PYTHON -c "import rumps" 2>/dev/null; then
    info "rumps already installed"
else
    info "Installing rumps..."
    $PIP install --quiet rumps
fi

# ── 3. copy app files ─────────────────────────────────────────────────────────
step "Installing app to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"
cp "$REPO_DIR/app.py" "$INSTALL_DIR/app.py"
info "app.py → $INSTALL_DIR/app.py"

# ── 4. install hook script ────────────────────────────────────────────────────
step "Installing hook script"

mkdir -p "$HOME/.claude/hooks"
cp "$REPO_DIR/../../../.claude/hooks/cc-status.py" "$HOOK_SCRIPT" 2>/dev/null \
    || cp "$REPO_DIR/cc-status.py" "$HOOK_SCRIPT" 2>/dev/null \
    || {
        # write it inline if not bundled alongside
        cat > "$HOOK_SCRIPT" << 'HOOKEOF'
#!/usr/bin/env python3
import sys, json, time, os
from pathlib import Path

def main():
    status = sys.argv[1] if len(sys.argv) > 1 else "idle"
    try:
        data = json.load(sys.stdin)
        session_id = data.get("session_id", "default")
    except Exception:
        session_id = "default"

    status_file = Path.home() / ".claude" / "cc-status.json"
    now = int(time.time())

    try:
        state = json.loads(status_file.read_text())
        if "sessions" not in state or not isinstance(state["sessions"], dict):
            raise ValueError
    except Exception:
        state = {"sessions": {}}

    state["sessions"][session_id] = {"status": status, "updated_at": now}
    state["sessions"] = {k: v for k, v in state["sessions"].items()
                         if now - v.get("updated_at", 0) < 300}

    tmp = str(status_file) + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, status_file)
    except Exception:
        pass

if __name__ == "__main__":
    main()
HOOKEOF
    }
chmod +x "$HOOK_SCRIPT"
info "Hook script → $HOOK_SCRIPT"

# ── 5. patch settings.json ────────────────────────────────────────────────────
step "Wiring Claude Code hooks"

$PYTHON - << PYEOF
import json, sys
from pathlib import Path

settings_path = Path("$SETTINGS_FILE")
hook_script   = "$HOOK_SCRIPT"

try:
    s = json.loads(settings_path.read_text())
except Exception:
    print("  ⚠  Could not read settings.json — skipping hook wiring.")
    print("     Add hooks manually per the README.")
    sys.exit(0)

def make_hook(status):
    return {
        "type": "command",
        "command": f"python3 {hook_script} {status}",
        "async": True,
        "timeout": 5,
    }

def already_wired(hooks_list, status):
    for group in hooks_list:
        for h in group.get("hooks", []):
            if "cc-status.py" in h.get("command", "") and status in h.get("command", ""):
                return True
    return False

mapping = {
    "PreToolUse":       "working",
    "UserPromptSubmit": "working",
    "SessionStart":     "working",
    "Stop":             "idle",
    "SessionEnd":       "idle",
    "PermissionRequest":"waiting",
    "Notification":     "waiting",
}

s.setdefault("hooks", {})
added = []
for event, status in mapping.items():
    if not already_wired(s["hooks"].get(event, []), status):
        s["hooks"].setdefault(event, []).append(
            {"matcher": "", "hooks": [make_hook(status)]}
        )
        added.append(event)

settings_path.write_text(json.dumps(s, indent=4))
if added:
    print(f"  Wired hooks for: {', '.join(added)}")
else:
    print("  Hooks already present — nothing changed.")
PYEOF

# ── 6. install LaunchAgent ────────────────────────────────────────────────────
step "Installing LaunchAgent (auto-start on login)"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_AGENT_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON}</string>
        <string>${INSTALL_DIR}/app.py</string>
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
info "LaunchAgent → $LAUNCH_AGENT_PLIST"

# ── 7. (re)start the app ──────────────────────────────────────────────────────
step "Starting cc-status"

launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
launchctl load   "$LAUNCH_AGENT_PLIST"
sleep 1

if pgrep -f "cc-status/app.py" > /dev/null 2>&1; then
    info "cc-status is running — look for 🟢 in your menu bar."
else
    warn "App may not have started. Check logs: cat /tmp/cc-status.log"
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}✓ Installation complete!${NC}"
echo
echo "  Menu bar:  🟢 Idle  🟡 Working  🔴 Waiting"
echo "  Logs:      cat /tmp/cc-status.log"
echo "  Restart:   launchctl kickstart -k gui/\$(id -u)/$LAUNCH_AGENT_LABEL"
echo "  Uninstall: launchctl unload $LAUNCH_AGENT_PLIST && rm -rf $INSTALL_DIR $HOOK_SCRIPT $LAUNCH_AGENT_PLIST"
echo
