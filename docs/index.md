---
layout: home

hero:
  name: Lighthouse
  text: Where your milliseconds go
  tagline: Profiling and live telemetry for Roblox. Per-system CPU on client and server, frame time, network per channel, memory, and what real players' devices see. Real numbers instead of guesses.
  image:
    src: /family/lighthouse.svg
    alt: Lighthouse
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: Open the viewer
      link: /viewer
    - theme: alt
      text: GitHub
      link: https://github.com/Acidgorgon/Lighthouse

features:
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2"/><path d="M9 2h6"/></svg>
    title: One line per system
    details: Wrap a function or bind it to a signal and it shows up by name, with self time, total time, p95 and calls per frame. Names line up with the MicroProfiler.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v18h18"/><path d="M7 16v-3"/><path d="M11 16V8"/><path d="M15 16v-5"/><path d="M19 16V5"/></svg>
    title: Overlay and viewer
    details: An in-game panel for mouse, touch and controller (F7, or L3 + R3), and a web viewer for exports with a zoomable frame timeline.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/></svg>
    title: Real devices
    details: Sampled players report frame percentiles, memory and their slowest systems. The server merges them by device class, so you see what phones and consoles really get.
---

::: tip Made with Claude
Most of Lighthouse was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.
:::

## Install

Copy the `src` folder into `ReplicatedStorage` and name it `Lighthouse`. Start it on both sides, then
wrap the systems you want to see:

::: code-group

```lua [server.server.luau]
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

```lua [client.client.luau]
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)
Lighthouse.start()
```

```lua [Crowd.luau]
local RunService = game:GetService("RunService")
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)

-- one line per thing you want to measure
Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", stepCrowd)
```

:::

Press **F7** in Studio (or **L3 + R3** on a controller) to open the overlay.
[Getting started](/guide/getting-started) walks through it, [Probes](/guide/probes) explains what the
numbers mean, and [the viewer](/viewer) opens an export in your browser.
