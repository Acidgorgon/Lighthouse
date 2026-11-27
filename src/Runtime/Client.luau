--!strict
-- Client side of the Lighthouse remote.
--
--   * finds "LighthouseR" (polled once per second until the server has created it)
--   * asks to view (HELLO) while the overlay is open or code reads the server snapshot,
--     says BYE when nothing needs the stream any more
--   * decodes the name table and server snapshots (last one kept for serverSnapshot())
--   * sends telemetry reports when sampled (Telemetry.clientTick)
--   * owns the overlay toggle: the `;` key, L3+R3 together on a gamepad, or Runtime.overlay();
--     in live games only after the server allowed this player (HELLO reply), in Studio always

local Wire = require(script.Parent.Wire)
local Telemetry = require(script.Parent.Telemetry)

local Client = {}

local PENDING_TIMEOUT = 5 -- seconds to wait for the server's answer to HELLO
local FIND_EVERY = 1 -- seconds between looks for the remote

local Core: any = nil
local opts: any = {}
local root: any = nil
local clock: () -> number = os.clock
local device = "Desktop"

local remote: any = nil
local remoteConn: any = nil
local connections: { any } = {}
local findAt = 0
local visibleCheckAt = 0

local names: { string } = {}
local lastSnapshot: any = nil
local lastTelemetry: any = nil
local receivedAt = 0

local allowed: boolean? = nil -- server's answer (nil = not asked or no answer)
local pendingAt: number? = nil -- HELLO sent, waiting for an answer
local helloSent = false -- the server streams to us (or we asked it to)
local wantOverlay = false -- the overlay is open (or opening once allowed)
local wantApi = false -- code read serverSnapshot()/telemetry()

local overlay: any = nil
local overlayVisible = false
local overlayFailed = false

local inputService: any = nil
local keyCode: any = nil
local padA: any = nil
local padB: any = nil
local padDown: { [any]: boolean } = {}

Client.counters = { bad = 0, snapshots = 0, names = 0, hellos = 0, byes = 0 }

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

local function send(payload: buffer, channel: string): boolean
	if remote == nil then
		return false
	end
	local ok = pcall(function()
		remote:FireServer(payload)
	end)
	if ok then
		Core.net("Lighthouse", channel, "out", buffer.len(payload))
	end
	return ok
end

--------------------------------------------------------------------------------
-- Viewing (HELLO / BYE)
--------------------------------------------------------------------------------

local function wantStream(): boolean
	return wantOverlay or wantApi
end

local function updateStream()
	if remote == nil then
		return -- sent when the remote shows up
	end
	if wantStream() and not helloSent then
		helloSent = true
		pendingAt = clock()
		Client.counters.hellos += 1
		send(Wire.encodeHello(), "Control")
	elseif not wantStream() and helloSent then
		helloSent = false
		Client.counters.byes += 1
		send(Wire.encodeBye(), "Control")
	end
end

--------------------------------------------------------------------------------
-- Overlay
--------------------------------------------------------------------------------

local function sourceFn(side: string): any
	if side == "server" then
		return lastSnapshot
	elseif side == "telemetry" then
		return lastTelemetry
	end
	local ok, s = pcall(Core.snapshot, "client")
	return if ok then s else nil
end
Client.source = sourceFn

local function ensureOverlay(): any
	if overlay ~= nil or overlayFailed then
		return overlay
	end
	local ok, result = pcall(function()
		local folder = root:FindFirstChild("Overlay")
		local module = folder and folder:FindFirstChild("Overlay")
		if module == nil then
			error("Overlay module missing")
		end
		local Overlay = require(module) :: any
		return Overlay.new(sourceFn)
	end)
	if ok and result ~= nil then
		overlay = result
	else
		overlayFailed = true
		warn("Lighthouse: overlay unavailable: " .. tostring(result))
	end
	return overlay
end

-- The panel can close itself (its own close button), so ask it rather than trusting a flag.
local function isVisible(): boolean
	if overlay == nil then
		return false
	end
	local ok, v = pcall(overlay.isVisible, overlay)
	if ok then
		overlayVisible = v == true
	end
	return overlayVisible
