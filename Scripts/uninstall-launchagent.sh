#!/bin/bash
# Uninstall PingClaude LaunchAgent
set -e

PLIST_NAME="com.pingclaude.app.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [ -f "$PLIST_PATH" ]; then
    echo "Unloading agent..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo "Removed $PLIST_PATH"
else
    echo "LaunchAgent not installed."
fi
