# Benchmark

Measures how fast AeroSpace switches workspaces and answers CLI queries, using windows of a controllable test app.

```bash
./build-debug.sh  # or swift build -c release --product AeroSpaceApp --product aerospace
bench/run-bench.sh .build/release/AeroSpaceApp .build/release/aerospace my-label 30
```

The script quits the running AeroSpace, starts the given server binary with `bench-config.toml`,
opens `benchapp` windows on workspaces `BENCH_A` and `BENCH_B` (3 windows of a responsive app,
and 1 window of an app that blocks its main thread for 40ms every 50ms, `SLOW_MS=0` disables it),
and switches between the workspaces.

Metrics:
- `new shown`/`old hidden`/`settle`: time from the `aerospace workspace` invocation until all windows of the new
  workspace are in place / all windows of the old workspace are hidden / both
- `holes`: how long the old windows were already hidden while the new ones were not yet in place (wallpaper flicker)
- `AX writes/switch`: position/size writes received by the test apps
- `frame changes/switch`: actual window moves/resizes. With 8 windows, 8 is the minimum
- `server cpu`/`apps cpu`: CPU time spent by AeroSpace and by the test apps
- `cli query`: latency of `aerospace list-workspaces --focused`

Results are noisy (the slow app answers AX requests at random moments), run the builds you compare interleaved.
