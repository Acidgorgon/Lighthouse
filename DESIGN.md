# Lighthouse design (v0.1)

Lighthouse is profiling and live telemetry for Roblox. It answers "where do my milliseconds and bytes
go?" with real numbers instead of guesses: per-system CPU on client and server, frame time, network
cost per channel (with built-in hooks for Current, Ripple and Tide), memory, and what real players'
devices see. Part of the Harbor family: Current (networking), Ripple (state sync), Anchor (saving),
Tide (motion), Lighthouse (profiling). Own design and names; not modelled on any other author's work.

Rules that shape everything:

1. **Very easy.** Two lines to start, one line per thing you want to measure.
2. **Cheap when on.** A probe pair costs two `os.clock()` calls plus a few array writes. No table, closure
   or string allocation per probe call or per frame (steady state). Aggregation work happens once per frame.
3. **Close to free when off.** Before `Lighthouse.start()` (or with `enabled = false`) every probe method is
   one upvalue test and return. `Lighthouse.wrap` returns the original function untouched when Lighthouse is
   disabled at wrap time.
4. **Never breaks the game.** Every receive path validates and never throws. A probe misuse (finish without
   begin, unbalanced nesting) is counted and repaired, never an error in a hot loop.
5. **Shows in MicroProfiler too.** Probes call `debug.profilebegin/profileend` with the same name when
   `microprofiler = true` (default true in Studio, false live), so Lighthouse names line up with Roblox's tools.

## Layout

```
src/
  init.luau            public API (same module on client and server; picks side by RunService:IsServer())
  Core/
    Clock.luau         os.clock wrapper, frame boundaries
    Probes.luau        probe registry, begin/finish stack, self vs total time, per-frame accumulators
    Frames.luau        per-frame ring (default 600 frames) of frame time + per-probe self time
    Stats.luau         rolling windows: avg, p50, p95, p99, max over last 1 s / 10 s / 60 s; histogram buckets
    Counters.luau      counters (per-second rates) and gauges (last value)
    Net.luau           network channels: (lib, channel, dir) -> bytes/s, packets/s, avg size
    Spikes.luau        "flares": frames over budget, stored with their top probes
    Snapshot.luau      builds the Snapshot table (see below) from the above
    Json.luau          export encoder (no HttpService dependency so it runs in tests)
  Runtime/
    Sampler.luau       engine numbers: Heartbeat/RenderStepped dt, Stats service, memory tags, ping, instance count
    Wire.luau          buffer codec for server->viewer stream and client->server reports (versioned, validated)
    Server.luau        viewer permissions, streams server snapshot to viewers, receives client reports, aggregates
    Client.luau        receives server snapshot, sends reports, owns the overlay toggle
    Telemetry.luau     player telemetry: sampling, aggregation by device class, AnalyticsService + HTTP + onReport
    Device.luau        device class: "Desktop" | "Mobile" | "Tablet" | "Console" | "VR"
  Overlay/
    Overlay.luau       in-game panel built from plain Instances (no UI library dependency), updates at 4 Hz
    Graph.luau         pooled bar graph (frame time history)
    Theme.luau         colours and sizes
tests/                 runner + Roblox mock (from Tide's tests), luau-bench host (Luau 0.700)
bench/                 overhead benchmarks: probe cost on/off, frame aggregation cost
docs/                  VitePress site, Harbor theme, includes the Viewer page (loads an export JSON)
```

## Public API

