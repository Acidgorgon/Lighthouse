--!strict
-- Client side of the Lighthouse remote.
--
--   * finds "LighthouseR" (polled once per second until the server has created it)
--   * asks to view (HELLO) while the overlay is open or code reads the server snapshot,
--     says BYE when nothing needs the stream any more
--   * decodes the name table and server snapshots (last one kept for serverSnapshot())
--   * sends telemetry reports when sampled (Telemetry.clientTick)
--   * owns the overlay toggle: the `;` key, hold R3 and press D-pad Left on a gamepad, or
--     Runtime.overlay(); in live games only after the server allowed this player (HELLO reply),
--     in Studio always
--
-- Gamepad: Lighthouse listens only while a combo button is held. The first button of the combo
-- to go down is watched through UserInputService and left to the game (a press cannot be taken
-- back once the combo is known). While it is held the other button is bound through
-- ContextActionService at overlayGamepadPriority and sunk, so whatever the game binds to it
-- does not fire. Nothing is bound for a player who may not open the overlay.
-- A press the action never gets (a game action bound above that priority, Roblox's own UI
-- navigation taking the D-pad) still toggles, from UserInputService; it just cannot be sunk.
-- Tabs: while overlayGamepad[1] is held and the panel is open, LB and RB are bound and sunk the
-- same way and step the tab. A bare LB / RB is never Lighthouse's: with the panel open during
-- play those are the game's buttons.

local Wire = require(script.Parent.Wire)
local Telemetry = require(script.Parent.Telemetry)

local Client = {}

local PENDING_TIMEOUT = 5 -- seconds to wait for the server's answer to HELLO
local FIND_EVERY = 1 -- seconds between looks for the remote
local PAD_ACTION = "LighthouseOverlay"
local PAD_PRIORITY = 3000 -- Enum.ContextActionPriority.High.Value

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
local padHold: any = nil -- overlayGamepad[1]
local padPress: any = nil -- overlayGamepad[2]
local padPriority = PAD_PRIORITY
local padTabs = false -- overlayGamepadTabs, and the combo leaves LB and RB free
local padPrev: any = nil -- ButtonL1
local padNext: any = nil -- ButtonR1
local padWatch: { [any]: boolean } = {} -- buttons followed through UserInputService
local padDown: { [any]: any } = {} -- watched button -> the gamepad (UserInputType) that holds it
local padAnchor: any = nil -- the combo button that went down first; set while the action is bound
local padSunk: { [any]: boolean } = {} -- presses taken from the game (their releases are taken too)
local padActed: { [any]: boolean } = {} -- presses that already toggled or stepped (acted on once)
local stateBegin: any = nil
local stateEnd: any = nil
local resultSink: any = nil
local resultPass: any = nil

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

local PAD_NAMES = {
	ButtonL1 = "LB",
	ButtonR1 = "RB",
	ButtonL2 = "LT",
	ButtonR2 = "RT",
	ButtonSelect = "View",
	ButtonStart = "Menu",
}

local function padName(kc: any): string
	local ok, name = pcall(function()
		return kc.Name
	end)
	if not ok or type(name) ~= "string" then
		return tostring(kc)
	end
	return PAD_NAMES[name] or (string.gsub(name, "^Button", ""))
end

-- What the panel prints next to its tab bar on a gamepad; nil when no button steps the tab.
local function tabHints(): { string }?
	if not padTabs then
		return nil
	end
	local hold = padName(padHold)
	return { hold .. "+" .. padName(padPrev), hold .. "+" .. padName(padNext) }
end

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
		return Overlay.new(sourceFn, { tabHints = tabHints() })
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

-- nil when the engine cannot say (then the InputBegan / InputEnded bookkeeping is trusted)
local function buttonDown(pad: any, kc: any): boolean?
	if inputService == nil or pad == true then
		return nil
	end
	local ok, down = pcall(inputService.IsGamepadButtonDown, inputService, pad, kc)
	if ok and type(down) == "boolean" then
		return down
	end
	return nil
end

