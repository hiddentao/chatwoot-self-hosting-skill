#!/usr/bin/env bash
# Checks a running installation from the public internet. Run it after first
# setup and after every upgrade.
#
# Usage: BASE_URL=https://chat.example.com verify.sh [website_token ...]
#
# Environment:
#   BASE_URL         the public address to check (required)
#   EXPECT_VERSION   the version /api should report, without the leading v
#   EXPECT_SDK       path to your patched sdk.js, compared against what is served
#
# Each website token adds the per-inbox checks for that widget inbox, and loads
# the widget once, which creates one throwaway anonymous contact in it.
#
# This checks what an outsider can see. It cannot see the settings that live in
# the database, so run rails/audit.rb as well. See verification.md.
set -euo pipefail

command -v curl >/dev/null || { echo "error: curl is not installed" >&2; exit 1; }
command -v openssl >/dev/null || { echo "error: openssl is not installed" >&2; exit 1; }

BASE="${BASE_URL:?set BASE_URL, e.g. https://chat.example.com}"
BASE="${BASE%/}"
FAILED=0

log() { printf '\n==> %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
is_status() { [[ "$(http_status "${@:2}")" == "$1" ]]; }
sri_of() { printf 'sha384-%s' "$(openssl dgst -sha384 -binary "$1" | openssl base64 -A)"; }

log "Server"
REPORTED="$(curl -fsS --max-time 15 "$BASE/api" | sed -nE 's/.*"version":"([^"]+)".*/\1/p')"
if [[ -n "${EXPECT_VERSION:-}" ]]; then
  check "serves Chatwoot $EXPECT_VERSION (reported $REPORTED)" test "$REPORTED" == "$EXPECT_VERSION"
else
  pass "serves Chatwoot $REPORTED (set EXPECT_VERSION to assert it)"
fi

log "Signup and private paths"
for api in v1 v2; do
  check "POST /api/$api/accounts is refused" \
    is_status 404 -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/$api/accounts"
done
for path in /super_admin /super_admin/sign_in /monitoring/sidekiq /installation/onboarding; do
  check "$path is not public" is_status 404 "$BASE$path"
done

log "Widget SDK"
SERVED_SDK="$(mktemp)"
trap 'rm -f "$SERVED_SDK"' EXIT
SDK_HEADERS="$(curl -fsS --max-time 15 -D - -o "$SERVED_SDK" "$BASE/packs/js/sdk.js")"
if [[ -n "${EXPECT_SDK:-}" ]]; then
  check "served sdk.js is your patched build ($(sri_of "$EXPECT_SDK"))" \
    test "$(sri_of "$SERVED_SDK")" == "$(sri_of "$EXPECT_SDK")"
else
  pass "served sdk.js has SRI $(sri_of "$SERVED_SDK") (set EXPECT_SDK to assert it)"
fi
check "sdk.js allows cross-origin reads (needed for integrity pinning)" \
  grep -qi '^access-control-allow-origin: \*' <<<"$SDK_HEADERS"
# Whether the guard is present cannot be read reliably out of a minified
# bundle. Prove it by hand instead: verification.md, "the forged message test".

log "Realtime"
check "/cable accepts a websocket upgrade" is_status 101 --http1.1 --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" -H "Origin: $BASE" "$BASE/cable"

for TOKEN in "$@"; do
  log "Widget inbox ${TOKEN:0:6}..."
  WIDGET="$(curl -fsS --max-time 15 -D - "$BASE/widget?website_token=$TOKEN")"
  CSP="$(grep -i '^content-security-policy:' <<<"$WIDGET" | tr -d '\r')"
  check "widget restricts framing ($CSP)" grep -q 'frame-ancestors [^*]' <<<"$CSP"

  AUTH_TOKEN="$(sed -nE "s/.*window\.authToken = '([^']+)'.*/\1/p" <<<"$WIDGET" | head -1)"
  check "unsigned identity is rejected with 401" is_status 401 -X PATCH \
    -H 'Content-Type: application/json' -H "X-Auth-Token: $AUTH_TOKEN" \
    -d "{\"identifier\":\"verify-probe-$(date +%s)\",\"name\":\"verify probe\"}" \
    "$BASE/api/v1/widget/contact/set_user?website_token=$TOKEN"
done

echo
if [[ "$FAILED" == 0 ]]; then
  echo "All outside-in checks passed. Now run rails/audit.rb for the database."
else
  echo "Some checks FAILED." >&2
  exit 1
fi
