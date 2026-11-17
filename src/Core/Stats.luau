--!strict
--!native
--!optimize 2
-- Rolling statistics from a fixed log-scale histogram (no sorting, no allocation after setup).
--
-- Buckets: index 0 holds values below MIN (0.001 ms) and zero; 1..B-2 are log spaced with SUB
-- buckets per octave (about 12% wide, so the midpoint is within ~6% of any value in the bucket);
-- B-1 holds everything above MIN * 2^OCTAVES (about 4.2 s). Quantiles interpolate geometrically
-- inside the bucket and are clamped to the observed max.
--
-- A Series (frame time, script time, one per probe) keeps a ring of RING one-second slots, each
-- a u8 histogram plus scalars (samples, sum, max, total, calls). When a second completes it is
-- added to the 10 s and 60 s aggregate histograms (u32) and the slots that left those windows
-- are subtracted, so window queries never merge 60 histograms. Each slot remembers the bucket
-- range it touched; rolling a second only walks those ranges.
--
-- Windows are "the last k completed seconds" (k = 1, 10, 60); the second in progress is not
-- included. Averages are per frame: sum / frames that ended in the window.

local Stats = {}

local SUB = 6
local OCTAVES = 22
local MIN = 0.001
local B = OCTAVES * SUB + 2 -- 134
local RING = 61 -- 60 s window + the slot being filled
local K = SUB / math.log(2)
local INV_MIN = 1 / MIN

Stats.BUCKETS = B
Stats.MIN = MIN
Stats.SUB = SUB
Stats.RING = RING

-- lower edge of bucket b (0-based) at lowEdge[b + 1]; bucket b spans [lowEdge[b+1], lowEdge[b+2])
local lowEdge: { number } = table.create(B + 1, 0)
lowEdge[1] = 0
for b = 1, B do
	lowEdge[b + 1] = MIN * 2 ^ ((b - 1) / SUB)
end
Stats.lowEdge = lowEdge

local function bucketOf(ms: number): number
	if not (ms >= MIN) then -- also NaN
		return 0
	end
	local b = math.floor(math.log(ms * INV_MIN) * K) + 1
	if b > B - 2 then
		return B - 1
	end
	return b
end
Stats.bucketOf = bucketOf

-- Value at rank fraction `frac` (0..1] inside bucket b.
local function inBucket(b: number, frac: number, max: number): number
	local v
	if b == 0 then
		v = MIN * frac
	elseif b >= B - 1 then
		v = max
	else
		v = lowEdge[b + 1] * 2 ^ (frac / SUB)
	end
	if v > max then
		v = max
	end
	return v
end

--------------------------------------------------------------------------------
-- Histogram object (Core.histogram(): merge across clients, Wire encode/decode)
--------------------------------------------------------------------------------

export type Histogram = {
	counts: { number }, -- counts[b + 1] for bucket b
	total: number,
	sum: number,
	max: number,
	min: number,
	add: (self: Histogram, ms: number, n: number?) -> (),
	merge: (self: Histogram, other: Histogram) -> (),
	quantile: (self: Histogram, q: number) -> number,
	mean: (self: Histogram) -> number,
	clear: (self: Histogram) -> (),
	encode: (self: Histogram) -> buffer,
	decode: (self: Histogram, b: buffer, offset: number?) -> (boolean, number),
}

local Hist = {}

function Hist.add(self: Histogram, ms: number, n: number?)
	local c = n or 1
	if type(ms) ~= "number" or ms ~= ms or ms == math.huge or ms < 0 or not (c > 0) or c == math.huge then
		return
	end
	local b = bucketOf(ms)
	self.counts[b + 1] += c
	self.total += c
	self.sum += ms * c
	if ms > self.max then
		self.max = ms
	end
	if ms < self.min then
		self.min = ms
	end
end

function Hist.merge(self: Histogram, other: Histogram)
	local a, o = self.counts, other.counts
	for i = 1, B do
		a[i] += o[i]
	end
	self.total += other.total
	self.sum += other.sum
	if other.max > self.max then
		self.max = other.max
	end
	if other.min < self.min then
		self.min = other.min
	end
end

