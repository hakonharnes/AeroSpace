#!/usr/bin/env bash
# Usage: bench/openclose.sh <server-binary> <cli-binary> <label> [iterations]
# Measures how long it takes until the layout settles after a window is opened or closed.
# Env: SLOW_MS (default 40, 0 = only responsive app windows)
set -euo pipefail
cd "$(dirname "$0")"
server="$1"; cli="$2"; label="$3"; iterations="${4:-10}"
out="${BENCH_OUT:-/tmp/aerospace-bench}"
mkdir -p "$out"
xcrun swiftc -O -swift-version 6 benchapp.swift -o "$out/benchapp" 2>/dev/null

osascript -e 'tell application "AeroSpace" to quit' 2>/dev/null || true
pkill -x AeroSpaceApp 2>/dev/null || true
pkill -x benchapp 2>/dev/null || true
sleep 1
log="$out/openclose.log"
rm -f "$log"
"$server" --config-path "$PWD/bench-config.toml" > "$out/server.log" 2>&1 &
server_pid=$!
trap 'pkill -x benchapp || true; kill $server_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do "$cli" list-workspaces --focused > /dev/null 2>&1 && break; sleep 0.2; done
sleep 1
"$cli" workspace BENCH_OC
sleep 0.3
export BENCHAPP_FRAME_LOG="$log"
"$out/benchapp" --name fast --windows 2 &
fast=$!
sleep 1.5
if test "${SLOW_MS:-40}" != 0; then
    "$out/benchapp" --name slow --windows 1 --slow-ms "${SLOW_MS:-40}" &
    sleep 1.5
fi
cpu() { ps -p "$server_pid" -o cputime= | awk -F'[:.]' '{print ($1*60+$2)*1000+$3*10}'; }
cpu_before=$(cpu)
for _ in $(seq "$iterations"); do
    kill -USR2 $fast; sleep 1
    kill -USR1 $fast; sleep 1
done
cpu_after=$(cpu)
echo "server cpu ms per open+close: $(( (cpu_after - cpu_before) / iterations ))"
python3 - "$log" "$label" <<'PY'
import sys
lines = [p for p in (l.split(None, 1) for l in open(sys.argv[1])) if len(p) == 2]
ev = [(float(t), rest.strip()) for t, rest in lines]
def stats(xs):
    xs = sorted(xs)
    return "p50=%.1f p90=%.1f max=%.1f" % (xs[len(xs) // 2], xs[int((len(xs) - 1) * 0.9)], xs[-1]) if xs else "n/a"
first_tile, settle_open, settle_close, changes_open, changes_close = [], [], [], [], []
started = False
for i, (t, e) in enumerate(ev):
    kind = e.split()[0]
    if kind == "open" and e.split()[1] == "fast-2": started = True
    if not started or kind not in ("open", "close"): continue
    title = e.split()[1]
    after = [(t2, e2) for t2, e2 in ev[i + 1:] if t2 - t < 900 and e2.split()[0] in ("move", "resize")]
    if kind == "open":
        mine = [t2 for t2, e2 in after if e2.split()[1] == title]
        if mine: first_tile.append(mine[0] - t)
        if after: settle_open.append(after[-1][0] - t)
        changes_open.append(len(after))
    else:
        if after: settle_close.append(after[-1][0] - t)
        changes_close.append(len(after))
print("== %s ==" % sys.argv[2])
print("open:  new window first tiled ms  ", stats(first_tile))
print("open:  layout settled ms          ", stats(settle_open), " frame changes/open=%.1f" % (sum(changes_open) / max(1, len(changes_open))))
print("close: layout settled ms          ", stats(settle_close), " frame changes/close=%.1f" % (sum(changes_close) / max(1, len(changes_close))))
PY
