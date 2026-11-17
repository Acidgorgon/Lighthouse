# Overlay

The overlay is an in-game panel with Lighthouse's live numbers. It is built from plain Instances
(no UI library), refreshes four times per second, and creates nothing after it is first opened.

## Open and close

| Input | Action |
|---|---|
| **F7** | toggle (keyboard; change it with `overlayKey`) |
| **L3 + R3** | toggle: press both thumbsticks together (change it with `overlayGamepad`) |
| **x** button | close |
| `Lighthouse.overlay(true \| false \| nil)` | show, hide or toggle from code |

```lua
Lighthouse.start({
	overlayKey = Enum.KeyCode.F8,                                     -- or false for no key
	overlayGamepad = { Enum.KeyCode.ButtonL3, Enum.KeyCode.ButtonR3 }, -- or false
})
```

The panel is built the first time it opens and only hidden when it closes. While it is closed it
costs nothing.

## Tabs

| Tab | Shows |
|---|---|
| **Frame** | last, p50, p95 and p99 frame time, fps, script time against frame time, a graph of the last 120 frames, and the newest flares with their slowest probes |
| **Probes** | probes by self time, grouped by dot prefix (self ms, p95, total, calls per frame), then counters and gauges |
| **Network** | channels grouped by library: bytes per second, packets per second, average packet size, 10 s peak; engine receive and send rates and ping |
| **Memory** | total memory, Luau heap, garbage rate (KB/s), instance count, and memory by tag |
| **Players** | [player telemetry](/guide/telemetry) by device class: players, frame p50/p95/p99, script p50, memory, ping, top probes |

Frame graph colours: **green** within budget, **amber** up to twice the budget, **red** beyond. The
white line is the budget.

The **client / server** button in the header switches the Frame, Probes, Network and Memory tabs
between this client's numbers and the server's.

## Controllers, touch and mouse

Every control works with each input:

- **Controller.** LB and RB switch tabs at any time while the panel is open, without taking focus
  from the game. To use the buttons, enter UI navigation (the Select or View button on most
  controllers), move with the D-pad and press A. Selection stays inside the panel while you
  navigate. Select a list and use the right stick to scroll it. Closing the panel gives focus back
  to the game.
- **Touch.** Tabs and buttons are bigger on touch screens. Lists scroll with a swipe.
- **Mouse.** Click a tab or button, scroll lists with the wheel.

The **move** button puts the panel in the next screen corner, for when it covers your own UI.

## Size on phones and TVs

The panel is laid out at 460 by 330 and scaled to the screen:

| Device | Scale |
|---|---|
| Desktop | 1 (1.25 on very tall screens) |
| Phone or tablet | fitted to the screen, never below 0.72 |
| Console or TV (10-foot UI) | up to 1.5, readable from a couch |

Text sizes are fixed (never `TextScaled`), so text never shrinks below about 9 px on a phone and
numbers in monospace (Roboto Mono) do not jump around between refreshes.

## Viewers

Client numbers are always available on the client. Server numbers are only sent to **viewers**:

- In Studio, everyone is a viewer.
- In live games, by default only the game's creator is a viewer (for a group game: rank 255 in the
  owning group).
- Non-viewers cannot open the overlay at all in live games.

Choose your own on the server:

::: code-group

```lua [user ids]
Lighthouse.start({ viewers = { 12345678, 87654321 } })
```

```lua [group rank]
Lighthouse.start({ viewers = { group = 1234567, rank = 200 } }) -- rank 200 and above
```

```lua [function]
Lighthouse.start({
	viewers = function(player)
		return player:GetAttribute("Admin") == true
	end,
})
```

:::

A viewer's client asks the server once when it opens the panel. The server checks the rule and,
if the player is allowed, sends a server snapshot every `stream` seconds (default 1) until the
viewer closes the panel or leaves. Non-viewers never receive server numbers.

::: warning
The server stream contains probe names and player counts. Only list people you trust as viewers.
:::