function Hist.quantile(self: Histogram, q: number): number
	local n = self.total
	if n <= 0 then
		return 0
	end
	local target = math.clamp(q, 0, 1) * n
	local counts = self.counts
	local cum = 0
	for i = 1, B do
		local c = counts[i]
		if c > 0 then
			if cum + c >= target then
				local v = inBucket(i - 1, (target - cum) / c, self.max)
				return if v < self.min then self.min else v
			end
			cum += c
		end
	end
	return self.max
end

function Hist.mean(self: Histogram): number
	return if self.total > 0 then self.sum / self.total else 0
end

function Hist.clear(self: Histogram)
	local counts = self.counts
	for i = 1, B do
		counts[i] = 0
	end
	self.total = 0
	self.sum = 0
	self.max = 0
	self.min = math.huge
end

-- Sparse encoding: u8 k, f32 sum, f32 max, then k x (u8 bucket, u32 count). 9 + 5k bytes.
function Hist.encode(self: Histogram): buffer
	local counts = self.counts
	local k = 0
	for i = 1, B do
		if counts[i] > 0 then
			k += 1
		end
	end
	local out = buffer.create(9 + 5 * k)
	buffer.writeu8(out, 0, k)
	buffer.writef32(out, 1, self.sum)
	buffer.writef32(out, 5, self.max)
	local pos = 9
	for i = 1, B do
		local c = counts[i]
		if c > 0 then
			buffer.writeu8(out, pos, i - 1)
			buffer.writeu32(out, pos + 1, math.min(c, 0xFFFFFFFF))
			pos += 5
		end
	end
	return out
end

-- Replaces the contents from an encoding at `offset` (default 0). Never throws; on bad input
-- returns false and leaves the histogram unchanged. Returns (ok, offset after the encoding).
function Hist.decode(self: Histogram, b: buffer, offset: number?): (boolean, number)
	local off = offset or 0
	if type(b) ~= "buffer" or type(off) ~= "number" or off ~= math.floor(off) or off < 0 then
		return false, off
	end
	local len = buffer.len(b)
	if off + 9 > len then
		return false, off
	end
	local k = buffer.readu8(b, off)
	local stop = off + 9 + 5 * k
	if k > B or stop > len then
		return false, off
	end
	local sum = buffer.readf32(b, off + 1)
	local max = buffer.readf32(b, off + 5)
	if not (sum >= 0 and sum < math.huge and max >= 0 and max < math.huge) then
		return false, off
	end
	local prev = -1
	local pos = off + 9
	for _ = 1, k do
		local idx = buffer.readu8(b, pos)
		local c = buffer.readu32(b, pos + 1)
		if idx >= B or idx <= prev or c == 0 then
			return false, off
		end
		prev = idx
		pos += 5
	end
	Hist.clear(self)
	local counts = self.counts
	local total = 0
	local first = -1
	pos = off + 9
	for _ = 1, k do
		local idx = buffer.readu8(b, pos)
		local c = buffer.readu32(b, pos + 1)
		counts[idx + 1] = c
		total += c
		if first < 0 then
			first = idx
		end
		pos += 5
	end
	self.total = total
	self.sum = sum
	self.max = max
	self.min = if first >= 0 then math.min(lowEdge[first + 1], max) else math.huge
	return true, stop
end

function Stats.histogram(): Histogram
	local h = {
		counts = table.create(B, 0),
		total = 0,
		sum = 0,
		max = 0,
		min = math.huge,
		add = Hist.add,
		merge = Hist.merge,
		quantile = Hist.quantile,
		mean = Hist.mean,
		clear = Hist.clear,
		encode = Hist.encode,
		decode = Hist.decode,
	}
	return h :: Histogram
end

--------------------------------------------------------------------------------
-- Series: per-second ring + 10 s / 60 s aggregates
--------------------------------------------------------------------------------
-- Everything per slot lives in buffers (about 12 KB per series):
--   sec   RING * B u8     per-second histogram counts (saturate at 255)
--   sc    RING * 5 f64    per-second scalars: samples, sum, max, total, calls
--   rng   RING * 2 u8     per-second touched bucket range: lo (B when empty), hi + 1 (0 when empty)
--   h10, h60  B u32       window aggregates

local SC_SIZE = 40 -- bytes of scalars per slot
local O_N, O_SUM, O_MAX, O_TOT, O_CALLS = 0, 8, 16, 24, 32