```lua
local Lighthouse = require(ReplicatedStorage.Lighthouse)

Lighthouse.start(opts?)            -- call once on server and once on client; safe to call again (merges opts)
Lighthouse.stop()                  -- back to the near-free off state

-- Measuring code
local crowd = Lighthouse.probe("Crowd.Step")  -- get once at module load (same name -> same probe)
crowd:begin()
...                                -- work
crowd:finish()

local step = Lighthouse.wrap("Crowd.Step", step)          -- wrap a function once; returns fn itself if off
Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", fn)   -- Connect + wrap; returns the RBXScriptConnection

-- Numbers you care about
Lighthouse.count("Pathfinds")       -- +1 (or Lighthouse.count(name, n)); shown as per second
Lighthouse.gauge("Npcs", #npcs)     -- last value

-- Network (Current, Ripple and Tide call this for you; use it for your own remotes)
Lighthouse.net("Game", "Shop", "out", bytes)   -- lib, channel, "in" | "out", bytes (packets counted as 1 per call)
local remote = Lighthouse.remote(remoteEvent)  -- counts your own RemoteEvent traffic (buffers measured exactly,
                                               -- other args estimated); returns a wrapper with the same Fire* methods

-- Seeing it
Lighthouse.overlay(true | false | nil)  -- show / hide / toggle the panel (client)
Lighthouse.snapshot()                   -- Snapshot table (this side)
Lighthouse.export(seconds?)             -- JSON string: snapshot + per-frame recording of the last `seconds`
Lighthouse.record(seconds)              -- start a detailed recording; Lighthouse.export() returns it after
Lighthouse.onFlare(fn)                  -- fn(flare) when a frame goes over budget (rate limited)
Lighthouse.onReport(fn)                 -- server: fn(report) for each client telemetry report

-- Hooks for libraries (see "Library hooks")
shared.Lighthouse                       -- set by Lighthouse at require time
```

Probe names use dots for grouping: `"Crowd.Step"` groups under `Crowd` in the overlay and the viewer.
Names are interned once; a probe is a small object with an integer id.

