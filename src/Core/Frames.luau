--!strict
--!native
--!optimize 2
-- Per-frame ring (default 600 frames): frame time, script time and the self time of every probe
-- that ran in that frame. Probe entries are stored sparsely, 8 bytes each, in one circular
-- buffer log (no table per frame). Also holds the explicit recording from Core.record(seconds).

local Frames = {}

local DEFAULT_CAP = 600
local MAX_RECORD_SECONDS = 120
local MAX_RECORD_ENTRIES = 1_000_000
local ENTRY = 8 -- bytes per probe entry: u32 id, f32 self ms

local cap = 0
local head = 0 -- frames written (logical index of the newest)
Frames.t = {} :: { number }
Frames.dt = {} :: { number }
Frames.script = {} :: { number }
Frames.cnt = {} :: { number } -- probe entries in the slot
Frames.pos = {} :: { number } -- entry index of the slot's first entry in `log`

-- Probe entries of all frames in the ring, as a circular log of contiguous per-frame records.
-- It grows (rarely, when more probes run per frame) so a record never overwrites a live one.
local logCap = 4096
Frames.log = buffer.create(logCap * ENTRY)
local wp = 0 -- next free entry

type Recording = {
	seconds: number,
	t0: number?,
	stop: number,
	done: boolean,
	t: { number },
	dt: { number },
	script: { number },
	start: { number },
	cnt: { number },
	ids: { number },
	vals: { number },
	entries: number,
}

local rec: Recording? = nil

function Frames.configure(n: number?)
	local want = math.clamp(math.floor(tonumber(n) or DEFAULT_CAP), 2, 36000)
	if want == cap then
		return
	end
	cap = want
	head = 0
	wp = 0
	Frames.t = table.create(cap, 0)
	Frames.dt = table.create(cap, 0)
	Frames.script = table.create(cap, 0)
	Frames.cnt = table.create(cap, 0)
	Frames.pos = table.create(cap, 0)
end

function Frames.capacity(): number
	return cap
end

function Frames.count(): number
	return math.min(head, cap)
end

-- Copies the live records (oldest first) into a bigger log.
local function grow(need: number, oldest: number, live: number)
	local total = 0
	for j = 0, live - 1 do
		total += Frames.cnt[(oldest + j - 1) % cap + 1]
	end
	local newCap = math.max(logCap * 2, (total + need) * 2)
	local newLog = buffer.create(newCap * ENTRY)
	local at = 0
	for j = 0, live - 1 do
		local i = (oldest + j - 1) % cap + 1
		local c = Frames.cnt[i]
		if c > 0 then
			buffer.copy(newLog, at * ENTRY, Frames.log, Frames.pos[i] * ENTRY, c * ENTRY)
		end
		Frames.pos[i] = at
		at += c
	end
	Frames.log = newLog
	logCap = newCap
	wp = at
end

-- Free entry index for a record of n entries, or nil when the log is too small. The write
-- position never catches up with the tail exactly, so wp == tail always means "empty".
local function place(n: number, tail: number?): number?
	if tail == nil then
		return if n < logCap then 0 else nil
	end
	if wp >= tail then
		if logCap - wp >= n then
			return wp
		end
		return if tail > n then 0 else nil
	end
	return if tail - wp > n then wp else nil
end

-- Starts a new frame slot with room for n probe entries. Returns (slot, first entry index):
-- the caller writes entry k at byte (first + k - 1) * 8 of Frames.log as u32 id, f32 ms (read
-- Frames.log after this call: it may have grown).
function Frames.push(frameMs: number, now: number, scriptMs: number, n: number): (number, number)
	head += 1
	local i = (head - 1) % cap + 1
	Frames.cnt[i] = 0 -- evicts the oldest frame when the ring is full
	local live = math.min(head - 1, cap - 1) -- records other than slot i
	local oldest = head - live -- logical index of the oldest live record
	local tail = if live > 0 then Frames.pos[(oldest - 1) % cap + 1] else nil
	local at = place(n, tail)
	if at == nil then
		grow(n, oldest, live)
		at = wp
	end
	Frames.t[i] = now
	Frames.dt[i] = frameMs
	Frames.script[i] = scriptMs
	Frames.pos[i] = at
	Frames.cnt[i] = n
	wp = at + n
	return i, at
end

-- Entry j (1-based) of ring slot i: (probe id, self ms).
function Frames.entry(i: number, j: number): (number, number)
	local o = (Frames.pos[i] + j - 1) * ENTRY
	return buffer.readu32(Frames.log, o), buffer.readf32(Frames.log, o + 4)
end

Frames.ENTRY = ENTRY

