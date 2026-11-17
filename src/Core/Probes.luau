--!strict
--!native
--!optimize 2
-- Probe registry and the begin/finish stack.
--
-- A probe is interned by name and owns an integer id. Everything per probe lives in parallel
-- arrays indexed by id, so a begin/finish pair is two clock reads plus a few array writes and
-- never allocates. The stack holds (id, start, child time) in three preallocated arrays.
--
-- finish() on the top entry is the fast path. finish() of a probe further down unwinds to it
-- (each unwound entry is finished at the same `now`) and counts one misuse; finish() of a probe
-- that is not on the stack is ignored and counts one misuse. Entries left open at a frame
-- boundary (an error inside a probed region) are dropped by repair() and counted as misuse.
--
-- Time is accumulated per frame (self, total, calls) and touched probes are put on a dirty list
-- so the frame boundary visits only what ran.

local Clock = require(script.Parent.Clock)

export type Probe = {
	id: number,
	name: string,
	begin: (self: Probe) -> (),
	finish: (self: Probe) -> (),
}

local MAX_DEPTH = 64

local Probes = {}
Probes.MAX_DEPTH = MAX_DEPTH

local active = false
local profiler = false
local clock: () -> number = os.clock
local dbg: any = debug
local profilebegin: ((string) -> ())? = dbg.profilebegin
local profileend: (() -> ())? = dbg.profileend

-- stack
local stackId: { number } = table.create(MAX_DEPTH, 0)
local stackStart: { number } = table.create(MAX_DEPTH, 0)
local stackChild: { number } = table.create(MAX_DEPTH, 0)
local depth = 0
local overflow = 0 -- begins past MAX_DEPTH whose finish has not arrived yet

-- registry
local count = 0
local byName: { [string]: Probe } = {}
local list: { Probe } = {}
local names: { string } = {}

-- per-frame accumulators (seconds)
local frameSelf: { number } = {}
local frameTotal: { number } = {}
local frameCalls: { number } = {}
local touched: { boolean } = {}
local dirty: { number } = {}
local dirtyN = 0
local topTotal = 0 -- sum of top-level totals this frame (script time)
local misuse = 0

Probes.names = names
Probes.list = list
Probes.frameSelf = frameSelf
Probes.frameTotal = frameTotal
Probes.frameCalls = frameCalls
Probes.dirty = dirty

Clock.onSet(function(fn)
	clock = fn
end)

local function begin(self: Probe)
	if not active then
		return
	end
	local d = depth + 1
	if d > MAX_DEPTH then
		overflow += 1
		misuse += 1
		return
	end
	depth = d
	stackId[d] = self.id
	stackChild[d] = 0
	if profiler then
		(profilebegin :: any)(self.name)
	end
	stackStart[d] = clock()
end

-- Pops entry d (must be the top) as finished at `now`.
local function pop(d: number, now: number)
	local id = stackId[d]
	local total = now - stackStart[d]
	frameTotal[id] += total
	frameSelf[id] += total - stackChild[d]
	frameCalls[id] += 1
	if not touched[id] then
		touched[id] = true
		dirtyN += 1
		dirty[dirtyN] = id
	end
	if d > 1 then
		stackChild[d - 1] += total
	else
		topTotal += total
	end
	if profiler then
		(profileend :: any)()
	end
end

local function finishSlow(id: number, now: number)
	if overflow > 0 then
		-- LIFO: the finishes of begins that did not fit arrive first
		overflow -= 1
		return
	end
	local k = depth
	while k > 0 and stackId[k] ~= id do
		k -= 1
	end
	misuse += 1
	if k == 0 then
		return
	end
	for j = depth, k, -1 do
		pop(j, now)
	end
	depth = k - 1
end

local function finish(self: Probe)
	if not active then
		return
	end
	local now = clock()
	local d = depth
	local id = self.id
	-- while begins past MAX_DEPTH are pending, this finish belongs to one of them (LIFO), even
	-- when the top entry has the same id (recursion): finishSlow absorbs it
	if d > 0 and stackId[d] == id and overflow == 0 then
		local total = now - stackStart[d]
		frameTotal[id] += total
		frameSelf[id] += total - stackChild[d]
		frameCalls[id] += 1
		if not touched[id] then
			touched[id] = true
			dirtyN += 1
			dirty[dirtyN] = id
		end
		if d > 1 then
			stackChild[d - 1] += total
		else
			topTotal += total
		end
		depth = d - 1
		if profiler then
			(profileend :: any)()
		end
	else
		finishSlow(id, now)
	end
end

Probes.begin = begin
Probes.finish = finish

-- Interned probe for `name` (same name -> same object).
function Probes.get(name: string): Probe
	local key = if type(name) == "string" then name else tostring(name)
	local probe = byName[key]
	if probe then
		return probe
	end
	count += 1
	local id = count
	probe = {
		id = id,
		name = key,
		begin = begin,
		finish = finish,
	}
	byName[key] = probe
	list[id] = probe
	names[id] = key
	frameSelf[id] = 0
	frameTotal[id] = 0
	frameCalls[id] = 0
	touched[id] = false
	dirty[id] = 0 -- capacity: the dirty list never holds more than `count` ids
	return probe
end

function Probes.find(name: string): Probe?
	return byName[name]
end

function Probes.count(): number
	return count
end

local function finishPass(p: Probe, ...: any): ...any
	finish(p)
	return ...
end

-- Function that runs fn inside probe `name` and returns all of fn's results. If fn errors the
-- entry stays open until the next finish below it or the frame boundary repairs the stack.
function Probes.wrap<A..., R...>(name: string, fn: (A...) -> R...): (A...) -> R...
	local p = Probes.get(name)
	local wrapped = function(...)
		if not active then
			return fn(...)
		end
		begin(p)
		return finishPass(p, fn(...))
	end
	return wrapped :: any
end

function Probes.setActive(on: boolean)
	if on ~= active then
		depth = 0
		overflow = 0
	end
	active = on
end

function Probes.isActive(): boolean
	return active
end

function Probes.setProfiler(on: boolean)
	profiler = on and profilebegin ~= nil and profileend ~= nil
end

function Probes.dirtyCount(): number
	return dirtyN
end

-- Clears the dirty list and per-frame accumulators of every dirty probe. Returns script seconds.
function Probes.endFrame(): number
	for k = 1, dirtyN do
		local id = dirty[k]
		frameSelf[id] = 0
		frameTotal[id] = 0
		frameCalls[id] = 0
		touched[id] = false
	end
	dirtyN = 0
	local script = topTotal
	topTotal = 0
	return script
end

function Probes.scriptSeconds(): number
	return topTotal
end

-- Drops entries left open (an error inside a probed region). Returns how many were dropped.
function Probes.repair(): number
	local open = depth + overflow
	if open > 0 then
		misuse += open
		if profiler then
			for _ = 1, depth do
				(profileend :: any)()
			end
		end
		depth = 0
		overflow = 0
	end
	return open
end

function Probes.depth(): number
	return depth
end

function Probes.misuse(): number
	return misuse
end

function Probes.reset()
	Probes.endFrame()
	depth = 0
	overflow = 0
	misuse = 0
end

return Probes
