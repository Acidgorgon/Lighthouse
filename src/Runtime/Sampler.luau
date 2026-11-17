--!strict
--!optimize 2
-- Engine sampling and the frame loop.
--
-- Every frame (cheap reads only, no allocation):
--   client: RenderStepped dt -> Core.endFrame (frame time), Heartbeat dt kept as heartbeatDtMs
--   server: Heartbeat dt -> Core.endFrame
--   gcinfo() delta (positive part) accumulated as the garbage rate
-- Every second: Stats service properties, memory tags, ping, physics fps, quality level,
-- player count -> Core.setEngine(engine, memory, extra).
--
-- Every engine read is pcall'd. A property or method that errors (or is not a number) on
-- its first read is marked unsupported and never read again.

local Sampler = {}

-- Stats properties: engine key -> Stats property
local STATS_PROPS = {
	{ "heartbeatMs", "HeartbeatTimeMs" },
	{ "physicsMs", "PhysicsStepTimeMs" },
	{ "recvKbps", "DataReceiveKbps" },
	{ "sendKbps", "DataSendKbps" },
	{ "physicsRecvKbps", "PhysicsReceiveKbps" },
	{ "physicsSendKbps", "PhysicsSendKbps" },
	{ "instances", "InstanceCount" },
	{ "primitives", "PrimitivesCount" },
	{ "movingPrimitives", "MovingPrimitivesCount" },
	{ "contacts", "ContactsCount" },
}

Sampler.MEMORY_TAGS = {
	"LuaHeap",
	"Script",
	"Instances",
	"PhysicsCollision",
	"PhysicsParts",
	"GraphicsTexture",
	"GraphicsMeshParts",
	"Animation",
	"Gui",
	"Sounds",
	"Navigation",
}

type Ctx = {
	isServer: boolean,
	clock: () -> number,
	device: string?,
	onFrame: ((dt: number) -> ())?, -- after Core.endFrame, every frame
	onHeartbeat: ((now: number) -> ())?, -- every Heartbeat (both sides)
}

local Core: any = nil
local ctx: Ctx? = nil
local connections: { any } = {}

-- supported[key]: nil = not tried yet, true = works, false = missing (never read again)
local supported: { [string]: boolean } = {}
-- reads[key]: attempts per key (tests check missing ones are not retried)
Sampler.reads = {} :: { [string]: number }
local tagEnums: { [string]: any } = {}

local services: { [string]: any } = {}

local lastSample = -math.huge
local lastGc = 0
local gcAlloc = 0 -- KB allocated (positive gcinfo deltas) since the last sample
local heartbeatDt = 0

Sampler.engine = nil :: { [string]: number }?
Sampler.memory = nil :: any
Sampler.extra = nil :: any

local function getService(name: string): any
	local s = services[name]
	if s == nil then
		local ok, v = pcall(function()
			return game:GetService(name)
		end)
		s = if ok and v ~= nil then v else false
		services[name] = s
	end
	return if s == false then nil else s
end

local function getProp(obj: any, key: string): any
	return obj[key]
end

local function callMethod(obj: any, key: string, arg: any): any
	if arg == nil then
		return obj[key](obj)
	end
	return obj[key](obj, arg)
end

local function count(key: string)
	local reads = Sampler.reads
	reads[key] = (reads[key] or 0) + 1
end

local function isNum(v: any): boolean
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

-- Property read with the supported cache. `key` names the cache slot.
local function readProp(obj: any, prop: string, key: string): number?
	if obj == nil or supported[key] == false then
		return nil
	end
	count(key)
	local ok, v = pcall(getProp, obj, prop)
	if ok and isNum(v) then
		supported[key] = true
		return v
	end
	if supported[key] == nil then
		supported[key] = false
	end
	return nil
end

local function readCall(obj: any, method: string, arg: any, key: string): number?
	if obj == nil or supported[key] == false then
		return nil
	end
	count(key)
	local ok, v = pcall(callMethod, obj, method, arg)
	if ok and isNum(v) then
		supported[key] = true
		return v
	end
	if supported[key] == nil then
		supported[key] = false
	end
	return nil
end

local function tagEnum(tag: string): any
	local e = tagEnums[tag]
	if e == nil then
		local ok, v = pcall(function()
			return (Enum :: any).DeveloperMemoryTag[tag]
		end)
		e = if ok and v ~= nil then v else false
		tagEnums[tag] = e
	end
	return if e == false then nil else e
end

local function quality(): number?
	if supported.quality == false then
		return nil
	end
	count("quality")
	local ok, v = pcall(function()
		local level = (UserSettings :: any)().GameSettings.SavedQualityLevel
		if type(level) == "number" then
			return level
		end
		return level.Value
	end)
	if ok and isNum(v) then
		supported.quality = true
		return v
	end
	if supported.quality == nil then
		supported.quality = false
	end
	return nil
