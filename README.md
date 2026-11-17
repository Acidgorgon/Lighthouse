# Lighthouse

**Docs: https://acidgorgon.github.io/Lighthouse/**

Profiling and live telemetry for Roblox. Lighthouse answers "where do my milliseconds and bytes go?"
with real numbers instead of guesses: CPU per system on the client and the server, frame time and its
percentiles, network cost per channel, memory, and what real players' devices see.

> [!NOTE]
> **Made with Claude.** Most of Lighthouse was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.

```lua
-- server and client: two lines
local Lighthouse = require(ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

```lua
-- one line per thing you want to measure
Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", stepCrowd)  -- a signal handler
local think = Lighthouse.wrap("Ai.Think", think)                  -- any function

local path = Lighthouse.probe("Crowd.Path")                       -- part of a function
path:begin() ... path:finish()

Lighthouse.count("Pathfinds")       -- per second
Lighthouse.gauge("Npcs", #npcs)     -- last value
```

Press **F7** (or **L3 + R3** on a controller) to open the overlay.

It is part of **Harbor**, a family of Roblox libraries: **Current** (networking), **Ripple** (state
sync), **Anchor** (saving), **Tide** (motion) and **Lighthouse** (profiling).

## Why

- **Cheap when on.** A probe pair is two `os.clock()` calls and a few array writes. Nothing is
  allocated per probe call or per frame in steady state; aggregation runs once per frame.
- **Close to free when off.** Before `start()`, or with `enabled = false`, every probe call is one
  check and a return, so probes can stay in shipping code.
- **Self time, not guesses.** Probes nest, and Lighthouse splits each probe's time into self and
  total, so lists sorted by self time point at the system that is slow. Script time next to frame
  time shows how much you have not measured yet. Names also show in the MicroProfiler.
- **Network per channel.** `Lighthouse.net` and `Lighthouse.remote` count bytes and packets per
  channel. Current, Ripple and Tide report their own channels when Lighthouse is present.
- **Real devices.** With `telemetry = true`, sampled clients report frame percentiles, memory and
  their slowest probes. The server merges them per device class (aggregates only) and can log them
  to AnalyticsService.
- **Overlay and viewer.** An in-game panel for mouse, touch and controller, and a
  [web viewer](https://acidgorgon.github.io/Lighthouse/viewer) for exports with a zoomable frame
  timeline.
- **Never breaks the game.** Every receive path validates and never throws. A probe misuse is
  counted and repaired.

## Install

Copy `src/` into `ReplicatedStorage` as a ModuleScript named `Lighthouse` (with Rojo:
`"Lighthouse": { "$path": "path/to/Lighthouse/src" }`). Then call `Lighthouse.start()` on the server
and on the client. See [Getting started](https://acidgorgon.github.io/Lighthouse/guide/getting-started).

## API at a glance

```lua
Lighthouse.start(opts?) / Lighthouse.stop()
Lighthouse.probe(name) -> probe:begin() / probe:finish()
Lighthouse.wrap(name, fn) / Lighthouse.bind(signal, name, fn)
Lighthouse.count(name, n?) / Lighthouse.gauge(name, value)
Lighthouse.net(lib, channel, "in" | "out", bytes, player?) / Lighthouse.remote(remoteEvent)
Lighthouse.overlay(on?)                 -- client
Lighthouse.snapshot() / Lighthouse.export(seconds?) / Lighthouse.record(seconds)
Lighthouse.onFlare(fn) / Lighthouse.flares()
Lighthouse.onReport(fn)                 -- server, player telemetry
```

Full reference: [API](https://acidgorgon.github.io/Lighthouse/reference/api). Overhead numbers:
[Benchmarks](https://acidgorgon.github.io/Lighthouse/benchmarks).

## Tests

```sh
sh bench/fetch_luau.sh   # Luau 0.700 sources (gitignored)
tests/run.sh             # builds the host with CMake, runs the tests interpreted and native
```

## Layout

- `src/` the library: `init.luau` (public API), `Core/` (pure Luau measuring and stats), `Runtime/`
  (engine sampling, wire, viewers, telemetry), `Overlay/` (the in-game panel)
- `tests/` tests on a Roblox mock (`tests/run.sh`)
- `bench/` overhead benchmarks
- `docs/` the documentation site (VitePress) with the export viewer

## License

MIT. See [LICENSE](LICENSE).
