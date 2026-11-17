# Network

Lighthouse counts network traffic per **channel**. A channel is a library, a channel name and a
direction: `("Ripple", "Inventory", "out")`. For each one you get bytes per second, packets per
second, the average packet size and the 10 s peak.

The overlay groups channels by library in the **Network** tab. Engine totals (the `Stats` service's
receive and send kbps, which include replication and physics) are on the same tab, so you can see
how much of the total your channels explain.

## Your own traffic: Lighthouse.net

Call `Lighthouse.net` where you send or receive:

```lua
Lighthouse.net("Game", "Shop", "out", buffer.len(payload))
shopRemote:FireServer(payload)
```

```lua
Lighthouse.net(lib, channel, dir, bytes, player?)
```

- `lib` groups channels in the overlay. Use your game's name, or a system name.
- `channel` is usually the remote or message name. Keep the set of names fixed (no ids).
- `dir` is `"in"` or `"out"`.
- `bytes` is the payload size. Each call counts as one packet.
- `player` (server, optional): the receiving or sending player. The server also tracks the top 5
  players by bytes out, which shows who costs the most bandwidth.

Like probes, `net` is one check and a return while Lighthouse is off.

## Your own remotes: Lighthouse.remote

`Lighthouse.remote` wraps a `RemoteEvent` so you don't have to count by hand. The wrapper has the
same methods, and counts every call under the library `"Remote"` and the remote's name:

```lua
local Shop = Lighthouse.remote(ReplicatedStorage.Remotes.Shop)

-- server
Shop.OnServerEvent:Connect(function(player, itemId, amount)
	-- ...
end)
Shop:FireClient(player, "bought", itemId)
Shop:FireAllClients("restock")

-- client
Shop:FireServer(itemId, 1)
Shop.OnClientEvent:Connect(function(kind, ...) end)
```

Sizes are **exact for buffers** and **estimates for everything else** (strings by length, numbers
9 B, Vector3 13 B, CFrame 25 B, Instances 5 B, tables by their contents). Roblox's real encoding
differs a bit, so use the numbers to compare channels, not to the byte. `FireAllClients` counts one
packet per player.

The original remote is at `wrapper.Instance`. Without the Runtime (for example in a pure Luau test)
`Lighthouse.remote` returns the remote itself.

## Current, Ripple and Tide

The Harbor libraries report their own traffic and work when Lighthouse is present. There is nothing
to set up: require Lighthouse and start it, and their channels appear.

| Library | Channels (`lib`, `channel`) | Probes |
|---|---|---|
| [Current](https://acidgorgon.github.io/Current/) | `"Current"`, one channel per event | `Current.Flush` and other `Current.*` stages |
| [Ripple](https://acidgorgon.github.io/Ripple/) | `"Ripple"`, one channel per state; `"Skipped"` on the client for states it does not hold | server: `Ripple.Encode`, `Ripple.Send`; client: `Ripple.Apply`, `Ripple.Events` |
| [Tide](https://acidgorgon.github.io/Tide/) | `"Tide"`: `Relay`, `Upload`, `Control` | `Tide.Sample`, `Tide.Relay`, `Tide.Receive`, `Tide.Upload`, `Tide.Render` |

How it works: Lighthouse sets `shared.Lighthouse` when it is required. Each library reads it once per
frame at the point where it flushes, never per event:

```lua
local lh = shared.Lighthouse
if lh then
	lh.net("Current", eventName, "out", bytes)
end
```

The libraries keep per-channel counters only while `shared.Lighthouse` is set, so without Lighthouse
they cost nothing. The part of the API they rely on is frozen: `probe(name)`,
`net(lib, channel, dir, bytes, player?)`, `count(name, n?)` and `gauge(name, v)`. Your own libraries
can use the same pattern.

## Reading the numbers

- **Per channel bytes per second** is a 1 s rate; **peak** is the highest 1 s rate in the last 10 s.
- **Average size** is bytes divided by packets. Many small packets cost more than their bytes: each
  remote call has a header of its own. If a channel sends hundreds of 20 B packets per second, batch
  them.
- **Engine recv/send** includes everything Roblox sends: property replication, physics and every
  remote, measured or not. A big gap between it and your channels means replication (parts and
  properties changing on the server) is doing the work.
