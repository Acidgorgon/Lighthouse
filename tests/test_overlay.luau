--!optimize 2
-- Overlay: builds against the mock with fake snapshots, never errors, and never creates
-- Instances after the first build (all rows, bars and labels are pooled).

return function(T)
local Mock = T.Mock

local function loadFile(path: string)
	local src = readfile(path) or error("cannot read " .. path)
	local fn, err = loadstring(src, "@" .. path)
	if not fn then
		error(err)
	end
	return fn()
end

local GuiMock = loadFile(T.ROOT .. "/tests/gui_mock.luau")

--------------------------------------------------------------------------------
-- Fake data
--------------------------------------------------------------------------------

local PROBES = {
	"Crowd.Step",
	"Crowd.Path",
	"Crowd.Animate",
	"Ai.Think",
	"Ai.Perception",
	"Weapons.Raycast",
	"Ui.Update",
	"Camera",
	"Current.Flush",
	"Ripple.Encode",
	"Tide.Relay",
}

local function snapshot(side: string, seed: number, probeCount: number?)
	-- small LCG so the test does not need Roblox's Random
	local state = seed * 7919 + 1
	local rng = {}
	function rng:NextNumber()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
	local history = {}
	for i = 1, 120 do
		history[i] = 12 + rng:NextNumber() * 10 + (if i % 37 == 0 then 40 else 0)
	end
	local probes = {}
	local n = probeCount or #PROBES
	for i = 1, n do
		local name = PROBES[(i - 1) % #PROBES + 1]
		if i > #PROBES then
			name = name .. "." .. i
		end
		local selfAvg = rng:NextNumber() * 3
		probes[i] = {
			name = name,
			selfAvg = selfAvg,
			selfP95 = selfAvg * 1.6,
			selfMax = selfAvg * 3,
			totalAvg = selfAvg * 1.2,
			calls = 1 + (i % 4),
		}
	end
	table.sort(probes, function(a, b)
		return a.selfAvg > b.selfAvg
	end)
	return {
		v = 1,
		side = side,
		t = 100 + seed,
		serverTime = 1000 + seed,
		device = if side == "client" then "Mobile" else nil,
		players = 12,
		frame = {
			last = history[120],
			avg1 = 16.4,
			p50 = 15.9,
			p95 = 22.5 + seed % 5,
			p99 = 41.2,
			max10 = 61.7,
			fps = 58,
			budget = 1000 / 60,
			scriptMs = 4.2,
			history = history,
		},
		probes = probes,
		counters = { { name = "Pathfinds", perSec = 12 + seed % 3 }, { name = "Hits", perSec = 0.5 } },
		gauges = { { name = "Npcs", value = 40, min = 38, max = 42 } },
		net = {
			{ lib = "Current", channel = "Shop", dir = "out", bps = 1200 + seed, pps = 10, avg = 120, peak = 2400 },
			{ lib = "Current", channel = "Chat", dir = "in", bps = 300, pps = 2, avg = 150, peak = 900 },
			{ lib = "Tide", channel = "Motion", dir = "in", bps = 14000, pps = 60, avg = 233, peak = 16000 },
			{ lib = "Ripple", channel = "Inventory", dir = "in", bps = 800, pps = 3, avg = 266, peak = 4000 },
			{ lib = "Game", channel = "Remote:Fire", dir = "out", bps = 50, pps = 1, avg = 50, peak = 50 },
		},
		memory = {
			totalMb = 1450 + seed,
			luaHeapMb = 212,
			gcKb = 217000,
			gcKbPerSec = 300 + (seed % 3) * 900,
			tags = { LuaHeap = 212, Instances = 180, GraphicsTexture = 420, Sounds = 35, Animation = 22, Gui = 12 },
		},
		engine = {
			heartbeatMs = 3.1,
			physicsMs = 1.2,
			recvKbps = 180,
			sendKbps = 40,
			instances = 48211,
			ping = 74,
			physicsFps = 60,
		},
		flares = {
			-- newest first, like Core's Snapshot
			{ t = 95 + seed, frameMs = 33.9, top = { { name = "Weapons.Raycast", ms = 9.1 } } },
			{ t = 90 + seed, frameMs = 48.2, top = { { name = "Crowd.Step", ms = 21 }, { name = "Ai.Think", ms = 8.3 } } },
		},
		misuse = seed % 2,
	}
end

local function telemetry(seed: number)
	return {
		t = 1000 + seed,
		reports = 40 + seed,
		players = 11,
		dropped = 0,
		devices = {
			{
				device = "Mobile",
				players = 6,
				reports = 24,
				frameP50 = 31.0,
				frameP95 = 58.4,
				frameP99 = 81.0,
				scriptP50 = 9.5,
				memoryMb = 1300,
				heapMb = 240,
				pingMs = 120,
				quality = 3,
				probes = { { name = "Crowd.Step", ms = 4.1 }, { name = "Ai.Think", ms = 2.2 } },
			},
			{
				device = "Desktop",
				players = 4,
				reports = 14,
				frameP50 = 8.2,
				frameP95 = 12.1,
				frameP99 = 19.3,
				scriptP50 = 3.1,
				memoryMb = 2100,
				heapMb = 230,
				pingMs = 45,
				quality = 8,
				probes = {},
			},
			{ device = "Console", players = 1, reports = 2 },
		},
	}
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

local function setup(opts: any?)
	local world = Mock.newWorld()
	local _, client = world:addPlayer()
	local gui = GuiMock.install(Mock, client, opts)
	local folder = client:mountTree(T.SRC .. "/Overlay", client.ReplicatedStorage, "Overlay")
	local Overlay = client:require(folder:FindFirstChild("Overlay"))

	local state = { client = nil, server = nil, telemetry = nil, calls = 0 }
	local overlay = Overlay.new(function(side)
		state.calls += 1
		return state[side]
	end, opts and opts.overlay)
	return {
		world = world,
		client = client,
		gui = gui,
		overlay = overlay,
		state = state,
		Overlay = Overlay,
	}
end

local function noErrors(ctx)
	T.eq(ctx.overlay.errors, 0, "overlay errors (last: " .. tostring(ctx.overlay.lastError) .. ")")
end

local function withSetup(opts: any?, fn: (any) -> ())
	local ctx = setup(opts)
	local ok, err = xpcall(fn, debug.traceback, ctx)
	ctx.overlay:destroy()
	ctx.gui:uninstall()
	if not ok then
		error(err, 0)
	end
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

T.test("Overlay.new builds nothing until the panel opens", function()
	withSetup(nil, function(ctx)
		T.eq(ctx.gui.created, 0, "instances before open")
		T.check(ctx.overlay.gui == nil, "no ScreenGui yet")
	end)
end)

T.test("opening builds a ScreenGui under PlayerGui with the right settings", function()
	withSetup(nil, function(ctx)
		ctx.state.client = snapshot("client", 1)
		ctx.overlay:setVisible(true)
		noErrors(ctx)
		local screen = ctx.overlay.gui
		T.check(screen ~= nil, "ScreenGui made")
		T.eq(screen.Parent, ctx.gui.PlayerGui, "parent")
		T.eq(screen.ClassName, "ScreenGui", "class")
		T.eq(screen.ResetOnSpawn, false, "ResetOnSpawn")
		T.eq(screen.IgnoreGuiInset, true, "IgnoreGuiInset")
		T.check(screen.DisplayOrder >= 1000, "high DisplayOrder")
		T.eq(screen.Enabled, true, "Enabled")
		T.eq(ctx.overlay.ui.fP50.Text, "15.9", "p50 text")
		T.check(string.find(ctx.overlay.ui.fScript.Text, "script 4.20 ms", 1, true) ~= nil, "script line: " .. ctx.overlay.ui.fScript.Text)
		local flare = ctx.overlay.ui.fFlares[1].Text
		T.check(string.find(flare, "33.9", 1, true) and string.find(flare, "-5s", 1, true), "newest flare first: " .. flare)
	end)
end)

T.test("refreshing every tab and side creates no Instances", function()
	withSetup(nil, function(ctx)
		local overlay, state = ctx.overlay, ctx.state
		state.client = snapshot("client", 1)
		overlay:setVisible(true)
		noErrors(ctx)
		local created = ctx.gui.created
		local count = GuiMock.count(overlay.gui)
		T.check(created > 300, "pools built up front (" .. created .. ")")

		for round = 1, 30 do
			state.client = snapshot("client", round, if round % 3 == 0 then 120 else nil)
			state.server = if round % 4 == 0 then nil else snapshot("server", round + 100)
			state.telemetry = if round % 5 == 0 then nil else telemetry(round)
			for tab = 1, 5 do
				overlay:setTab(tab)
				overlay:refresh()
				overlay:setSide(if round % 2 == 0 then "server" else "client")
				overlay:refresh()
			end
		end
		noErrors(ctx)
		T.eq(ctx.gui.created, created, "Instance.new calls after build")
		T.eq(GuiMock.count(overlay.gui), count, "Instances under the ScreenGui")
	end)
end)

T.test("probes are grouped by dot prefix and overflow shows a note", function()
	withSetup(nil, function(ctx)
		local overlay, state = ctx.overlay, ctx.state
		state.client = snapshot("client", 2)
		overlay:setVisible(true)
		overlay:setTab(2)
		local pool = overlay.ui.probes
		local groups, items = {}, 0
		for i = 1, pool.shown do
			local row = pool.rows[i]
			T.eq(row.frame.Visible, true, "shown rows visible")
			if row.kind == "group" then
				groups[row.cells[1].Text] = true
			elseif row.kind == "item" then
				items += 1
			end
		end
		T.check(groups.Crowd and groups.Ai, "Crowd and Ai groups")
		T.check(groups.counters and groups.gauges, "counters and gauges sections")
		T.check(items >= 9, "items: " .. items)
		T.eq(pool.rows[pool.shown + 1].frame.Visible, false, "unused rows hidden")

		state.client = snapshot("client", 3, 200)
		overlay:refresh()
		noErrors(ctx)
		local last = pool.rows[pool.shown]
		T.eq(last.kind, "note", "overflow note")
		T.check(string.match(last.cells[1].Text, "^%+%d+ more$") ~= nil, "overflow text: " .. last.cells[1].Text)
	end)
end)

T.test("frame graph colours bars against the budget", function()
	withSetup(nil, function(ctx)
		local overlay, state = ctx.overlay, ctx.state
		local snap = snapshot("client", 4)
		for i = 1, 120 do
			snap.frame.history[i] = if i == 120 then 50 elseif i == 119 then 25 else 10
		end
		state.client = snap
		overlay:setVisible(true)
		noErrors(ctx)
		local graph = overlay.ui.graph
		local Theme = ctx.client:require(ctx.client.ReplicatedStorage.Overlay.Theme)
		T.eq(graph.colors[120], Theme.colors.bad, "50 ms is red")
		T.eq(graph.colors[119], Theme.colors.warn, "25 ms is amber")
		T.eq(graph.colors[1], Theme.colors.good, "10 ms is green")
		T.check(graph.heights[120] > graph.heights[1], "taller bar for a slower frame")

		-- a short history is right-aligned, the rest stays empty
		snap.frame.history = { 10, 12 }
		overlay:refresh()
		T.eq(graph.heights[1], 0, "empty slot")
		T.check(graph.heights[120] > 0, "newest on the right")
	end)
end)

T.test("missing and malformed snapshots never error", function()
	withSetup(nil, function(ctx)
		local overlay, state = ctx.overlay, ctx.state
		overlay:setVisible(true)
		for tab = 1, 5 do
			overlay:setTab(tab)
		end
		T.eq(overlay.ui.message.Visible, false, "Players tab has no waiting message")
		overlay:setTab(1)
		T.eq(overlay.ui.message.Visible, true, "waiting message")
		overlay:setSide("server")
		T.check(string.find(overlay.ui.message.Text, "viewers", 1, true) ~= nil, "server hint mentions viewers")

		local junk = {
			{},
			{ frame = 5, probes = "x", net = { 1, 2, false }, memory = { tags = { A = "big" } }, flares = { 1 } },
			{ frame = { history = { 0 / 0, -1, math.huge }, budget = 0.0166 }, probes = { { name = 3 }, { name = "A.B" } } },
			{ net = { { lib = nil, bps = "fast" } }, engine = { ping = 0 / 0 } },
		}
		for _, side in { "client", "server" } do
			overlay:setSide(side)
			for _, snap in junk do
				state[side] = snap
				state.telemetry = { devices = { 5, { device = "VR" } } }
				for tab = 1, 5 do
					overlay:setTab(tab)
				end
			end
		end
		noErrors(ctx)

		-- a throwing source is contained too
		ctx.overlay.source = function()
			error("boom")
		end
		overlay:refresh()
		noErrors(ctx)
	end)
end)

T.test("refreshes at 4 Hz from Heartbeat, only while open", function()
	withSetup(nil, function(ctx)
		local overlay, state, client = ctx.overlay, ctx.state, ctx.client
		state.client = snapshot("client", 5)
		overlay:setVisible(true)
		local base = overlay.refreshes
		for _ = 1, 60 do
			client:step(1 / 60)
		end
		local perSecond = overlay.refreshes - base
		T.check(perSecond >= 3 and perSecond <= 5, "refreshes in one second: " .. perSecond)

		overlay:setVisible(false)
		local closed = overlay.refreshes
		for _ = 1, 60 do
			client:step(1 / 60)
		end
		T.eq(overlay.refreshes, closed, "no refresh while closed")
		T.eq(#client.RunService.Heartbeat._fns, 0, "Heartbeat disconnected while closed")
		T.eq(overlay.gui.Enabled, false, "hidden, kept for the next open")

		local created = ctx.gui.created
		overlay:setVisible(true)
		T.eq(ctx.gui.created, created, "re-opening builds nothing")
	end)
end)

T.test("tabs switch with buttons and stepTab, never on a bare LB / RB press", function()
	withSetup({ gamepad = true, overlay = { tabHints = { "R3+LB", "R3+RB" } } }, function(ctx)
		local overlay, state, gui = ctx.overlay, ctx.state, ctx.gui
		state.client = snapshot("client", 6)
		overlay:setVisible(true)
		local ui = overlay.ui
		T.eq(ui.lbHint.Visible, true, "hint with a gamepad")
		T.eq(ui.lbHint.Text, "R3+LB", "previous tab hint")
		T.eq(ui.rbHint.Text, "R3+RB", "next tab hint")

		for i, b in ui.tabButtons do
			T.eq(b.Selectable, true, "tab selectable")
			T.check(b.NextSelectionLeft ~= nil and b.NextSelectionRight ~= nil, "tab neighbours")
			T.check(b.SelectionImageObject ~= nil, "selection image")
			local _ = i
		end
		T.eq(ui.panel.SelectionGroup, true, "panel is a selection group")
		for _, side in { "Up", "Down", "Left", "Right" } do
			T.check(ui.panel["SelectionBehavior" .. side] ~= Enum.SelectionBehavior.Stop, "the D-pad can leave the panel: " .. side)
		end

		ui.tabButtons[3].Activated:_fire()
		T.eq(overlay.tab, 3, "button switches tab")
		T.eq(ui.pages[3].Visible, true, "page shown")
		T.eq(ui.pages[1].Visible, false, "other page hidden")

		-- the panel is open while the game is played: LB and RB are the game's buttons
		T.eq(#gui.UserInputService.InputBegan._fns, 0, "the panel listens to no key or button")
		local function press(key)
			gui.UserInputService.InputBegan:_fire({ KeyCode = key, UserInputType = Enum.UserInputType.Gamepad1 }, false)
		end
		press(Enum.KeyCode.ButtonR1)
		press(Enum.KeyCode.ButtonL1)
		T.eq(overlay.tab, 3, "a bare RB / LB does not switch tabs")

		-- stepTab is what the runtime calls while the combo's first button is held
		overlay:stepTab(1)
		T.eq(overlay.tab, 4, "next")
		overlay:stepTab(1)
		overlay:stepTab(1)
		T.eq(overlay.tab, 1, "next wraps")
		overlay:stepTab(-1)
		T.eq(overlay.tab, 5, "previous wraps back")
		T.eq(ui.pages[5].Visible, true, "page follows")

		-- selection follows when it is on the tab bar
		gui.GuiService.SelectedObject = ui.tabButtons[5]
		overlay:stepTab(1)
		T.eq(gui.GuiService.SelectedObject, ui.tabButtons[1], "selection moved with the tab")

		ui.sideButton.Activated:_fire()
		T.eq(overlay.side, "server", "side switch")
		T.eq(ui.sideButton.Text, "server", "side label")

		-- closing hands gamepad focus back to the game
		ui.closeButton.Activated:_fire()
		T.eq(overlay.visible, false, "closed by the x button")
		T.eq(gui.GuiService.SelectedObject, nil, "selection cleared")
		noErrors(ctx)
	end)
end)

T.test("tab hints show only what the runtime binds", function()
	withSetup({ gamepad = true }, function(ctx)
		local overlay = ctx.overlay
		overlay:setVisible(true)
		local ui = overlay.ui
		local full = ui.tabHolder.Size
		T.eq(ui.lbHint.Visible, false, "no hints given: none shown")
		T.eq(ui.rbHint.Visible, false)

		local created = ctx.gui.created
		overlay:setTabHints({ "L3+LB", "L3+RB" })
		T.eq(ui.lbHint.Visible, true, "hints appear")
		T.eq(ui.lbHint.Text, "L3+LB")
		T.eq(ui.rbHint.Text, "L3+RB")
		T.check(ui.tabHolder.Size ~= full, "the tab bar makes room")
		overlay:setTabHints(nil)
		T.eq(ui.lbHint.Visible, false, "and go again (overlayGamepadTabs = false)")
		T.eq(ui.tabHolder.Size, full, "the tab bar is full width again")
		overlay:setTabHints({ 1, 2 } :: any)
		T.eq(ui.lbHint.Visible, false, "junk is no hint")
		T.eq(ctx.gui.created, created, "no Instances made")
		noErrors(ctx)
	end)
	-- no gamepad: no hints even when buttons are bound
	withSetup({ overlay = { tabHints = { "R3+LB", "R3+RB" } } }, function(ctx)
		ctx.overlay:setVisible(true)
		T.eq(ctx.overlay.ui.lbHint.Visible, false, "keyboard and mouse: no hint")
	end)
end)

T.test("scale fits phones and grows on TVs", function()
	withSetup({ touch = true, viewport = { 390, 844 } }, function(ctx)
		ctx.overlay:setVisible(true)
		local s = ctx.overlay.ui.scale.Scale
		T.check(s >= 0.72 and s < 1, "portrait phone scale " .. s)
		T.eq(ctx.overlay.ui.lbHint.Visible, false, "no LB hint without a gamepad")
		-- rotating the phone rescales on the next refresh
		ctx.gui.camera.ViewportSize = Vector2.new(844, 390)
		ctx.overlay:refresh()
		T.check(ctx.overlay.ui.scale.Scale >= 0.72, "landscape scale")
		-- the move button cycles corners
		local before = ctx.overlay.ui.panel.AnchorPoint
		ctx.overlay.ui.moveButton.Activated:_fire()
		T.check(ctx.overlay.ui.panel.AnchorPoint ~= before, "moved to another corner")
		noErrors(ctx)
	end)
	withSetup({ tenFoot = true, gamepad = true, viewport = { 1920, 1080 } }, function(ctx)
		ctx.overlay:setVisible(true)
		T.check(ctx.overlay.ui.scale.Scale >= 1.25, "TV scale " .. ctx.overlay.ui.scale.Scale)
	end)
end)

T.test("destroy removes the panel and every connection", function()
	withSetup(nil, function(ctx)
		local overlay = ctx.overlay
		overlay:setVisible(true)
		local screen = overlay.gui
		overlay:destroy()
		T.eq(screen.Parent, nil, "ScreenGui removed")
		T.eq(#ctx.gui.UserInputService.InputBegan._fns, 0, "input disconnected")
		T.eq(#ctx.client.RunService.Heartbeat._fns, 0, "Heartbeat disconnected")
		overlay:setVisible(true) -- after destroy: ignored
		T.eq(overlay.visible, false, "stays closed")
	end)
end)
end
