# Getting started

Lighthouse measures where a Roblox game spends its time and bytes: CPU per system on the client and
the server, frame time, network per channel, memory, and what real players' devices see. This page
gets it running and shows your first numbers.

## Install

Lighthouse is one ModuleScript named `Lighthouse` with three folders of child modules. Both sides
require it, so it goes in `ReplicatedStorage`.

::: code-group

```text [Studio]
ReplicatedStorage
└─ Lighthouse        ← the src/ folder as a ModuleScript (init.luau)
   ├─ Core           (Clock, Probes, Frames, Stats, Counters, Net, Spikes, Snapshot, Json)
   ├─ Runtime        (Sampler, Wire, Server, Client, Telemetry, Device)
   └─ Overlay        (Overlay, Graph, Theme)
```

```json [default.project.json (Rojo)]
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Lighthouse": { "$path": "Packages/Lighthouse/src" }
    }
  }
}
```

:::

- **Name it `Lighthouse`.** Any name works for `require`, but the examples use `ReplicatedStorage.Lighthouse`.
- **No package manager yet.** Copy `src/` from the [repository](https://github.com/Acidgorgon/Lighthouse)
  (a git submodule works well with Rojo).
- **One remote.** `Lighthouse.start()` on the server creates a `RemoteEvent` named `LighthouseR` inside
  the module. It carries server numbers to viewers and telemetry reports from clients.

## Start it

Two lines on each side:

::: code-group

```lua [ServerScriptService/Lighthouse.server.luau]
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

```lua [StarterPlayerScripts/Lighthouse.client.luau]
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

:::

That already gives you frame time, frame percentiles, engine numbers (heartbeat, physics, network
kbps, instance count, ping) and memory by tag. Press **;** (semicolon) to see them.

Options go in the same call. All are optional; see [the API reference](/reference/api#options):

```lua
Lighthouse.start({
	budget = 1 / 60,                 -- frames slower than this are flares
	viewers = { group = 1234567, rank = 200 }, -- who may see server numbers in live games
	telemetry = true,                -- sampled players report what their device sees
})
```

## Measure your first system

A probe is a named stopwatch. The easiest way to use one is `bind`, which connects a function to a
signal and measures every call:

```lua
local RunService = game:GetService("RunService")
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)

Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", function(dt)
	stepCrowd(dt)
end)
```

Or wrap a function once and call the wrapped one:

```lua
local stepCrowd = Lighthouse.wrap("Crowd.Step", stepCrowd)
```

Open the overlay, go to **Probes**, and `Crowd.Step` is there with its time per frame. The
[Probes guide](/guide/probes) covers manual begin and finish, naming and nesting.

## Open the overlay

| Input | Action |
|---|---|
| **;** (semicolon) | toggle (keyboard) |
| hold **R3**, press **D-pad Left** | toggle (controller) |
| hold **R3**, press **LB / RB** | previous / next tab while open |
| `Lighthouse.overlay()` | toggle from code |

The same key works in Studio and in a live client, and never fires while you type. The controller
buttons reach the game untouched unless R3 is held. [Input the overlay takes](/guide/overlay#input-the-overlay-takes)
has the details and the options to change or turn off each one.

In Studio everyone can open it. In live games only [viewers](/guide/overlay#viewers) can: by default
the game's creator, or rank 255 in the owning group.

## Export a recording

`Lighthouse.export()` returns a JSON string with this side's snapshot and a per-frame recording. Open
it in the [viewer](/viewer) for a zoomable frame timeline:

```lua
-- in the Studio command bar while play testing (client or server)
print(require(game.ReplicatedStorage.Lighthouse).export(10))
```

Copy the output, then paste it into the viewer (or save it as a `.json` file and drop it there).

## Turn it off

`Lighthouse.stop()` goes back to the near-free off state. To ship Lighthouse in a live game with a
switch, start it with `enabled = false` and flip it later:

```lua
Lighthouse.start({ enabled = false })
-- later, for example from an admin command
Lighthouse.start({ enabled = true })
```

While off, every probe call is one check and a return. [What it costs](/guide/cost) has the numbers.
