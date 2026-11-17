--!strict
--!native
--!optimize 2
-- Flares: frames over budget (and over 1.5x the 10 s median), kept with their top probes by
-- self time. The last 32 are stored in preallocated records, so a game that is over budget every
-- frame still allocates nothing here. onFlare listeners get a copy, at most 2 per second.

local Spikes = {}

local KEEP = 32
local TOP = 5
local MAX_PER_SECOND = 2

export type Flare = { t: number, frameMs: number, frame: number, top: { { name: string, ms: number } } }

type Record = {
	t: number,
	frameMs: number,
	frame: number,
	n: number,
	names: { string },
	ms: { number },
}

local records: { Record } = table.create(KEEP)
for i = 1, KEEP do
	records[i] = { t = 0, frameMs = 0, frame = 0, n = 0, names = table.create(TOP, ""), ms = table.create(TOP, 0) }
end
local head = 0 -- flares recorded so far
local cur: Record = records[1]

local listeners: { (Flare) -> () } = {}
local spawn: (fn: (Flare) -> (), flare: Flare) -> () = function(fn, flare)
	pcall(fn, flare)
end
local firedSecond = -math.huge
local fired = 0

function Spikes.setSpawn(fn: ((fn: (Flare) -> (), flare: Flare) -> ())?)
	spawn = fn or function(f, flare)
		pcall(f, flare)
	end
end

-- Starts a flare record for this frame.
function Spikes.begin(now: number, frameMs: number, frame: number)
	head += 1
	cur = records[(head - 1) % KEEP + 1]
	cur.t = now
	cur.frameMs = frameMs
	cur.frame = frame
	cur.n = 0
end

-- Offers a probe's self time for the current flare's top list (kept sorted, descending).
function Spikes.offer(name: string, ms: number)
	local r = cur
	local names, mss = r.names, r.ms
	local n = r.n
	if n == TOP and ms <= mss[TOP] then
		return
	end
	local pos = if n < TOP then n + 1 else TOP
	while pos > 1 and mss[pos - 1] < ms do
		names[pos] = names[pos - 1]
		mss[pos] = mss[pos - 1]
		pos -= 1
	end
	names[pos] = name
	mss[pos] = ms
	if n < TOP then
		r.n = n + 1
	end
end

local function copy(r: Record): Flare
	local top = table.create(r.n)
	for i = 1, r.n do
		top[i] = { name = r.names[i], ms = r.ms[i] }
	end
	return { t = r.t, frameMs = r.frameMs, frame = r.frame, top = top }
end

-- Finishes the current flare; notifies listeners unless 2 already fired this second.
function Spikes.commit(second: number)
	if #listeners == 0 then
		return
	end
	if second ~= firedSecond then
		firedSecond = second
		fired = 0
	end
	if fired >= MAX_PER_SECOND then
		return
	end
	fired += 1
	for _, fn in table.clone(listeners) do
		spawn(fn, copy(cur))
	end
end

-- Registers fn(flare). Returns a function that unregisters it.
function Spikes.onFlare(fn: (Flare) -> ()): () -> ()
	if type(fn) ~= "function" then
		return function() end
	end
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

-- Stored flares, newest first (copies).
function Spikes.list(): { Flare }
	local n = math.min(head, KEEP)
	local out = table.create(n)
	for j = 0, n - 1 do
		out[j + 1] = copy(records[(head - 1 - j) % KEEP + 1])
	end
	return out
end

function Spikes.count(): number
	return head
end

function Spikes.reset()
	head = 0
	cur = records[1]
	firedSecond = -math.huge
	fired = 0
	table.clear(listeners)
end

return Spikes
