#!/usr/bin/env bash
# Local parity checks only: `parity.sh <name> <web-path> [mac-press-label] [web-steps.json] [mac-steps]`
# dumps Web boxes and the Mac AX tree for the same screen into .runtime/parity/<name>.{box,ax,diff}.
# mac-steps is a ';'-separated list of snap.sh commands run before the capture, e.g. "press 我的简历;press 新建简历".
set -euo pipefail
cd "$(dirname "$0")"
OUT="../../../.runtime/parity"; mkdir -p "$OUT"
name="$1" path="$2" steps="${4:-}" mac="${5:-}"
[ -n "${3:-}" ] && mac="press ${3}${mac:+;$mac}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [ -n "$steps" ]; then python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(json.dumps(s+[{"boxes":True}]))' "$steps" > "$tmp"
else echo '[{"boxes":true,"wait":3000}]' > "$tmp"; fi
node web-snap.mjs "$path" "$tmp" | sed -n '/^---- boxes/,/^- /p' | grep -v '^- ' > "$OUT/$name.box" &
IFS=';' read -ra cmds <<< "$mac"
# Each step is "press <label>" (an optional trailing number is the wait); labels may contain spaces.
for c in "${cmds[@]}"; do
  [ -z "$c" ] && continue
  verb="${c%% *}" rest="${c#* }" wait=2.5
  if [[ "$rest" =~ ^(.*)\ ([0-9.]+)$ ]]; then rest="${BASH_REMATCH[1]}"; wait="${BASH_REMATCH[2]}"; fi
  bash snap.sh "$verb" "$rest" "$wait" >/dev/null
done
sleep 1.5
bash snap.sh shot "$name" > "$OUT/$name.ax"
wait
python3 compare.py "$OUT/$name.box" "$OUT/$name.ax" | tee "$OUT/$name.diff"