### Options (`Lighthouse.start(opts)`)

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` keeps everything in the off state (for a live switch) |
| `budget` | client 1/60 s, server 1/60 s | frame budget in seconds; frames over it are flares |
| `frames` | `600` | frames kept in the ring |
| `microprofiler` | `RunService:IsStudio()` | also call debug.profilebegin/end |
| `viewers` | creator + Studio | server: `function(player): boolean` or a list of UserIds / group `{ group = id, rank = n }` allowed to see server numbers and open the overlay in live games |
| `overlayKey` | `Enum.KeyCode.F8` | keyboard toggle |
| `overlayGamepad` | `{ ButtonL3, ButtonR3 }` | press both to toggle (controller players) |
| `telemetry` | `false` | `true` or a table: `{ sample = 0.1, every = 60, analytics = true, http = nil }` |
| `stream` | `1` | seconds between server snapshot sends to viewers |

## Core behaviour

### Probes

- `begin()` pushes `(probeId, os.clock())` on a preallocated stack (numbers in two arrays, max depth 64).
- `finish()` pops; `total = now - start`; adds `total` to the probe's frame total and `total - childTime`
  to its frame self time; adds `total` to the parent's child time; increments the probe's frame call count.
- `finish()` for a probe that is not on top: unwind to it (counting each unwound probe as finished at `now`)
  and bump `misuse` counter; if it is not on the stack at all, ignore and bump `misuse`.
- Off state: `begin/finish` check one upvalue `active` and return.
- A pair must begin and finish inside one event callback (one frame). Entries still open at the frame
  boundary (an error inside a probed region, or a begin without finish) are dropped there, their time
  discarded, and each counts as one `misuse`. Nesting deeper than 64 is not pushed and counts as misuse;
  the matching finishes are absorbed.
- `wrap(name, fn)`: returns a function that does begin, `fn(...)`, finish; it must return all results and keep
  working if `fn` errors (use a depth check at the next frame boundary to repair the stack, not pcall per call).
- Frame boundary: the Runtime calls `Core.endFrame(frameTime)` once per frame (client: RenderStepped start of
  next frame; server: Heartbeat). It moves per-probe frame accumulators into the frame ring, updates stats,
  checks flares, and zeroes the accumulators. Only probes touched this frame are visited (dirty list).

### Rolling stats

Per probe and for frame time: last-frame value, and over 1 s / 10 s / 60 s windows: avg, p50, p95, p99,
max, calls per frame. Percentiles come from a fixed log-scale histogram, so no sorting and no allocation:
134 buckets, 6 per octave (about 12% wide, a value is within ~6% of its bucket's midpoint) from 0.001 ms
to about 4.2 s, plus an underflow and an overflow bucket; quantiles interpolate inside the bucket and
are clamped to the observed max.

Each series (frame ms, script ms, each probe's self ms) keeps a ring of 61 one-second slots (a u8
histogram plus samples / sum / max / total / calls per slot). When a second completes it is added to
running 10 s and 60 s aggregate histograms and the slots that left those windows are subtracted, so a
window query never merges histograms. A window is "the last k completed seconds" (the second in
progress is not included). Averages are per frame (sum / frames in the window), so a probe that runs
every 4th frame for 4 ms has avg 1 ms; its percentiles and max are over the frames it ran in.
About 17.5 KB per probe (see bench/RESULTS.md).

### Flares (spikes)

A frame over `budget` (and over 1.5x the 10 s p50) becomes a flare: `{ t, frameMs, frame, top = { { name, ms }, ... up to 5 } }`
(top = the frame's probes with the most self time). Last 32 flares kept in preallocated records.
`onFlare` callbacks get a copy, run through `opts.spawn` (task.spawn in Roblox), at most 2 per second.

### Counters, gauges

Counters accumulate per frame and report per second (over the last completed second; after a hitch of
k seconds, the count divided by k). Gauges keep the last value and the 10 s min/max.

### Network channels

Key `(lib, channel, dir)`. Per frame bytes and packets; reported as bytes/s, packets/s, avg bytes per packet,
peak bytes/s over 10 s. Grouped in the overlay by lib. Server additionally tracks the top 5 players by
bytes out when the lib passes a player (`Lighthouse.net(lib, channel, dir, bytes, player?)`), as a 10 s
moving average; keys that go quiet are dropped. Snapshot field `netTop = { { who = tostring(key), bps } }`.

## Engine sampling (Runtime/Sampler)

Every frame (cheap reads only):
- client: frame dt from RenderStepped, Heartbeat dt; server: Heartbeat dt.
- Script time per frame = sum of top-level probe totals (shown next to frame time so you see "unmeasured").

Every second (pcall'd, missing properties skipped, each read wrapped so a renamed property never errors):
- `Stats`: `HeartbeatTimeMs`, `PhysicsStepTimeMs`, `DataReceiveKbps`, `DataSendKbps`, `PhysicsReceiveKbps`,
  `PhysicsSendKbps`, `InstanceCount`, `PrimitivesCount`, `MovingPrimitivesCount`, `ContactsCount`,
  `GetTotalMemoryUsageMb()`, `GetMemoryUsageMbForTag` for LuaHeap, Script, Instances, PhysicsCollision,
  PhysicsParts, GraphicsTexture, GraphicsMeshParts, Animation, Gui, Sounds, Navigation (whatever exists).
- `gcinfo()` (Luau heap KB) and its per-second growth (garbage rate, a big CPU hint).
- client: `Players.LocalPlayer:GetNetworkPing()`, `workspace:GetRealPhysicsFPS()`, camera/quality where readable
  (`UserSettings().GameSettings.SavedQualityLevel` in pcall), device class.
- server: player count, `workspace:GetRealPhysicsFPS()`.

## Snapshot (shared shape for overlay, wire, export, viewer)

```lua
{
  v = 1, side = "client" | "server", t = os.clock(), serverTime = workspace:GetServerTimeNow(),
  device = "Desktop", players = 12,
  frame = { last, avg1, p50, p95, p99, max10, fps, budget, scriptMs, history = { ...last 120 frame ms } },
  probes = { { name, selfAvg, selfP95, selfMax, totalAvg, calls }, ... } -- sorted by selfAvg desc, top 40
  counters = { { name, perSec }, ... }, gauges = { { name, value, min, max }, ... },
  net = { { lib, channel, dir, bps, pps, avg, peak }, ... },
  memory = { totalMb, luaHeapMb, tags = { [tag] = mb }, gcKb, gcKbPerSec },
  engine = { heartbeatMs, physicsMs, recvKbps, sendKbps, instances, ping, physicsFps },
  flares = { { t, frameMs, frame, top = { { name, ms }, ... } }, ... },  -- newest first
  misuse = n,
  frames = n,                             -- endFrame count
  netTop = { { who, bps }, ... },          -- top 5 by bytes out (when a key is passed to net)
}
```

Every record is a keyed table (`{ name = "Crowd.Step", selfAvg = 0.4, ... }`), never positional. All
durations are milliseconds (`frame.budget` too); `t` is `os.clock()` seconds. `frame.avg1`, `frame.fps`
(frames in that second) and `frame.scriptMs` cover the last completed second (before the first second
completes they fall back to the last frame); `p50/p95/p99/max10` cover 10 s; `frame.scriptP50` is the
10 s median of script ms; `history` is oldest first. Probe `selfAvg`, `totalAvg` and `calls` are per frame
over the last completed second; `selfP95` and `selfMax` cover 10 s. `memory` and `engine` are the tables
the Runtime passed to `Core.setEngine` (`{}` before that).

`Lighthouse.export()` returns JSON `{ lighthouse = 1, side, client = Snapshot?, server = Snapshot?, recording = {...}, reports = {...} }`.
`recording` = per-frame arrays (frame ms and each probe's self ms per frame, column layout:
`{ source = "ring" | "record", done, t0, probes = {names}, frames = { t = {...}, dt = {...}, script = {...}, self = { [i] = {...} } } }`,
`t` in seconds since `t0`, the others in ms, `self[i][f]` = 0 when probe i did not run in frame f) for the
viewer's timeline. It is the `Lighthouse.record(seconds)` capture (max 120 s) when one exists and
`export()` gets no `seconds`, else the last `seconds` of the frame ring (all of it when nil).

JSON rules (Core/Json): NaN and +-inf become `null`, an empty table becomes `[]`, keys are sorted.

## Wire (Runtime/Wire)

One `RemoteEvent` named `LighthouseR` under the Lighthouse module (created by the server). All payloads are
buffers with `u8 version, u8 tag`; strings are interned: a name table is sent once per viewer and on change,
then ids (u16). Tags: 1 server snapshot (to viewers, `stream` seconds), 2 name table, 3 client report
(client->server), 4 viewer hello (client asks to view; server replies with 1 or nothing), 5 viewer bye.
The server also sets the attributes `LighthouseTelemetryEvery` and `LighthouseTelemetrySample` on the
remote (absent when telemetry is off), so a client whose own `start()` has no `telemetry` follows the server's.

Server receive validation: type check `buffer`, max 2 KB, version, tag, lengths in range, numbers finite and
clamped, rate limit 1 report per `every/2` seconds per player and 4 hellos per minute. Anything bad is
dropped and counted (never throws).

## Player telemetry (Runtime/Telemetry)

Goal: what real players on mobile and console see, without a server of our own.

- When `telemetry` is on, each client is in the sample with probability `sample` (decided once per session).
- Every `every` seconds a sampled client sends a report: device class, frame p50/p95/p99, script ms p50,
  memory MB, Luau heap MB, ping, quality level, and its top 5 probes by self time.
- Server aggregates per device class (merge histograms, so percentiles stay real), exposes it in the
  server snapshot (`reports` section) and calls `onReport` callbacks.
- `analytics = true`: server calls `AnalyticsService:LogCustomEvent(player, "LH_FrameP50", p50ms, { device, place })`
  (low-cardinality custom fields only, rate limited per player) so numbers show up in the Creator Hub
  analytics with no extra infrastructure.
- `http = { url = "...", every = 300 }`: server POSTs the aggregate JSON (not per-player data) via HttpService.
  Off by default.

## Overlay

Plain Instances (ScreenGui, Frames, TextLabels; no Vide/Roact dependency), created on first open, destroyed
or hidden on close, updated at 4 Hz (never per frame). Tabs: **Frame** (frame-time bar graph, p50/p95/p99,
script vs frame, flares list), **Probes** (top self time, grouped by dot prefix, client | server toggle),
**Network** (channels by lib, in/out bytes/s), **Memory** (tags, Luau heap and garbage rate), **Players**
(server: telemetry by device class). Works with keyboard, mouse, touch and gamepad (tabs selectable with
the D-pad, LB/RB switch tab). Toggle: F8, or L3+R3 together on a gamepad, or `Lighthouse.overlay()`.
Only viewers (see `viewers`) can open it in live games; in Studio everyone can.

## Library hooks (Current, Ripple, Tide)

Lighthouse sets `shared.Lighthouse` to its public API at require time. A library reads it lazily **once per
frame** at the point it flushes (never per event):

```lua
local lh = shared.Lighthouse
if lh then
    lh.net("Current", eventName, "out", bytes)
