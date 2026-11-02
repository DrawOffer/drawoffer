#!/usr/bin/env bash
# Local parity checks only: rebuild, relaunch against the parity Web origin, sign in, and size the
# window so its content area matches the 1440×900 Web viewport used by web-snap.mjs.
set -euo pipefail
cd "$(dirname "$0")"
export DRAWOFFER_API_ORIGIN="${DRAWOFFER_API_ORIGIN:-http://127.0.0.1:5175}"
[ "${1:-}" = "--no-build" ] || { out="$(bash bundle.sh 2>&1)" || { printf '%s\n' "$out" | grep -E "error" | head -20; exit 1; }; }
bash snap.sh launch 6
bash dev-login.sh >/dev/null
osascript -e 'tell application "System Events" to tell (first process whose name is "DrawOffer") to set size of window 1 to {1440, 932}' >/dev/null
sleep 5
