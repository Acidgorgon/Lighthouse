--!strict
-- Server side of the Lighthouse remote ("LighthouseR", created under the Lighthouse module).
--
--   * viewers: players allowed to see server numbers and open the overlay in live games
--     (opts.viewers: function(player) -> boolean | { userIds } | { group = id, rank = n };
--     default: the game's creator, or rank 255 in the owning group; everyone in Studio)
--   * HELLO from an allowed player -> reply HELLO(allowed = 1), then the name table and a
--     snapshot right away and every `stream` seconds after; non-viewers get nothing
--   * BYE stops the stream; REPORT goes to Telemetry
--   * every receive path validates and never throws (bad payloads are dropped and counted)

local Wire = require(script.Parent.Wire)
local Telemetry = require(script.Parent.Telemetry)

local Server = {}

local HELLO_PER_MINUTE = 4
local VIEWER_CACHE = 60 -- seconds a permission answer is reused

type Viewer = { namesSent: number }

local Core: any = nil
local opts: any = {}
local clock: () -> number = os.clock
local remote: any = nil
local connections: { any } = {}

local names = Wire.interner()
local viewers: { [any]: Viewer } = {}
local helloTokens: { [any]: number } = {}
local helloT: { [any]: number } = {}
local permission: { [any]: { allowed: boolean, at: number } } = {}
local streamAt = 0
local streamEvery = 1
local namesReset = false

Server.counters = {
	badType = 0,
	badSize = 0,
	badVersion = 0,
	badTag = 0,
	helloLimited = 0,
	denied = 0,
	errors = 0,
	snapshots = 0,
	bytesOut = 0,
}

local function getService(name: string): any
	local ok, s = pcall(function()
		return game:GetService(name)
	end)
	return if ok then s else nil
end

local function isStudio(): boolean
	local RunService = getService("RunService")
	local ok, v = pcall(function()
		return RunService:IsStudio()
	end)
	return ok and v == true
end

local function userId(player: any): number?
	local ok, id = pcall(function()
		return player.UserId
	end)
	return if ok and type(id) == "number" then id else nil
end

local function rankIn(player: any, group: number): number
	local ok, rank = pcall(function()
		return player:GetRankInGroup(group)
	end)
	return if ok and type(rank) == "number" then rank else 0
end

local function creatorIsGroup(): boolean
	local ok, v = pcall(function()
		return game.CreatorType == (Enum :: any).CreatorType.Group
	end)
	return ok and v == true
end

-- Whether `player` may view server numbers (uncached; may yield for group ranks).
function Server.checkViewer(player: any): boolean
	if isStudio() then
		return true
	end
	local rule = opts.viewers
	if type(rule) == "function" then
		local ok, v = pcall(rule, player)
		return ok and v == true
	elseif type(rule) == "table" then
		if type(rule.group) == "number" then
			local need = if type(rule.rank) == "number" then rule.rank else 1
			return rankIn(player, rule.group) >= need
		end
		local id = userId(player)
		return id ~= nil and table.find(rule, id) ~= nil
	end
	local creator = 0
	pcall(function()
		creator = game.CreatorId
	end)
	if type(creator) ~= "number" or creator <= 0 then
		return false
	end
	if creatorIsGroup() then
		return rankIn(player, creator) >= 255
	end
	return userId(player) == creator
end

function Server.isViewer(player: any, now: number?): boolean
	local t = now or clock()
	local cached = permission[player]
	if cached and t - cached.at < VIEWER_CACHE then
		return cached.allowed
	end
	local allowed = Server.checkViewer(player)
	permission[player] = { allowed = allowed, at = t }
	return allowed
end

-- Server snapshot with the telemetry aggregate attached as `reports`.
function Server.snapshot(): any
	local s = Core.snapshot("server")
	s.reports = Telemetry.aggregate()
	return s
end

local function fire(player: any, payload: buffer)
	local ok = pcall(function()
		remote:FireClient(player, payload)
	end)
	if ok then
		local n = buffer.len(payload)
		Server.counters.bytesOut += n
		Core.net("Lighthouse", "Stream", "out", n, player)
	end
end

-- Sends the snapshot (and any new names) to the listed viewers.
local function sendTo(list: { any }, s: any?)
	if remote == nil or #list == 0 then
		return
	end
	local snap = s or Server.snapshot()
	if #names.list > Wire.MAX_NAMES then
		names = Wire.interner()
		namesReset = true
	end
	if namesReset then
		for _, v in viewers do
			v.namesSent = 0
		end
		namesReset = false
	end
	local payload = Wire.encodeSnapshot(snap, names)
	local total = #names.list
	local namesPayload: buffer? = nil
	local namesFrom = -1
	for _, player in list do
		local v = viewers[player]
		if v then
			if v.namesSent < total then
				if namesFrom ~= v.namesSent then
					namesFrom = v.namesSent
					namesPayload = Wire.encodeNames(names.list, v.namesSent)
				end
				fire(player, namesPayload :: buffer)
				v.namesSent = total
			end
			fire(player, payload)
		end
	end
	Server.counters.snapshots += 1
	Server.lastPayload = payload
end
Server.lastPayload = nil :: buffer?

local function onPlayerRemoving(player: any)
	viewers[player] = nil
	helloTokens[player] = nil
	helloT[player] = nil
	permission[player] = nil
	Telemetry.forget(player)
end

-- false once the player has left (Player.Parent is nil after PlayerRemoving).
local function inGame(player: any): boolean
	local ok, parent = pcall(function()
		return player.Parent
	end)
	return ok and parent ~= nil
end

local function onHello(player: any, now: number)
	-- 4 hellos per minute per player (token bucket)
	local tokens = (helloTokens[player] or HELLO_PER_MINUTE) + (now - (helloT[player] or now)) * (HELLO_PER_MINUTE / 60)
	if tokens > HELLO_PER_MINUTE then
		tokens = HELLO_PER_MINUTE
	end
	helloT[player] = now
	if tokens < 1 then
		helloTokens[player] = tokens
		Server.counters.helloLimited += 1
		return
	end
	helloTokens[player] = tokens - 1
	-- may yield (GetRankInGroup, a custom viewers function): the player can leave meanwhile
	local allowed = Server.isViewer(player, now)
	if not inGame(player) then
		onPlayerRemoving(player) -- PlayerRemoving already ran: do not keep entries for them
		return
	end
	if not allowed then
		Server.counters.denied += 1
		return
	end
	if viewers[player] == nil then
		viewers[player] = { namesSent = 0 }
	end
	fire(player, Wire.encodeAllow(true))
	sendTo({ player }, nil)
end

local function onEvent(player: any, payload: any)
	local now = clock()
	if type(payload) ~= "buffer" then
		Server.counters.badType += 1
		Telemetry.drop()
		return
	end
	local n = buffer.len(payload)
	if n < 2 or n > Wire.MAX_IN then
		Server.counters.badSize += 1
		Telemetry.drop()
		return
	end
	Core.net("Lighthouse", "Control", "in", n, player)
	local version, tag = Wire.header(payload)
	if version ~= Wire.VERSION then
		Server.counters.badVersion += 1
		Telemetry.drop()
		return
	end
	if tag == Wire.REPORT then
		Telemetry.receive(player, payload, now)
	elseif tag == Wire.HELLO and n == 2 then
		onHello(player, now)
	elseif tag == Wire.BYE and n == 2 then
		viewers[player] = nil
	else
		Server.counters.badTag += 1
		Telemetry.drop()
	end
end

local function safeEvent(player: any, payload: any, ...)
	local ok, err = pcall(onEvent, player, payload)
	if not ok then
		Server.counters.errors += 1
		warn("Lighthouse: dropped a message: " .. tostring(err))
	end
end
Server.receive = safeEvent

function Server.configure(newOpts: any)
	opts = newOpts or {}
	local s = opts.stream
	streamEvery = if type(s) == "number" and s == s then math.clamp(s, 0.25, 60) else 1
	table.clear(permission) -- viewer rules may have changed
end

-- `telemetry` is a server option: clients learn sample / every from attributes on the remote
-- (Client reads them when its own start() has no `telemetry`). nil attributes = off.
local function publishTelemetry(cfg: any)
	pcall(function()
		remote:SetAttribute(Wire.ATTR_EVERY, if cfg.enabled then cfg.every else nil)
		remote:SetAttribute(Wire.ATTR_SAMPLE, if cfg.enabled then cfg.sample else nil)
	end)
end

function Server.start(core: any, newOpts: any, root: any, clockFn: () -> number)
	Core = core
	clock = clockFn
	Server.configure(newOpts)
	local telemetry = Telemetry.config(opts.telemetry)
	Telemetry.startServer(core, telemetry, clock())
	if #connections > 0 then
		publishTelemetry(telemetry)
		return -- already running: options applied above
	end
	local existing = root:FindFirstChild("LighthouseR")
	if existing then
		remote = existing
		publishTelemetry(telemetry)
	else
		remote = Instance.new("RemoteEvent")
		remote.Name = "LighthouseR"
		publishTelemetry(telemetry) -- before parenting: replicates with the remote
		remote.Parent = root
	end
	table.insert(connections, remote.OnServerEvent:Connect(safeEvent))
	local Players = getService("Players")
	if Players then
		table.insert(connections, Players.PlayerRemoving:Connect(onPlayerRemoving))
	end
	streamAt = clock() + streamEvery
end

-- Every Heartbeat: stream to viewers when due, HTTP export when due.
function Server.tick(now: number)
	if now >= streamAt then
		streamAt = now + streamEvery
		if next(viewers) ~= nil then
			local list = {}
			for player in viewers do
				table.insert(list, player)
			end
			local ok, err = pcall(sendTo, list, nil)
			if not ok then
				Server.counters.errors += 1
				warn("Lighthouse: stream error: " .. tostring(err))
			end
		end
	end
	Telemetry.serverTick(now)
end

function Server.stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(viewers)
	-- PlayerRemoving is disconnected too: drop per-player state now so players who leave while
	-- stopped are not kept forever (only resets rate limits and the permission cache)
	table.clear(helloTokens)
	table.clear(helloT)
	table.clear(permission)
	Telemetry.forgetAll()
	-- the remote stays: clients keep their reference across a restart
end

function Server.viewers(): { any }
	local list = {}
	for player in viewers do
		table.insert(list, player)
	end
	return list
end

function Server.remote(): any
	return remote
end

return Server
