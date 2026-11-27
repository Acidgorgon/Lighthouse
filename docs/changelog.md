# Changelog

Lighthouse is vendored: a game copies `src/`. Each entry says what changes for a game that updates.
The version is `Lighthouse.version`.

## 0.2.0

Overlay input. The panel is meant to stay open while the game is played, also on a controller, and
three things got in the way: the default key could not be used in Studio, the controller combo let
the game's own actions on those buttons fire, and LB / RB switched tabs on every press.

### Defaults that changed

A game that relied on the defaults gets the new ones. A game that passes its own `overlayKey` or
`overlayGamepad` keeps them and needs no change.

| | 0.1.1 | 0.2.0 |
|---|---|---|
| Keyboard toggle (`overlayKey`) | F8 | **;** (`Enum.KeyCode.Semicolon`) |
| Controller toggle (`overlayGamepad`) | L3 + R3 together | hold **R3**, press **D-pad Left** |
| Previous / next tab on a controller | LB / RB whenever the panel is open | hold **R3**, press **LB / RB** |

- **`;` instead of F8.** F8 is Studio's Run key (and F7, the first default, is Studio's Start), so
  neither could open the panel in Studio. Studio and the client take most function keys between
  them; neither binds `;`. See [the keyboard key](/guide/overlay#the-keyboard-key).
- **R3 + D-pad Left instead of L3 + R3.** One button for each thumb, and R3 is rarely held during
  play. See [the controller combo](/guide/overlay#the-controller-combo).
- To keep the 0.1.1 inputs, pass them:
  `overlayKey = Enum.KeyCode.F8, overlayGamepad = { Enum.KeyCode.ButtonL3, Enum.KeyCode.ButtonR3 }`.
  Tab switching on a bare LB / RB is gone for good.

### Fixed

- **The controller combo no longer fires the game's actions.** It was read from
  `UserInputService.InputBegan`, which cannot sink input. Now the second button is bound through
  `ContextActionService` while the first is held, and its press and release are sunk. The bind is
  released with the first button, on gamepad disconnect, on focus loss and on `stop()`. The first
  button's own press still reaches the game.
- **LB / RB no longer switch tabs during play.** The panel listens to no button itself. LB and RB
  step the tab only while the combo's first button is held and the panel is open, and are sunk
  then. A bare LB / RB always goes to the game.
- **No toggle while typing.** The keyboard key ignored processed presses already; it now also
  ignores any press while a TextBox has focus, and so do the combo and the tab buttons.
- **Nothing is taken from players who cannot open the overlay.** In a live game the combo binds and
  sinks only for viewers.
- **Controller selection is not trapped in the panel.** The panel stopped the D-pad at its edges,
  so a selection that moved onto it from the game's menu could not leave. It can now.
- **No console warnings about memory tracking on live clients.** The memory calls run only while
  `Stats.MemoryTrackingEnabled` is true (this fix came after 0.1.1 without a version of its own).

### Added

- `overlayGamepadTabs` (default `true`): `false` turns the controller tab buttons off.
- `overlayGamepadPriority` (default `3000`, `Enum.ContextActionPriority.High`): the priority the
  combo and the tab buttons are bound at. Raise it above a game action that should lose to the
  combo.
- `overlayGamepad = false` now turns off every controller input of the overlay, tabs included.

### Updating a game

- Delete game-side workarounds for the three defects: code that passed `overlayGamepad = false` and
  listened for the chord itself, a guard wrapped around `Overlay.setTab`, a different key for
  Studio. Pass the buttons you want as `overlayKey` and `overlayGamepad` instead.
- `Overlay.new` takes a second argument and the panel no longer connects to
  `UserInputService.InputBegan`. Both are internal; they matter only to code that patched the
  overlay module.

## 0.1.1

- `overlayKey` defaults to F8 instead of F7. Roblox marks F7 as processed, and the toggle ignores
  processed input, so the F7 default never opened the panel.

## 0.1.0

- First version: probes, frame statistics, counters and gauges, network channels, flares, engine
  sampling, the viewer stream, player telemetry, the overlay and the export viewer.
