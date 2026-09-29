#!/usr/bin/env bash
# What the app costs over a stretch of time, for comparing one build with another on the same phone:
# CPU time of the app's process, frames drawn, and how often the room connection was rebuilt. Silent:
# it never touches the volume, so set that to 0 first. Do not run it on a phone somebody is using.
#
# The phone is on a cable, so its battery gauge means nothing; CPU time is the stand-in. Start the
# music (alone or in a room) first, then:
#
# usage: app/tool/battery.sh SERIAL [MINUTES=10] [LABEL=run] [off|on]
#   off: the screen is put to sleep for the whole time (the case that matters most, music in a pocket)
#   on:  the screen is left as it is; frames drawn are counted too
set -u
DEVICE=${1:?adb serial}
MINUTES=${2:-10}
LABEL=${3:-run}
SCREEN=${4:-off}
PACKAGE=app.unison
adb_() { adb -s "$DEVICE" "$@"; }

pid=$(adb_ shell pidof "$PACKAGE" | tr -d '\r' | awk '{print $1}')
[ -n "$pid" ] || { echo "$PACKAGE is not running on $DEVICE"; exit 1; }

cpu_seconds() {
  adb_ shell cat "/proc/$pid/stat" | tr -d '\r' | python3 -c '
import sys
rest = sys.stdin.read().rsplit(")", 1)[1].split()
print((int(rest[11]) + int(rest[12])) / 100)'
}

adb_ logcat -c
adb_ shell dumpsys gfxinfo "$PACKAGE" reset > /dev/null 2>&1
start=$(cpu_seconds) || { echo "cannot read /proc/$pid/stat on this phone"; exit 1; }
[ "$SCREEN" = off ] && adb_ shell input keyevent KEYCODE_SLEEP
echo "[$LABEL] started $(date +%T): ${MINUTES} min, screen $SCREEN, pid $pid"
sleep $((MINUTES * 60))
[ "$SCREEN" = off ] && adb_ shell input keyevent KEYCODE_WAKEUP
end=$(cpu_seconds)

frames=$(adb_ shell dumpsys gfxinfo "$PACKAGE" | tr -d '\r' | awk -F': ' '/Total frames rendered/ {print $2}')
adb_ logcat -d -s Unison > "/tmp/battery-$LABEL.log"
python3 - "$start" "$end" "$MINUTES" "${frames:-0}" "$LABEL" "/tmp/battery-$LABEL.log" <<'PY'
import re, sys
start, end, minutes, frames, label, log = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
used = end - start
lines = open(log, errors="replace").read().splitlines()
connects = sum(1 for l in lines if "connected to" in l)
drops = sum(1 for l in lines if "reconnecting in" in l or "dropping the connection" in l)
print(f"[{label}] CPU {used:.1f} s in {minutes:.0f} min = {used / (minutes * 60) * 100:.2f}% of one core")
print(f"[{label}] frames drawn: {frames}, connections made: {connects}, dropped or retried: {drops}, log lines: {len(lines)}")
PY
