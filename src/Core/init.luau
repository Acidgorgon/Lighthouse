--!strict
--!native
--!optimize 2
-- Lighthouse Core: probes, frame aggregation, rolling stats, counters, network channels,
-- flares, snapshots and JSON. Pure Luau with no Roblox services, so it runs in tests and benches.
--
-- Hot paths (probe begin/finish, count, gauge, net) test one `active` upvalue and return when
-- off, and allocate nothing when on. endFrame (once per frame from the Runtime) visits only the
-- probes that ran, and allocates nothing in steady state. snapshot/recording/export allocate and
-- are meant for a few calls per second at most.

local Clock = require(script.Clock)
local Probes = require(script.Probes)
local Frames = require(script.Frames)
local Stats = require(script.Stats)
local Counters = require(script.Counters)
local Net = require(script.Net)
local Spikes = require(script.Spikes)
local Snapshot = require(script.Snapshot)
local Json = require(script.Json)

export type Probe = Probes.Probe
export type Histogram = Stats.Histogram
export type Flare = Spikes.Flare

local Core = {}

Core.HIST_BUCKETS = Stats.BUCKETS
Core.Json = Json
Core.Clock = Clock

local active = false
local budgetMs = 1000 / 60
local frameSeries = Stats.newSeries()
local scriptSeries = Stats.newSeries()
local probeSeries: { [number]: Stats.Series } = {}
local frameP50 = 0 -- frame ms median over 10 s, refreshed once per second (flare rule)
local engine: { [string]: any }? = nil
local memory: { [string]: any }? = nil
local extra: { [string]: any }? = nil

local names = Probes.names
local dirty = Probes.dirty
local frameSelf = Probes.frameSelf
local frameTotal = Probes.frameTotal
local frameCalls = Probes.frameCalls

--------------------------------------------------------------------------------
-- configuration and state
--------------------------------------------------------------------------------

-- opts: budget (seconds), frames (ring size), microprofiler (boolean), spawn (fn, args: how
-- onFlare listeners run; task.spawn in Roblox). Unknown keys are ignored. Safe to call again.
function Core.configure(opts: { [string]: any }?)
	local o = opts or {}
	local budget = o.budget
	if type(budget) == "number" and budget > 0 and budget < math.huge then
		budgetMs = budget * 1000
	end
	if o.frames ~= nil then
		Frames.configure(o.frames)
	end
	if o.microprofiler ~= nil then
		Probes.setProfiler(o.microprofiler == true)
	end
	if type(o.spawn) == "function" then
		Spikes.setSpawn(o.spawn)
	end
end

function Core.setActive(on: boolean)
	local v = on == true
	active = v
	Probes.setActive(v)
	Counters.setActive(v)
	Net.setActive(v)
end

function Core.isActive(): boolean
	return active
end

--------------------------------------------------------------------------------
-- measuring (hot)
--------------------------------------------------------------------------------

Core.probe = Probes.get
Core.wrap = Probes.wrap
Core.count = Counters.count
Core.gauge = Counters.gauge
Core.net = Net.net

--------------------------------------------------------------------------------
-- frame boundary
--------------------------------------------------------------------------------

-- Once per frame from the Runtime. frameSeconds = the frame's dt, now = os.clock().
function Core.endFrame(frameSeconds: number, now: number?)
	if not active then
		return
	end
	local t = if type(now) == "number" and now == now then now else Clock.now()
	local dt = if type(frameSeconds) == "number" and frameSeconds >= 0 then math.min(frameSeconds, 3600) else 0

	Probes.repair()
	local steps = Stats.advance(t)
	if steps > 0 then
		Counters.roll(steps)
		Net.roll(steps)
		frameP50 = Stats.quantile(frameSeries, 10, 0.5)
	end
	Stats.frame()

	local frameMs = dt * 1000
	local scriptMs = Probes.scriptSeconds() * 1000
	Stats.add(frameSeries, frameMs, frameMs, 1)
	Stats.add(scriptSeries, scriptMs, scriptMs, 1)

	local flare = frameMs > budgetMs and frameMs > 1.5 * frameP50
	if flare then
		Spikes.begin(t, frameMs, Clock.frame + 1)
	end

	local n = Probes.dirtyCount()
	local slot, first = Frames.push(frameMs, t, scriptMs, n)
	local log = Frames.log
	local at = first * Frames.ENTRY
	for k = 1, n do
		local id = dirty[k]
		local selfMs = frameSelf[id] * 1000
		local s = probeSeries[id]
		if s == nil then
			s = Stats.newSeries()
			probeSeries[id] = s
		end
		Stats.add(s, selfMs, frameTotal[id] * 1000, frameCalls[id])
		buffer.writeu32(log, at, id)
		buffer.writef32(log, at + 4, selfMs)
		at += 8
		if flare then
			Spikes.offer(names[id], selfMs)
		end
	end
	if Frames.recording() then
		Frames.recordSlot(slot)
	end
	Probes.endFrame()
	Clock.markFrame(dt, t)
	if flare then
		Spikes.commit(Stats.second())
	end
