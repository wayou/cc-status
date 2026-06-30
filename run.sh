#!/usr/bin/env bash
# Launch the Claude Code status menu bar app.
# Keep this running in the background; it will appear in the macOS menu bar.
exec python3 "$(dirname "$0")/app.py"