export type Series = {
	sec: buffer,
	sc: buffer,
	rng: buffer,
	h10: buffer,
	h60: buffer,
	n10: number, -- samples in h10
	n60: number, -- samples in h60
	last: number,
	lastSecond: number, -- second index of the newest sample
}

local slot = 0 -- 0-based slot being filled
local second: number? = nil -- second index (floor(now)) of `slot`
local frameN: { number } = table.create(RING, 0) -- frames that ended in each slot
local series: { Series } = {}
local seriesN = 0

local function emptyRanges(rng: buffer)
	for i = 0, RING - 1 do
		buffer.writeu8(rng, i * 2, B)
		buffer.writeu8(rng, i * 2 + 1, 0)
	end
end

function Stats.newSeries(): Series
	local s: Series = {
		sec = buffer.create(RING * B),
		sc = buffer.create(RING * SC_SIZE),
		rng = buffer.create(RING * 2),
		h10 = buffer.create(B * 4),
		h60 = buffer.create(B * 4),
		n10 = 0,
		n60 = 0,
		last = 0,
		lastSecond = -math.huge,
	}
	emptyRanges(s.rng)
	seriesN += 1
	series[seriesN] = s
	return s
end

-- Adds one frame's value (ms) to the slot being filled. totalMs / calls are scalars only.
function Stats.add(s: Series, ms: number, totalMs: number, calls: number)
	local b = bucketOf(ms)
	local sec = s.sec
	local off = slot * B + b
	local v = buffer.readu8(sec, off)
	if v < 255 then
		buffer.writeu8(sec, off, v + 1)
	end
	local sc = s.sc
	local o = slot * SC_SIZE
	buffer.writef64(sc, o + O_N, buffer.readf64(sc, o + O_N) + 1)
	buffer.writef64(sc, o + O_SUM, buffer.readf64(sc, o + O_SUM) + ms)
	if ms > buffer.readf64(sc, o + O_MAX) then
		buffer.writef64(sc, o + O_MAX, ms)
	end
	buffer.writef64(sc, o + O_TOT, buffer.readf64(sc, o + O_TOT) + totalMs)
	buffer.writef64(sc, o + O_CALLS, buffer.readf64(sc, o + O_CALLS) + calls)
	local rng = s.rng
	local r = slot * 2
	if b < buffer.readu8(rng, r) then
		buffer.writeu8(rng, r, b)
	end
	if b >= buffer.readu8(rng, r + 1) then
		buffer.writeu8(rng, r + 1, b + 1)
	end
	s.last = ms
	s.lastSecond = second or 0
end

-- Counts a frame in the slot being filled (denominator for per-frame averages).
function Stats.frame()
	frameN[slot + 1] += 1
end

-- Adds (sign 1) or removes (sign -1) slot x's counts; returns the count moved.
local function addSlot(s: Series, x: number, agg: buffer, sign: number): number
	local rng = s.rng
	local lo, hi = buffer.readu8(rng, x * 2), buffer.readu8(rng, x * 2 + 1) - 1
	local sec = s.sec
	local base = x * B
	local moved = 0
	for b = lo, hi do
		local v = buffer.readu8(sec, base + b)
		if v > 0 then
			local o = b * 4
			buffer.writeu32(agg, o, buffer.readu32(agg, o) + sign * v)
			moved += v
		end
	end
	return moved
end

local function clearSlot(s: Series, x: number)
	local rng = s.rng
	local lo, hi = buffer.readu8(rng, x * 2), buffer.readu8(rng, x * 2 + 1) - 1
	if lo <= hi then
		buffer.fill(s.sec, x * B + lo, 0, hi - lo + 1)
	end
	buffer.writeu8(rng, x * 2, B)
	buffer.writeu8(rng, x * 2 + 1, 0)
	buffer.fill(s.sc, x * SC_SIZE, 0, SC_SIZE)
end

-- Completed slot c: add to both windows, drop c-10 from the 10 s window and c-60 (the slot
-- that is filled next) from the 60 s window, then clear that slot.
local function rollSeries(s: Series, c: number)
	local moved = addSlot(s, c, s.h10, 1)
	if moved > 0 then
		addSlot(s, c, s.h60, 1)
		s.n10 += moved
		s.n60 += moved
	end
	s.n10 -= addSlot(s, (c - 10) % RING, s.h10, -1)
	local x = (c + 1) % RING
	s.n60 -= addSlot(s, x, s.h60, -1)
	clearSlot(s, x)
