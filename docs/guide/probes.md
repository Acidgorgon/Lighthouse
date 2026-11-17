# Probes

A probe is a named stopwatch for one piece of code. Lighthouse adds up every probe's time per frame,
keeps a rolling history, and shows it in the overlay, the snapshot and exports.

## Three ways to measure

### bind: a signal handler

```lua
Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", function(dt)
	stepCrowd(dt)
end)
```

`bind` is `signal:Connect(Lighthouse.wrap(name, fn))`. It returns the connection, so you can
`:Disconnect()` it as usual.

### wrap: any function

```lua
local Crowd = {}

function Crowd.step(dt)
	-- ...
end
Crowd.step = Lighthouse.wrap("Crowd.Step", Crowd.step)

return Crowd
```

The wrapped function passes every argument through and returns every result. Wrap once, at module
load, and call the wrapped function; don't wrap inside a loop.

If `fn` errors, the error goes to the caller as usual. Lighthouse does not use `pcall` per call: it
repairs its probe stack at the next frame boundary instead, so an error never leaves a probe open.

### begin and finish: part of a function

```lua
local pathProbe = Lighthouse.probe("Crowd.Path") -- once, at module load

local function updateNpc(npc)
	pathProbe:begin()
	local path = computePath(npc)
	pathProbe:finish()
	moveAlong(npc, path)
end
```

Get the probe once and keep it in a local. The same name always returns the same probe, so two
modules that ask for `"Crowd.Path"` share it.

Calling `finish` on a probe that is not the innermost open one closes the inner ones at the same
time and counts a **misuse**. A `finish` without a `begin` is ignored and counted too. The overlay
shows the count under Probes. Nothing ever throws.

## Naming

Use dots to group: `"Crowd.Step"`, `"Crowd.Path"` and `"Crowd.Animate"` show up under a `Crowd`
group with its total, in both the overlay and the viewer. One level of dots is enough for grouping;
more dots are kept in the name.

- Name systems, not functions: `"Inventory.Save"`, not `"saveInventoryToDataStoreAsync"`.
- Keep the set of names fixed. Don't put ids, player names or counters in a name: every distinct
  name is a new probe that lives until the server shuts down.
- Libraries in the Harbor family use `"<Lib>.<Stage>"`, for example `Current.Flush`, `Ripple.Encode`
  and `Tide.Relay`. Avoid those prefixes for your own probes.

With `microprofiler = true` (the default in Studio), every probe also calls
`debug.profilebegin(name)` and `debug.profileend()`, so the same names show up in the MicroProfiler
(Ctrl+F6).

## Nesting: self time and total time

Probes nest. A probe that runs inside another one is its **child**:

```lua
local step = Lighthouse.probe("Crowd.Step")
local path = Lighthouse.probe("Crowd.Path")

step:begin()          -- Crowd.Step  ┐
moveEveryone()        --             │ 1.0 ms
path:begin()          --   Crowd.Path ┐
computePaths()        --              │ 3.0 ms
path:finish()         --              ┘
animate()             --             │ 0.5 ms
step:finish()         --             ┘
```

| Probe | total | self |
|---|---:|---:|
| `Crowd.Step` | 4.5 ms | 1.5 ms |
| `Crowd.Path` | 3.0 ms | 3.0 ms |

- **Total time** is from `begin` to `finish`.
- **Self time** is total time minus the time spent in child probes. It is the time that belongs to
  this probe alone, so self times add up without counting anything twice.

Lists are sorted by **self time**: that is where to look first. A probe with a large total and a
small self time is just a parent of slow children.

**Script time** in the overlay is the sum of the top-level probes' total time per frame (probes
with no parent). Compare it with the frame time: the difference is everything you have not measured
yet (other scripts, physics, rendering, the engine). See the [recipe](/guide/fm-recipes).

## Don't yield inside a probe

A `begin`/`finish` pair has to finish inside the same callback. If the code between them yields
(`task.wait`, a DataStore call, `WaitForChild`, a yielding `OnServerEvent` handler you wrapped),
the probe stays open until the end of the frame. Lighthouse then closes it, drops that time and
counts a misuse (shown as `misuse` in the snapshot). It never throws, but the numbers for that
frame are wrong. Measure the work before and after the yield with two probes instead.

## What is recorded

For each probe, per frame: self time, total time and the number of calls. From those, over 1 s,
10 s and 60 s windows: average, p50, p95, p99 and max. Percentiles come from a log-scale histogram
(about 12% wide buckets), so they cost nothing to keep and never need a sort.

The snapshot lists the top 40 probes by self time:

```lua
{ name = "Crowd.Path", selfAvg = 3.0, selfP95 = 4.1, selfMax = 9.8, totalAvg = 3.0, calls = 1 }
```

## Counters and gauges

Two more one-liners for numbers that are not time:

```lua
Lighthouse.count("Pathfinds")        -- +1, shown per second
Lighthouse.count("Bullets", #fired)  -- +n
Lighthouse.gauge("Npcs", #npcs)      -- last value, with the 10 s min and max
```

They show at the bottom of the Probes tab.

## Flares

A frame slower than `budget` (and slower than 1.5 times the 10 s median) is a **flare**. Lighthouse
keeps the last 32 with the five probes that took the most self time in that frame. They are in the
Frame tab of the overlay and in exports.

```lua
Lighthouse.onFlare(function(flare)
	print(string.format("%.1f ms frame, worst: %s", flare.frameMs, flare.top[1] and flare.top[1].name or "?"))
end)
```

`onFlare` callbacks run at most twice per second.

## Off means off

Before `Lighthouse.start()`, after `Lighthouse.stop()`, and with `enabled = false`, `begin` and
`finish` test one value and return. You can leave probes in shipping code.

With `enabled = false` at the time of the call, `wrap` and `bind` return the original function, with
no wrapper at all. Functions wrapped that way stay unmeasured if you enable Lighthouse later; wrap
again after enabling, or use `begin` and `finish` for code you want to switch on in a live server.
