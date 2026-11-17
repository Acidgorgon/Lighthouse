--!strict
--!optimize 2
-- Buffer codec for the Lighthouse remote ("LighthouseR").
--
-- Every payload starts with `u8 version, u8 tag`:
--   1 SNAPSHOT  server -> viewer   server Snapshot (names as u16 ids into the name table)
--   2 NAMES     server -> viewer   u16 first, u16 count, count x (u8 len, bytes); first = 0 resets
--   3 REPORT    client -> server   telemetry report (see encodeReport)
--   4 HELLO     client -> server   "I want to view"; server -> client: u8 allowed (1) reply
--   5 BYE       client -> server   "stop streaming to me"
--
-- Number encodings:
--   ms16  u16 milliseconds: 0.01 ms steps below 300 ms, 1 ms steps above (max ~35.5 s)
--   log8  u8 frame history: 0 = 0, else 0.02 ms * 1.05^(code - 1) (5% steps, max ~4.8 s)
--   f32   rates, sizes and gauges (non-finite written as 0, clamped to the f32 range)
--
-- Decoders never throw: reads past the end set a failure flag and return 0, and the
-- result is nil when the flag is set or the payload is not consumed exactly.

local Wire = {}

Wire.VERSION = 1
Wire.SNAPSHOT = 1
Wire.NAMES = 2
Wire.REPORT = 3
Wire.HELLO = 4
Wire.BYE = 5

-- Attributes on the remote: the server's telemetry `every` and `sample` (absent when off)
Wire.ATTR_EVERY = "LighthouseTelemetryEvery"
Wire.ATTR_SAMPLE = "LighthouseTelemetrySample"

Wire.MAX_IN = 2048 -- largest client -> server payload accepted
Wire.MAX_NAME = 64 -- bytes kept of a name in the server name table
Wire.MAX_REPORT_NAME = 48 -- bytes kept of a probe name in a client report
Wire.MAX_NAMES = 3000 -- name table entries before the server resets it

-- Section caps (keep a full snapshot near 1 KB typical, ~2 KB worst case).
Wire.CAP_HISTORY = 120
Wire.CAP_PROBES = 40
Wire.CAP_COUNTERS = 24
Wire.CAP_GAUGES = 16
Wire.CAP_NET = 24
Wire.CAP_TAGS = 16
Wire.CAP_FLARES = 8
Wire.CAP_FLARE_TOP = 5
Wire.CAP_DEVICES = 5
Wire.CAP_REPORT_PROBES = 5
Wire.CAP_NET_TOP = 5

Wire.DEVICES = { "Desktop", "Mobile", "Tablet", "Console", "VR" }
local DEVICE_ID: { [string]: number } = {}
for i, name in Wire.DEVICES do
	DEVICE_ID[name] = i
end

-- Engine keys carried in a snapshot (presence bitmask, f32 each).
Wire.ENGINE_KEYS = {
	"heartbeatMs",
	"physicsMs",
	"recvKbps",
	"sendKbps",
	"instances",
	"ping",
	"physicsFps",
	"physicsRecvKbps",
	"physicsSendKbps",
	"primitives",
	"movingPrimitives",
	"contacts",
	"quality",
	"heartbeatDtMs",
}
local MEMORY_KEYS = { "totalMb", "luaHeapMb", "gcKb", "gcKbPerSec" }
local FRAME_MS_KEYS = { "last", "avg1", "p50", "p95", "p99", "max10", "budget", "scriptMs" }

local F32_MAX = 3.4e38

local floor = math.floor
local log = math.log
local exp = math.exp
local bcreate = buffer.create
local blen = buffer.len
local bcopy = buffer.copy
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writeu32 = buffer.writeu32
local writef32 = buffer.writef32
local writef64 = buffer.writef64
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readu32 = buffer.readu32
local readf32 = buffer.readf32
local readf64 = buffer.readf64
local writestring = buffer.writestring
local readstring = buffer.readstring

--------------------------------------------------------------------------------
-- Number helpers
--------------------------------------------------------------------------------

