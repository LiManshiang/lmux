#!/bin/bash
# Assert a packaged lmux.app can actually load its SwiftPM resource bundles.
#
# SwiftPM generates two shapes of `Bundle.module` accessor and they probe
# different locations:
#
#   * swiftbuild (Xcode 26+)     Bundle.main.resourceURL  → <app>/Contents/Resources
#   * legacy SwiftPM (Xcode 16)  Bundle.main.bundleURL    → <app> itself
#
# Neither probes the other's location, and either one calls fatalError when no
# candidate resolves. The accessor runs before ghostty_init (it is reached from
# GhosttyRuntimeResources.directoryURL), so a bundle the running app cannot see
# is a SIGTRAP on the first terminal session. That is how 1.0.279 shipped: the
# bundles were in Contents/Resources, CI's legacy toolchain looked in the app
# root, and every user got the trap. assemble_bundle puts a copy in both places
# for exactly this reason, and this script is what keeps that honest.
#
# "A *.bundle directory exists" is not the invariant — that check passed on the
# broken release. The invariant is that both probe locations resolve *and* that
# each bundle still carries the payload its consumers look up.
#
# usage: check-app-bundles.sh <app> [app ...]
set -uo pipefail

status=0

fail() {
	echo "ERROR: $*" >&2
	status=1
}

# A bundle keeps its payload either in Contents/Resources (macOS-style, what
# swiftbuild emits) or in the bundle directory itself (flat, legacy SwiftPM).
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
	local app="$1" bundle name found=0 names=()
	if [ ! -d "$app" ]; then
		fail "$app does not exist"
		return
	fi

	for bundle in "$app"/Contents/Resources/*.bundle; do
		[ -d "$bundle" ] || continue
		found=1
		name="$(basename "$bundle")"
		names+=("$name")

		# Contents/Resources is the swiftbuild probe; the app root is the
		# legacy probe. Both copies have to be usable, not just present.
		check_bundle "$bundle"
		if [ -d "$app/$name" ]; then
			check_bundle "$app/$name"
		else
			fail "$app/$name is missing - the legacy SwiftPM accessor probes Bundle.main.bundleURL and would trap"
		fi
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
