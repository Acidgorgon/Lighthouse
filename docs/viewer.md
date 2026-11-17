---
title: Viewer
description: Open a Lighthouse export in the browser. Frame timeline, flares, probes, network and memory.
outline: false
aside: false
---

<script setup>
import LighthouseViewer from './.vitepress/components/LighthouseViewer.vue'
</script>

# Viewer

Open an export from `Lighthouse.export()` to see every frame on a zoomable timeline, the flares, a
probe table sorted by self time, network channels and memory. No game needed to try it:
**Load the sample** shows made-up data from a mobile client.

<ClientOnly>
  <LighthouseViewer />
</ClientOnly>

## Getting an export

In Studio, while play testing, run this in the command bar on the side you want (client or server):

```lua
print(require(game.ReplicatedStorage.Lighthouse).export(10)) -- the last 10 seconds
```

Copy the line from the Output window and paste it on this page. For a longer capture of a specific
moment, start a recording first:

```lua
local Lighthouse = require(game.ReplicatedStorage.Lighthouse)
Lighthouse.record(20)       -- capture the next 20 seconds (at most 120)
task.wait(21)
print(Lighthouse.export())  -- returns the capture
```

Long exports can be cut off in the Output window. If the viewer says the JSON is not valid, export
fewer seconds.

A client export also carries the server snapshot when the player is a [viewer](/guide/overlay#viewers),
and a server export carries the [player telemetry](/guide/telemetry) aggregate. The JSON format is
in the [API reference](/reference/api#lighthouse-export).
