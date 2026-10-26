#!/usr/bin/env bash
# Builds the web app and copies it to server/web-dist, where the Worker serves it from.
#
#   app/tool/web.sh            build and copy
#   app/tool/web.sh deploy     the same, then deploy the Worker (outward-facing: only when the owner asks)
#
# Deploying the Worker without this build takes the web app down, see `predeploy` in server/package.json.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PATH="$HOME/.local/share/flutter/bin${NODE_BIN:+:$NODE_BIN}:$PATH"

cd "$ROOT/app"
flutter build web --wasm --release

DIST="$ROOT/server/web-dist"
find "$DIST" -mindepth 1 ! -name .gitkeep -delete
cp -r build/web/. "$DIST/"
# Debug symbols of the engine are for people with a debugger, not for visitors
find "$DIST" -name '*.symbols' -delete
rm -f "$DIST/.last_build_id"

echo "web app copied to $DIST ($(du -sh "$DIST" | cut -f1))"

if [ "${1:-}" = deploy ]; then
  cd "$ROOT/server" && npm run deploy
fi