end
```

Libraries keep their own per-channel counters only while `lh` is present (so they cost nothing without
Lighthouse), and wrap their per-frame work in probes named `"<Lib>.<Stage>"` (e.g. `Current.Flush`,
`Ripple.Encode`, `Tide.Relay`), created lazily from `lh.probe`. The hook API that libraries may rely on is
frozen: `probe(name)`, `net(lib, channel, dir, bytes, player?)`, `count(name, n?)`, `gauge(name, v)`.

## Internal contract between modules (v0.1)

`src/Core/init.luau` (module `Core`) is pure Luau with no Roblox services (testable anywhere). It exports:

```lua
Core.configure(opts)                  -- budget, frames, microprofiler (Core calls debug.profilebegin/end only if present),
                                      -- spawn (how onFlare listeners run; init passes task.spawn)
Core.setActive(on: boolean)           -- flips the single `active` upvalue the probes test
Core.isActive(): boolean
Core.probe(name): Probe               -- interned; Probe has :begin(), :finish(), .name, .id
Core.wrap(name, fn): fn
Core.count(name, n?)  Core.gauge(name, v)
Core.net(lib, channel, dir, bytes, who?)   -- who: any key (Player on server), optional
Core.endFrame(frameSeconds: number, now: number)  -- once per frame from Runtime; now = os.clock()
Core.setEngine(engineTable, memoryTable, extra)    -- Runtime/Sampler pushes 1 Hz engine + memory numbers + {device, players, serverTime}
Core.snapshot(side: string): Snapshot -- the shape in "Snapshot"; allocates (called <= 4 Hz)
Core.record(seconds)  Core.recording(seconds?): table?   -- column layout, see "Snapshot"
Core.flares(): {Flare}  Core.onFlare(fn): () -> ()       -- returns an unregister function
Core.histogram(): Histogram           -- log-bucket histogram object (see below)
Core.HIST_BUCKETS                     -- 134
Core.frameStats(window?) / Core.scriptStats(window?)    -- { avg, p50, p95, p99, max, n, frames, last }, window 1 | 10 | 60
Core.probeStats(name, window?)        -- { selfAvg, p50, p95, p99, max, totalAvg, calls, n, frames, last } or nil
Core.frameHistogram(window?, into?) / Core.scriptHistogram(window?, into?)  -- window as a Histogram (telemetry)
Core.counterRate(name)  Core.misuse()  Core.Json (encode / decode)
Core.reset()  Core.setClock(fn?)      -- tests
```

Histogram: fields `counts` (1-based, `HIST_BUCKETS` long), `total` (samples), `sum`, `max`, `min`; methods
`:add(ms, n?)`, `:merge(other)`, `:quantile(q)`, `:mean()`, `:clear()`, `:encode(): buffer` and
`:decode(b, offset?): (ok, nextOffset)`. Encoding: `u8 k, f32 sum, f32 max`, then k x `(u8 bucket, u32 count)`
for the non-empty buckets (9 + 5k bytes). decode validates everything, never throws, and leaves the
histogram unchanged on bad input.

`src/init.luau` (public API) = Core functions re-exported with off-state fast paths + Runtime start/stop +
`overlay`, `export`, `remote`, `bind`, `onReport`, and sets `shared.Lighthouse` (when not already set).
`Lighthouse.wrap` returns `fn` itself only after `start({ enabled = false })`; before `start()` it wraps
(module-load wraps must measure once started) and the wrapper costs one upvalue test while off.
`start()` merges opts, calls `Core.configure` + `Core.setActive(true)`, then `Runtime.start(Core, opts)`
(every call; Runtime must accept repeats); `stop()` calls `Core.setActive(false)` then `Runtime.stop()`.
The Runtime module is required on first use (start, overlay, onReport, remote); Runtime calls are
pcall'd and a failure is a warning, never an error in the game. Runtime modules receive Core
via `Runtime.start(Core, opts)`; Overlay via `Overlay.new(sourceFn)` where `sourceFn(side)` returns the latest
Snapshot for "client" or "server" (server one arrives over the wire) plus the telemetry aggregate.
