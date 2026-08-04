#!/bin/bash
# Auto-increment minor version: 1.0.1 -> 1.0.2 -> 1.0.3 ...
# Usage: ./bump-version.sh

VERSION_FILE="lmux-app/Sources/LMUX/Utils/Version.swift"
CURRENT=$(grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' "$VERSION_FILE" | head -1)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
NEW="$MAJOR.$MINOR.$((PATCH + 1))"
sed -i '' "s/$CURRENT/$NEW/" "$VERSION_FILE"
echo "Version: $CURRENT -> $NEW"