local function finite(v: any): number
	if type(v) ~= "number" or v ~= v then
		return 0
	end
	if v > F32_MAX then
		return F32_MAX
	elseif v < -F32_MAX then
		return -F32_MAX
	end
	return v
end
Wire.finite = finite

function Wire.ms16(ms: any): number
	ms = finite(ms)
	if ms <= 0 then
		return 0
	elseif ms < 300 then
		return floor(ms * 100 + 0.5)
	end
	local v = 30000 + floor(ms - 300 + 0.5)
	return if v > 65535 then 65535 else v
end

function Wire.unms16(v: number): number
	if v <= 30000 then
		return v / 100
	end
	return 300 + (v - 30000)
end

local LOG_BASE = log(1.05)
function Wire.log8(ms: any): number
	ms = finite(ms)
	if ms <= 0 then
		return 0
	end
	local c = floor(log(ms / 0.02) / LOG_BASE + 0.5) + 1
	if c < 1 then
		return 1
	elseif c > 255 then
		return 255
	end
	return c
end

function Wire.unlog8(c: number): number
	if c == 0 then
		return 0
	end
	return 0.02 * exp((c - 1) * LOG_BASE)
end

local ms16 = Wire.ms16
local unms16 = Wire.unms16

function Wire.deviceId(name: any): number
	return DEVICE_ID[name] or 1
end

function Wire.deviceName(id: number): string?
	return Wire.DEVICES[id]
end

--------------------------------------------------------------------------------
-- Writer (one growing scratch buffer; take() copies out the written bytes)
--------------------------------------------------------------------------------

local wb = bcreate(4096)
local wcap = 4096
local wpos = 0

local function ensure(n: number)
	if wpos + n > wcap then
		local size = wcap
		while wpos + n > size do
			size *= 2
		end
		local nb = bcreate(size)
		bcopy(nb, 0, wb, 0, wpos)
		wb = nb
		wcap = size
	end
end

local function wu8(v: number)
	ensure(1)
	writeu8(wb, wpos, v)
	wpos += 1
end

local function wu16(v: number)
	ensure(2)
	writeu16(wb, wpos, v)
	wpos += 2
end

local function wu32(v: number)
	ensure(4)
	writeu32(wb, wpos, v)
	wpos += 4
end

local function wf32(v: any)
	ensure(4)
	writef32(wb, wpos, finite(v))
	wpos += 4
end

local function wf64(v: any)
	ensure(8)
	local n = if type(v) == "number" and v == v and v > -math.huge and v < math.huge then v else 0
	writef64(wb, wpos, n)
	wpos += 8
end

local function wms(v: any)
	wu16(ms16(v))
end

local function clampInt(v: any, hi: number): number
	v = finite(v)
	if v <= 0 then
		return 0
	end
	v = floor(v + 0.5)
	return if v > hi then hi else v
end

local function wstr(s: string, max: number)
	local n = #s
	if n > max then
		n = max
	end
	wu8(n)
	ensure(n)
	writestring(wb, wpos, s, n)
	wpos += n
end

local function begin(tag: number)
	wpos = 0
	wu8(Wire.VERSION)
	wu8(tag)
end

local function take(): buffer
	local out = bcreate(wpos)
	bcopy(out, 0, wb, 0, wpos)
	return out
end

--------------------------------------------------------------------------------
-- Reader (bounds checked; a short read sets `bad` and returns 0)
--------------------------------------------------------------------------------

local rb: buffer = bcreate(0)
local rpos = 0
local rlen = 0
local bad = false

local function open(b: buffer)
	rb = b
	rpos = 0
	rlen = blen(b)
	bad = false
end

local function has(n: number): boolean
	if bad or rpos + n > rlen then
		bad = true
		return false
	end
	return true
end

local function ru8(): number
	if not has(1) then
		return 0
	end
	local v = readu8(rb, rpos)
	rpos += 1
	return v
end

local function ru16(): number
	if not has(2) then
		return 0
	end
	local v = readu16(rb, rpos)
	rpos += 2
	return v
