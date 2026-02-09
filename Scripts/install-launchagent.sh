#!/bin/bash
# Install PingClaude LaunchAgent (for macOS 12 launch-at-login)
set -e

PLIST_NAME="com.pingclaude.app.plist"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$DEST_DIR"
cp "$SRC_DIR/$PLIST_NAME" "$DEST_DIR/$PLIST_NAME"

echo "Installed $DEST_DIR/$PLIST_NAME"
echo "Loading agent..."
launchctl load "$DEST_DIR/$PLIST_NAME" 2>/dev/null || true
echo "Done. PingClaude will start at login."
