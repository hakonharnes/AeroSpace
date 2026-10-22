#!/usr/bin/env bash
# Usage: bench/run-bench.sh <server-binary> <cli-binary> <label> [iterations]
# Env: SLOW_MS=<ms> how long the "slow" app blocks its main thread every 50ms (default 40, 0 disables the slow app)
# Quits the running AeroSpace, starts <server-binary> with bench-config.toml, opens benchapp windows on
# BENCH_A/BENCH_B, runs the benchmark and quits the server again.
set -euo pipefail
cd "$(dirname "$0")"
server="$1"; cli="$2"; label="$3"; iterations="${4:-30}"
out="${BENCH_OUT:-/tmp/aerospace-bench}"
mkdir -p "$out"
xcrun swiftc -O -swift-version 6 benchapp.swift -o "$out/benchapp" 2>/dev/null
xcrun swiftc -O -swift-version 5 bench.swift -o "$out/bench" 2>/dev/null

osascript -e 'tell application "AeroSpace" to quit' 2>/dev/null || true
pkill -x AeroSpaceApp 2>/dev/null || true
pkill -x benchapp 2>/dev/null || true
sleep 1
rm -rf "$out/stats" && mkdir -p "$out/stats"

"$server" --config-path "$PWD/bench-config.toml" > "$out/server.log" 2>&1 &
server_pid=$!
trap 'pkill -x benchapp || true; kill $server_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do "$cli" list-workspaces --focused > /dev/null 2>&1 && break; sleep 0.2; done
sleep 1

open_apps() {
    "$cli" workspace "$1"
    sleep 0.3
    "$out/benchapp" --name "fast$1" --windows 3 --stats "$out/stats/fast$1.json" &
    sleep 1.5
    if test "${SLOW_MS:-40}" != 0; then
        "$out/benchapp" --name "slow$1" --windows 1 --slow-ms "${SLOW_MS:-40}" --stats "$out/stats/slow$1.json" &
        sleep 1.5
    fi
}
open_apps BENCH_A
open_apps BENCH_B
sleep 1

"$out/bench" --cli "$cli" --server-pid "$server_pid" --stats-dir "$out/stats" --iterations "$iterations" --label "$label"
