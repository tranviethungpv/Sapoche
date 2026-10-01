#!/usr/bin/env bash
# Builds the release APK, checks it, and makes it ready for the app's own updates (Settings > Updates).
#
# usage: app/tool/release.sh [--publish] ["what changed"]
#   without --publish: builds into ~/unison-release-arm64-<version>.apk and writes the update files next to it
#   with --publish:    also puts them in the private R2 bucket (needs `wrangler login`; the APK first, then
#                      latest.json, so a phone never reads news of a file that is not there yet; the file is
#                      named unison-<version>.apk, and latest.json says so)
#
# Bump `version:` in pubspec.yaml first: a phone only offers an update whose build number is higher.
set -euo pipefail

PUBLISH=0
if [ "${1:-}" = "--publish" ]; then PUBLISH=1; shift; fi
NOTES=${1:-}

APP=$(cd "$(dirname "$0")/.." && pwd)
SERVER=$(cd "$APP/../server" && pwd)
FLUTTER=${FLUTTER:-$HOME/.local/share/flutter/bin/flutter}
BUILD_TOOLS=$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/* | sort -V | tail -1)
export PATH=$HOME/.local/share/node/bin:$PATH

VERSION=$(sed -n 's/^version: *//p' "$APP/pubspec.yaml")
NAME=${VERSION%+*}
CODE=${VERSION#*+}
[ "$NAME" != "$VERSION" ] || { echo "pubspec.yaml version needs a build number (1.2.3+4)"; exit 1; }

cd "$APP"
"$FLUTTER" build apk --release --target-platform android-arm64

OUT=$HOME/unison-release-arm64-$NAME.apk
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"

# Signed with the release key, not the debug one: the debug key would install but could never update the real app
"$BUILD_TOOLS/apksigner" verify --print-certs "$OUT" | grep "SHA-256" | head -1
if "$BUILD_TOOLS/apksigner" verify --print-certs "$OUT" | grep -q "Android Debug"; then
  echo "signed with the debug key; unison.properties has no release keystore"; exit 1
fi
BADGING=$("$BUILD_TOOLS/aapt2" dump badging "$OUT")
echo "$BADGING" | grep -q "versionCode='$CODE'" || { echo "the APK does not carry build number $CODE"; exit 1; }
echo "$BADGING" | grep -q "application-debuggable" && { echo "the APK is debuggable"; exit 1; }

SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
SIZE=$(stat -c %s "$OUT")
LATEST=$(dirname "$OUT")/unison-latest-$NAME.json
python3 - "$LATEST" "$CODE" "$NAME" "$SHA" "$SIZE" "$NOTES" <<'PY'
import json, sys
path, code, name, sha, size, notes = sys.argv[1:]
json.dump({"versionCode": int(code), "versionName": name, "sha256": sha, "size": int(size), "file": f"unison-{name}.apk", "notes": notes}, open(path, "w"))
PY
echo "built $OUT ($SIZE bytes, sha256 $SHA)"

if [ "$PUBLISH" = 1 ]; then
  cd "$SERVER"
  npx wrangler r2 object put "unison-releases/unison-$NAME.apk" --remote --file "$OUT" --content-type application/vnd.android.package-archive
  npx wrangler r2 object put "unison-releases/latest.json" --remote --file "$LATEST" --content-type application/json
  echo "published $NAME ($CODE)"
else
  echo "not published; run again with --publish to put it in the bucket"
fi