end

-- workspace:GetServerTimeNow(), or 0 when it is missing.
function Sampler.serverTime(): number
	return readCall(workspace, "GetServerTimeNow", nil, "GetServerTimeNow") or 0
end

-- One 1 Hz sample; pushes it to Core and returns engine, memory, extra.
function Sampler.sample(now: number): (any, any, any)
	local c = ctx
	local isServer = if c then c.isServer else true
	local stats = getService("Stats")
	local engine: { [string]: number } = {}
	for _, pair in STATS_PROPS do
		local v = readProp(stats, pair[2], pair[2])
		if v ~= nil then
			engine[pair[1]] = v
		end
	end
	local physicsFps = readCall(workspace, "GetRealPhysicsFPS", nil, "GetRealPhysicsFPS")
	if physicsFps ~= nil then
		engine.physicsFps = physicsFps
	end
	engine.heartbeatDtMs = heartbeatDt * 1000

	local players = getService("Players")
	if not isServer then
		local localPlayer = players and players.LocalPlayer
		local ping = readCall(localPlayer, "GetNetworkPing", nil, "GetNetworkPing")
		if ping ~= nil then
			engine.ping = ping * 1000
		end
		local q = quality()
		if q ~= nil then
			engine.quality = q
		end
	end

	local gc = gcinfo()
	local dt = now - lastSample
	local memory: any = { tags = {}, gcKb = gc }
	if dt > 0 and dt < math.huge then
		memory.gcKbPerSec = gcAlloc / dt
	else
		memory.gcKbPerSec = 0
	end
	gcAlloc = 0
	local total = readCall(stats, "GetTotalMemoryUsageMb", nil, "GetTotalMemoryUsageMb")
	if total ~= nil then
		memory.totalMb = total
	end
	for _, tag in Sampler.MEMORY_TAGS do
		local key = "tag:" .. tag
		if supported[key] ~= false then
			local e = tagEnum(tag)
			if e == nil then
				supported[key] = false
			else
				local mb = readCall(stats, "GetMemoryUsageMbForTag", e, key)
				if mb ~= nil then
					memory.tags[tag] = mb
				end
			end
		end
	end
	memory.luaHeapMb = memory.tags.LuaHeap or gc / 1024

	local playerCount = 0
	if players then
		local ok, list = pcall(function()
			return players:GetPlayers()
		end)
		if ok and type(list) == "table" then
			playerCount = #list
		end
	end
	local extra = {
		device = if c then c.device else nil,
		players = playerCount,
		serverTime = Sampler.serverTime, -- Core calls it at snapshot time
	}

	lastSample = now
	Sampler.engine = engine
	Sampler.memory = memory
	Sampler.extra = extra
	if Core then
		Core.setEngine(engine, memory, extra)
	end
	return engine, memory, extra
end

local function trackGc()
	local g = gcinfo()
	if g > lastGc then
		gcAlloc += g - lastGc
	end
	lastGc = g
end

function Sampler.start(core: any, context: Ctx)
	Sampler.stop()
	Core = core
	ctx = context
	local clock = context.clock
	local RunService = game:GetService("RunService")
	lastGc = gcinfo()
	gcAlloc = 0
	lastSample = clock()
	local onFrame = context.onFrame
	local onHeartbeat = context.onHeartbeat

	if context.isServer then
		table.insert(
			connections,
			RunService.Heartbeat:Connect(function(dt: number)
				local now = clock()
				heartbeatDt = dt
				core.endFrame(dt, now)
				trackGc()
				if onFrame then
					onFrame(dt)
				end
				if now - lastSample >= 1 then
					Sampler.sample(now)
				end
				if onHeartbeat then
					onHeartbeat(now)
				end
			end)
		)
	else
		table.insert(
			connections,
			RunService.RenderStepped:Connect(function(dt: number)
				core.endFrame(dt, clock())
				trackGc()
				if onFrame then
					onFrame(dt)
				end
			end)
		)
		table.insert(
			connections,
			RunService.Heartbeat:Connect(function(dt: number)
				local now = clock()
				heartbeatDt = dt
				if now - lastSample >= 1 then
					Sampler.sample(now)
				end
				if onHeartbeat then
					onHeartbeat(now)
				end
			end)
		)
	end
end

function Sampler.stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	ctx = nil
end

-- Whether an engine read is known to work (true), known missing (false) or untried (nil).
function Sampler.supported(key: string): boolean?
	return supported[key]
end

function Sampler.resetCache()
	table.clear(supported)
	table.clear(tagEnums)
	table.clear(services)
	table.clear(Sampler.reads)
end

return Sampler
