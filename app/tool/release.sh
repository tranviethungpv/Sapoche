#!/usr/bin/env bash
# Builds the release APK, checks it, and makes it ready for the app's own updates (Settings > Updates).
#
# usage: app/tool/release.sh [--publish] ["a line of what changed" ...]
#   The notes people read under Settings > Updates come from app/release-notes/<version>.txt (English) and
#   <version>.vi.txt (Vietnamese; shown when the app speaks Vietnamese). A line starting with "- " is a bullet, any
#   other line is a heading. Lines given on the command line replace the English file.
#   without --publish: builds into ~/sapoche-release-arm64-<version>.apk and writes the update files next to it
#   with --publish:    first opens the APK on the emulator (app/tool/smoke.sh) and stops if it crashes; then
#                      puts the files in the private R2 bucket (needs `wrangler login`; the APK first, then
#                      latest.json, so a phone never reads news of a file that is not there yet; the file is
#                      named sapoche-<version>.apk, and latest.json says so)
#
# Bump `version:` in pubspec.yaml first: a phone only offers an update whose build number is higher.
set -euo pipefail

PUBLISH=0
if [ "${1:-}" = "--publish" ]; then PUBLISH=1; shift; fi

APP=$(cd "$(dirname "$0")/.." && pwd)
SERVER=$(cd "$APP/../server" && pwd)
FLUTTER=${FLUTTER:-$HOME/.local/share/flutter/bin/flutter}
BUILD_TOOLS=$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/* | sort -V | tail -1)
# wrangler needs Node 22 or newer; NODE_BIN is the folder of a Node that is not the one on the PATH, if there is one
export PATH=${NODE_BIN:+$NODE_BIN:}$PATH

VERSION=$(sed -n 's/^version: *//p' "$APP/pubspec.yaml")
NOTES_ARGS=("$@")
NAME=${VERSION%+*}
CODE=${VERSION#*+}
[ "$NAME" != "$VERSION" ] || { echo "pubspec.yaml version needs a build number (1.2.3+4)"; exit 1; }

cd "$APP"
"$FLUTTER" build apk --release --target-platform android-arm64

OUT=$HOME/sapoche-release-arm64-$NAME.apk
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"

# Signed with the release key, not the debug one: the debug key would install but could never update the real app
"$BUILD_TOOLS/apksigner" verify --print-certs "$OUT" | grep "SHA-256" | head -1
if "$BUILD_TOOLS/apksigner" verify --print-certs "$OUT" | grep -q "Android Debug"; then
  echo "signed with the debug key; sapoche.properties has no release keystore"; exit 1
fi
BADGING=$("$BUILD_TOOLS/aapt2" dump badging "$OUT")
echo "$BADGING" | grep -q "versionCode='$CODE'" || { echo "the APK does not carry build number $CODE"; exit 1; }
echo "$BADGING" | grep -q "application-debuggable" && { echo "the APK is debuggable"; exit 1; }

SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
SIZE=$(stat -c %s "$OUT")
LATEST=$(dirname "$OUT")/sapoche-latest-$NAME.json
python3 - "$LATEST" "$CODE" "$NAME" "$SHA" "$SIZE" "$APP/release-notes" "${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"}" <<'PY'
import json, os, sys
path, code, name, sha, size, folder, *lines = sys.argv[1:]

def read(file):
    full = os.path.join(folder, file)
    return open(full, encoding="utf-8").read().strip() if os.path.exists(full) else ""

notes = "\n".join(lines).strip() or read(f"{name}.txt")
notes_vi = read(f"{name}.vi.txt")
latest = {"versionCode": int(code), "versionName": name, "sha256": sha, "size": int(size), "file": f"sapoche-{name}.apk", "notes": notes}
if notes_vi:
    latest["notesVi"] = notes_vi
# The notes of the last few versions too, so that a phone that is several versions behind can read all it has missed
# (the notes inside the app stop at the version it was built as)
def number(version):
    return [int(part) for part in version.split(".")]

versions = sorted(
    (f[:-4] for f in os.listdir(folder) if f.endswith(".txt") and not f.endswith(".vi.txt") and f[:-4].replace(".", "").isdigit()),
    key=number,
    reverse=True,
)
history = []
for version in versions:
    if number(version) > number(name):
        continue
    entry = {"version": version, "notes": notes if version == name else read(f"{version}.txt")}
    vi = notes_vi if version == name else read(f"{version}.vi.txt")
    if vi:
        entry["notesVi"] = vi
    history.append(entry)
latest["history"] = history[:10]
if not notes:
    print(f"warning: no release notes for {name} (app/release-notes/{name}.txt)", file=sys.stderr)
json.dump(latest, open(path, "w"), ensure_ascii=False)
PY
echo "built $OUT ($SIZE bytes, sha256 $SHA)"

if [ "$PUBLISH" = 1 ]; then
  # A phone never goes back to a lower build number, so a release that crashes at launch must not leave this computer.
  # The emulator runs x86_64 only, so the same code is built once more for it.
  "$FLUTTER" build apk --release --target-platform android-x64
  SMOKE_APK=$HOME/sapoche-release-x64-$NAME.apk
  cp build/app/outputs/flutter-apk/app-release.apk "$SMOKE_APK"
  "$APP/tool/smoke.sh" "$SMOKE_APK"
  cd "$SERVER"
  npx wrangler r2 object put "sapoche-releases/sapoche-$NAME.apk" --remote --file "$OUT" --content-type application/vnd.android.package-archive
  npx wrangler r2 object put "sapoche-releases/latest.json" --remote --file "$LATEST" --content-type application/json
  echo "published $NAME ($CODE)"
else
  echo "not published; run again with --publish to put it in the bucket"
fi
