#!/usr/bin/env bash
# Opens an APK on the emulator and fails if the app does not live through its first seconds. release.sh runs it
# before publishing, because a phone only takes a higher build number: a release that crashes at launch could not be
# taken back, and it would take the app's own updates down with it.
#
# usage: app/tool/smoke.sh APK
#   The APK must hold x86_64 code: the emulator cannot load the arm64 libflutter.so of the published APK, so
#   release.sh builds an x86_64 one from the same commit for this.
#   SMOKE_DEVICE (default emulator-5580) must be an emulator, never a phone: the app's data on it may be wiped.
#   When it is not running, the AVD SMOKE_AVD (default sapoche_test, see docs/ops/devices.md) is started and stopped
#   again at the end.
set -euo pipefail

APK=${1:?the APK to try}
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
ADB="$SDK/platform-tools/adb"
SERIAL=${SMOKE_DEVICE:-emulator-5580}
AVD=${SMOKE_AVD:-sapoche_test}
PACKAGE=app.sapoche
WAIT=${SMOKE_SECONDS:-10}

[[ $SERIAL == emulator-* ]] || { echo "smoke: $SERIAL is not an emulator"; exit 1; }
adb() { "$ADB" -s "$SERIAL" "$@"; }

STARTED=0
if [ "$(adb get-state 2>/dev/null)" != device ]; then
  echo "smoke: starting $AVD on ${SERIAL#emulator-}"
  setsid nohup "$SDK/emulator/emulator" -avd "$AVD" -no-window -no-audio -gpu swiftshader_indirect -no-snapshot \
    -port "${SERIAL#emulator-}" >/dev/null 2>&1 &
  STARTED=1
  timeout 300 "$ADB" -s "$SERIAL" wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
fi
# Waits until the emulator is gone, so that the next run does not find it half shut down
stop() {
  [ "$STARTED" = 1 ] || return 0
  adb emu kill >/dev/null 2>&1 || true
  while "$ADB" devices | grep -q "^$SERIAL"; do sleep 1; done
}
trap stop EXIT

# A build signed with another key (a debug one) cannot be replaced, only removed first
if ! adb install -r "$APK" >/dev/null 2>&1; then
  adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
  adb install "$APK" >/dev/null
fi
adb logcat -b crash -c
adb shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null
sleep "$WAIT"

PID=$(adb shell pidof "$PACKAGE" | tr -d '\r' || true)
# Java and native crashes both land in the crash buffer, with the package's name in them
CRASH=$(adb logcat -d -b crash | grep -A12 -F "$PACKAGE" || true)
adb shell am force-stop "$PACKAGE"
if [ -z "$PID" ] || [ -n "$CRASH" ]; then
  echo "smoke: $PACKAGE did not survive ${WAIT}s after launch"
  [ -n "$CRASH" ] && echo "$CRASH" | head -20
  exit 1
fi
echo "smoke: $PACKAGE ran ${WAIT}s on $SERIAL without crashing"
