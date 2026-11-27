# API

```lua
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)
```

The same module runs on both sides. Functions marked **server** or **client** do something only on
that side. Times in snapshots are milliseconds unless the name says otherwise. Before `start()`,
after `stop()` and with `enabled = false`, every measuring function tests one value and returns.

## Starting and stopping

### Lighthouse.start

```lua
Lighthouse.start(opts: Options?) -> boolean
```

Starts measuring, engine sampling, the viewer stream, the overlay toggle and telemetry. Call it
once on the server and once on each client. Calling it again merges the new options into the
previous ones and applies them. Returns `true` when Lighthouse is on, `false` when `enabled = false`.

### Options

| Option | Type | Default | Side | Meaning |
|---|---|---|---|---|
| `enabled` | boolean | `true` | both | `false` keeps everything in the off state (a live switch) |
| `budget` | number | `1/60` | both | frame budget in seconds; slower frames are [flares](#lighthouse-onflare) |
| `frames` | number | `600` | both | frames kept in the history ring |
| `microprofiler` | boolean | `RunService:IsStudio()` | both | also call `debug.profilebegin` / `profileend` with each probe's name |
| `viewers` | function or table | creator | server | who may see server numbers and open the overlay in live games: `function(player): boolean`, a list of user ids, or `{ group = id, rank = n }`. Everyone in Studio |
| `overlayKey` | `Enum.KeyCode` or `false` | `Semicolon` | client | keyboard toggle; ignored while a TextBox has focus. `false`: no key |
| `overlayGamepad` | `{ KeyCode, KeyCode }` or `false` | `{ ButtonR3, DPadLeft }` | client | controller toggle: hold the first, press the second. The second is bound through `ContextActionService` while the first is held, and sunk. `false`: no controller input at all |
| `overlayGamepadTabs` | boolean | `true` | client | hold `overlayGamepad[1]` and press LB / RB for the previous / next tab while the panel is open (sunk). `false`: off. A bare LB / RB never switches tabs |
| `overlayGamepadPriority` | number or `Enum.ContextActionPriority` | `3000` (`High`) | client | priority the combo and the tab buttons are bound at |
| `telemetry` | boolean or table | `false` | server | `true` or `{ sample = 0.1, every = 60, analytics = true, http = nil }`, see [telemetry](/guide/telemetry) |
| `stream` | number | `1` | server | seconds between server snapshots sent to viewers |

The default viewer is the game's creator, or for a group game, rank 255 in the owning group.
[Input the overlay takes](/guide/overlay#input-the-overlay-takes) explains the overlay options.

```lua
Lighthouse.start({
	budget = 1 / 60,
	viewers = { group = 1234567, rank = 200 },
	telemetry = { sample = 0.1, every = 60 },
})
```

### Lighthouse.stop

```lua
Lighthouse.stop()
```

Back to the near-free off state. Collected numbers are kept; `start()` continues from them.

### Lighthouse.isActive

```lua
Lighthouse.isActive() -> boolean
```

Whether Lighthouse is measuring.

## Measuring

### Lighthouse.probe

```lua
Lighthouse.probe(name: string) -> Probe
```

Returns the probe with this name, creating it on first use. The same name always returns the same
probe. Get it once, at module load. Dots group probes: `"Crowd.Step"` is under `Crowd`.

| Member | Meaning |
|---|---|
| `probe:begin()` | starts timing |
| `probe:finish()` | stops timing; adds total and self time to this frame |
| `probe.name` | the name |
| `probe.id` | a small integer id |

A `finish` for a probe that is not the innermost open one closes the inner ones too; a `finish`
without a `begin` is ignored. Both count as a misuse (`snapshot.misuse`) and never throw. Probes
nest up to 64 deep. See [Probes](/guide/probes).

### Lighthouse.wrap

```lua
Lighthouse.wrap(name: string, fn: (A...) -> R...) -> (A...) -> R...
```

Returns a function that runs `fn` inside the probe `name` and returns all of its results. Errors in
`fn` reach the caller as usual; the probe stack is repaired at the next frame. When Lighthouse was
started with `enabled = false`, returns `fn` itself.

### Lighthouse.bind

```lua
Lighthouse.bind(signal: RBXScriptSignal, name: string, fn: (...any) -> ()) -> RBXScriptConnection
```

`signal:Connect(Lighthouse.wrap(name, fn))`. Returns the connection.

### Lighthouse.count

```lua
Lighthouse.count(name: string, n: number?)
```

Adds `n` (default 1) to a counter. Counters are shown per second (over the last second).

### Lighthouse.gauge

```lua
Lighthouse.gauge(name: string, value: number)
```

Sets a gauge to its latest value. Snapshots show the value and its 10 s min and max.

## Network

### Lighthouse.net

```lua
Lighthouse.net(lib: string, channel: string, dir: "in" | "out", bytes: number, player: Player?)
```

Counts one packet of `bytes` on the channel `(lib, channel, dir)`. On the server, pass `player` to
also track the top 5 players by bytes out. Current, Ripple and Tide call this for you. See
[Network](/guide/network).

### Lighthouse.remote

```lua
Lighthouse.remote(remote: RemoteEvent) -> RemoteWrapper
```

Returns a wrapper with the same `FireServer`, `FireClient`, `FireAllClients`,
`OnServerEvent:Connect` and `OnClientEvent:Connect`, counting traffic under
`("Remote", remote.Name, dir)`. Buffers are measured exactly, other arguments are estimated.
`wrapper.Instance` is the remote. Without the Runtime it returns `remote` itself.

## Seeing the numbers

### Lighthouse.overlay

```lua
Lighthouse.overlay(on: boolean?)
```

**Client.** Shows (`true`), hides (`false`) or toggles (`nil`) the [overlay](/guide/overlay). In live
games it opens only for [viewers](/guide/overlay#viewers).

### Lighthouse.snapshot

```lua
Lighthouse.snapshot() -> Snapshot
```

A table with this side's numbers right now ([shape below](#snapshot)). On the server it includes the
telemetry aggregate as `reports`. It allocates; call it a few times per second at most.

### Lighthouse.export

```lua
Lighthouse.export(seconds: number?) -> string
```

A JSON string for the [viewer](/viewer):

```lua
{
	lighthouse = 1,
	side = "client" | "server",
	client = Snapshot?,   -- on the client
	server = Snapshot?,   -- on the server; on a viewer's client, the last one received
	recording = Recording?,
	reports = Telemetry?, -- the telemetry aggregate, when there is one
}
```

`recording` is the capture from [`Lighthouse.record`](#lighthouse-record) when there is one and
`seconds` is nil. Otherwise it is the last `seconds` of the frame history (all of it when nil).

### Lighthouse.record

```lua
Lighthouse.record(seconds: number)
```

Starts a detailed capture of every frame for `seconds` (at most 120). `Lighthouse.export()` returns
it once it is done (or so far, while it runs). It allocates while recording.

### Lighthouse.onFlare

```lua
Lighthouse.onFlare(fn: (flare: Flare) -> ()) -> () -> ()
```

Calls `fn` when a frame is slower than `budget` and slower than 1.5 times the 10 s median. At most 2
calls per second. Returns a function that removes the callback.

```lua
type Flare = { t: number, frameMs: number, frame: number, top: { { name: string, ms: number } } }
```

`t` is `os.clock()` seconds, `frame` the frame number, `top` the up to 5 probes with the most self
time in that frame.

### Lighthouse.flares

```lua
Lighthouse.flares() -> { Flare }
```

The last 32 flares, newest first.

### Lighthouse.onReport

```lua
Lighthouse.onReport(fn: (report: Report) -> ())
```

**Server.** Calls `fn` with each validated client [telemetry](/guide/telemetry) report:
`device`, `frameP50`, `frameP95`, `frameP99`, `scriptP50`, `memoryMb`, `heapMb`, `pingMs`, `quality`,
`frames`, `probes` (`{ { name, ms } }`) and `player`. Errors in `fn` are caught and printed.

## Other members

| Member | Meaning |
|---|---|
| `Lighthouse.version` | `"0.2.0"` ([changelog](/changelog)) |
| `Lighthouse.isServer` | `true` on the server |
| `Lighthouse.histogram()` | a new log-bucket histogram object (`:add(ms)`, `:merge(other)`, `:quantile(q)`) |
| `Lighthouse.Core` | the pure Luau core, for tests and tools |
| `shared.Lighthouse` | set to the API when Lighthouse is first required, for [library hooks](/guide/network#current-ripple-and-tide) |

The hook API that libraries may rely on is frozen: `probe(name)`,
`net(lib, channel, dir, bytes, player?)`, `count(name, n?)` and `gauge(name, v)`.

## Snapshot

```lua
{
	v = 1,
	side = "client" | "server",
	t = number,          -- os.clock() seconds on that side
	serverTime = number, -- workspace:GetServerTimeNow()
	device = "Desktop" | "Mobile" | "Tablet" | "Console" | "VR", -- client
	players = number,    -- server
	frame = {
		last, avg1, p50, p95, p99, max10, -- ms; percentiles over 10 s
		fps, budget,                     -- budget in ms
		scriptMs,                        -- top-level probe time per frame (1 s average)
		history = { number },            -- last 120 frame times, oldest first
	},
	probes = { { name, selfAvg, selfP95, selfMax, totalAvg, calls } }, -- top 40 by selfAvg
	counters = { { name, perSec } },
	gauges = { { name, value, min, max } },
	net = { { lib, channel, dir, bps, pps, avg, peak } }, -- bytes/s, packets/s, bytes, bytes/s
	memory = { totalMb, luaHeapMb, tags = { [tag]: mb }, gcKb, gcKbPerSec },
	engine = { heartbeatMs, physicsMs, recvKbps, sendKbps, instances, ping, physicsFps },
	flares = { Flare },  -- newest first
	misuse = number,
	reports = Telemetry?, -- server
}
```

## Recording

The per-frame capture in exports, in columns:

```lua
{
	source = "ring" | "record",
	done = boolean,
	t0 = number,              -- os.clock() of the first frame
	probes = { string },      -- probe names, one column each
	frames = {
		t = { number },       -- seconds since t0
		dt = { number },      -- frame ms
		script = { number },  -- script ms
		self = { { number } },-- self[p][f]: ms of probes[p] in frame f
	},
}
```
