# Overlay

The overlay is an in-game panel with Lighthouse's live numbers. It is built from plain Instances
(no UI library), refreshes four times per second, and creates nothing after it is first opened.

## Open and close

| Input | Action |
|---|---|
| **;** (semicolon) | toggle (keyboard; change it with `overlayKey`) |
| hold **R3**, press **D-pad Left** | toggle (controller; change it with `overlayGamepad`) |
| **x** button | close |
| `Lighthouse.overlay(true \| false \| nil)` | show, hide or toggle from code |

```lua
Lighthouse.start({
	overlayKey = Enum.KeyCode.Semicolon,                               -- the default; or false for no key
	overlayGamepad = { Enum.KeyCode.ButtonR3, Enum.KeyCode.DPadLeft }, -- hold, press; or false for no controller input
	overlayGamepadTabs = true,                                         -- hold R3 + LB / RB switch tabs; or false
	overlayGamepadPriority = Enum.ContextActionPriority.High.Value,    -- 3000: where the combo binds
})
```

The panel is built the first time it opens and only hidden when it closes. While it is closed it
costs nothing.

## Input the overlay takes

The panel is meant to stay open while the game is played, so it takes as little input as it can:

| Input | Taken from the game |
|---|---|
| Keyboard | only the toggle key, and never while a TextBox has focus |
| Controller | only while the combo's first button is held: the second button, and LB / RB while the panel is open |
| Mouse and touch | clicks, touches and the scroll wheel on the panel itself; use **move** when it covers your UI |

Everything else reaches the game as if Lighthouse were not there. A bare LB or RB never switches
tabs.

### The keyboard key

The default is **;** because the function keys are taken on one side or the other:

| Key | Taken by |
|---|---|
| F5, F7, F8 | Studio: Play, Start and Run. Studio acts on them during a play test, and F7 arrives marked as processed, so a toggle on it never fired |
| F9, F11, F12 | the developer console, full screen and video recording |
| `/`, backtick, `.`, backslash, Tab, Esc | chat, the backpack, the emotes menu, UI selection, the player list, the menu |

Neither Studio nor the Roblox client binds `;`, so one default works in both. A key press that the
engine marks as processed is ignored, and so is any press while a TextBox has focus: typing `;`
into chat or a search field never opens the panel.

Pass your own key if your game or an admin script uses `;`, or if `;` is not a key of its own on
your keyboard layout:

```lua
Lighthouse.start({ overlayKey = Enum.KeyCode.L })
```

### The controller combo

`overlayGamepad = { hold, press }`: hold the first button, press the second. The default is
**R3 + D-pad Left**: one button for each thumb, and R3 is rarely held, so play does not hit it by
accident. (Pressing them the other way round works too.)

- **The second button is sunk.** While the first button is held, Lighthouse binds the second
  through `ContextActionService` at `overlayGamepadPriority` and sinks its press and its release,
  so the action your game has on that button does not fire. `UserInputService.InputBegan` still
  reports the press, with `gameProcessedEvent = true`. The bind is gone as soon as the first button
  is released, and also when the gamepad disconnects, the window loses focus or `Lighthouse.stop()`
  runs.
- **The first button is not.** Its press reaches the game: when it goes down nobody can know that a
  combo follows. Choose a first button whose press alone is harmless in your game. With Roblox's
  default camera, R3 also steps the camera zoom.
- **Priority.** The default is `Enum.ContextActionPriority.High.Value` (3000), above
  `BindAction` (2000). If your game binds the second button higher than that, the combo still
  toggles but cannot sink the press; raise `overlayGamepadPriority` above your own. The same
  applies when the engine takes the press first, for example the D-pad for UI navigation while a
  GuiObject is selected.
- **Only for players who can open the overlay.** For everyone else in a live game nothing is bound
  and nothing is sunk. A viewer's very first press in a session is not sunk either: the server has
  not answered yet.
- **Off.** `overlayGamepad = false` turns all controller input off: no combo, no tab buttons.

A game that already passes its own two buttons keeps them:

```lua
Lighthouse.start({ overlayGamepad = { Enum.KeyCode.ButtonL3, Enum.KeyCode.ButtonR3 } })
```

### Tabs on a controller

Hold the combo's first button and press **LB** or **RB** (R3 + LB / R3 + RB by default) for the
previous or next tab. The two are bound and sunk exactly like the combo, only while the panel is
open, so the game does not see them; the tab bar shows the hint. A shoulder button that is already
down when you press R3 stays with the game for that hold.

`overlayGamepadTabs = false` turns the tab buttons off. They are also off when the combo itself
uses LB or RB. Tabs stay reachable with the D-pad (see below), the mouse and touch.

## Tabs

| Tab | Shows |
|---|---|
| **Frame** | last, p50, p95 and p99 frame time, fps, script time against frame time, a graph of the last 120 frames, and the newest flares with their slowest probes |
| **Probes** | probes by self time, grouped by dot prefix (self ms, p95, total, calls per frame), then counters and gauges |
| **Network** | channels grouped by library: bytes per second, packets per second, average packet size, 10 s peak; engine receive and send rates and ping |
| **Memory** | total memory, Luau heap, garbage rate (KB/s), instance count, and memory by tag (total and tags only where `Stats.MemoryTrackingEnabled` is on, usually Studio; elsewhere the heap comes from `gcinfo()`) |
| **Players** | [player telemetry](/guide/telemetry) by device class: players, frame p50/p95/p99, script p50, memory, ping, top probes |

Frame graph colours: **green** within budget, **amber** up to twice the budget, **red** beyond. The
white line is the budget.

The **client / server** button in the header switches the Frame, Probes, Network and Memory tabs
between this client's numbers and the server's.

## Controllers, touch and mouse

Every control works with each input:

- **Controller.** Hold R3 and press LB or RB to switch tabs without taking focus from the game
  ([Tabs on a controller](#tabs-on-a-controller)). To use the buttons, enter UI navigation (the
  Select or View button on most controllers), move with the D-pad and press A. The D-pad prefers
  the panel's own controls while the selection is inside it, and can always leave it again for
  your game's UI. Select a list and use the right stick to scroll it. Closing the panel clears a
  selection that was inside it.
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