end

local function clearSeries(s: Series)
	buffer.fill(s.sec, 0, 0)
	buffer.fill(s.sc, 0, 0)
	buffer.fill(s.h10, 0, 0)
	buffer.fill(s.h60, 0, 0)
	emptyRanges(s.rng)
	s.n10 = 0
	s.n60 = 0
	s.last = 0
	s.lastSecond = -math.huge
end

local function rollOnce()
	for k = 1, seriesN do
		rollSeries(series[k], slot)
	end
	slot = (slot + 1) % RING
	frameN[slot + 1] = 0
end

-- Moves to the second containing `now`. Returns the number of seconds completed (0 if none).
function Stats.advance(now: number): number
	local s = math.floor(now)
	local cur = second
	if cur == nil then
		second = s
		return 0
	end
	if s == cur then
		return 0
	end
	local steps = s - cur
	second = s
	if steps < 0 or steps > RING then
		-- clock jumped: start over with empty windows
		for k = 1, seriesN do
			clearSeries(series[k])
		end
		for i = 1, RING do
			frameN[i] = 0
		end
		slot = 0
		return if steps < 0 then 1 else steps
	end
	for _ = 1, steps do
		rollOnce()
	end
	return steps
end

function Stats.second(): number
	return second or 0
end

-- Slot index (0-based) of the newest completed second.
local function completed(): number
	return (slot - 1) % RING
end

-- Frames that ended in the last `window` completed seconds.
function Stats.frames(window: number): number
	local c = completed()
	local f = 0
	for j = 0, math.min(window, RING - 1) - 1 do
		f += frameN[(c - j) % RING + 1]
	end
	return f
end

export type Window = {
	avg: number, -- sum / frames in window
	p50: number,
	p95: number,
	p99: number,
	max: number,
	n: number, -- samples
	frames: number,
	totalAvg: number,
	calls: number, -- calls per frame
	last: number,
}

local function readCount(agg: buffer, base: number, wide: boolean, b: number): number
	return if wide then buffer.readu32(agg, base + b * 4) else buffer.readu8(agg, base + b)
end

-- Quantile q of n samples in buckets lo..hi of a u8 (slot) or u32 (aggregate) histogram.
-- High quantiles walk down from the top bucket, so p95 / p99 touch only a few buckets.
local function quantileBuf(agg: buffer, base: number, wide: boolean, lo: number, hi: number, n: number, q: number, max: number): number
	if n <= 0 then
		return 0
	end
	local target = q * n
	if q >= 0.5 then
		local above = 0
		for b = hi, lo, -1 do
			local c = readCount(agg, base, wide, b)
			if c > 0 then
				local before = n - above - c
				if before < target then
					return inBucket(b, (target - before) / c, max)
				end
				above += c
			end
		end
		return inBucket(lo, 0, max)
	end
	local cum = 0
	for b = lo, hi do
		local c = readCount(agg, base, wide, b)
		if c > 0 then
			if cum + c >= target then
				return inBucket(b, (target - cum) / c, max)
			end
			cum += c
		end
	end
	return max
end

-- Where a window's samples are: (buffer, base, wide, lo, hi, n).
local function source(s: Series, w: number, c: number, max: number): (buffer, number, boolean, number, number, number)
	if w == 1 then
		local lo, hi = buffer.readu8(s.rng, c * 2), buffer.readu8(s.rng, c * 2 + 1) - 1
		local n = 0
		local base = c * B
		for b = lo, hi do
			n += buffer.readu8(s.sec, base + b)
		end
		return s.sec, base, false, lo, hi, n
	end
	-- buckets above the window's max are empty
	local hi = bucketOf(max)
	if w == 10 then
		return s.h10, 0, true, 0, hi, s.n10
	end
	return s.h60, 0, true, 0, hi, s.n60
end

local function clampWindow(window: number): number
	return if window >= 60 then 60 elseif window >= 10 then 10 else 1
end