end

local function ru32(): number
	if not has(4) then
		return 0
	end
	local v = readu32(rb, rpos)
	rpos += 4
	return v
end

local function rf32(): number
	if not has(4) then
		return 0
	end
	local v = readf32(rb, rpos)
	rpos += 4
	if v ~= v or v == math.huge or v == -math.huge then
		return 0
	end
	return v
end

local function rf64(): number
	if not has(8) then
		return 0
	end
	local v = readf64(rb, rpos)
	rpos += 8
	if v ~= v or v == math.huge or v == -math.huge then
		return 0
	end
	return v
end

local function rms(): number
	return unms16(ru16())
end

local function rstr(): string
	local n = ru8()
	if not has(n) then
		return ""
	end
	local s = readstring(rb, rpos, n)
	rpos += n
	return s
end

local function done(): boolean
	return not bad and rpos == rlen
end

-- Version and tag of a payload, or nil if it is not a Lighthouse buffer.
function Wire.header(b: any): (number?, number?)
	if type(b) ~= "buffer" or blen(b) < 2 then
		return nil, nil
	end
	return readu8(b, 0), readu8(b, 1)
end

--------------------------------------------------------------------------------
-- Name table (server side interner, client side list)
--------------------------------------------------------------------------------

export type Interner = { list: { string }, ids: { [string]: number } }

function Wire.interner(): Interner
	return { list = {}, ids = {} }
end

function Wire.intern(t: Interner, name: any): number
	if type(name) ~= "string" then
		name = tostring(name)
	end
	if #name > Wire.MAX_NAME then
		name = string.sub(name, 1, Wire.MAX_NAME)
	end
	local id = t.ids[name]
	if id == nil then
		id = #t.list + 1
		if id > 65535 then
			return 0
		end
		t.list[id] = name
		t.ids[name] = id
	end
	return id
end