local function unbindPad()
	if padAnchor == nil then
		return
	end
	padAnchor = nil
	table.clear(padSunk)
	table.clear(padActed)
	local cas = getService("ContextActionService")
	if cas ~= nil then
		pcall(cas.UnbindAction, cas, PAD_ACTION)
	end
end

-- The gamepad went away or the window lost focus: releases may never arrive.
local function resetPad()
	table.clear(padDown)
	unbindPad()
end

-- A press of `kc` from gamepad `from` while a combo button is held: toggles the overlay or steps
-- the tab, once per press whoever reports it first (the bound action or UserInputService).
-- Returns whether the press is Lighthouse's.
local function padPressed(kc: any, from: any): boolean
	local anchor = padAnchor
	local pad = anchor ~= nil and padDown[anchor]
	if not pad or (pad ~= true and from ~= nil and from ~= pad) then
		return false -- the held button is up again, or this press is from another gamepad
	end
	local step = 0
	if padTabs and anchor == padHold and (kc == padPrev or kc == padNext) then
		if not isVisible() then
			return false
		end
		step = if kc == padPrev then -1 else 1
	elseif kc ~= (if anchor == padHold then padPress else padHold) then
		return false
	end
	if typing() then
		return false
	end
	if not padActed[kc] then
		padActed[kc] = true
		if step == 0 then
			Client.overlay(nil)
		else
			pcall(overlay.stepTab, overlay, step)
		end
	end
	return true
end

-- Bound while a combo button is held. Returns Pass for everything that is not ours, so the game
-- keeps its input; a press that toggles or steps the tab is sunk together with its release.
local function onPadAction(_name: string, state: any, input: any): any
	local kc = input and input.KeyCode
	if kc == nil then
		return resultPass
	end
	if state == stateBegin then
		if not padPressed(kc, input.UserInputType) then
			return resultPass
		end
		padSunk[kc] = true
		padDown[kc] = padDown[padAnchor]
		return resultSink
	end
	if padSunk[kc] then
		if state == stateEnd then
			padSunk[kc] = nil
			padActed[kc] = nil
			padDown[kc] = nil
		end
		return resultSink
	end
	return resultPass
end

