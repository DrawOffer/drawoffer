#!/usr/bin/env bash
# Local parity checks only: completes the browser login for the running bundled app with a
# fictional Dev account. Needs a running Web dev server and password login (Local/Development).
set -euo pipefail
cd "$(dirname "$0")/.."
SNAP="${DRAWOFFER_SNAPSHOT_DIR:-$PWD/../../.runtime/snap}"
ORIGIN="${DRAWOFFER_API_ORIGIN:-http://127.0.0.1:5174}"
EMAIL="${DRAWOFFER_TEST_EMAIL:-mac-parity-test@example.com}"
PASSWORD="${DRAWOFFER_TEST_PASSWORD:-$(cat "$PWD/../../.runtime/test-password")}"
rm -f "$SNAP/browser-url.txt"
sleep 4
if ! bash scripts/snap.sh shot pre-login | grep -q "登录 / 恢复登录"; then echo "already signed in"; exit 0; fi
bash scripts/snap.sh press "登录 / 恢复登录" 1 >/dev/null
bash scripts/snap.sh press "在浏览器中登录" 1 >/dev/null
for _ in $(seq 1 20); do [ -f "$SNAP/browser-url.txt" ] && break; sleep 0.5; done
URL="$(cat "$SNAP/browser-url.txt")"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
curl -sf -c "$JAR" -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" "$ORIGIN/api/auth/login" >/dev/null
QUERY="${URL#*\?}"
param() { printf '%s' "$QUERY" | tr '&' '\n' | sed -n "s/^$1=//p"; }
CODE="$(curl -sf -b "$JAR" -H 'Content-Type: application/json' \
  -d "{\"platform\":\"$(param platform)\",\"client_version\":\"$(param client_version)\",\"code_challenge\":\"$(param challenge)\",\"code_challenge_method\":\"S256\"}" \
  "$ORIGIN/api/auth/desktop/browser/authorize" | python3 -c 'import json,sys,urllib.parse;print(urllib.parse.quote(json.load(sys.stdin)["code"],safe=""))')"
open "drawoffer://auth/callback?code=$CODE&state=$(param state)"
sleep 3
echo "signed in"
