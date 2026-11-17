--!strict
-- Player telemetry: what real players' devices see.
--
-- Client: in the sample with probability `sample` (decided once per session). Every `every`
-- seconds a sampled client sends a REPORT: device class, frame and script histograms over the
-- largest Core window that fits in `every` (so reports never double count frames), frame
-- p50/p95/p99, script p50, memory, Luau heap, ping, quality level and its top 5 probes.
--
-- Server: validates (Wire.decodeReport, rate limited per player), merges the histograms per
-- device class so percentiles stay real, calls onReport callbacks, optionally logs
-- AnalyticsService custom events (low-cardinality fields, rate limited) and POSTs the aggregate
-- JSON with HttpService. Nothing here throws on bad input.

local Wire = require(script.Parent.Wire)
local Sampler = require(script.Parent.Sampler)

local Telemetry = {}

export type Config = {
	enabled: boolean,
	sample: number,
	every: number,
	analytics: boolean,
	http: { url: string, every: number }?,
}

local DEFAULTS = { sample = 0.1, every = 60, analytics = true }
local MIN_EVERY = 5
local MAX_EVERY = 3600
local MAX_PROBE_NAMES = 64 -- distinct probe names kept per device class
local ANALYTICS_PER_MINUTE = 60 -- events per minute for the whole server
local ANALYTICS_MIN_GAP = 60 -- seconds between event batches per player

local function clampNum(v: any, lo: number, hi: number, default: number): number
	if type(v) ~= "number" or v ~= v then
		return default
	end
	return math.clamp(v, lo, hi)
end

-- telemetry option: false | true | { sample, every, analytics, http } -> Config
function Telemetry.config(opt: any): Config
	if opt == nil or opt == false then
		return { enabled = false, sample = 0, every = DEFAULTS.every, analytics = false, http = nil }
	end
	local t = if type(opt) == "table" then opt else {}
	local http = nil
	if type(t.http) == "table" and type(t.http.url) == "string" then
		http = { url = t.http.url, every = clampNum(t.http.every, 30, 86400, 300) }
	elseif type(t.http) == "string" then
		http = { url = t.http, every = 300 }
	end
	return {
		enabled = true,
		sample = clampNum(t.sample, 0, 1, DEFAULTS.sample),
		every = clampNum(t.every, MIN_EVERY, MAX_EVERY, DEFAULTS.every),
		analytics = if t.analytics == nil then DEFAULTS.analytics else t.analytics == true,
		http = http,
	}
end

local function getService(name: string): any
	local ok, s = pcall(function()
		return game:GetService(name)
	end)
	return if ok then s else nil
end

-- Largest Core window (1, 10, 60 s) not longer than `every`.
function Telemetry.windowFor(every: number): number
	if every >= 60 then
		return 60
	elseif every >= 10 then
		return 10
	end
	return 1
end

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------

local client = {
	cfg = nil :: Config?,
	sampled = nil :: boolean?, -- decided once per session
	nextAt = math.huge,
	frameHist = nil :: any,
	scriptHist = nil :: any,
	sent = 0,
}
Telemetry.client = client

function Telemetry.startClient(Core: any, cfg: Config, now: number, roll: number?)
	client.cfg = cfg
	if not cfg.enabled then
		client.nextAt = math.huge
		return
	end
	if client.sampled == nil then
		client.sampled = (roll or math.random()) < cfg.sample
	end
	if client.frameHist == nil then
		client.frameHist = Core.histogram()
		client.scriptHist = Core.histogram()
	end
	client.nextAt = if client.sampled then now + cfg.every else math.huge
end