local function bindPad(anchor: any): boolean
	local cas = getService("ContextActionService")
	if cas == nil or stateBegin == nil or stateEnd == nil or resultSink == nil or resultPass == nil then
		return false
	end
	padAnchor = anchor
	local buttons = { if anchor == padHold then padPress else padHold }
	if padTabs and anchor == padHold then
		-- a shoulder button that is down belongs to the game for this hold: binding over a press in
		-- progress would cancel the game's action
		local pad = padDown[anchor]
		for _, kc in { padPrev, padNext } do
			if padDown[kc] == nil and buttonDown(pad, kc) ~= true then
				table.insert(buttons, kc)
			end
		end
	end
	local ok = pcall(cas.BindActionAtPriority, cas, PAD_ACTION, onPadAction, false, padPriority, table.unpack(buttons))
	if not ok then
		padAnchor = nil
	end
	return ok
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
	if not padWatch[kc] then
		return
	end
	-- held or not is a fact about the button: a press the game or the engine processed still counts
	local wasDown = padDown[kc] ~= nil
	padDown[kc] = input.UserInputType or true
	if padAnchor ~= nil then
		-- Bound: onPadAction takes the press. Unless something above it took the press first (a game
		-- action at a higher priority, Roblox's UI navigation on the D-pad): then it could not be
		-- sunk, but the combo still does what it says.
		if not wasDown and kc ~= padAnchor then
			padPressed(kc, input.UserInputType)
		end
		return
	end
	if wasDown or (kc ~= padHold and kc ~= padPress) then
		return -- LB and RB are only followed
	end
	if padDown[if kc == padHold then padPress else padHold] ~= nil then
		-- both are down and nothing was bound: this player may not open the overlay (or the
		-- service is missing), so nothing is taken from the game. Ask anyway: a viewer's first
		-- press in a live game is how the server gets to allow it.
		if not typing() then
			Client.overlay(nil)
		end
	elseif mayOpen() then
		bindPad(kc)
	end
end

local function onInputEnded(input: any)
	local kc = input.KeyCode
	if kc ~= nil and padDown[kc] ~= nil then
		padDown[kc] = nil
		padActed[kc] = nil
		if kc == padAnchor and next(padSunk) == nil then
			unbindPad()
		end
	end
end

-- Every Heartbeat while the action is bound: releases it once the held button is up and every
-- press it took has ended. A sunk press is waited for here and not in onInputEnded, so a release
-- that UserInputService reports before the action sees it cannot reach the game without its press.
local function tickPad()
	local anchor = padAnchor
	if anchor == nil then
		return
	end
	local waiting = false
	for kc in padSunk do
		local held = padDown[kc]
		if held == nil or buttonDown(held, kc) == false then
			padSunk[kc] = nil -- its release came, or never will (a Roblox menu took it)
			padActed[kc] = nil
			padDown[kc] = nil
		else
			waiting = true
		end
	end
	local pad = padDown[anchor]
	if pad ~= nil and buttonDown(pad, anchor) == false then
		padDown[anchor] = nil
		pad = nil
	end
	if pad == nil and not waiting then
		unbindPad()
	end
end

local function bindInput()
	resetPad()
	-- Semicolon, not a function key. Studio takes F5 (Play), F7 (Start: the engine marks it processed, so the
	-- first default never opened the panel), F8 (Run), F11 and F12; the client takes F9 (console), F11 and
	-- F12. Roblox leaves `;` alone on both (chat is `/`, the backpack the backtick, emotes `.`, UI selection
	-- the backslash), and a press while typing is ignored (see onInputBegan).
	keyCode = if opts.overlayKey == false then nil else (opts.overlayKey or enumItem("KeyCode", "Semicolon"))
	-- Hold R3, press D-pad Left: one button per thumb and R3 is rarely held, so play does not hit it by
	-- accident. L3 + R3 (the 0.1 default) opens a menu in some games and each stick click alone is often
	-- sprint or crouch; D-pad Up goes to Roblox's avatar context menu when a game turns that on.
	local pad = opts.overlayGamepad
	if pad == false then
		padHold, padPress = nil, nil
	elseif type(pad) == "table" and pad[1] ~= nil and pad[2] ~= nil then
		padHold, padPress = pad[1], pad[2]
	else
		padHold, padPress = enumItem("KeyCode", "ButtonR3"), enumItem("KeyCode", "DPadLeft")
	end
	if padHold == nil or padPress == nil or padHold == padPress then
		padHold, padPress = nil, nil
	end
	local priority = opts.overlayGamepadPriority
	if type(priority) ~= "number" then
		local ok, value = pcall(function()
			return priority.Value -- an Enum.ContextActionPriority item
		end)
		priority = if ok and type(value) == "number" then value else PAD_PRIORITY
	end
	padPriority = priority
	padPrev, padNext = enumItem("KeyCode", "ButtonL1"), enumItem("KeyCode", "ButtonR1")
	padTabs = opts.overlayGamepadTabs ~= false and padHold ~= nil and padPrev ~= nil and padNext ~= nil
	for _, kc in { padPrev, padNext } do
		if kc == padHold or kc == padPress then
			padTabs = false -- the combo itself uses a shoulder button
		end
	end
	table.clear(padWatch)
	if padHold ~= nil then
		padWatch[padHold] = true
		padWatch[padPress] = true
	end
	if padTabs then
		padWatch[padPrev] = true
		padWatch[padNext] = true
	end
	if overlay ~= nil then
		pcall(overlay.setTabHints, overlay, tabHints())
	end
	stateBegin = enumItem("UserInputState", "Begin")
	stateEnd = enumItem("UserInputState", "End")
	resultSink = enumItem("ContextActionResult", "Sink")
	resultPass = enumItem("ContextActionResult", "Pass")
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
	for _, name in { "GamepadDisconnected", "WindowFocusReleased" } do
		pcall(function()
			table.insert(connections, uis[name]:Connect(resetPad))
		end)
	end
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
	tickPad()
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
	resetPad()
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
