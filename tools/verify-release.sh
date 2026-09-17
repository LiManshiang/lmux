#!/usr/bin/env bash
#
# Verify that a published release actually carries its SwiftPM resource bundles.
#
# Why this exists: releases shipped for months without them, and the app traps
# with fatalError on its first terminal session when they are missing (see the
# assemble_bundle comment in lmux-app/Makefile). 1.0.279 then shipped with the
# bundles present but only in Contents/Resources, which the accessor that CI's
# toolchain generates never probes — so the check has to assert the layout, not
# just that a *.bundle directory exists. Both checks live in
# lmux-app/tools/check-app-bundles.sh, shared with `make verify-bundles` and CI.
#
# usage: tools/verify-release.sh v1.0.274
set -euo pipefail

TAG="${1:?usage: verify-release.sh <tag>   e.g. v1.0.274}"
REPO="LiManshiang/lmux"
WORK="$(mktemp -d)"
CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lmux-app/tools/check-app-bundles.sh"
trap 'rm -rf "$WORK"' EXIT

echo "Verifying $TAG"

# 1) Preferred: inspect the published zip.
# Both a versioned and a stable-named archive match, so unpack with -o: without
# it unzip asks about replacing the second one and dies in a non-interactive
# shell, which looked like "download unavailable" and silently downgraded this
# to the CI-log check below.
if gh release download "$TAG" -R "$REPO" -p "*macos.zip" -D "$WORK" --clobber 2>/dev/null; then
  if (cd "$WORK" && unzip -oq ./*macos.zip 2>/dev/null); then
    if bash "$CHECK" "$WORK/lmux.app"; then
      echo "PASS: the published app loads its bundles"
      exit 0
    fi
    echo "FAIL: the published app traps on its first connect"
    exit 1
  fi
fi

# 2) Fallback: the download was blocked, so read what CI reported instead. The
# check itself ran there against the apps it was about to zip, so its verdict
# for both of them is what to look for — not merely that it copied something.
echo "download unavailable; checking the CI log"
run_id=$(gh run list -R "$REPO" --limit 40 --json databaseId,headBranch \
  --jq ".[] | select(.headBranch == \"$TAG\") | .databaseId" | head -1)
if [ -z "$run_id" ]; then
  echo "FAIL: no CI run found for $TAG"
  exit 1
fi
log=$(gh run view "$run_id" -R "$REPO" --log 2>/dev/null || true)
if grep -q 'lmux\.app: ' <<<"$log" && grep -q 'lmux-st\.app: ' <<<"$log"; then
  echo "PASS: CI's bundle check accepted both packaged apps"
  grep -oE '[^[:space:]]*lmux(-st)?\.app: .*' <<<"$log" | sort -u | sed 's/^/  /'
else
  echo "FAIL: the CI log has no bundle check result for both apps"
  exit 1
fi