end

--------------------------------------------------------------------------------
-- engine numbers, snapshot, recording
--------------------------------------------------------------------------------

-- Runtime/Sampler pushes 1 Hz engine + memory numbers and { device, players, serverTime }
-- (serverTime: number, or a function called at snapshot time). Tables are kept by reference.
function Core.setEngine(engineTable: { [string]: any }?, memoryTable: { [string]: any }?, extraTable: { [string]: any }?)
	engine = engineTable
	memory = memoryTable
	extra = extraTable
end

function Core.snapshot(side: string): { [string]: any }
	return Snapshot.build(side, {
		probeSeries = probeSeries,
		frameSeries = frameSeries,
		scriptSeries = scriptSeries,
		budgetMs = budgetMs,
		engine = engine,
		memory = memory,
		extra = extra,
	})
end

-- Starts a detailed recording of the next `seconds` (max 120) of frames.
function Core.record(seconds: number)
	Frames.record(seconds)
end

-- Column layout { probes, frames = { t, dt, script, self } }: the explicit recording when one
-- exists and `seconds` is nil, else the last `seconds` of the frame ring (all of it when nil).
function Core.recording(seconds: number?): Frames.Columns?
	return Frames.columns(seconds, names)
end

function Core.flares(): { Flare }
	return Spikes.list()
end

Core.onFlare = Spikes.onFlare

--------------------------------------------------------------------------------
-- stats queries
--------------------------------------------------------------------------------

function Core.histogram(): Histogram
	return Stats.histogram()
end

local function windowOf(s: Stats.Series, window: number?)
	local w = Stats.window(s, window or 10)
	return { avg = w.avg, p50 = w.p50, p95 = w.p95, p99 = w.p99, max = w.max, n = w.n, frames = w.frames, last = w.last }
end

-- Frame ms over the last `window` (1, 10 or 60) completed seconds: { avg, p50, p95, p99, max, n, frames, last }.
function Core.frameStats(window: number?)
	return windowOf(frameSeries, window)
end

-- Script ms per frame (sum of top-level probe totals), same shape as frameStats.
function Core.scriptStats(window: number?)
	return windowOf(scriptSeries, window)
end

-- Self ms per frame of probe `name`: { selfAvg, p50, p95, p99, max, totalAvg, calls, n, frames, last }.
-- p50..max are over frames the probe ran in; selfAvg / totalAvg / calls are per frame.
function Core.probeStats(name: string, window: number?)
	local p = Probes.find(name)
	local s = p and probeSeries[p.id]
	if s == nil then
		return nil
	end
	local w = Stats.window(s, window or 10)
	return {
		selfAvg = w.avg,
		p50 = w.p50,
		p95 = w.p95,
		p99 = w.p99,
		max = w.max,
		totalAvg = w.totalAvg,
		calls = w.calls,
		n = w.n,
		frames = w.frames,
		last = w.last,
	}
end

function Core.frameHistogram(window: number?, into: Histogram?): Histogram
	return Stats.toHistogram(frameSeries, window or 60, into)
end

function Core.scriptHistogram(window: number?, into: Histogram?): Histogram
	return Stats.toHistogram(scriptSeries, window or 60, into)
end

function Core.counterRate(name: string): number?
	return Counters.rate(name)
end

function Core.misuse(): number
	return Probes.misuse()
end

-- Clears all measurements (probe objects stay valid; counters, gauges and channels are forgotten).
function Core.reset()
	Probes.reset()
	Stats.reset()
	Frames.reset()
	Counters.reset()
	Net.reset()
	Spikes.reset()
	Clock.reset()
	frameP50 = 0
	engine = nil
	memory = nil
	extra = nil
end

-- Replaces the clock used by probes and snapshots (tests); nil restores os.clock.
function Core.setClock(fn: (() -> number)?)
	Clock.set(fn)
end

return Core
