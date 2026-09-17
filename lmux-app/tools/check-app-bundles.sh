#!/bin/bash
# Assert a packaged lmux.app can actually load its SwiftPM resource bundles.
#
# SwiftPM's generated `Bundle.module` accessor comes in two shapes and only one
# of them can ever work inside an .app:
#
#   swiftbuild  probes Bundle.main.resourceURL  → <app>/Contents/Resources
#   native      probes Bundle.main.bundleURL    → <app> itself, then a build-time
#               absolute path that exists only on the build machine
#
# The native shape cannot be satisfied by a packaged .app: codesign seals only
# Contents/ and refuses to sign a bundle that has "unsealed contents present in
# the bundle root", so the bundles cannot be placed at the app root either. An
# app built by the native system is therefore unshippable. That is how 1.0.279
# went out — the bundles were in Contents/Resources, CI's Xcode 16 had built the
# frontend with the deprecated native system, so the accessor looked in the app
# root, and every user crashed on their first terminal session (the accessor
# runs before ghostty_init; it is reached from GhosttyRuntimeResources
# .directoryURL).
#
# So this checks three things, none of which the old "a *.bundle directory
# exists" check covered: the bundles are in Contents/Resources, each one still
# carries the payload its consumer looks up, and the frontend was not built by
# the native build system.
#
# Which bundles an app must carry is not asserted here, only that whatever it
# ships is complete: the set is decided by what the build produced, and
# assemble_bundle copies all of it in one step. The two variants need different
# bundles (the ghostty renderer needs GhosttyKit's terminfo, the SwiftTerm
# renderer its metallib), so a fixed list here would be wrong for one of them.
#
# usage: check-app-bundles.sh <app> [app ...]
set -uo pipefail

status=0

fail() {
	echo "ERROR: $*" >&2
	status=1
}

# A bundle keeps its payload either in Contents/Resources (macOS-style, what
# swiftbuild emits) or in the bundle directory itself (flat, what the native
# build system emitted); accept both so a legacy app can still be diagnosed.
check_payload() {
	local bundle="$1" root relative
	shift
	for root in "$bundle" "$bundle/Contents/Resources"; do
		for relative in "$@"; do
			if [ -e "$root/$relative" ]; then
				return 0
			fi
		done
	done
	fail "$bundle is missing $*"
}

check_bundle() {
	local bundle="$1" name
	name="$(basename "$bundle")"
	case "$name" in
	GhosttyKit_GhosttyTerminal)
		check_payload "$bundle" Ghostty/shell-integration terminfo
		;;
	SwiftTerm_SwiftTerm)
		# The Metal renderer takes either the shader source or the precompiled
		# library, depending on which toolchain built the bundle.
		check_payload "$bundle" Shaders.metal default.metallib
		;;
	esac
}

check_app() {
	local app="$1" bundle binary name found=0 names=()
	if [ ! -d "$app" ]; then
		fail "$app does not exist"
		return
	fi

	# The native build system's accessor traps with this message; if the
	# frontend carries it, no layout can save the app.
	binary="$app/Contents/MacOS/lmux"
	if [ ! -f "$binary" ]; then
		fail "$app/Contents/MacOS/lmux is missing"
	else
		if grep -qa 'could not load resource bundle: from' "$binary"; then
			fail "$binary was built by SwiftPM's deprecated native build system; its Bundle.module accessor probes the .app root, where a signed app cannot carry bundles. Rebuild with swiftbuild (Swift 6.2+, Xcode 26+, --build-system swiftbuild)."
		elif ! grep -qa 'unable to find bundle named' "$binary"; then
			echo "  note: $binary carries neither known accessor marker; checking the layout only"
		fi
	fi

	for bundle in "$app"/Contents/Resources/*.bundle; do
		[ -d "$bundle" ] || continue
		found=1
		name="$(basename "$bundle")"
		names+=("$name")
		check_bundle "$bundle"
	done

	if [ "$found" = 0 ]; then
		fail "$app/Contents/Resources carries no *.bundle - the app would trap on first connect"
		return
	fi

	echo "$app: ${names[*]}"
}

for app in "$@"; do
	check_app "$app"
done

if [ "$status" != 0 ]; then
	echo "FAIL: the app above cannot load its resource bundles"
fi
exit "$status"