-- Names list[first + 1 .. #list] (first = 0 means "replace the whole table").
function Wire.encodeNames(list: { string }, first: number): buffer
	begin(Wire.NAMES)
	local count = #list - first
	if count < 0 then
		count = 0
	end
	wu16(first)
	wu16(count)
	for i = first + 1, first + count do
		wstr(list[i], Wire.MAX_NAME)
	end
	return take()
end

-- Applies a NAMES payload to `list`; false if it is malformed or out of order.
function Wire.decodeNames(b: any, list: { string }): boolean
	if type(b) ~= "buffer" then
		return false
	end
	open(b)
	if ru8() ~= Wire.VERSION or ru8() ~= Wire.NAMES then
		return false
	end
	local first = ru16()
	local count = ru16()
	if bad or first > #list or count * 1 > rlen then
		return false
	end
	local names = table.create(count)
	for i = 1, count do
		names[i] = rstr()
	end
	if not done() then
		return false
	end
	if first == 0 then
		table.clear(list)
	else
		for i = #list, first + 1, -1 do
			list[i] = nil
		end
	end
	for i = 1, count do
		list[first + i] = names[i]
	end
	return true
end

--------------------------------------------------------------------------------
-- Snapshot (server -> viewer)
--------------------------------------------------------------------------------

local function capOf(list: any, cap: number): number
	if type(list) ~= "table" then
		return 0
	end
	local n = #list
	return if n > cap then cap else n
end

local function field(t: any, key: string): any
	if type(t) ~= "table" then
		return nil
	end
	return t[key]
end

local function writeReports(rep: any, names: Interner)
	if type(rep) ~= "table" or type(rep.devices) ~= "table" then
		wu8(0)
		return
	end
	local n = capOf(rep.devices, Wire.CAP_DEVICES)
	wu8(n + 1) -- 0 = no section; else devices + 1
	wu32(clampInt(rep.reports, 4294967295))
	wu16(clampInt(rep.players, 65535))
	wu32(clampInt(rep.dropped, 4294967295))
	for i = 1, n do
		local d = rep.devices[i]
		wu8(Wire.deviceId(field(d, "device")))
		wu16(clampInt(field(d, "players"), 65535))
		wu32(clampInt(field(d, "reports"), 4294967295))
		wms(field(d, "frameP50"))
		wms(field(d, "frameP95"))
		wms(field(d, "frameP99"))
		wms(field(d, "scriptP50"))
		wf32(field(d, "memoryMb"))
		wf32(field(d, "heapMb"))
		wms(field(d, "pingMs"))
		wu8(clampInt(finite(field(d, "quality")) * 20, 255))
		local probes = field(d, "probes")
		local np = capOf(probes, Wire.CAP_REPORT_PROBES)
		wu8(np)
		for j = 1, np do
			local p = probes[j]
			wu16(Wire.intern(names, field(p, "name") or "?"))
			wms(field(p, "ms"))
		end
	end
end

local function nameOf(list: { string }, id: number): string
	return list[id] or "?"
end

local function readReports(list: { string }): any
	local n = ru8()
	if n == 0 then
		return nil
	end
	n -= 1
	if n > Wire.CAP_DEVICES then
		bad = true
		return nil
	end
	local rep = { reports = ru32(), players = ru16(), dropped = ru32(), devices = table.create(n) }
	for i = 1, n do
		local d: any = {
			device = Wire.deviceName(ru8()) or "Desktop",
			players = ru16(),
			reports = ru32(),
			frameP50 = rms(),
			frameP95 = rms(),
			frameP99 = rms(),
			scriptP50 = rms(),
			memoryMb = rf32(),
			heapMb = rf32(),
			pingMs = rms(),
			quality = ru8() / 20,
		}
		local np = ru8()
		if np > Wire.CAP_REPORT_PROBES then
			bad = true
			return nil
		end
		local probes = table.create(np)
		for j = 1, np do
			probes[j] = { name = nameOf(list, ru16()), ms = rms() }
		end
		d.probes = probes
		rep.devices[i] = d
	end
	return rep
end

-- Encodes a Snapshot. Interns every name into `names` first: send the new part of the
-- name table (encodeNames) before this payload.
function Wire.encodeSnapshot(s: any, names: Interner): buffer
	begin(Wire.SNAPSHOT)
	local t = finite(s.t)
	wf64(t)
	wf64(s.serverTime)
	wu8(if s.side == "client" then 1 else 2)
	wu8(Wire.deviceId(s.device))
	wu16(clampInt(s.players, 65535))
	wu16(clampInt(s.misuse, 65535))

	local frame = s.frame or {}
	for _, key in FRAME_MS_KEYS do
		wms(frame[key])
	end
	wu16(clampInt(finite(frame.fps) * 10, 65535))
	local history = frame.history
	local nh = capOf(history, Wire.CAP_HISTORY)
	wu8(nh)
	local h0 = if type(history) == "table" then #history - nh else 0
	for i = 1, nh do
		wu8(Wire.log8(history[h0 + i]))
	end

	local probes = s.probes
	local np = capOf(probes, Wire.CAP_PROBES)
	wu8(np)
	for i = 1, np do
		local p = probes[i]
		wu16(Wire.intern(names, field(p, "name") or "?"))
		wms(field(p, "selfAvg"))
		wms(field(p, "selfP95"))
		wms(field(p, "selfMax"))
		wms(field(p, "totalAvg"))
		wf32(field(p, "calls"))
	end

	local counters = s.counters
	local nc = capOf(counters, Wire.CAP_COUNTERS)
	wu8(nc)
	for i = 1, nc do
		local c = counters[i]
		wu16(Wire.intern(names, field(c, "name") or "?"))
		wf32(field(c, "perSec"))
	end

	local gauges = s.gauges
	local ng = capOf(gauges, Wire.CAP_GAUGES)
	wu8(ng)
	for i = 1, ng do
		local g = gauges[i]
		wu16(Wire.intern(names, field(g, "name") or "?"))
		wf32(field(g, "value"))
		wf32(field(g, "min"))
		wf32(field(g, "max"))
	end

	local net = s.net
	local nn = capOf(net, Wire.CAP_NET)
	wu8(nn)
	for i = 1, nn do
		local c = net[i]
		wu16(Wire.intern(names, field(c, "lib") or "?"))
		wu16(Wire.intern(names, field(c, "channel") or "?"))
		wu8(if field(c, "dir") == "in" then 1 else 2)
		wf32(field(c, "bps"))
		wf32(field(c, "pps"))
		wf32(field(c, "avg"))
		wf32(field(c, "peak"))
	end

	local memory = s.memory
	local mask = 0
	for i, key in MEMORY_KEYS do
		if type(field(memory, key)) == "number" then
			mask += 2 ^ (i - 1)
		end
	end
	wu8(mask)
	for i, key in MEMORY_KEYS do
		if mask // 2 ^ (i - 1) % 2 == 1 then
			wf32(memory[key])
		end
	end
	local tags = field(memory, "tags")
	local ntags = 0
	if type(tags) == "table" then
		for _ in tags do
			ntags += 1
		end
	end
	if ntags > Wire.CAP_TAGS then
		ntags = Wire.CAP_TAGS
	end
	wu8(ntags)
	if ntags > 0 then
		local k = 0
		for tag, mb in tags do
			if k >= ntags then
				break
			end
			k += 1
			wu16(Wire.intern(names, tag))
			wf32(mb)
		end
	end

	local engine = s.engine
	local emask = 0
	for i, key in Wire.ENGINE_KEYS do
		if type(field(engine, key)) == "number" then
			emask += 2 ^ (i - 1)
		end
	end
	wu16(emask)
	for i, key in Wire.ENGINE_KEYS do
		if emask // 2 ^ (i - 1) % 2 == 1 then
			wf32(engine[key])
		end
	end

	local flares = s.flares
	local nf = capOf(flares, Wire.CAP_FLARES) -- newest first: keep the first nf
	wu8(nf)
	for i = 1, nf do
		local f = flares[i]
		wf32(t - finite(field(f, "t")))
		wms(field(f, "frameMs"))
		local top = field(f, "top")
		local nt = capOf(top, Wire.CAP_FLARE_TOP)
		wu8(nt)
		for j = 1, nt do
			local e = top[j]
			wu16(Wire.intern(names, field(e, "name") or "?"))
			wms(field(e, "ms"))
		end
	end

	wu32(clampInt(s.frames, 4294967295))
	local netTop = s.netTop
	local nt = capOf(netTop, Wire.CAP_NET_TOP)
	wu8(nt)
	for i = 1, nt do
		local e = netTop[i]
		wu16(Wire.intern(names, tostring(field(e, "who") or "?")))
		wf32(field(e, "bps"))
	end

	writeReports(s.reports, names)
	return take()
end

-- Decodes a SNAPSHOT payload with the name list; nil if malformed.
function Wire.decodeSnapshot(b: any, list: { string }): any
	if type(b) ~= "buffer" then
		return nil
	end
	open(b)
	if ru8() ~= Wire.VERSION or ru8() ~= Wire.SNAPSHOT then
		return nil
	end
	local t = rf64()
	local s: any = {
		v = 1,
		t = t,
		serverTime = rf64(),
		side = if ru8() == 1 then "client" else "server",
		device = Wire.deviceName(ru8()) or "Desktop",
		players = ru16(),
		misuse = ru16(),
	}
	local frame: any = {}
	for _, key in FRAME_MS_KEYS do
		frame[key] = rms()
	end
	frame.fps = ru16() / 10
	local nh = ru8()
	if not has(nh) then
		return nil
	end
	local history = table.create(nh)
	for i = 1, nh do
		history[i] = Wire.unlog8(ru8())
	end
	frame.history = history
	s.frame = frame

	local np = ru8()
	if not has(np * 14) then
		return nil
	end
	local probes = table.create(np)
	for i = 1, np do
		probes[i] = {
			name = nameOf(list, ru16()),
			selfAvg = rms(),
			selfP95 = rms(),
			selfMax = rms(),
			totalAvg = rms(),
			calls = rf32(),
		}
	end
	s.probes = probes

	local nc = ru8()
	if not has(nc * 6) then
		return nil
	end
	local counters = table.create(nc)
	for i = 1, nc do
		counters[i] = { name = nameOf(list, ru16()), perSec = rf32() }
	end
	s.counters = counters

	local ng = ru8()
	if not has(ng * 14) then
		return nil
	end
	local gauges = table.create(ng)
	for i = 1, ng do
		gauges[i] = { name = nameOf(list, ru16()), value = rf32(), min = rf32(), max = rf32() }
	end
	s.gauges = gauges

	local nn = ru8()
	if not has(nn * 21) then
		return nil
	end
	local net = table.create(nn)
	for i = 1, nn do
		net[i] = {
			lib = nameOf(list, ru16()),
			channel = nameOf(list, ru16()),
			dir = if ru8() == 1 then "in" else "out",
			bps = rf32(),
			pps = rf32(),
			avg = rf32(),
			peak = rf32(),
		}
	end
	s.net = net

	local memory: any = {}
	local mask = ru8()
	for i, key in MEMORY_KEYS do
		if mask // 2 ^ (i - 1) % 2 == 1 then
			memory[key] = rf32()
		end
	end
	local tags = {}
	local ntags = ru8()
	if ntags > Wire.CAP_TAGS then
		return nil
	end
	for _ = 1, ntags do
		local name = nameOf(list, ru16())
		tags[name] = rf32()
	end
	memory.tags = tags
	s.memory = memory

	local engine: any = {}
	local emask = ru16()
	for i, key in Wire.ENGINE_KEYS do
		if emask // 2 ^ (i - 1) % 2 == 1 then
			engine[key] = rf32()
		end
	end
	s.engine = engine

	local nf = ru8()
	if nf > Wire.CAP_FLARES then
		return nil
	end
	local flares = table.create(nf)
	for i = 1, nf do
		local ft = t - rf32()
		local frameMs = rms()
		local nt = ru8()
		if nt > Wire.CAP_FLARE_TOP then
			return nil
		end
		local top = table.create(nt)
		for j = 1, nt do
			top[j] = { name = nameOf(list, ru16()), ms = rms() }
		end
		flares[i] = { t = ft, frameMs = frameMs, top = top }
	end
	s.flares = flares

	s.frames = ru32()
	local nt = ru8()
	if nt > Wire.CAP_NET_TOP then
		return nil
	end
	local netTop = table.create(nt)
	for i = 1, nt do
		netTop[i] = { who = nameOf(list, ru16()), bps = rf32() }
	end
	s.netTop = netTop

	s.reports = readReports(list)
	if not done() then
		return nil
	end
	return s
end

--------------------------------------------------------------------------------
-- Report (client -> server)
--------------------------------------------------------------------------------

export type Report = {
	device: string,
	quality: number?,
	pingMs: number,
	memoryMb: number,
	heapMb: number,
	frameP50: number,
	frameP95: number,
	frameP99: number,
	scriptP50: number,
	frames: number,
	frameHist: any?, -- Core Histogram (frame ms over the report window)
	scriptHist: any?, -- Core Histogram (script ms per frame)
	probes: { { name: string, ms: number } },
}

-- Histogram blobs are Core Histogram:encode() buffers (u16 length prefix, 0 = none).
local function wblob(blob: buffer?)
	if blob == nil then
		wu16(0)
		return
	end
	local n = blen(blob)
	if n > 1024 then
		wu16(0)
		return
	end
	wu16(n)
	ensure(n)
	bcopy(wb, wpos, blob, 0, n)
	wpos += n
end

function Wire.encodeReport(r: any, frameHist: buffer?, scriptHist: buffer?): buffer
	begin(Wire.REPORT)
	wu8(Wire.deviceId(r.device))
	local q = r.quality
	wu8(if type(q) == "number" and q == q then clampInt(q, 10) else 255)
	wms(r.pingMs)
	wu16(clampInt(r.memoryMb, 65535))
	wu16(clampInt(finite(r.heapMb) * 10, 65535))
	wms(r.frameP50)
	wms(r.frameP95)
	wms(r.frameP99)
	wms(r.scriptP50)
	wu16(clampInt(r.frames, 65535))
	wblob(frameHist)
	wblob(scriptHist)
	local probes = r.probes
	local np = capOf(probes, Wire.CAP_REPORT_PROBES)
	wu8(np)
	for i = 1, np do
		local p = probes[i]
		local name = field(p, "name")
		wstr(if type(name) == "string" then name else "?", Wire.MAX_REPORT_NAME)
		wms(field(p, "ms"))
	end
	return take()
end

local function cleanName(s: string): string?
	if #s == 0 or utf8.len(s) == nil or string.find(s, "%c") then
		return nil
	end
	return s
end

-- Reads a length-prefixed histogram blob into a fresh histogram from `newHist`.
-- false if malformed; true with nil when absent.
local function rblob(newHist: (() -> any)?): (boolean, any)
	local n = ru16()
	if bad or not has(n) then
		return false, nil
	end
	if n == 0 then
		return true, nil
	end
	local start = rpos
	rpos += n
	if newHist == nil then
		return true, nil
	end
	local h = newHist()
	local okCall, ok, nextOffset = pcall(h.decode, h, rb, start)
	if not okCall or ok ~= true or nextOffset ~= start + n then
		return false, nil
	end
	return true, h
end

-- Validates and decodes a REPORT from an untrusted client. nil if anything is off.
-- `newHist` creates an empty Core histogram (its :decode(b, offset) validates the blob).
function Wire.decodeReport(b: any, newHist: (() -> any)?): Report?
	if type(b) ~= "buffer" then
		return nil
	end
	local n = blen(b)
	if n < 2 or n > Wire.MAX_IN then
		return nil
	end
	open(b)
	if ru8() ~= Wire.VERSION or ru8() ~= Wire.REPORT then
		return nil
	end
	local device = Wire.deviceName(ru8())
	if device == nil then
		return nil
	end
	local q = ru8()
	local quality: number? = nil
	if q <= 10 then
		quality = q
	elseif q ~= 255 then
		return nil
	end
	local r: any = {
		device = device,
		quality = quality,
		pingMs = rms(),
		memoryMb = ru16(),
		heapMb = ru16() / 10,
		frameP50 = rms(),
		frameP95 = rms(),
		frameP99 = rms(),
		scriptP50 = rms(),
		frames = ru16(),
	}
	local okF, frameHist = rblob(newHist)
	if not okF then
		return nil
	end
	local okS, scriptHist = rblob(newHist)
	if not okS then
		return nil
	end
	r.frameHist = frameHist
	r.scriptHist = scriptHist
	local np = ru8()
	if np > Wire.CAP_REPORT_PROBES then
		return nil
	end
	local probes = table.create(np)
	for i = 1, np do
		local name = rstr()
		local ms = rms()
		if bad or #name > Wire.MAX_REPORT_NAME then
			return nil
		end
		local clean = cleanName(name)
		if clean == nil then
			return nil
		end
		probes[i] = { name = clean, ms = ms }
	end
	r.probes = probes
	if not done() then
		return nil
	end
	return r
end

--------------------------------------------------------------------------------
-- Small messages
--------------------------------------------------------------------------------

function Wire.encodeHello(): buffer
	begin(Wire.HELLO)
	return take()
end

function Wire.encodeBye(): buffer
	begin(Wire.BYE)
	return take()
end

-- Server -> client reply to HELLO.
function Wire.encodeAllow(allowed: boolean): buffer
	begin(Wire.HELLO)
	wu8(if allowed then 1 else 0)
	return take()
end

function Wire.decodeAllow(b: any): boolean?
	if type(b) ~= "buffer" or blen(b) ~= 3 then
		return nil
	end
	if readu8(b, 0) ~= Wire.VERSION or readu8(b, 1) ~= Wire.HELLO then
		return nil
	end
	return readu8(b, 2) == 1
end

return Wire
