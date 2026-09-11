#!/bin/bash
# Record a short GIF of the lmux *demo* instance for the README.
#
# Usage:
#   ./tools/record-demo-gif.sh [seconds]
#
# Safety: it only ever captures the window of a lmux process started with
# LMUX_DATA_DIR set (the isolated demo instance) — never your real sessions.
set -euo pipefail

SECS="${1:-15}"
OUT="${OUT:-docs/screenshots/demo.gif}"
FPS="${FPS:-2}"
PREP="${PREP:-3}"   # seconds of countdown before capturing
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. find the demo instance's pid via its backend port (its env carries
#    LMUX_DATA_DIR, which `ps -E` cannot read for GUI apps)
DEMO_PORT="${LMUX_DEMO_PORT:-19681}"
BACKEND_PID="$(lsof -nP -iTCP:"$DEMO_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
if [ -z "$BACKEND_PID" ]; then
  echo "No demo instance found (nothing listening on port $DEMO_PORT)."
  echo "Start one first:"
  echo "  LMUX_DATA_DIR=/tmp/lmux-demo LMUX_PORT=$DEMO_PORT /Applications/lmux.app/Contents/MacOS/lmux"
  exit 1
fi
DEMO_PID="$(ps -o ppid= -p "$BACKEND_PID" | tr -d ' ')"
DEMO_CMD="$(ps -o command= -p "$DEMO_PID" 2>/dev/null || true)"
case "$DEMO_CMD" in
  *MacOS/lmux*) ;;
  *) echo "port $DEMO_PORT belongs to '$DEMO_CMD', not a lmux demo instance"; exit 1 ;;
esac
echo "demo instance pid=$DEMO_PID (backend $BACKEND_PID on :$DEMO_PORT)"

# 2. its window id
WID=$(swift - "$DEMO_PID" << 'SWIFT'
import CoreGraphics
import Foundation
let want = Int(CommandLine.arguments[1]) ?? -1
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int) == want else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let area = (b["Width"] as? Double ?? 0) * (b["Height"] as? Double ?? 0)
    if area > 100_000 {           // a real window, not a tooltip
        print(w[kCGWindowNumber as String] as? Int ?? 0)
        break
    }
}
SWIFT
)
if [ -z "$WID" ] || [ "$WID" = "0" ]; then echo "demo window not found"; exit 1; fi

echo "Capturing window $WID (demo instance only) for ${SECS}s at ${FPS}fps…"
echo ">>> Switch between your two demo sessions now <<<"
for i in $(seq "$PREP" -1 1); do printf "\rstarting in %s…" "$i"; sleep 1; done; printf "\r"

FRAMES=$(( SECS * FPS ))
for i in $(seq 1 "$FRAMES"); do
  screencapture -x -o -l"$WID" "$WORK/f$(printf '%03d' "$i").png"
  sleep "$(python3 -c "print(1/$FPS)")"
done

python3 - "$WORK" "$OUT" "$FPS" << 'PY'
import glob, sys
from PIL import Image

work, out, fps = sys.argv[1], sys.argv[2], int(sys.argv[3])
files = sorted(glob.glob(f"{work}/f*.png"))
if not files:
    sys.exit("no frames captured")
frames = []
for f in files:
    im = Image.open(f).convert("RGB")
    w = 1000
    im = im.resize((w, int(im.height * w / im.width)), Image.LANCZOS)
    frames.append(im.quantize(colors=128, method=Image.MEDIANCUT))
frames[0].save(out, save_all=True, append_images=frames[1:],
               duration=int(1000 / fps), loop=0, optimize=True)
print("wrote", out, f"({len(frames)} frames, {frames[0].width}x{frames[0].height})")
PY
