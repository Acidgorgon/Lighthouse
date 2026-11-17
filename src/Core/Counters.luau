--!strict
--!native
--!optimize 2
-- Counters (summed per second, reported as a rate over the last completed second) and gauges
-- (last value plus min / max over the last 10 s). Names are interned into ids on first use;
-- after that count() and gauge() are a table lookup and a few array writes.

local Counters = {}

local GAUGE_RING = 10

local active = false

-- counters
local cId: { [string]: number } = {}
local cName: { string } = {}
local cCur: { number } = {}
local cRate: { number } = {}
local cN = 0

-- gauges
local gId: { [string]: number } = {}
local gName: { string } = {}
local gValue: { number } = {}
local gMin: { number } = {} -- this second
local gMax: { number } = {}
local gMins: { { number } } = {} -- ring of per-second minima
local gMaxs: { { number } } = {}
local gN = 0
local gSlot = 1

local function newCounter(name: string): number
	cN += 1
	cId[name] = cN
	cName[cN] = name
	cCur[cN] = 0
	cRate[cN] = 0
	return cN
end

-- +n (default 1) to counter `name`.
function Counters.count(name: string, n: number?)
	if not active then
		return
	end
	local id = cId[name]
	if id == nil then
		if type(name) ~= "string" then
			return
		end
		id = newCounter(name)
	end
	if n == nil then
		cCur[id] += 1
	elseif type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge then
		cCur[id] += n
	end
end

local function newGauge(name: string, v: number): number
	gN += 1
	gId[name] = gN
	gName[gN] = name
	gValue[gN] = v
	gMin[gN] = v
	gMax[gN] = v
	gMins[gN] = table.create(GAUGE_RING, v)
	gMaxs[gN] = table.create(GAUGE_RING, v)
	return gN
end

-- Sets gauge `name` to v.
function Counters.gauge(name: string, v: number)
	if not active then
		return
	end
	if type(v) ~= "number" or v ~= v then
		return
	end
	local id = gId[name]
	if id == nil then
		if type(name) ~= "string" then
			return
		end
		newGauge(name, v)
		return
	end
	gValue[id] = v
	if v < gMin[id] then
		gMin[id] = v
	end
	if v > gMax[id] then
		gMax[id] = v
	end
end

-- `steps` seconds completed: the counts since the last roll become the rate.
function Counters.roll(steps: number)
	local inv = 1 / math.max(steps, 1)
	for id = 1, cN do
		cRate[id] = cCur[id] * inv
		cCur[id] = 0
	end
	for _ = 1, math.min(steps, GAUGE_RING) do
		gSlot = gSlot % GAUGE_RING + 1
		for id = 1, gN do
			gMins[id][gSlot] = gMin[id]
			gMaxs[id][gSlot] = gMax[id]
			local v = gValue[id]
			gMin[id] = v
			gMax[id] = v
		end
	end
end

function Counters.rate(name: string): number?
	local id = cId[name]
	return if id then cRate[id] else nil
end

-- { {name, perSec} } sorted by name.
function Counters.counterList(): { { name: string, perSec: number } }
	local out = table.create(cN)
	for id = 1, cN do
		out[id] = { name = cName[id], perSec = cRate[id] }
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- { {name, value, min, max} } sorted by name; min / max cover the last 10 s and this second.
function Counters.gaugeList(): { { name: string, value: number, min: number, max: number } }
	local out = table.create(gN)
	for id = 1, gN do
		local lo, hi = gMin[id], gMax[id]
		local mins, maxs = gMins[id], gMaxs[id]
		for j = 1, GAUGE_RING do
			if mins[j] < lo then
				lo = mins[j]
			end
			if maxs[j] > hi then
				hi = maxs[j]
			end
		end
		out[id] = { name = gName[id], value = gValue[id], min = lo, max = hi }
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

function Counters.setActive(on: boolean)
	active = on
end

-- Forgets every counter and gauge.
function Counters.reset()
	table.clear(cId)
	table.clear(cName)
	table.clear(cCur)
	table.clear(cRate)
	cN = 0
	table.clear(gId)
	table.clear(gName)
	table.clear(gValue)
	table.clear(gMin)
	table.clear(gMax)
	table.clear(gMins)
	table.clear(gMaxs)
	gN = 0
	gSlot = 1
end

return Counters
