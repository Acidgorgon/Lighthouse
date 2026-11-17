# Lighthouse overhead

Measured with `bench/overhead.luau` on the Luau 0.700 `luau-bench` host (`bench/host`), compiled
at `-O2` like Roblox, once interpreted and once with `--codegen` (native, like `--!native` in
Roblox). Machine: a shared 4 vCPU cloud container (Intel Xeon @ 2.10GHz). Absolute numbers are
not Roblox numbers and moved by up to ~20% between runs; read them relative to each other, and
against the `os.clock()` floor measured in the same run. Each figure is the best of 7 trials;
the cost of the benchmark loop calling an empty function is subtracted.

```sh
sh bench/fetch_luau.sh                   # Luau sources (or set HOST to an existing build)
HOST=/path/to/luau-bench
$HOST bench/overhead.luau .
$HOST --codegen bench/overhead.luau .
```

## Per call

| Operation | interpreted | native |
|---|---:|---:|
| `os.clock()` x2 (the floor for a pair) | 112 ns | 118 ns |
| `probe:begin()` + `probe:finish()`, on | 324 ns | 186 ns |
| same, nested inside another pair (per inner pair) | 317 ns | 199 ns |
| same, **off** (before `start()`) | 62 ns | 57 ns |
| `wrap` overhead over a direct call, on | 346 ns | 209 ns |
| `wrap` overhead over a direct call, **off** | 61 ns | 46 ns |
| `count(name)` | 76 ns | 33 ns |
| `gauge(name, v)` | 119 ns | 39 ns |
| `net(lib, channel, dir, bytes)` | 114 ns | 43 ns |
| `net(..., player)` (top senders tracking) | 143 ns | 64 ns |
| `count` / `net`, **off** | 34 ns | 19 ns |

A probe pair costs the two clock reads plus about 200 ns (interpreted) or 70 ns (native) of
array work. Off, a pair is two method calls that test one upvalue.

## Per frame (`Core.endFrame`)

Each frame touches N probes once (plus a counter and a network channel). "Average" includes
the once-per-second window roll spread over 60 frames; the roll frame is shown on its own.

| Probes touched per frame | average, interpreted | average, native | roll frame, interpreted | roll frame, native |
|---:|---:|---:|---:|---:|
| 10 | 4.5 us | 1.4 us | 17 us | 9 us |
| 50 | 17.9 us | 5.1 us | 71 us | 31 us |
| 200 | 68.5 us | 24.9 us | 267 us | 173 us |

At 50 probes and 60 FPS that is about 0.1% of a frame budget (interpreted, average).

## Snapshot and export (a few times per second at most)

| Operation | interpreted | native |
|---|---:|---:|
| `Core.snapshot()`, 200 live probes | 267 us | 131 us |
| `Json.encode(snapshot)`, 200 live probes | 284 us | 391 us |

The snapshot ranks probes by their 1 s average first and computes the 10 s p95 / max only for
the 40 it returns.

## Memory

About **17.5 KB per probe** (measured from the VM heap after a full GC, 600-frame ring): a 61 s
ring of one-second u8 histograms (134 buckets, 8.2 KB), per-second scalars (2.4 KB), 10 s / 60 s
u32 aggregates (1 KB) and the probe's 8-byte entries in the 600-frame ring (4.8 KB). 200 probes
are about 3.5 MB.

## Allocations

`tests/test_alloc.luau` checks exact VM allocation counts: begin/finish, `count`, `gauge`, `net`
(with and without a player key) and `Core.endFrame` with 50 probes across second rolls and flares
allocate nothing in steady state, on and off.
