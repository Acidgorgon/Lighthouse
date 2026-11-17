# Benchmarks

Lighthouse's own overhead, measured with the benchmark harness in
[bench/](https://github.com/Acidgorgon/Lighthouse/tree/main/bench): a Luau 0.700 host with a Roblox
mock. The full tables are in
[bench/RESULTS.md](https://github.com/Acidgorgon/Lighthouse/blob/main/bench/RESULTS.md).

## Results

| Measurement | Interpreted | Native codegen |
|---|---:|---:|
| `os.clock()` twice (the floor for any timer) | 112 ns | 118 ns |
| Probe pair, Lighthouse off | 62 ns | 57 ns |
| Probe pair, Lighthouse on | 324 ns | 186 ns |
| `wrap` call overhead, on | 346 ns | 209 ns |
| `wrap` call overhead, off | 61 ns | 46 ns |
| `count` / `gauge` / `net` call | 76 / 119 / 114 ns | 33 / 39 / 43 ns |
| Frame aggregation, 10 probes | 4.5 µs | 1.4 µs |
| Frame aggregation, 50 probes | 17.9 µs | 5.1 µs |
| Frame aggregation, 200 probes | 68.5 µs | 24.9 µs |
| Once-a-second roll, 50 probes | 71 µs | 31 µs |
| Snapshot build, 200 probes (at most 4 per second) | 267 µs | 131 µs |
| Allocations per frame, steady state | 0 | 0 |

Measured on a 4 vCPU cloud container. Runs vary by about 20%, so read them as relative numbers.
A Roblox server or a phone is slower in absolute terms, but the ratios hold.

Memory: about 17.5 KB per probe name (history ring and per-second windows), so 50 probes is under 1 MB.

## How to read them

- A **probe pair** is one `begin` and one `finish`.
- **Frame aggregation** is the once-per-frame work: moving this frame's probe times into the history,
  updating the windows and checking for a flare.
- **Snapshot build** runs at most a few times per second (overlay, viewer stream, exports).
- The off state is what a game pays when Lighthouse is required but not started, or started with
  `enabled = false`.

See [What it costs](/guide/cost) for what each part does.
