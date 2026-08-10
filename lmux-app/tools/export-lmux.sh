#!/bin/bash
# Export lmux app data so sessions + agent conversations can be restored on
# another Mac. Quit lmux first so the SQLite WAL is flushed consistently.
#
#   Usage: ./export-lmux.sh [output-path]
#
# Restore on the other machine (same username, same project paths):
#   tar -xzf lmux-backup-*.tar.gz -C /
#   # then copy lmux.app to /Applications and launch
set -e

STAMP=$(date +%Y%m%d-%H%M)
OUT="${1:-$HOME/lmux-backup-$STAMP.tar.gz}"

if pgrep -f "MacOS/lmux" >/dev/null 2>&1; then
  echo "Quit the lmux app first (Cmd+Q) so data is consistent."
  exit 1
fi

echo "Exporting lmux data to $OUT ..."
tar -czf "$OUT" \
  "$HOME/.lmux" \
  "$HOME/Library/Application Support/lmux/restore.json" \
  "$HOME/.codebuddy/settings.json" \
  "$HOME/.codebuddy/projects" \
  "$HOME/.claude/settings.json" \
  "$HOME/.claude/projects" \
  2>/dev/null || {
    echo "tar failed — check the paths above exist."
    exit 1
  }

echo "Done: $OUT"
echo
echo "To restore on another Mac (same username):"
echo "  1. Copy $OUT and lmux.app to the other machine"
echo "  2. Install lmux.app into /Applications"
echo "  3. Run:  tar -xzf $(basename "$OUT") -C /"
echo "  4. Also copy your project files under $HOME if they aren't in git"
