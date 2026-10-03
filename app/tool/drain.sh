#!/usr/bin/env bash
# How much battery and warmth a listening session costs, for comparing one build or one setting with another on
# the same phone. Unlike battery.sh this needs the phone OFF the cable (a charging battery shows nothing), so it
# talks to the phone over Wi-Fi:
#   1. phone and computer on the same Wi-Fi; on the phone: Developer options > Wireless debugging > on
#   2. adb pair HOST:PORT   (with the pairing code from "Pair device with pairing code", once)
#   3. adb connect HOST:PORT   (the address under Wireless debugging), then unplug the cable
#   4. start the music, put the phone as the scenario wants it (screen on a page, or screen off), then:
#
# usage: app/tool/drain.sh SERIAL [MINUTES=30] [LABEL=run]
#   SERIAL is the Wi-Fi address from "adb devices" (like 192.168.1.20:37099)
#
# Silent: it never touches the volume or the screen. It samples once a minute: battery level, battery temperature,
# the system's thermal status, and the CPU time of the app. At the end it also asks the system what it thinks the app
# used (estimated mAh, from `dumpsys batterystats`), which is rough but is what Android's own battery page shows.
set -u
DEVICE=${1:?adb serial (the Wi-Fi address)}
MINUTES=${2:-30}
LABEL=${3:-run}
PACKAGE=app.sapoche
OUT=${TMPDIR:-/tmp}/drain-$LABEL
mkdir -p "$OUT"
adb_() { adb -s "$DEVICE" "$@"; }

battery() { adb_ shell dumpsys battery | tr -d '\r'; }
charging() { battery | awk '/AC powered|USB powered|Wireless powered|Dock powered/ && $NF == "true" {found=1} END {print found ? "yes" : "no"}'; }
level() { battery | awk '/^  level:/ {print $2}'; }
# tenths of a degree
temp() { battery | awk '/^  temperature:/ {print $2}'; }
thermal() { adb_ shell dumpsys thermalservice 2>/dev/null | tr -d '\r' | awk -F': ' '/Current thermal status|^Thermal Status/ {print $2; exit}'; }
pid() { adb_ shell pidof "$PACKAGE" | tr -d '\r' | awk '{print $1}'; }
cpu_seconds() {
  adb_ shell cat "/proc/$1/stat" 2>/dev/null | tr -d '\r' | python3 -c '
import sys
data = sys.stdin.read()
if ")" not in data:
    print(-1)
else:
    rest = data.rsplit(")", 1)[1].split()
    print((int(rest[11]) + int(rest[12])) / 100)'
}

[ "$(charging)" = no ] || { echo "the phone is charging: unplug the cable (and use adb over Wi-Fi) or the battery says nothing"; exit 1; }
p=$(pid)
[ -n "$p" ] || { echo "$PACKAGE is not running on $DEVICE"; exit 1; }

adb_ shell dumpsys batterystats --reset > /dev/null 2>&1
start_level=$(level)
start_cpu=$(cpu_seconds "$p")
echo "[$LABEL] started $(date +%T): $MINUTES min, battery $start_level%, $(($(temp) / 10)) C"
echo "minute,level,temp_tenths_c,thermal_status,cpu_s" > "$OUT/samples.csv"
for ((m = 1; m <= MINUTES; m++)); do
  sleep 60
  echo "$m,$(level),$(temp),$(thermal),$(cpu_seconds "$p")" >> "$OUT/samples.csv"
done
adb_ shell dumpsys batterystats "$PACKAGE" | tr -d '\r' > "$OUT/batterystats.txt"
echo "[$LABEL] charging again? $(charging) (should be no)"

python3 - "$OUT" "$start_level" "$start_cpu" "$MINUTES" "$LABEL" <<'PY'
import csv, re, sys
out, start_level, start_cpu, minutes, label = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
rows = list(csv.DictReader(open(f"{out}/samples.csv")))
levels = [int(r["level"]) for r in rows if r["level"]]
temps = [int(r["temp_tenths_c"]) / 10 for r in rows if r["temp_tenths_c"]]
status = [r["thermal_status"] for r in rows if r["thermal_status"]]
end_cpu = float(rows[-1]["cpu_s"])
print(f"[{label}] battery {start_level}% -> {levels[-1]}%  (lost {start_level - levels[-1]} points in {minutes} min)")
if temps:
    print(f"[{label}] battery temperature {temps[0]:.1f} -> {temps[-1]:.1f} C, highest {max(temps):.1f} C")
if status:
    print(f"[{label}] highest thermal status {max(status)} (0 none, 1 light, 2 moderate, 3 severe)")
if end_cpu >= 0 and start_cpu >= 0:
    used = end_cpu - start_cpu
    print(f"[{label}] app CPU {used:.1f} s = {used / (minutes * 60) * 100:.2f}% of one core")
text = open(f"{out}/batterystats.txt", errors="replace").read()
m = re.search(r"Estimated power use \(mAh\):.*?Uid u0a\d+: ([\d.]+)[^\n]*", text, re.S)
mine = re.search(r"Uid u0a\d+: ([\d.]+) \( ([^)]*)\)", text)
print(f"[{label}] system's estimate for the app: {mine.group(1) + ' mAh (' + mine.group(2) + ')' if mine else 'not available on this phone'}")
print(f"[{label}] raw numbers in {out}")
PY
