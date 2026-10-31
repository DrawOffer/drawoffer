#!/usr/bin/env bash
# Local parity checks: `snap.sh launch` (re)starts the bundled app against the dev Web origin;
# `snap.sh shot <name>` captures window PNG + accessibility tree; `snap.sh click <name> x y` clicks in-window points.
set -euo pipefail
cd "$(dirname "$0")/.."
SNAP="${DRAWOFFER_SNAPSHOT_DIR:-$PWD/../../.runtime/snap}"
mkdir -p "$SNAP"
# SwiftUI only exposes its accessibility tree while the app is frontmost.
front() { osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "DrawOffer") to true' >/dev/null 2>&1 || true; sleep 0.4; }
[ "$1" != launch ] && front
case "$1" in
  launch)
    pkill -x DrawOffer 2>/dev/null || true; sleep 1
    open -n .build/DrawOffer.app --env DRAWOFFER_API_ORIGIN="${DRAWOFFER_API_ORIGIN:-http://127.0.0.1:5174}" \
      --env DRAWOFFER_ALLOW_LOCAL_HTTP=1 --env DRAWOFFER_SNAPSHOT_DIR="$SNAP" --env DRAWOFFER_SNAPSHOT_CAPTURE_LOGIN=1 \
      ${DRAWOFFER_MOCK_FIXTURE:+--env DRAWOFFER_MOCK_FIXTURE="$DRAWOFFER_MOCK_FIXTURE"}
    sleep "${2:-6}" ;;
  shot)
    rm -f "$SNAP/$2.png" "$SNAP/$2.ax.txt"; touch "$SNAP/request-$2"
    for _ in $(seq 1 40); do [ -f "$SNAP/$2.ax.txt" ] && break; sleep 0.25; done
    cat "$SNAP/$2.ax.txt" ;;
  press)
    # snap.sh press "<label>" [wait]: AXPress the first matching control
    key="p$RANDOM"; printf '%s' "$2" > "$SNAP/press-$key"
    for _ in $(seq 1 40); do [ -f "$SNAP/$key.press.txt" ] && break; sleep 0.25; done
    cat "$SNAP/$key.press.txt"; echo; rm -f "$SNAP/$key.press.txt"; sleep "${3:-1.5}" ;;
  menu)
    printf '%s' "$2" > "$SNAP/menu-m$RANDOM"; sleep "${3:-1.5}" ;;
  fill)
    # snap.sh fill "<field label>" "<text>" [submit]: focus a field by label, replace its text, optionally press Return
    key="f$RANDOM"; body="$3"; [ "${4:-}" = submit ] && body="$body"$'\n'
    printf '%s\n%s' "$2" "$body" > "$SNAP/fill-$key"
    for _ in $(seq 1 40); do [ -f "$SNAP/$key.fill.txt" ] && break; sleep 0.25; done
    cat "$SNAP/$key.fill.txt"; echo; rm -f "$SNAP/$key.fill.txt"; sleep 1.5 ;;
  js)
    # snap.sh js <file.js>: evaluate a script in the editable paper WebView and print the result
    key="j$RANDOM"; cp "$2" "$SNAP/js-$key"
    for _ in $(seq 1 40); do [ -f "$SNAP/$key.js.txt" ] && break; sleep 0.25; done
    cat "$SNAP/$key.js.txt"; echo; rm -f "$SNAP/$key.js.txt" ;;
  type)
    printf '%s' "$2" > "$SNAP/type-t$RANDOM"; sleep 1 ;;
esac
