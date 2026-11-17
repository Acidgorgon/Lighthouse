# Player telemetry

Studio runs on your machine. Your players run on phones, old laptops and consoles. Player telemetry
answers "what do real devices see?" without a server of your own.

## Turn it on

On the server:

```lua
Lighthouse.start({ telemetry = true })
```

Or with settings:

```lua
Lighthouse.start({
	telemetry = {
		sample = 0.1,     -- share of clients that report (decided once per session)
		every = 60,       -- seconds between reports from a sampled client (5 to 3600)
		analytics = true, -- log custom events to AnalyticsService
		http = nil,       -- { url = "https://...", every = 300 } to POST the aggregate
	},
})
```

The client side needs nothing more than `Lighthouse.start()`.

## What a report contains

Every `every` seconds, a sampled client sends one small report (a buffer, at most 2 KB):

- device class: `Desktop`, `Mobile`, `Tablet`, `Console` or `VR`
- frame time histogram, and from it p50, p95 and p99
- script time p50
- total memory and Luau heap (MB)
- ping (ms) and graphics quality level
- its top 5 probes by self time

No user ids, names, chat or positions are in a report.

## The aggregate

The server merges reports **per device class**. Frame and script percentiles come from merged
histograms, not averaged percentiles, so the p95 for `Mobile` is the real p95 of every mobile frame
reported. Memory, ping and quality are averages.

Read it in the overlay's **Players** tab, in `Lighthouse.snapshot().reports` on the server, or in
`Lighthouse.export()`:

```lua
{
	t = 1234.5,      -- server time
	reports = 42,    -- reports received
	players = 11,    -- players who reported
	dropped = 0,     -- bad or too frequent reports dropped
	devices = {      -- sorted by players
		{
			device = "Mobile", players = 6, reports = 24,
			frameP50 = 31.0, frameP95 = 58.4, frameP99 = 81.0, scriptP50 = 9.5,
			memoryMb = 1300, heapMb = 240, pingMs = 120, quality = 3,
			probes = { { name = "Crowd.Step", ms = 4.1 }, ... },
		},
		...
	},
}
```

For each report, `Lighthouse.onReport` gives you the validated report on the server. It has the fields
listed above (one device, not merged) plus `report.player`, the sender, which stays on the server:

```lua
Lighthouse.onReport(function(report)
	if report.device == "Mobile" and report.frameP95 > 50 then
		-- log it, lower your effects budget for that player, ...
	end
end)
```

## AnalyticsService

With `analytics = true` (the default when telemetry is on), the server logs two custom events per
report with `AnalyticsService:LogCustomEvent`:

| Event | Value | Custom fields |
|---|---|---|
| `LH_FrameP50` | frame p50 in ms | device class, place id |
| `LH_FrameP95` | frame p95 in ms | device class, place id |

They show up in the Creator Hub analytics for your experience, split by device, with no extra
infrastructure. Events are rate limited: at most one batch per player per minute and 60 events per
minute per server.

## HTTP export

`http = { url = "...", every = 300 }` makes the server POST the aggregate JSON (not per-player data)
to your URL every `every` seconds (30 s at least). It needs **HTTP Requests** enabled in Game
Settings. It is off by default.

## Privacy

- **Aggregates only leave the server.** Reports are merged per device class. Analytics events carry
  numbers and the device class; the HTTP export carries the per-device aggregate.
- **Nothing that identifies a player** (user id, name, chat, position) is in a report, an analytics
  field or the export. `LogCustomEvent` takes the player as an argument, as Roblox requires, and
  the dashboards show totals.
- **Sampled.** By default 1 in 10 sessions reports, once a minute.
- **Checked.** The server validates every report (type, size, version, ranges, finite numbers) and
  rate limits each player. Bad reports are dropped and counted, never thrown.

If your experience has its own privacy policy, mention that anonymous performance data is collected.
