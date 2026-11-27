# Recipe: a slow client frame

A worked example: a game whose client frame takes 60 ms (16 fps) on a mid-range phone, when the
budget is 16.7 ms. Where do the 60 ms go? Follow these steps in order; each one narrows it down.

## 1. Measure the frame as it is

Start Lighthouse on both sides with no probes yet, play on the device, and open the overlay
(hold R3 and press D-pad Left on a controller, `;` on a keyboard). On the **Frame** tab note:

- **p50, p95, p99.** A high p50 means every frame is slow (steady work). A fine p50 with a bad p99
  means spikes: look at the flares instead.
- **Script vs frame.** With no probes, script time is 0 and all 60 ms are "unmeasured". That is
  the starting point.

Do this on the slow device, not in Studio. A desktop hides most of the problem.

## 2. Wrap the big systems

Put one probe around each big client system: one line each, at the place where it runs every frame.

```lua
-- each in its own module, once
Lighthouse.bind(RunService.RenderStepped, "Camera.Update", updateCamera)
Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", stepCrowd)
Lighthouse.bind(RunService.Heartbeat, "Vfx.Step", stepEffects)
Ui.update = Lighthouse.wrap("Ui.Update", Ui.update)
Weapons.update = Lighthouse.wrap("Weapons.Update", Weapons.update)
```

Name them by system with a dot prefix so related probes group together. Five to ten probes are
enough for a first pass.

## 3. Compare script ms with frame ms

Back on the Frame tab, read the script line: `script 21.0 ms of 60.0 ms frame (35%)`.

| What you see | What it means | Next |
|---|---|---|
| Script close to frame (say 50 of 60 ms) | your Luau is the cost | step 4: find the system |
| Script small (say 10 of 60 ms), unmeasured large | the engine is the cost: rendering, physics, animation, or Luau you have not wrapped yet | step 5 |
| In between | both | do step 4, then step 5 |

If you are not sure the probes cover all your scripts, wrap more systems until adding one no
longer moves the script number much.

## 4. Find the system (script time)

Open the **Probes** tab. It is sorted by **self time**, the time that belongs to each probe alone.

- The top line is your first target. Wrap its parts in child probes (`Crowd.Path`, `Crowd.Animate`)
  to see which part is slow. Self and total time are explained in [Probes](/guide/probes#nesting-self-time-and-total-time).
- Look at **calls**: a system called 30 times per frame when you expected once is a bug, not a
  slow system (a signal connected many times, a loop over all players per player).
- Look at **p95** next to the average. A large gap means the system is spiky: it does work in bursts
  (pathfinding every N frames, a big table rebuild on an event).

## 5. Check the garbage rate

Open the **Memory** tab and read **garbage KB/s**: how fast the Luau heap grows between collections.

- Under about 500 KB/s is normal.
- Several MB per second means the garbage collector runs often, and its time shows up as slow,
  uneven frames that no probe explains. It is often a big part of "unmeasured".

Common causes, all fixable: new tables or closures every frame (`{x, y}` vectors as tables, `table.clone`
in a loop, `string.format` for UI text every frame), `Vector3`/`CFrame` math in tight loops,
`:GetChildren()` or `:GetDescendants()` every frame, and building strings for keys. Probe the
suspects; when a probe's time drops after a fix, the garbage rate should drop too.

## 6. Check the engine side

If unmeasured time stays large after steps 2 to 5:

- **Memory tab:** `GraphicsTexture`, `GraphicsMeshParts` and `Instances` show what the scene costs.
  A mobile device that is out of memory is also slow.
- **Instance count** (Memory tab) and the server's **physics ms** (switch to server) show how much
  the world does. Thousands of moving, unanchored parts cost physics time on every client that
  sees them.
- **Network tab:** a high engine receive rate with little in your own channels means replication:
  the server changes many properties every frame (for example, moving parts on the server instead
  of on the client).
- Use the MicroProfiler (Ctrl+F6 on desktop). With `microprofiler = true`, your probe names appear
  there too, next to Roblox's own render and physics labels.

## 7. See what real players get

Studio and your own phone are two devices. Turn on [player telemetry](/guide/telemetry) on the
server and look at the **Players** tab after a few minutes with real players:

```lua
Lighthouse.start({ telemetry = { sample = 0.2, every = 60 } })
```

- Compare **Mobile** with **Desktop**: frame p50 and p95, script p50, memory.
- The **top probes** under each device class show which of your systems are slowest on that device.
  A system that is cheap on desktop and slow on mobile is usually allocation heavy (step 5) or does
  work per Instance.
- The `LH_FrameP50` and `LH_FrameP95` events in the Creator Hub show the same numbers over days.

## 8. Record and share

To look at a bad moment in detail, or to send it to someone:

```lua
Lighthouse.record(20) -- start a 20 s capture now
-- ... play through the slow part ...
print(Lighthouse.export()) -- returns the capture
```

Paste the output into the [viewer](/viewer): the frame timeline shows every frame with the probe that
took the most time, and you can zoom into a spike.