end

local function setVisible(on: boolean)
	overlayVisible = on
	if on then
		local o = ensureOverlay()
		if o then
			pcall(o.setVisible, o, true)
		end
	elseif overlay then
		pcall(overlay.setVisible, overlay, false)
	end
end

local function mayOpen(): boolean
	return allowed == true or isStudio()
end

-- Show (true), hide (false) or toggle (nil) the overlay.
function Client.overlay(on: boolean?)
	local target = if on == nil then not (isVisible() or (wantOverlay and pendingAt ~= nil)) else on
	if target then
		wantOverlay = true
		updateStream()
		if mayOpen() then
			setVisible(true)
		end
		-- else: opens when the server answers HELLO with "allowed"
	else
		wantOverlay = false
		setVisible(false)
		updateStream()
	end
end

function Client.overlayVisible(): boolean
	return isVisible()
end

--------------------------------------------------------------------------------
-- Receive
--------------------------------------------------------------------------------

local function onEvent(payload: any)
	local version, tag = Wire.header(payload)
	if version ~= Wire.VERSION then
		Client.counters.bad += 1
		return
	end
	Core.net("Lighthouse", "Stream", "in", buffer.len(payload))
	if tag == Wire.NAMES then
		if Wire.decodeNames(payload, names) then
			Client.counters.names += 1
		else
			Client.counters.bad += 1
		end
	elseif tag == Wire.SNAPSHOT then
		local s = Wire.decodeSnapshot(payload, names)
		if s then
			lastSnapshot = s
			lastTelemetry = s.reports
			receivedAt = clock()
			Client.counters.snapshots += 1
		else
			Client.counters.bad += 1
		end
	elseif tag == Wire.HELLO then
		local ok = Wire.decodeAllow(payload)
		if ok == nil then
			Client.counters.bad += 1
			return
		end
		allowed = ok
		pendingAt = nil
		if ok and wantOverlay and not overlayVisible then
			setVisible(true)
		end
	else
		Client.counters.bad += 1
	end
end

local function safeEvent(payload: any)
	local ok, err = pcall(onEvent, payload)
	if not ok then
		Client.counters.bad += 1
		warn("Lighthouse: dropped a server message: " .. tostring(err))
	end
end

-- `telemetry` is a server option: without one in this client's start(), use the server's
-- (published as attributes on the remote; absent = off).
local function telemetryOpt(): any
	if opts.telemetry ~= nil or remote == nil then
		return opts.telemetry
	end
	local ok, every, sample = pcall(function()
		return remote:GetAttribute(Wire.ATTR_EVERY), remote:GetAttribute(Wire.ATTR_SAMPLE)
	end)
	if ok and type(every) == "number" then
		return { every = every, sample = sample }
	end
	return nil
end

local function startTelemetry(now: number)
	Telemetry.startClient(Core, Telemetry.config(telemetryOpt()), now)
end

local function findRemote(now: number)
	if remote ~= nil or now < findAt then
		return
	end
	findAt = now + FIND_EVERY
	local r = root and root:FindFirstChild("LighthouseR")
	if r == nil then
		return
	end
	remote = r
	remoteConn = r.OnClientEvent:Connect(safeEvent)
	if opts.telemetry == nil then
		startTelemetry(now)
	end
	helloSent = false
	updateStream()
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function enumItem(enum: string, name: string): any
	local ok, v = pcall(function()
		return (Enum :: any)[enum][name]
	end)
	return if ok then v else nil
end

-- A TextBox has the keyboard (chat, a search field of the game). The engine marks those key presses as
-- processed; asking for the focused box as well covers a press that arrives unmarked.
local function typing(): boolean
	if inputService == nil then
		return false
	end
	local ok, box = pcall(inputService.GetFocusedTextBox, inputService)
	return ok and box ~= nil
end