-- Last `n` frame times (ms), oldest first, into `into` (cleared).
function Frames.history(n: number, into: { number }?): { number }
	local out = into or table.create(n)
	table.clear(out)
	local have = math.min(head, cap, n)
	for j = have - 1, 0, -1 do
		local i = (head - 1 - j) % cap + 1
		table.insert(out, Frames.dt[i])
	end
	return out
end

-- Recording ------------------------------------------------------------------

function Frames.record(seconds: number)
	local s = math.clamp(tonumber(seconds) or 10, 0, MAX_RECORD_SECONDS)
	rec = {
		seconds = s,
		t0 = nil,
		stop = math.huge,
		done = false,
		t = {},
		dt = {},
		script = {},
		start = {},
		cnt = {},
		ids = {},
		vals = {},
		entries = 0,
	}
end

function Frames.recording(): boolean
	return rec ~= nil and not (rec :: Recording).done
end

-- Appends ring slot i to the active recording (called by Core.endFrame while recording).
function Frames.recordSlot(i: number)
	local r = rec
	if r == nil or r.done then
		return
	end
	local now = Frames.t[i]
	if r.t0 == nil then
		r.t0 = now
		r.stop = now + r.seconds
	end
	local f = #r.t + 1
	r.t[f] = now
	r.dt[f] = Frames.dt[i]
	r.script[f] = Frames.script[i]
	r.start[f] = r.entries
	local k = Frames.cnt[i]
	r.cnt[f] = k
	local e = r.entries
	for j = 1, k do
		local id, ms = Frames.entry(i, j)
		r.ids[e + j] = id
		r.vals[e + j] = ms
	end
	r.entries = e + k
	if now >= r.stop or r.entries >= MAX_RECORD_ENTRIES then
		r.done = true
	end
end

-- Column layout --------------------------------------------------------------

export type Columns = {
	source: string, -- "ring" | "record"
	done: boolean,
	t0: number,
	probes: { string },
	frames: {
		t: { number }, -- seconds since t0
		dt: { number }, -- frame ms
		script: { number }, -- script ms
		self: { { number } }, -- self[p][f] = ms of probes[p] in frame f
	},
}

local function build(source: string, done: boolean, n: number, getFrame: (f: number) -> (number, number, number, number), entry: (f: number, j: number) -> (number, number), names: { string }): Columns
	local t, dt, script = table.create(n), table.create(n), table.create(n)
	local colOf: { [number]: number } = {}
	local probes: { string } = {}
	local self: { { number } } = {}
	local t0 = 0
	for f = 1, n do
		local ft, fdt, fscript, k = getFrame(f)
		if f == 1 then
			t0 = ft
		end
		t[f] = ft - t0
		dt[f] = fdt
		script[f] = fscript
		for j = 1, k do
			local id, ms = entry(f, j)
			local col = colOf[id]
			if col == nil then
				col = #probes + 1
				colOf[id] = col
				probes[col] = names[id] or ("#" .. id)
				self[col] = table.create(n, 0)
			end
			self[col][f] = ms
		end
	end
	return {
		source = source,
		done = done,
		t0 = t0,
		probes = probes,
		frames = { t = t, dt = dt, script = script, self = self },
	}
end

-- Column layout of the explicit recording if one exists (and `seconds` is nil), else of the
-- ring's last `seconds` (all of it when nil). nil when there is nothing.
function Frames.columns(seconds: number?, names: { string }): Columns?
	local r = rec
	if seconds == nil and r ~= nil and #r.t > 0 then
		local ids, vals, start = r.ids, r.vals, r.start
		return build("record", r.done, #r.t, function(f)
			return r.t[f], r.dt[f], r.script[f], r.cnt[f]
		end, function(f, j)
			local e = start[f] + j
			return ids[e], vals[e]
		end, names)
	end
	local have = math.min(head, cap)
	if have == 0 then
		return nil
	end
	local newest = (head - 1) % cap + 1
	local n = have
	if seconds ~= nil then
		local tNew = Frames.t[newest]
		n = 0
		for j = 0, have - 1 do
			local i = (head - 1 - j) % cap + 1
			if tNew - Frames.t[i] > seconds then
				break
			end
			n += 1
		end
		if n == 0 then
			return nil
		end
	end
	local first = head - n -- logical index before the oldest included frame
	local function slotOf(f: number): number
		return (first + f - 1) % cap + 1
	end
	return build("ring", true, n, function(f)
		local i = slotOf(f)
		return Frames.t[i], Frames.dt[i], Frames.script[i], Frames.cnt[i]
	end, function(f, j)
		return Frames.entry(slotOf(f), j)
	end, names)
end

function Frames.reset()
	head = 0
	wp = 0
	rec = nil
end

Frames.configure(DEFAULT_CAP)

return Frames
