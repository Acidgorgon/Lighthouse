--!strict
-- Lighthouse Runtime: everything that touches Roblox services. src/init.luau requires this
-- lazily and drives it:
--   Runtime.start(Core, opts)   idempotent: a second call applies the new opts, never reconnects
--   Runtime.stop()
--   Runtime.serverSnapshot()    server: Core.snapshot("server") + reports; client: last one received
--   Runtime.telemetry()         aggregate by device class (client: the copy streamed to viewers)
--   Runtime.onReport(fn)        server: fn(report) per accepted client report
--   Runtime.remote(remote)      RemoteEvent wrapper that counts bytes via Core.net
--   Runtime.overlay(on?)        client: show / hide / toggle the overlay
--
-- opts.clock (undocumented, tests): function returning seconds, used instead of os.clock for
-- scheduling (1 Hz sampling, streaming, reports, rate limits) and Core.endFrame's `now`.

local Sampler = require(script.Sampler)
local Device = require(script.Device)
local Telemetry = require(script.Telemetry)
local Server = require(script.Server)
local Client = require(script.Client)

local Runtime = {}

local started = false
local isServer = true
local Core: any = nil

Runtime.Sampler = Sampler
Runtime.Device = Device
Runtime.Telemetry = Telemetry
Runtime.Server = Server
Runtime.Client = Client
Runtime.Wire = require(script.Wire)

local function detectServer(): boolean
	local ok, v = pcall(function()
		return game:GetService("RunService"):IsServer()
	end)
	return ok and v == true
end

function Runtime.start(core: any, opts: any?)
	local o = opts or {}
	Core = core
	local clock: () -> number = if type(o.clock) == "function" then o.clock else os.clock
	local root = script.Parent
	if not started then
		isServer = detectServer()
	end
	local device = if isServer then nil else Device.get()
	if isServer then
		Server.start(core, o, root, clock)
	else
		Client.start(core, o, root, clock, device :: string)
	end
	if started then
		return -- options applied; the frame loop is already running
	end
	started = true
	Sampler.start(core, {
		isServer = isServer,
		clock = clock,
		device = device,
		onFrame = nil,
		onHeartbeat = if isServer then Server.tick else Client.tick,
	})
	Sampler.sample(clock())
end

function Runtime.stop()
	if not started then
		return
	end
	started = false
	Sampler.stop()
	if isServer then
		Server.stop()
	else
		Client.stop()
	end
end

function Runtime.isStarted(): boolean
	return started
end

function Runtime.serverSnapshot(): any
	if not started or Core == nil then
		return nil
	end
	if isServer then
		local ok, s = pcall(Server.snapshot)
		return if ok then s else nil
	end
	return Client.serverSnapshot()
end

function Runtime.telemetry(): any
	if isServer then
		return Telemetry.aggregate()
	end
	if not started then
		return nil
	end
	return Client.telemetry()
end

function Runtime.onReport(fn: (any) -> ())
	Telemetry.onReport(fn)
end

function Runtime.overlay(on: boolean?)
	if not started or isServer then
		return
	end
	Client.overlay(on)
end

--------------------------------------------------------------------------------
-- RemoteEvent wrapper
--------------------------------------------------------------------------------

local estimate: (any, number) -> number

local function estimateTable(t: any, depth: number): number
	if depth > 3 then
		return 16
	end
	local size = 2
	local n = 0
	for k, v in t do
		n += 1
		if n > 64 then
			-- extrapolate the rest instead of walking huge tables
			local per = size / 64
			local total = 0
			for _ in t do
				total += 1
			end
			return math.floor(per * total)
		end
		if type(k) ~= "number" then
			size += estimate(k, depth + 1)
		end
		size += estimate(v, depth + 1)
	end
	return size
end

-- Cheap size estimate of one remote argument (buffers and strings exact plus a header).
function estimate(v: any, depth: number): number
	local t = type(v)
	if t == "buffer" then
		return buffer.len(v) + 2
	elseif t == "string" then
		return #v + 2
	elseif t == "number" then
		return 9
	elseif t == "boolean" or t == "nil" then
		return 1
	elseif t == "vector" then
		return 13
	elseif t == "table" then
		local rt = typeof(v)
		if rt == "table" then
			return estimateTable(v, depth)
		elseif rt == "Instance" then
			return 5
		elseif rt == "CFrame" then
			return 25
		end
		return 9
	end
	local rt = typeof(v)
	if rt == "Vector3" then
		return 13
	elseif rt == "CFrame" then
		return 25
	elseif rt == "Instance" then
		return 5
	elseif rt == "EnumItem" then
		return 3
	elseif rt == "Color3" or rt == "Vector2" then
		return 9
	elseif rt == "UDim2" then
		return 17
	end
	return 9
end

local function sizeOf(...: any): number
	local size = 0
	for i = 1, select("#", ...) do
		size += estimate((select(i, ...)), 0)
	end
	return size
end
Runtime.sizeOf = sizeOf

local function counting(): any
	local c = Core
	if c ~= nil and started and c.isActive() then
		return c
	end
	return nil
end

-- Wraps a RemoteEvent: same Fire* methods and OnServerEvent/OnClientEvent:Connect, with bytes
-- counted under Core.net("Remote", remote.Name, dir, bytes, player?).
function Runtime.remote(remote: any): any
	local channel = tostring(remote.Name)
	local w = { Instance = remote, Name = channel }

	function w.FireServer(_self: any, ...: any)
		local c = counting()
		if c then
			c.net("Remote", channel, "out", sizeOf(...))
		end
		remote:FireServer(...)
	end

	function w.FireClient(_self: any, player: any, ...: any)
		local c = counting()
		if c then
			c.net("Remote", channel, "out", sizeOf(...), player)
		end
		remote:FireClient(player, ...)
	end

	function w.FireAllClients(_self: any, ...: any)
		local c = counting()
		if c then
			local bytes = sizeOf(...)
			local ok, players = pcall(function()
				return game:GetService("Players"):GetPlayers()
			end)
			if ok then
				for _, player in players do
					c.net("Remote", channel, "out", bytes, player)
				end
			end
		end
		remote:FireAllClients(...)
	end

	w.OnServerEvent = {
		Connect = function(_self: any, fn: (any, ...any) -> ())
			return remote.OnServerEvent:Connect(function(player: any, ...: any)
				local c = counting()
				if c then
					c.net("Remote", channel, "in", sizeOf(...), player)
				end
				fn(player, ...)
			end)
		end,
	}

	w.OnClientEvent = {
		Connect = function(_self: any, fn: (...any) -> ())
			return remote.OnClientEvent:Connect(function(...: any)
				local c = counting()
				if c then
					c.net("Remote", channel, "in", sizeOf(...))
				end
				fn(...)
			end)
		end,
	}

	return w
end

return Runtime
