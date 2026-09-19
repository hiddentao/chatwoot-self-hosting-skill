#!/usr/bin/env bash
# Builds the patched widget SDK for one Chatwoot release.
#
# Usage: patch-sdk.sh <tag> <image-ref> [out-dir]
#   tag        upstream git tag, e.g. v4.17.1
#   image-ref  the image the server runs, e.g. chatwoot/chatwoot:v4.17.1-ce@sha256:...
#   out-dir    where sdk.js and upstream.sha256 are written, relative to where
#              you run this (default: ./sdk). Make it a directory in your own
#              deployment repository: sdk.js is what you sync to the server and
#              mount into the proxy, and upstream.sha256 is what you commit so
#              the next release has something to compare against.
#
# Steps:
#   1. Extract the sdk.js the image ships and record its sha256 (drift detection).
#   2. Build the SDK from the tag's source without changes and compare it to the
#      shipped file, which proves the build reproduces upstream.
#   3. Apply sdk/IFrameHelper.patch, run its message-guard spec, build again,
#      and write sdk.js.
#   4. Print the Subresource Integrity string that every embedding page pins.
#
# Step 2 is the gate. A build that does not reproduce the shipped file byte for
# byte tells you nothing about what the patched build contains, so the script
# stops there rather than writing a file you cannot account for.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_IMAGE="${NODE_IMAGE:-node:24-bookworm}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/chatwoot/chatwoot.git}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
sri_of() { printf 'sha384-%s' "$(openssl dgst -sha384 -binary "$1" | openssl base64 -A)"; }

for tool in docker git openssl; do command -v "$tool" >/dev/null || die "$tool is not installed"; done

[[ $# -ge 2 ]] || die "usage: patch-sdk.sh <tag> <image-ref> [out-dir]"
TAG="$1"
IMAGE="$2"
# Output goes to the directory you run this from, not into the skill's own
# tools/sdk, which holds the patch and must not collect build artefacts.
SDK_DIR="${3:-$PWD/sdk}"
PATCH="$ROOT/sdk/IFrameHelper.patch"
[[ -f "$PATCH" ]] || die "patch not found at $PATCH"
mkdir -p "$SDK_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "Extracting shipped sdk.js from $IMAGE"
docker pull --quiet --platform linux/amd64 "$IMAGE" >/dev/null
CID="$(docker create --platform linux/amd64 "$IMAGE")"
docker cp "$CID:/app/public/packs/js/sdk.js" "$WORK/upstream.sdk.js" >/dev/null
docker rm "$CID" >/dev/null
UPSTREAM_SHA="$(sha256_of "$WORK/upstream.sdk.js")"

if [[ -f "$SDK_DIR/upstream.sha256" ]]; then
  read -r PREV_SHA PREV_TAG <"$SDK_DIR/upstream.sha256"
  if [[ "$PREV_SHA" == "$UPSTREAM_SHA" ]]; then
    echo "    upstream sdk.js is unchanged since $PREV_TAG"
  else
    echo "    upstream sdk.js CHANGED since $PREV_TAG: review the SDK diff for new config keys or events"
  fi
fi

log "Cloning chatwoot $TAG"
git clone --quiet --depth 1 --branch "$TAG" "$UPSTREAM_REPO" "$WORK/src" 2>/dev/null
git -C "$WORK/src" apply --check "$PATCH" ||
  die "the patch does not apply to $TAG; re-read the upstream file and rebase it"

in_node() {
  docker run --rm -v "$WORK/src:/src" -w /src "$NODE_IMAGE" bash -euc "
    corepack enable >/dev/null 2>&1
    [ -d node_modules ] || CI=true pnpm install --frozen-lockfile --ignore-scripts >/dev/null
    $1
  "
}

build() { in_node 'pnpm exec vite build --config vite.lib.config.ts >/dev/null'; }

log "Building unmodified SDK (reproducibility check)"
build
if [[ "$(sha256_of "$WORK/src/public/packs/js/sdk.js")" == "$UPSTREAM_SHA" ]]; then
  echo "    build reproduces the shipped sdk.js exactly"
else
  echo "    WARNING: unmodified build differs from the shipped sdk.js; inspect before trusting the patched build" >&2
  exit 1
fi

log "Testing the message guard"
git -C "$WORK/src" apply "$PATCH"
in_node 'TZ=UTC pnpm exec vitest run --no-coverage app/javascript/sdk/specs/IFrameHelperMessageGuard.spec.js'

log "Building patched SDK"
build
cp "$WORK/src/public/packs/js/sdk.js" "$SDK_DIR/sdk.js"
printf '%s %s\n' "$UPSTREAM_SHA" "$TAG" >"$SDK_DIR/upstream.sha256"

echo
echo "upstream sha256 : $UPSTREAM_SHA ($TAG)"
echo "patched sha256  : $(sha256_of "$SDK_DIR/sdk.js")"
echo "patched SRI     : $(sri_of "$SDK_DIR/sdk.js")"
echo
echo "Serve $SDK_DIR/sdk.js at /packs/js/sdk.js and pin the SRI on every"
echo "embedding page. Rolling out a new hash takes three deploys: see"
echo "widget-security.md, 'rolling out a new hash'."