local function windowMax(s: Series, w: number, c: number): number
	local sc = s.sc
	local max = 0
	for j = 0, w - 1 do
		local m = buffer.readf64(sc, ((c - j) % RING) * SC_SIZE + O_MAX)
		if m > max then
			max = m
		end
	end
	return max
end

-- Stats of `s` over the last `window` (1, 10 or 60) completed seconds, written into `into`.
function Stats.window(s: Series, window: number, into: Window?): Window
	local out: Window = into
		or { avg = 0, p50 = 0, p95 = 0, p99 = 0, max = 0, n = 0, frames = 0, totalAvg = 0, calls = 0, last = 0 }
	local w = clampWindow(window)
	local c = completed()
	local sc = s.sc
	local sum, total, calls, n, max, frames = 0, 0, 0, 0, 0, 0
	for j = 0, w - 1 do
		local x = (c - j) % RING
		local o = x * SC_SIZE
		n += buffer.readf64(sc, o + O_N)
		sum += buffer.readf64(sc, o + O_SUM)
		total += buffer.readf64(sc, o + O_TOT)
		calls += buffer.readf64(sc, o + O_CALLS)
		local m = buffer.readf64(sc, o + O_MAX)
		if m > max then
			max = m
		end
		frames += frameN[x + 1]
	end
	out.avg = if frames > 0 then sum / frames else 0
	out.totalAvg = if frames > 0 then total / frames else 0
	out.calls = if frames > 0 then calls / frames else 0
	out.max = max
	out.n = n
	out.frames = frames
	out.last = s.last
	local agg, base, wide, lo, hi, hn = source(s, w, c, max)
	out.p50 = quantileBuf(agg, base, wide, lo, hi, hn, 0.5, max)
	out.p95 = quantileBuf(agg, base, wide, lo, hi, hn, 0.95, max)
	out.p99 = quantileBuf(agg, base, wide, lo, hi, hn, 0.99, max)
	return out
end

-- One quantile of `s` over a window, and the window's max (no table needed).
function Stats.quantile(s: Series, window: number, q: number): (number, number)
	local w = clampWindow(window)
	local c = completed()
	local max = windowMax(s, w, c)
	local agg, base, wide, lo, hi, n = source(s, w, c, max)
	return quantileBuf(agg, base, wide, lo, hi, n, q, max), max
end

-- Per-frame averages over the last completed second: (self avg, total avg, calls, samples).
function Stats.recentAvg(s: Series): (number, number, number, number)
	local c = completed()
	local o = c * SC_SIZE
	local sc = s.sc
	local n = buffer.readf64(sc, o + O_N)
	local frames = frameN[c + 1]
	if frames <= 0 then
		return 0, 0, 0, n
	end
	return buffer.readf64(sc, o + O_SUM) / frames, buffer.readf64(sc, o + O_TOT) / frames, buffer.readf64(sc, o + O_CALLS) / frames, n
end

-- Copies a window of `s` into a Histogram (for telemetry reports).
function Stats.toHistogram(s: Series, window: number, into: Histogram?): Histogram
	local h = into or Stats.histogram()
	h:clear()
	local w = clampWindow(window)
	local c = completed()
	local sum = 0
	for j = 0, w - 1 do
		sum += buffer.readf64(s.sc, ((c - j) % RING) * SC_SIZE + O_SUM)
	end
	local max = windowMax(s, w, c)
	local counts = h.counts
	local total = 0
	local first = -1
	for b = 0, B - 1 do
		local v = if w == 1
			then buffer.readu8(s.sec, c * B + b)
			else buffer.readu32(if w == 10 then s.h10 else s.h60, b * 4)
		counts[b + 1] = v
		total += v
		if v > 0 and first < 0 then
			first = b
		end
	end
	h.total = total
	h.sum = sum
	h.max = max
	h.min = if first >= 0 then math.min(lowEdge[first + 1], max) else math.huge
	return h
end

-- Whether `s` has a sample in the last `window` completed seconds or the current one.
function Stats.recent(s: Series, window: number): boolean
	return s.lastSecond >= (second or 0) - window
end

function Stats.reset()
	for k = 1, seriesN do
		clearSeries(series[k])
	end
	for i = 1, RING do
		frameN[i] = 0
	end
	slot = 0
	second = nil
end

return Stats
