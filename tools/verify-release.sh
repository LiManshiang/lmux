#!/usr/bin/env bash
#
# Verify that a published release actually carries its SwiftPM resource bundles.
#
# Why this exists: releases shipped for months without them, and the app traps
# with fatalError on its first terminal session when they are missing (see the
# assemble_bundle comment in lmux-app/Makefile). CI now asserts this before
# packaging; this script checks the published artifact — or, when the network
# blocks the download, the CI log that produced it.
#
# usage: tools/verify-release.sh v1.0.274
set -euo pipefail

TAG="${1:?usage: verify-release.sh <tag>   e.g. v1.0.274}"
REPO="LiManshiang/lmux"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Verifying $TAG"

# 1) Preferred: inspect the published zip.
if gh release download "$TAG" -R "$REPO" -p "*macos.zip" -D "$WORK" --clobber 2>/dev/null; then
  if (cd "$WORK" && unzip -q ./*macos.zip 2>/dev/null); then
    bundles=$(ls -d "$WORK"/lmux.app/Contents/Resources/*.bundle 2>/dev/null || true)
    if [ -z "$bundles" ]; then
      echo "FAIL: the published app carries no .bundle — it crashes on first connect"
      exit 1
    fi
    echo "PASS: $(basename -a $bundles | tr '\n' ' ')"
    if strings "$WORK/lmux.app/Contents/MacOS/lmux" | grep -qE '(\.build/|/Users/)[^ ]*\.bundle'; then
      echo "FAIL: binary contains a hard-coded build path"
      exit 1
    fi
    exit 0
  fi
fi

# 2) Fallback: the download was blocked, so read what CI reported instead.
echo "download unavailable; checking the CI log"
run_id=$(gh run list -R "$REPO" --limit 40 --json databaseId,headBranch \
  --jq ".[] | select(.headBranch == \"$TAG\") | .databaseId" | head -1)
if [ -z "$run_id" ]; then
  echo "FAIL: no CI run found for $TAG"
  exit 1
fi
log=$(gh run view "$run_id" -R "$REPO" --log 2>/dev/null || true)
if grep -q "Copying resource bundles" <<<"$log"; then
  echo "PASS: CI copied the bundles while packaging"
  grep -o "Copying resource bundles:.*" <<<"$log" | sort -u | sed 's/^/  /'
else
  echo "FAIL: the CI log never mentions copying bundles"
  exit 1
fi
