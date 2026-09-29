#!/usr/bin/env bash
# Listening session with both screens off, on the phones already in a playing room. Silent: it
# never touches the volume, so set that to 0 first. Prints what went wrong (if anything) at the end.
#
# usage: app/tool/soak.sh OUT_DIR [MINUTES=30] SERIAL SERIAL...
set -u
OUT=${1:?output dir}
MINUTES=${2:-30}
shift 2
DEVICES=("$@")
[ ${#DEVICES[@]} -gt 0 ] || { echo "give at least one adb serial"; exit 1; }
mkdir -p "$OUT"

for d in "${DEVICES[@]}"; do
  adb -s "$d" logcat -c
  adb -s "$d" shell input keyevent KEYCODE_SLEEP
done
echo "screens off at $(date +%T), listening for ${MINUTES} min"
sleep $((MINUTES * 60))

for d in "${DEVICES[@]}"; do
  adb -s "$d" shell input keyevent KEYCODE_WAKEUP
  adb -s "$d" logcat -d -s Unison > "$OUT/$d.log"
done

python3 - "$OUT" "${DEVICES[@]}" <<'PY'
import re, statistics, sys
out, devices = sys.argv[1], sys.argv[2:]
for d in devices:
    lines = open(f"{out}/{d}.log", errors="replace").read().splitlines()
    text = "\n".join(lines)
    drifts = [abs(int(m)) for m in re.findall(r"smoothed=(-?\d+)ms", text)]
    def count(pattern):
        return sum(1 for l in lines if re.search(pattern, l) and "drift=" not in l)
    print(f"== {d}: {len(lines)} log lines")
    print(f"   track changes: {count(r'transition to=')}, resyncs: {count(r'resync|catching up')}, "
          f"recoveries: {count(r'recover')}, load errors: {count(r'\[load\] error')}, "
          f"player errors: {count(r'player error|Source error')}, giving up: {count(r'giving up')}")
    if drifts:
        drifts.sort()
        print(f"   |drift| median {statistics.median(drifts):.0f} ms, p95 {drifts[int(len(drifts) * .95)]} ms, max {drifts[-1]} ms "
              f"({len(drifts)} samples)")
    beats = [l for l in lines if "[beat]" in l]
    stalled = [l for l in beats if "playing=false" in l]
    print(f"   heartbeats: {len(beats)}, not playing at {len(stalled)} of them")
PY
