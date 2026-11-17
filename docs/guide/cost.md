# What it costs

A profiler that slows the game down measures itself. Lighthouse is built to stay out of the way:
nothing is allocated per probe call or per frame in steady state, and the off state is one check.

## Off

Before `Lighthouse.start()`, after `Lighthouse.stop()`, or with `enabled = false`:

- `probe:begin()` and `probe:finish()` test one value and return.
- `Lighthouse.count`, `gauge` and `net` test the same value and return.
- `Lighthouse.wrap` and `bind` return the function itself when `enabled = false`, so a wrapped call
  is a plain call.
- No frame work, no sampling, no remotes, no overlay.

You can leave probes in shipping code.

## On

| Work | When | Cost |
|---|---|---|
| A probe pair (`begin` + `finish`) | each call | two `os.clock()` calls and a few array writes, no allocation |
| `wrap` | each call | a probe pair plus one extra function call |
| `count`, `gauge`, `net` | each call | a table lookup and an add |
| Frame aggregation | once per frame | visits only the probes used this frame |
| Engine sampling (`Stats`, memory tags, ping) | once per second | a few property reads |
| Server stream to viewers | every `stream` seconds, viewers only | one buffer per viewer |
| Telemetry report | every `every` seconds, sampled clients only | one buffer, at most 2 KB |
| Overlay | 4 times per second, only while open | property writes, no new Instances |
| MicroProfiler labels | each probe, when `microprofiler = true` | `debug.profilebegin` and `profileend` (on in Studio, off live by default) |

Measured numbers are on the [benchmarks](/benchmarks) page.

## Memory

- About 600 frames of history (the `frames` option) with each frame's probe self times.
- Per probe: a few rolling windows of fixed-size histograms. A probe costs about the same whether
  it is called once or a thousand times per frame.
- Distinct names are kept for the life of the server. Keep probe and channel names fixed.

## Bandwidth

- Viewers: one server snapshot per `stream` seconds (default 1) while their overlay is open, a few
  KB each. Non-viewers get nothing.
- Telemetry: one report of at most 2 KB per sampled client every `every` seconds. With the defaults
  (10% of clients, once a minute) that is at most about 35 bytes per second per sampled player.

## Tips

- Put probes around systems, not around tiny functions called thousands of times per frame. A pair
  is cheap, but ten thousand pairs per frame still add up.
- Use `microprofiler = false` when you measure Lighthouse's own overhead in Studio.
- `Lighthouse.record(seconds)` keeps every frame's probe times for up to 120 s. It allocates while
  it records; use it for a capture, not all the time.
