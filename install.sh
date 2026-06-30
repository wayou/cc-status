#!/usr/bin/env bash
set -euo pipefail

# ── cc-status installer ────────────────────────────────────────────────────────
# Installs the Claude Code status menu bar app on macOS.
#
# Usage:
#   bash install.sh                   # install latest release from GitHub
#   bash install.sh v1.2.3            # install a specific version
#   bash install.sh --update          # update to latest release
#   bash install.sh                   # (re)install from local clone
# ──────────────────────────────────────────────────────────────────────────────

REPO="wayou/cc-status"
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

# ── parse args ────────────────────────────────────────────────────────────────
VERSION=""
UPDATE=false
REMOTE=false   # true when invoked via curl | bash (no local clone)

for arg in "$@"; do
    case "$arg" in
        --update) UPDATE=true ;;
        v*)       VERSION="$arg" ;;
        *)        error "Unknown argument: $arg" ;;
    esac
done

# Detect whether we're running from inside a local clone or piped from curl.
# When piped, BASH_SOURCE[0] is "" or non-existent.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
    REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    # Only treat as local clone when app.py is present next to this script.
    if [[ ! -f "$REPO_DIR/app.py" ]]; then
        REMOTE=true
    fi
else
    REMOTE=true
fi

# --update: resolve to latest tag and force remote download
if [[ "$UPDATE" == true ]]; then
    REMOTE=true
    info "Checking for latest release..."
    VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    [[ -n "$VERSION" ]] || error "Could not determine latest version."
    info "Latest version: $VERSION"

    # Compare with currently installed version
    INSTALLED_VERSION="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || true)"
    if [[ "$INSTALLED_VERSION" == "$VERSION" ]]; then
        info "Already on $VERSION — nothing to do."
        exit 0
    fi
fi

# If we're fetching from GitHub, download the assets to a temp dir
if [[ "$REMOTE" == true ]]; then
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    if [[ -z "$VERSION" ]]; then
        # No version specified: use latest
        RELEASE_URL="https://github.com/$REPO/releases/latest/download"
    else
        RELEASE_URL="https://github.com/$REPO/releases/download/$VERSION"
    fi

    step "Downloading cc-status ${VERSION:-latest} from GitHub"
    curl -fsSL "$RELEASE_URL/app.py"     -o "$TMP_DIR/app.py"     || error "Failed to download app.py from $RELEASE_URL"
    curl -fsSL "$RELEASE_URL/install.sh" -o "$TMP_DIR/install.sh" || error "Failed to download install.sh"
    info "Downloaded to $TMP_DIR"

    REPO_DIR="$TMP_DIR"

    # Resolve the actual version tag for the VERSION file
    if [[ -z "$VERSION" ]]; then
        VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || true)
    fi
fi

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

# Record installed version
if [[ -n "$VERSION" ]]; then
    echo "$VERSION" > "$INSTALL_DIR/VERSION"
    info "Version: $VERSION"
fi

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

    URGENCY = {"waiting": 0, "working": 1, "idle": 2}
    current = state["sessions"].get(session_id, {})
    current_urgency = URGENCY.get(current.get("status", "idle"), 2)
    new_urgency = URGENCY.get(status, 2)
    age = now - current.get("updated_at", 0)
    if new_urgency > current_urgency and age < 3:
        return
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
    "PostToolUse":      "working",
    "UserPromptSubmit": "working",
    "SessionStart":     "working",
    "Stop":             "idle",
    "SessionEnd":       "remove",
    "PermissionRequest":"waiting",
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
[[ -n "$VERSION" ]] && echo "  Version:   $VERSION"
echo
echo "  Menu bar:  🟢 Idle  🟡 Working  🔴 Waiting"
echo "  Logs:      cat /tmp/cc-status.log"
echo "  Update:    bash install.sh --update"
echo "  Restart:   launchctl kickstart -k gui/\$(id -u)/$LAUNCH_AGENT_LABEL"
echo "  Uninstall: launchctl unload $LAUNCH_AGENT_PLIST && rm -rf $INSTALL_DIR $HOOK_SCRIPT $LAUNCH_AGENT_PLIST"
echo
