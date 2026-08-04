#!/bin/bash
# Auto-increment minor version: 1.0.1 -> 1.0.2 -> 1.0.3 ...
# Updates both Version.swift (in-app display) and Info.plist (About dialog).
# Usage: ./bump-version.sh

VERSION_FILE="lmux-app/Sources/LMUX/Utils/Version.swift"
PLIST_FILE="lmux-app/Info.plist"

CURRENT=$(grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' "$VERSION_FILE" | head -1)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
NEW="$MAJOR.$MINOR.$((PATCH + 1))"
NEW_BUILD="$((PATCH + 1))"

# Update Version.swift
sed -i '' "s/$CURRENT/$NEW/" "$VERSION_FILE"

# Update Info.plist
sed -i '' "s/<string>$CURRENT<\/string>/<string>$NEW<\/string>/" "$PLIST_FILE"
# CFBundleVersion is just the patch number
sed -i '' "/CFBundleVersion/{n;s|<string>.*</string>|<string>$NEW_BUILD</string>|;}" "$PLIST_FILE"

echo "Version: $CURRENT -> $NEW (build $NEW_BUILD)"