local function onInputBegan(input: any, processed: boolean)
	local kc = input.KeyCode
	if kc == nil then
		return
	end
	if keyCode ~= nil and kc == keyCode then
		if not processed and not typing() then
			Client.overlay(nil)
		end
		return
	end
	if padA ~= nil and (kc == padA or kc == padB) then
		local wasBoth = padDown[padA] and padDown[padB]
		padDown[kc] = true
		if not wasBoth and padDown[padA] and padDown[padB] then
			Client.overlay(nil)
		end
	end
end

local function onInputEnded(input: any)
	local kc = input.KeyCode
	if kc ~= nil and padDown[kc] then
		padDown[kc] = false
	end
end

local function bindInput()
	-- Semicolon, not a function key. Studio takes F5 (Play), F7 (Start: the engine marks it processed, so the
	-- first default never opened the panel), F8 (Run), F11 and F12; the client takes F9 (console) to F12.
	-- Roblox leaves `;` alone on both (chat is `/`, the backpack the backtick, emotes `.`, UI selection the
	-- backslash), and a press while typing is ignored (see onInputBegan).
	keyCode = if opts.overlayKey == false then nil else (opts.overlayKey or enumItem("KeyCode", "Semicolon"))
	local pad = opts.overlayGamepad
	if pad == false then
		padA, padB = nil, nil
	elseif type(pad) == "table" and pad[1] ~= nil and pad[2] ~= nil then
		padA, padB = pad[1], pad[2]
	else
		padA, padB = enumItem("KeyCode", "ButtonL3"), enumItem("KeyCode", "ButtonR3")
	end
	if #connections > 0 then
		return
	end
	local uis = getService("UserInputService")
	if uis == nil then
		return
	end
	inputService = uis
	pcall(function()
		table.insert(connections, uis.InputBegan:Connect(function(input, processed)
			pcall(onInputBegan, input, processed)
		end))
		table.insert(connections, uis.InputEnded:Connect(function(input)
			pcall(onInputEnded, input)
		end))
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Client.start(core: any, newOpts: any, rootInst: any, clockFn: () -> number, deviceClass: string)
	Core = core
	opts = newOpts or {}
	root = rootInst
	clock = clockFn
	device = deviceClass
	local now = clock()
	startTelemetry(now)
	bindInput()
	findAt = 0
	findRemote(now)
end

local function sendReport(payload: buffer)
	send(payload, "Report")
end

-- Every Heartbeat.
function Client.tick(now: number)
	if remote == nil then
		findRemote(now)
	end
	if pendingAt ~= nil and now - pendingAt > PENDING_TIMEOUT then
		-- no answer: not a viewer (the server stays silent). Forget the request so a
		-- later toggle asks again (the server rate limits HELLOs).
		pendingAt = nil
		helloSent = false
		if allowed == nil then
			allowed = false
		end
		if not overlayVisible then
			wantOverlay = false
		end
	end
	-- closed from its own button: stop the stream
	if wantOverlay and overlay ~= nil and pendingAt == nil and now >= visibleCheckAt then
		visibleCheckAt = now + 0.5
		if not isVisible() then
			wantOverlay = false
			updateStream()
		end
	end
	Telemetry.clientTick(Core, now, device, sendReport)
end

function Client.stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	if remoteConn then
		remoteConn:Disconnect()
		remoteConn = nil
	end
	if helloSent then
		send(Wire.encodeBye(), "Control")
		helloSent = false
	end
	remote = nil
	wantOverlay = false
	wantApi = false
	overlayVisible = false
	if overlay then
		pcall(overlay.destroy, overlay)
		overlay = nil
	end
	overlayFailed = false
	table.clear(padDown)
end

-- Last server snapshot received (subscribes on first call).
function Client.serverSnapshot(): any
	if not wantApi then
		wantApi = true
		updateStream()
	end
	return lastSnapshot
end

function Client.telemetry(): any
	if not wantApi then
		wantApi = true
		updateStream()
	end
	return lastTelemetry
end

function Client.state(): any
	return {
		remote = remote ~= nil,
		allowed = allowed,
		pending = pendingAt ~= nil,
		subscribed = helloSent,
		overlay = overlayVisible,
		receivedAt = receivedAt,
	}
end

return Client
