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
# The sticker packs are static files too (artwork downloaded on the first run and kept in build/stickers-cache). Without
# them the chat still works: a sticker shows as the emoji it stands for
python3 tool/stickers.py || echo "warning: no sticker packs were built, the web app goes without" >&2

DIST="$ROOT/server/web-dist"
find "$DIST" -mindepth 1 ! -name .gitkeep -delete
cp -r build/web/. "$DIST/"
if [ -f build/stickers/index.json ]; then cp -r build/stickers "$DIST/stickers"; fi
# Debug symbols of the engine are for people with a debugger, not for visitors
find "$DIST" -name '*.symbols' -delete
rm -f "$DIST/.last_build_id"

echo "web app copied to $DIST ($(du -sh "$DIST" | cut -f1))"

if [ "${1:-}" = deploy ]; then
  cd "$ROOT/server" && npm run deploy
fi