-- Builds a report table and the encoded payload from Core and the last engine sample.
function Telemetry.buildReport(Core: any, device: string, window: number): (any, buffer)
	local fh = Core.frameHistogram(window, client.frameHist)
	local sh = Core.scriptHistogram(window, client.scriptHist)
	client.frameHist = fh
	client.scriptHist = sh
	local engine = Sampler.engine or {}
	local memory = Sampler.memory or {}
	local probes = {}
	local ok, snap = pcall(Core.snapshot, "client")
	if ok and type(snap) == "table" and type(snap.probes) == "table" then
		for i = 1, math.min(#snap.probes, Wire.CAP_REPORT_PROBES) do
			local p = snap.probes[i]
			probes[i] = { name = p.name, ms = p.selfAvg }
		end
	end
	local report = {
		device = device,
		quality = engine.quality,
		pingMs = engine.ping or 0,
		memoryMb = memory.totalMb or 0,
		heapMb = memory.luaHeapMb or 0,
		frameP50 = fh:quantile(0.5),
		frameP95 = fh:quantile(0.95),
		frameP99 = fh:quantile(0.99),
		scriptP50 = sh:quantile(0.5),
		frames = fh.total,
		probes = probes,
	}
	return report, Wire.encodeReport(report, fh:encode(), sh:encode())
end

-- Called every Heartbeat on the client; sends when due.
function Telemetry.clientTick(Core: any, now: number, device: string, send: (buffer) -> ())
	if now < client.nextAt then
		return
	end
	local cfg = client.cfg
	if cfg == nil or not cfg.enabled or not client.sampled then
		client.nextAt = math.huge
		return
	end
	client.nextAt = now + cfg.every
	local ok, _, payload = pcall(Telemetry.buildReport, Core, device, Telemetry.windowFor(cfg.every))
	if ok and payload then
		client.sent += 1
		send(payload)
	end
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

type DeviceAgg = {
	frame: any,
	script: any,
	players: { [any]: boolean },
	nPlayers: number,
	reports: number,
	memSum: number,
	heapSum: number,
	pingSum: number,
	qualitySum: number,
	qualityN: number,
	probes: { [string]: { sum: number, n: number } },
	nProbes: number,
}

local server = {
	Core = nil :: any,
	cfg = nil :: Config?,
	devices = {} :: { [string]: DeviceAgg },
	reporters = {} :: { [any]: boolean },
	nReporters = 0,
	reports = 0,
	dropped = 0,
	rateLimited = 0,
	lastReport = {} :: { [any]: number },
	lastAnalytics = {} :: { [any]: number },
	analyticsTokens = ANALYTICS_PER_MINUTE,
	analyticsT = 0,
	analyticsSent = 0,
	analyticsFailed = 0,
	callbacks = {} :: { (any) -> () },
	cache = nil :: any,
	dirty = true,
	httpAt = 0,
	httpDirty = false,
	httpSent = 0,
	httpFailed = 0,
}
Telemetry.server = server

function Telemetry.startServer(Core: any, cfg: Config, now: number)
	server.Core = Core
	server.cfg = cfg
	server.analyticsT = now
	if server.httpAt == 0 and cfg.http then
		server.httpAt = now + cfg.http.every
	end
end

function Telemetry.onReport(fn: (any) -> ())
	table.insert(server.callbacks, fn)
end

function Telemetry.forget(player: any)
	server.lastReport[player] = nil
	server.lastAnalytics[player] = nil
end

-- Drops every per-player entry (Server.stop: PlayerRemoving is no longer connected).
function Telemetry.forgetAll()
	table.clear(server.lastReport)
	table.clear(server.lastAnalytics)
end

local function deviceAgg(device: string): DeviceAgg
	local d = server.devices[device]
	if d == nil then
		local Core = server.Core
		d = {
			frame = Core.histogram(),
			script = Core.histogram(),
			players = {},
			nPlayers = 0,
			reports = 0,
			memSum = 0,
			heapSum = 0,
			pingSum = 0,
			qualitySum = 0,
			qualityN = 0,
			probes = {},
			nProbes = 0,
		}
		server.devices[device] = d
	end
	return d
end

local function playerKey(player: any): any
	if typeof(player) == "Instance" then
		local ok, id = pcall(function()
			return player.UserId
		end)
		if ok and id ~= nil then
			return id
		end
	end
	return player
end

local function analyticsFields(device: string): { [string]: string }
	local f1, f2 = "CustomField01", "CustomField02"
	pcall(function()
		local keys = (Enum :: any).AnalyticsCustomFieldKeys
		f1 = keys.CustomField01.Name
		f2 = keys.CustomField02.Name
	end)
	local place = "0"
	pcall(function()
		place = tostring(game.PlaceId)
	end)
	return { [f1] = device, [f2] = place }
end

local function logAnalytics(player: any, r: any, now: number)
	local last = server.lastAnalytics[player]
	if last ~= nil and now - last < ANALYTICS_MIN_GAP then
		return
	end
	-- server-wide token bucket (events per minute)
	local tokens = server.analyticsTokens + (now - server.analyticsT) * (ANALYTICS_PER_MINUTE / 60)
	if tokens > ANALYTICS_PER_MINUTE then
		tokens = ANALYTICS_PER_MINUTE
	end
	server.analyticsT = now
	if tokens < 2 then
		server.analyticsTokens = tokens
		return
	end
	server.analyticsTokens = tokens - 2
	server.lastAnalytics[player] = now
	local service = getService("AnalyticsService")
	if service == nil then
		server.analyticsFailed += 1
		return
	end
	local fields = analyticsFields(r.device)
	local ok1 = pcall(function()
		service:LogCustomEvent(player, "LH_FrameP50", r.frameP50, fields)
	end)
	local ok2 = pcall(function()
		service:LogCustomEvent(player, "LH_FrameP95", r.frameP95, fields)
	end)
	if ok1 then
		server.analyticsSent += 1
	else
		server.analyticsFailed += 1
	end
	if ok2 then
		server.analyticsSent += 1
	else
		server.analyticsFailed += 1
	end
end

-- A report window covers at most 60 s; more frames than 60 s at 2000 fps is a forged histogram.
local MAX_HIST_FRAMES = 120000
local MAX_HIST_MS = 3600 * 1000

local function plausible(r: any): boolean
	for _, h in { r.frameHist, r.scriptHist } do
		if h ~= nil then
			local total = h.total
			if type(total) ~= "number" or total > MAX_HIST_FRAMES then
				return false
			end
			if type(h.max) ~= "number" or h.max > MAX_HIST_MS or type(h.sum) ~= "number" or h.sum > MAX_HIST_MS * 60 then
				return false
			end
		end
	end
	return true
end

-- Handles one REPORT payload from `player`. Returns the decoded report or nil (dropped).
function Telemetry.receive(player: any, payload: any, now: number): any
	local cfg = server.cfg
	local Core = server.Core
	if cfg == nil or not cfg.enabled or Core == nil then
		server.dropped += 1
		return nil
	end
	local last = server.lastReport[player]
	if last ~= nil and now - last < cfg.every / 2 then
		server.rateLimited += 1
		server.dropped += 1
		server.dirty = true
		return nil
	end
	local ok, r = pcall(Wire.decodeReport, payload, Core.histogram)
	if not ok or r == nil or not plausible(r) then
		server.dropped += 1
		server.dirty = true
		return nil
	end
	server.lastReport[player] = now
	local report: any = r

	local d = deviceAgg(report.device)
	if report.frameHist then
		d.frame:merge(report.frameHist)
	end
	if report.scriptHist then
		d.script:merge(report.scriptHist)
	end
	local key = playerKey(player)
	if not d.players[key] then
		d.players[key] = true
		d.nPlayers += 1
	end
	if not server.reporters[key] then
		server.reporters[key] = true
		server.nReporters += 1
	end
	d.reports += 1
	d.memSum += report.memoryMb
	d.heapSum += report.heapMb
	d.pingSum += report.pingMs
	if report.quality ~= nil then
		d.qualitySum += report.quality
		d.qualityN += 1
	end
	for _, p in report.probes do
		local e = d.probes[p.name]
		if e == nil and d.nProbes < MAX_PROBE_NAMES then
			e = { sum = 0, n = 0 }
			d.probes[p.name] = e
			d.nProbes += 1
		end
		if e then
			e.sum += p.ms
			e.n += 1
		end
	end
	server.reports += 1
	server.dirty = true
	server.httpDirty = true

	report.player = player
	report.frameHist = nil
	report.scriptHist = nil
	if cfg.analytics then
		logAnalytics(player, report, now)
	end
	for _, fn in server.callbacks do
		local okCb, err = pcall(fn, report)
		if not okCb then
			warn("Lighthouse.onReport callback error: " .. tostring(err))
		end
	end
	return report
end

-- Counts a payload dropped before it reached receive() (bad type, size, tag, rate).
function Telemetry.drop()
	server.dropped += 1
	server.dirty = true
end

-- Aggregate by device class (see Runtime.telemetry); nil before any report.
function Telemetry.aggregate(): any
	if server.reports == 0 then
		return nil
	end
	if not server.dirty and server.cache then
		return server.cache
	end
	local devices = {}
	for name, d in server.devices do
		local probes = {}
		for pname, e in d.probes do
			table.insert(probes, { name = pname, ms = e.sum / e.n })
		end
		table.sort(probes, function(a, b)
			return a.ms > b.ms
		end)
		for i = #probes, Wire.CAP_REPORT_PROBES + 1, -1 do
			probes[i] = nil
		end
		local n = math.max(d.reports, 1)
		table.insert(devices, {
			device = name,
			players = d.nPlayers,
			reports = d.reports,
			frameP50 = d.frame:quantile(0.5),
			frameP95 = d.frame:quantile(0.95),
			frameP99 = d.frame:quantile(0.99),
			scriptP50 = d.script:quantile(0.5),
			memoryMb = d.memSum / n,
			heapMb = d.heapSum / n,
			pingMs = d.pingSum / n,
			quality = if d.qualityN > 0 then d.qualitySum / d.qualityN else nil,
			probes = probes,
		})
	end
	table.sort(devices, function(a, b)
		if a.players == b.players then
			return a.reports > b.reports
		end
		return a.players > b.players
	end)
	local agg = {
		t = Sampler.serverTime(),
		reports = server.reports,
		players = server.nReporters,
		dropped = server.dropped,
		devices = devices,
	}
	server.cache = agg
	server.dirty = false
	return agg
end

-- Called every Heartbeat on the server: optional HTTP export.
function Telemetry.serverTick(now: number)
	local cfg = server.cfg
	local http = cfg and cfg.http
	if http == nil or now < server.httpAt then
		return
	end
	server.httpAt = now + http.every
	if not server.httpDirty then
		return
	end
	server.httpDirty = false
	local agg = Telemetry.aggregate()
	local HttpService = getService("HttpService")
	if agg == nil or HttpService == nil then
		return
	end
	local body = { lighthouse = 1, telemetry = agg, placeId = 0, jobId = "" }
	pcall(function()
		body.placeId = game.PlaceId
		body.jobId = game.JobId
	end)
	local okJson, json = pcall(function()
		return HttpService:JSONEncode(body)
	end)
	if not okJson then
		server.httpFailed += 1
		return
	end
	local url = http.url
	task.spawn(function()
		local ok = pcall(function()
			HttpService:PostAsync(url, json, (Enum :: any).HttpContentType.ApplicationJson)
		end)
		if ok then
			server.httpSent += 1
		else
			server.httpFailed += 1
		end
	end)
end

-- Counters for tests and the overlay.
function Telemetry.stats(): { [string]: number }
	return {
		reports = server.reports,
		dropped = server.dropped,
		rateLimited = server.rateLimited,
		analyticsSent = server.analyticsSent,
		analyticsFailed = server.analyticsFailed,
		httpSent = server.httpSent,
		httpFailed = server.httpFailed,
		clientSent = client.sent,
	}
end

return Telemetry
