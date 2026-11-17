--!strict
--!native
--!optimize 2
-- Network channels keyed by (lib, channel, dir). Each call adds bytes and one packet to the
-- second in progress; a completed second becomes bytes/s and packets/s, and the last 10 seconds
-- give the peak. When a `who` key is passed (a Player on the server), bytes out are also kept per
-- key as a 10 s moving average for the "top senders" list.

local Net = {}

local PEAK_RING = 10
local WHO_DECAY = 0.9 -- per second: about a 10 s average

local active = false

local byLib: { [string]: { [string]: number } } = {}
local libOf: { string } = {}
local chanOf: { string } = {}
local dirOf: { string } = {}
local curBytes: { number } = {}
local curPackets: { number } = {}
local bps: { number } = {}
local pps: { number } = {}
local peaks: { { number } } = {}
local used: { boolean } = {}
local n = 0
local peakSlot = 1

local whoCur: { [any]: number } = {}
local whoRate: { [any]: number } = {}

local function newId(lib: string, channel: string, dir: string): number
	n += 1
	libOf[n] = lib
	chanOf[n] = channel
	dirOf[n] = dir
	curBytes[n] = 0
	curPackets[n] = 0
	bps[n] = 0
	pps[n] = 0
	peaks[n] = table.create(PEAK_RING, 0)
	used[n] = false
	return n
end

local function channelBase(lib: string, channel: string): number?
	local chans = byLib[lib]
	if chans == nil then
		if type(lib) ~= "string" then
			return nil
		end
		chans = {}
		byLib[lib] = chans
	end
	local base = chans[channel]
	if base == nil then
		if type(channel) ~= "string" then
			return nil
		end
		base = newId(lib, channel, "in")
		newId(lib, channel, "out")
		chans[channel] = base
	end
	return base
end

-- bytes on channel (lib, channel) in direction "in" | "out"; counts one packet per call.
function Net.net(lib: string, channel: string, dir: string, bytes: number, who: any?)
	if not active then
		return
	end
	if type(bytes) ~= "number" or not (bytes >= 0) or bytes == math.huge then
		return
	end
	local chans = byLib[lib]
	local base = if chans then chans[channel] else nil
	if base == nil then
		base = channelBase(lib, channel)
		if base == nil then
			return
		end
	end
	local id
	if dir == "out" then
		id = base + 1
		if who ~= nil then
			local cur = whoCur[who]
			whoCur[who] = (cur or 0) + bytes
		end
	elseif dir == "in" then
		id = base
	else
		return
	end
	curBytes[id] += bytes
	curPackets[id] += 1
	used[id] = true
end

function Net.roll(steps: number)
	local inv = 1 / math.max(steps, 1)
	for _ = 1, math.min(steps, PEAK_RING) do
		peakSlot = peakSlot % PEAK_RING + 1
		for id = 1, n do
			peaks[id][peakSlot] = 0
		end
	end
	for id = 1, n do
		local b = curBytes[id] * inv
		bps[id] = b
		pps[id] = curPackets[id] * inv
		peaks[id][peakSlot] = b
		curBytes[id] = 0
		curPackets[id] = 0
	end
	-- whoRate keys are a subset of whoCur keys; values are zeroed rather than removed so a
	-- steady sender never re-inserts its key. Quiet keys (players who left) are dropped.
	local decay = WHO_DECAY ^ steps
	for who, cur in whoCur do
		local r = (whoRate[who] or 0) * decay + (1 - decay) * cur * inv
		if cur == 0 and r < 0.5 then
			whoRate[who] = nil
			whoCur[who] = nil
		else
			whoRate[who] = r
			whoCur[who] = 0
		end
	end
end

export type Channel = { lib: string, channel: string, dir: string, bps: number, pps: number, avg: number, peak: number }

-- Channels with traffic in the last 10 s, grouped by lib then channel, "in" before "out".
function Net.list(): { Channel }
	local out = {}
	for id = 1, n do
		if used[id] then
			local peak = 0
			for _, v in peaks[id] do
				if v > peak then
					peak = v
				end
			end
			if peak > 0 or curBytes[id] > 0 then
				table.insert(out, {
					lib = libOf[id],
					channel = chanOf[id],
					dir = dirOf[id],
					bps = bps[id],
					pps = pps[id],
					avg = if pps[id] > 0 then bps[id] / pps[id] else 0,
					peak = peak,
				})
			end
		end
	end
	table.sort(out, function(a, b)
		if a.lib ~= b.lib then
			return a.lib < b.lib
		elseif a.channel ~= b.channel then
			return a.channel < b.channel
		end
		return a.dir < b.dir
	end)
	return out
end

-- Top `k` keys by bytes out per second (10 s moving average): { {who = tostring(key), bps} }.
function Net.top(k: number): { { who: string, bps: number } }
	local out = {}
	for who, rate in whoRate do
		table.insert(out, { who = tostring(who), bps = rate })
	end
	table.sort(out, function(a, b)
		return a.bps > b.bps
	end)
	for i = #out, k + 1, -1 do
		out[i] = nil
	end
	return out
end

function Net.setActive(on: boolean)
	active = on
end

function Net.reset()
	table.clear(byLib)
	table.clear(libOf)
	table.clear(chanOf)
	table.clear(dirOf)
	table.clear(curBytes)
	table.clear(curPackets)
	table.clear(bps)
	table.clear(pps)
	table.clear(peaks)
	table.clear(used)
	n = 0
	peakSlot = 1
	table.clear(whoCur)
	table.clear(whoRate)
end

return Net
