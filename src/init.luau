--!strict
-- Lighthouse: profiling and live telemetry for Roblox.
--
--   local Lighthouse = require(ReplicatedStorage.Lighthouse)
--   Lighthouse.start()                                   -- once on the server, once on the client
--
--   local crowd = Lighthouse.probe("Crowd.Step")         -- at module load
--   crowd:begin() ... crowd:finish()
--   local step = Lighthouse.wrap("Crowd.Step", step)     -- or wrap a function
--   Lighthouse.bind(RunService.Heartbeat, "Crowd.Step", fn)
--   Lighthouse.count("Pathfinds")  Lighthouse.gauge("Npcs", #npcs)
--   Lighthouse.net("Game", "Shop", "out", bytes)
--   Lighthouse.overlay()  Lighthouse.snapshot()  Lighthouse.export(10)
--
-- Before start() (or with enabled = false) every measuring call tests one upvalue and returns.
-- The Runtime (engine sampling, wire, overlay, telemetry) is required on first use, so Core
-- works on its own. Sets shared.Lighthouse for library hooks (Current, Ripple, Tide).

local Core = require(script.Core)

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()
local SIDE = if IS_SERVER then "server" else "client"

local Lighthouse = {}

Lighthouse.version = "0.2.0"
Lighthouse.isServer = IS_SERVER
Lighthouse.Core = Core

local options: { [string]: any } = {}
local disabled = false -- start({ enabled = false }): wrap returns functions untouched
local Runtime: any = nil
local runtimeFailed = false

local function isStudio(): boolean
	local ok, studio = pcall(function()
		return RunService:IsStudio()
	end)
	return ok and studio == true
end

local function runtime(): any
	if Runtime == nil and not runtimeFailed then
		local module = script:FindFirstChild("Runtime")
		if module == nil then
			runtimeFailed = true
			return nil
		end
		local ok, result = pcall(require, module)
		if ok then
			Runtime = result
		else
			runtimeFailed = true
			warn("Lighthouse: Runtime failed to load: " .. tostring(result))
		end
	end
	return Runtime
end

local function callRuntime(name: string, ...: any): any
	local rt = runtime()
	local fn = rt and rt[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn(`Lighthouse: Runtime.{name} failed: {result}`)
		return nil
	end
	return result
end

-- Starts measuring (and the Runtime: engine sampling, viewer stream, overlay, telemetry).
-- Safe to call again: opts are merged into the previous ones. Returns whether Lighthouse is on.
function Lighthouse.start(opts: { [string]: any }?): boolean
	if type(opts) == "table" then
		for k, v in opts do
			options[k] = v
		end
	elseif opts ~= nil then
		warn("Lighthouse.start: opts must be a table")
	end
	if options.enabled == false then
		disabled = true
		Lighthouse.stop()
		return false
	end
	disabled = false
	local cfg = table.clone(options)
	if cfg.microprofiler == nil then
		cfg.microprofiler = isStudio()
	end
	if cfg.spawn == nil then
		cfg.spawn = task.spawn
	end
	Core.configure(cfg)
	Core.setActive(true)
	callRuntime("start", Core, cfg)
	return true
end

-- Back to the near-free off state. Collected numbers are kept.
function Lighthouse.stop()
	Core.setActive(false)
	if Runtime ~= nil then
		callRuntime("stop")
	end
end

function Lighthouse.isActive(): boolean
	return Core.isActive()
end

-- Measuring: these are Core's functions themselves (each tests `active` first).
Lighthouse.probe = Core.probe
Lighthouse.count = Core.count
Lighthouse.gauge = Core.gauge
Lighthouse.net = Core.net
Lighthouse.record = Core.record
Lighthouse.onFlare = Core.onFlare
Lighthouse.flares = Core.flares
Lighthouse.histogram = Core.histogram

-- fn inside probe `name`, returning all of fn's results. Returns fn itself when Lighthouse was
-- started with enabled = false.
function Lighthouse.wrap<A..., R...>(name: string, fn: (A...) -> R...): (A...) -> R...
	if disabled then
		return fn
	end
	return Core.wrap(name, fn)
end

-- signal:Connect(Lighthouse.wrap(name, fn)); returns the connection.
function Lighthouse.bind(signal: RBXScriptSignal, name: string, fn: (...any) -> ()): RBXScriptConnection
	return signal:Connect(Lighthouse.wrap(name, fn))
end

-- Shows (true), hides (false) or toggles (nil) the overlay panel. Client only.
function Lighthouse.overlay(on: boolean?)
	if IS_SERVER then
		return
	end
	callRuntime("overlay", on)
end

-- Snapshot of this side. On the server it includes the telemetry `reports` when the Runtime runs.
function Lighthouse.snapshot(): { [string]: any }
	if IS_SERVER and Runtime ~= nil then
		local snap = callRuntime("serverSnapshot")
		if type(snap) == "table" then
			return snap
		end
	end
	return Core.snapshot(SIDE)
end

-- JSON: { lighthouse = 1, side, client = Snapshot?, server = Snapshot?, recording, reports }.
-- recording is the Core.record() capture when there is one and `seconds` is nil, else the last
-- `seconds` of the frame ring.
function Lighthouse.export(seconds: number?): string
	local doc: { [string]: any } = {
		lighthouse = 1,
		side = SIDE,
		recording = Core.recording(seconds),
	}
	if IS_SERVER then
		doc.server = Lighthouse.snapshot()
	else
		doc.client = Core.snapshot("client")
		if Runtime ~= nil then
			doc.server = callRuntime("serverSnapshot")
		end
	end
	if Runtime ~= nil then
		doc.reports = callRuntime("telemetry")
	end
	return Core.Json.encode(doc)
end

-- Server: fn(report) for each client telemetry report.
function Lighthouse.onReport(fn: (report: { [string]: any }) -> ()): any
	return callRuntime("onReport", fn)
end

-- Wrapper around a RemoteEvent (same Fire* methods) that counts its traffic.
-- Without the Runtime it returns the remote itself.
function Lighthouse.remote(remoteEvent: RemoteEvent): any
	local wrapped = callRuntime("remote", remoteEvent)
	return if wrapped ~= nil then wrapped else remoteEvent
end

if shared.Lighthouse == nil then
	shared.Lighthouse = Lighthouse
end

return Lighthouse
