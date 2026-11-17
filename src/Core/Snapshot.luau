--!strict
-- Builds the Snapshot table (see DESIGN.md "Snapshot"): the one shape shared by the overlay, the
-- wire, exports and the viewer. Allocates; called at most a few times per second.
-- All durations are milliseconds; `t` is os.clock() seconds.

local Probes = require(script.Parent.Probes)
local Stats = require(script.Parent.Stats)
local Frames = require(script.Parent.Frames)
local Counters = require(script.Parent.Counters)
local Net = require(script.Parent.Net)
local Spikes = require(script.Parent.Spikes)
local Clock = require(script.Parent.Clock)

local Snapshot = {}

local TOP_PROBES = 40
local HISTORY = 120
local TOP_SENDERS = 5

export type Context = {
	probeSeries: { [number]: Stats.Series },
	frameSeries: Stats.Series,
	scriptSeries: Stats.Series,
	budgetMs: number,
	engine: { [string]: any }?,
	memory: { [string]: any }?,
	extra: { [string]: any }?,
}

local function serverTime(extra: { [string]: any }?): number?
	local v = extra and extra.serverTime
	if type(v) == "function" then
		local ok, r = pcall(v)
		return if ok and type(r) == "number" then r else nil
	end
	return if type(v) == "number" then v else nil
end

function Snapshot.build(side: string, ctx: Context): { [string]: any }
	local extra = ctx.extra
	local w1 = Stats.window(ctx.frameSeries, 1)
	local w10 = Stats.window(ctx.frameSeries, 10)
	local s1 = Stats.window(ctx.scriptSeries, 1)
	local s10 = Stats.window(ctx.scriptSeries, 10)
	local started = w1.frames > 0 -- a second has completed

	-- rank every recent probe by its 1 s self average (cheap), then compute the 10 s tail only
	-- for the ones that are shown
	local probes = {}
	local names = Probes.names
	for id, s in ctx.probeSeries do
		if Stats.recent(s, 10) then
			local selfAvg, totalAvg, calls = Stats.recentAvg(s)
			table.insert(probes, {
				name = names[id],
				selfAvg = if started then selfAvg else s.last,
				selfP95 = 0,
				selfMax = 0,
				totalAvg = totalAvg,
				calls = calls,
				id = id,
			})
		end
	end
	table.sort(probes, function(a, b)
		if a.selfAvg ~= b.selfAvg then
			return a.selfAvg > b.selfAvg
		end
		return a.name < b.name
	end)
	for i = #probes, TOP_PROBES + 1, -1 do
		probes[i] = nil
	end
	for _, e in probes do
		local p95, max = Stats.quantile(ctx.probeSeries[e.id], 10, 0.95)
		e.selfP95 = p95
		e.selfMax = max
		e.id = nil :: any
	end

	return {
		v = 1,
		side = side,
		t = Clock.now(),
		serverTime = serverTime(extra),
		device = extra and extra.device,
		players = extra and extra.players,
		frames = Clock.frame,
		frame = {
			last = ctx.frameSeries.last,
			avg1 = if started then w1.avg else ctx.frameSeries.last,
			p50 = w10.p50,
			p95 = w10.p95,
			p99 = w10.p99,
			max10 = w10.max,
			fps = Stats.frames(1),
			budget = ctx.budgetMs,
			scriptMs = if started then s1.avg else ctx.scriptSeries.last,
			scriptP50 = s10.p50,
			history = Frames.history(HISTORY),
		},
		probes = probes,
		counters = Counters.counterList(),
		gauges = Counters.gaugeList(),
		net = Net.list(),
		netTop = Net.top(TOP_SENDERS),
		memory = ctx.memory or {},
		engine = ctx.engine or {},
		flares = Spikes.list(),
		misuse = Probes.misuse(),
	}
end

return Snapshot
