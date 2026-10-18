# Synthetic terminal profile benchmark

[Project index](../../README.md#project-map) · [Cockpit guide](../README.md)

This guide owns the synthetic render workload. Use [Linux profiling](../docs/linux-performance-profiling.md) for real-application acceptance and [flow control](../docs/terminal-output-flow-control.md) for invariants; their results are not interchangeable.

From `cockpit/`, run:

```powershell
flutter run --profile -d windows -t benchmark/terminal_profile.dart
```

For a controlled four-way comparison, set `BENCH_RENDER_GATE` and
`BENCH_SCAN_THROTTLE` to `false` for the baseline, then enable each separately,
then both. The environment variables are read at runtime so one profile build
can be reused. `BENCH_RESULT_FILE` writes the JSON to a chosen temporary file
when launching the built Windows executable directly. `BENCH_SWITCH_MS`,
`BENCH_OUTPUT_MS`, and `BENCH_DURATION_MS` adjust the synthetic workload.
`BENCH_HIDDEN_FRAMES=true` restores the previous frame scheduling for output
only in hidden tabs. `BENCH_VISIBLE_OUTPUT=false` sends output only to the nine
hidden tabs at any moment, while tab switching continues.

The standalone entrypoint runs for 30 seconds and prints one `terminal_profile`
JSON line. It creates ten in-memory Ghostty/flterm controllers and sends the
same fixed ANSI output to each every 50 ms. All ten `TerminalView` widgets stay
mounted under a shared `TerminalScope`; one is presented while the others use
the production `Offstage`, `TickerMode`, and `presentationActive` settings. The
benchmark switches tabs every 500 ms by default. The normal app bootstrap, stored terminal
profiles, native PTYs, and installed user data are not used.

`frameP95Us`, `frameMaxUs`, and `jankFrames` come from Flutter's engine frame
timings. Jank means a total frame time over 16,667 microseconds. The
`buildP95Us` and `rasterP95Us` fields separate UI and GPU work from total
frame latency. Tab switch durations run from the state change to the next
post-frame callback. PTY pending
values are the aggregate scheduler queue, not a native PTY pipe. `rssBytes` is
the benchmark process's resident memory at the end. `syntheticProcessScans`
counts calls to a provider with a fixed 20 ms delay, allowing a controlled
comparison of monitor scheduling; it does not measure real Windows CIM cost.

Use the same device, window size, Flutter version, and workload when comparing
two revisions. Profile builds on physical desktop hardware are necessary for
meaningful frame timings; widget tests do not provide comparable raster times.
