-- Runtime: frame loop, engine sampling, viewer stream, telemetry, overlay toggle, remote wrapper.
-- Server and clients run through the mock network (tests/mock.luau, Mock.extendLighthouse).
return function(T)
	local Mock = T.Mock
	Mock.extendLighthouse()
	local DT = 1 / 60
	local OVERLAY_PATH = T.SRC .. "/Overlay/Overlay.luau"

	-- Stand-in for Overlay.luau (the real one needs the GUI mock): records what Runtime asks.
	local function fakeOverlayModule()
		local mod = { created = 0, last = nil }
		function mod.new(source)
			mod.created += 1
			local o = { visible = false, destroyed = false, source = source }
			function o:setVisible(on)
				self.visible = on
			end
			function o:isVisible()
				return self.visible
			end
			function o:destroy()
				self.destroyed = true
			end
			mod.last = o
			return o
		end
		return mod
	end

	local function module(env, root, ...)
		local inst = root
		for _, name in { ... } do
			inst = inst:FindFirstChild(name) or error("no module " .. name)
		end
		return env:require(inst)
	end

	-- configure(world) runs before players join (world.lh knobs); opts go to Lighthouse.start
	-- (clientOpts, when given, replace opts on the clients)
	local function setup(nPlayers: number, opts: any?, configure: ((any) -> ())?, clientOpts: any?)
		local world = T.world({ latency = 0.03, start = 1000 })
		if configure then
			configure(world)
		end
		for _ = 1, nPlayers do
			world:addPlayer()
		end
		local function clock()
			return world.now
		end
		local o = table.clone(opts or {})
		o.clock = clock
		local server = {
			env = world.server,
			lh = T.serverLighthouse(world),
			core = module(world.server, world.lighthouseModule, "Core"),
			rt = module(world.server, world.lighthouseModule, "Runtime"),
		}
		server.core.setClock(clock)
		server.lh.start(table.clone(o))
		local clients = {}
		for i = 1, nPlayers do
			local env = world.clients[i]
			local overlay = fakeOverlayModule()
			env.modules[OVERLAY_PATH] = overlay
			local root = env.ReplicatedStorage:FindFirstChild("Lighthouse")
			local c = {
				env = env,
				overlay = overlay,
				lh = env:require(root),
				core = module(env, root, "Core"),
				rt = module(env, root, "Runtime"),
			}
			c.core.setClock(clock)
			local co = o
			if clientOpts ~= nil then
				co = table.clone(clientOpts)
				co.clock = clock
			end
			c.lh.start(table.clone(co))
			clients[i] = c
		end
		return world, server, clients
	end

	local function run(world, seconds: number, each: (() -> ())?)
		for _ = 1, math.floor(seconds / DT + 0.5) do
			if each then
				each()
			end
			world:frame(DT)
		end
	end

	T.test("Device classes from inputs", function()
		local world = Mock.newWorld()
		local Device = world.server:requireFile(T.SRC .. "/Runtime/Device.luau")
		T.eq(Device.fromInputs(false, false, false, true, 1080), "Desktop")
		T.eq(Device.fromInputs(false, false, true, false, 390), "Mobile")
		T.eq(Device.fromInputs(false, false, true, false, 820), "Tablet")
		T.eq(Device.fromInputs(false, false, true, true, 390), "Desktop", "touch laptop")
		T.eq(Device.fromInputs(false, true, false, false, 1080), "Console")
		T.eq(Device.fromInputs(true, true, true, false, 1080), "VR")
	end)

	T.test("Device.detect on mock clients", function()
		local world = T.world()
		world.lh.devices[1] = { touch = true, viewport = { 844, 390 } }
		world.lh.devices[2] = { touch = true, viewport = { 1180, 820 } }
		world.lh.devices[3] = { tenFoot = true }
		world.lh.devices[4] = { vr = true }
		local expected = { "Mobile", "Tablet", "Console", "VR", "Desktop" }
		for i = 1, 5 do
			world:addPlayer()
			local env = world.clients[i]
			local Device = env:requireFile(T.SRC .. "/Runtime/Device.luau")
			T.eq(Device.detect(), expected[i], "client " .. i)
		end
	end)

	T.test("frame loop: endFrame once per frame on each side, 1 Hz engine sample", function()
		local world, server, clients = setup(1)
		local work = server.lh.probe("Server.Work")
		local cwork = clients[1].lh.probe("Client.Work")
		run(world, 3, function()
			work:begin()
			work:finish()
			cwork:begin()
			cwork:finish()
		end)
		local s = server.core.snapshot("server")
		T.check(s.frames >= 179 and s.frames <= 181, "server frames " .. tostring(s.frames))
		T.near(s.frame.fps, 60, 1, "server fps")
		T.near(s.frame.p50, 1000 / 60, 0.1 * 1000 / 60, "server frame p50")
		T.eq(s.probes[1].name, "Server.Work")
		T.near(s.engine.heartbeatMs, 2.5, 1e-9, "Stats.HeartbeatTimeMs")
		T.eq(s.engine.instances, 5000)
		T.eq(s.engine.physicsFps, 60)
		T.eq(s.players, 1)
		T.near(s.serverTime, world.now, 1e-6)
		T.eq(s.memory.totalMb, 512)
		T.eq(s.memory.tags.LuaHeap, 11, "memory tags")
		T.eq(s.memory.luaHeapMb, 11)
		T.check(type(s.memory.gcKb) == "number" and s.memory.gcKbPerSec >= 0)
		local c = clients[1].core.snapshot("client")
		T.check(c.frames >= 179 and c.frames <= 181, "client frames " .. tostring(c.frames))
		T.eq(c.probes[1].name, "Client.Work")
		T.near(c.engine.ping, 80, 1e-6, "ping ms")
		T.eq(c.device, "Desktop")
		-- the frame loop connects once even when start is called again
		local hb = #world.server.RunService.Heartbeat._fns
		server.lh.start({})
		clients[1].lh.start({})
		T.eq(#world.server.RunService.Heartbeat._fns, hb, "no double connect on restart")
		server.lh.stop()
		T.eq(#world.server.RunService.Heartbeat._fns, hb - 1, "stop disconnects")
	end)

	T.test("missing Stats members are read once, then skipped; nothing errors", function()
		local world, server = setup(1, nil, function(world)
			world.lh.statsMissing.HeartbeatTimeMs = true
			world.lh.statsMissing.ContactsCount = true
			world.lh.statsMissing.GetMemoryUsageMbForTag = true
		end)
		run(world, 5.5)
		local Sampler = module(world.server, world.lighthouseModule, "Runtime", "Sampler")
		T.eq(Sampler.supported("HeartbeatTimeMs"), false)
		T.eq(Sampler.supported("PhysicsStepTimeMs"), true)
		T.eq(Sampler.reads.HeartbeatTimeMs, 1, "a missing property is tried once")
		T.check(Sampler.reads.PhysicsStepTimeMs >= 5, "supported ones are read every second")
		T.eq(Sampler.reads["tag:LuaHeap"], 1, "a missing method is tried once")
		local s = server.core.snapshot("server")
		T.eq(s.engine.heartbeatMs, nil)
		T.eq(s.engine.contacts, nil)
		T.near(s.engine.physicsMs, 1.25, 1e-9)
		T.check(next(s.memory.tags) == nil, "no tags")
		T.check(s.memory.luaHeapMb > 0, "heap falls back to gcinfo")
		-- a value that is not a number counts as missing too
		world.lh.stats.InstanceCount = "lots"
		Sampler.resetCache()
		Sampler.sample(world.now)
		T.eq(Sampler.supported("InstanceCount"), false)
		T.eq(#world.warnings, 0, "no warnings: " .. table.concat(world.warnings, "; "))
	end)

	T.test("memory calls are skipped while Stats.MemoryTrackingEnabled is false (no live warning spam)", function()
		local world, server = setup(1, nil, function(world)
			world.lh.stats.MemoryTrackingEnabled = false
		end)
		run(world, 5.5)
		local Sampler = module(world.server, world.lighthouseModule, "Runtime", "Sampler")
		T.eq(world.lh.statsReads.GetMemoryUsageMbForTag, nil, "no tag reads while tracking is off")
		T.eq(world.lh.statsReads.GetTotalMemoryUsageMb, nil, "no total read while tracking is off")
		T.check(Sampler.reads.MemoryTrackingEnabled >= 5, "the flag is checked every sample")
		local s = server.core.snapshot("server")
		T.eq(s.memory.totalMb, nil)
		T.check(next(s.memory.tags) == nil, "no tags")
		T.check(s.memory.luaHeapMb > 0, "heap falls back to gcinfo")
		-- tracking switched on later: the reads start on the next sample
		world.lh.stats.MemoryTrackingEnabled = true
		run(world, 1.5)
		s = server.core.snapshot("server")
		T.eq(s.memory.totalMb, 512)
		T.eq(s.memory.tags.LuaHeap, 11)
		T.eq(#world.warnings, 0, "no warnings: " .. table.concat(world.warnings, "; "))
	end)

	T.test("server streams to viewers that said hello, never to others", function()
		-- player 1 (UserId 1001) is the game's creator
		local world, server, clients = setup(2, { stream = 1 })
		local probe = server.lh.probe("Npc.Think")
		server.lh.count("Pathfinds", 3)
		run(world, 0.5)
		T.eq(clients[1].rt.serverSnapshot(), nil, "nothing before the hello")
		T.eq(clients[2].rt.serverSnapshot(), nil)
		local s2cBefore = world.stats.s2cCalls
		run(world, 3.2, function()
			probe:begin()
			probe:finish()
			server.lh.count("Pathfinds")
		end)
		local snap = clients[1].rt.serverSnapshot()
		T.check(snap ~= nil, "viewer has a snapshot")
		T.eq(snap.side, "server")
		T.eq(snap.players, 2)
		T.check(snap.frame.fps > 55, "fps " .. snap.frame.fps)
		local found = false
		for _, p in snap.probes do
			if p.name == "Npc.Think" then
				found = true
			end
		end
		T.check(found, "server probe name arrives through the name table")
		T.check(clients[1].rt.Client.counters.snapshots >= 3, "streamed every second")
		T.check(clients[1].rt.Client.counters.names >= 1)
		-- player 2 asked too but is not a viewer: no reply at all
		T.eq(clients[2].rt.serverSnapshot(), nil, "non-viewer gets nothing")
		T.eq(clients[2].rt.Client.counters.snapshots, 0)
		T.eq(clients[2].rt.Client.counters.names, 0)
		T.eq(server.rt.Server.counters.denied, 1)
		T.eq(#server.rt.Server.viewers(), 1)
		T.check(world.stats.s2cCalls > s2cBefore)
		-- Lighthouse's own traffic shows up as a channel
		local s = server.core.snapshot("server")
		local stream = false
		for _, c in s.net do
			if c.lib == "Lighthouse" and c.channel == "Stream" and c.dir == "out" then
				stream = true
			end
		end
		T.check(stream, "Lighthouse.Stream channel counted")
		print(string.format("    streamed snapshot: %d bytes", buffer.len(server.rt.Server.lastPayload)))
	end)

	T.test("viewer rules: list, function, group rank, Studio", function()
		local function viewersFor(opts, configure)
			local world, server = setup(3, opts, configure)
			local Server = server.rt.Server
			local out = {}
			for i, p in world.players do
				out[i] = Server.checkViewer(p)
			end
			return out
		end
		local d = viewersFor(nil)
		T.check(d[1] and not d[2] and not d[3], "default: creator only")
		local l = viewersFor({ viewers = { 1002, 1003 } })
		T.check(not l[1] and l[2] and l[3], "user id list")
		local f = viewersFor({
			viewers = function(p)
				return p.Name == "Player3"
			end,
		})
		T.check(not f[1] and not f[2] and f[3], "function")
		local e = viewersFor({
			viewers = function()
				error("oops")
			end,
		})
		T.check(not e[1] and not e[2], "erroring function denies")
		local g = viewersFor({ viewers = { group = 77, rank = 200 } }, function(world)
			world.lh.ranks[1002] = { [77] = 250 }
			world.lh.ranks[1003] = { [77] = 100 }
		end)
		T.check(not g[1] and g[2] and not g[3], "group rank")
		local og = viewersFor(nil, function(world)
			world.lh.creatorType = "Group"
			world.lh.creatorId = 55
			world.lh.ranks[1003] = { [55] = 255 }
		end)
		T.check(not og[1] and not og[2] and og[3], "group-owned game: rank 255")
		local st = viewersFor({ viewers = {} }, function(world)
			world.lh.studio = true
		end)
		T.check(st[1] and st[2] and st[3], "everyone in Studio")
	end)

	T.test("overlay toggle: F8 and L3+R3 for viewers only, bye stops the stream", function()
		local world, server, clients = setup(2)
		run(world, 0.5)
		local viewer, other = clients[1], clients[2]
		local KeyCode = Enum.KeyCode

		Mock.press(viewer.env, KeyCode.F8)
		T.eq(viewer.overlay.created, 0, "live game: waits for the server's answer")
		run(world, 0.2)
		T.eq(viewer.overlay.created, 1, "opened after the server allowed it")
		T.check(viewer.overlay.last.visible)
		T.check(viewer.rt.Client.state().allowed == true)
		run(world, 2)
		T.check(viewer.overlay.last.source("server") ~= nil, "overlay source has the server snapshot")
		T.eq(viewer.overlay.last.source("client").side, "client")

		Mock.press(other.env, KeyCode.F8)
		run(world, 6)
		T.eq(other.overlay.created, 0, "non-viewer cannot open it")
		T.eq(other.rt.Client.state().allowed, false)
		T.eq(other.rt.Client.counters.snapshots, 0)

		-- gamepad: L3 held, then R3
		Mock.press(viewer.env, KeyCode.ButtonL3, true)
		T.check(viewer.overlay.last.visible, "one stick button does nothing")
		Mock.press(viewer.env, KeyCode.ButtonR3, true)
		T.check(not viewer.overlay.last.visible, "L3+R3 toggles off")
		Mock.release(viewer.env, KeyCode.ButtonL3)
		Mock.release(viewer.env, KeyCode.ButtonR3)
		run(world, 0.2)
		T.eq(#server.rt.Server.viewers(), 0, "closing says bye")
		local n = viewer.rt.Client.counters.snapshots
		run(world, 3)
		T.eq(viewer.rt.Client.counters.snapshots, n, "no stream after bye")

		-- the panel's own close button: Runtime notices and says bye
		Mock.press(viewer.env, KeyCode.ButtonL3, true)
		Mock.press(viewer.env, KeyCode.ButtonR3, true)
		run(world, 0.2)
		T.check(viewer.overlay.last.visible)
		T.eq(#server.rt.Server.viewers(), 1)
		viewer.overlay.last:setVisible(false)
		run(world, 1)
		T.eq(#server.rt.Server.viewers(), 0, "bye after closing from the panel")

		-- in Studio everyone opens at once. F7 (the 0.1.0 default) does nothing now, and neither does a
		-- processed F8 (Roblox marks F7 processed, which is why the default moved)
		world.lh.studio = true
		Mock.press(other.env, KeyCode.F7)
		T.eq(other.overlay.created, 0, "F7 is not the toggle")
		Mock.press(other.env, KeyCode.F8, false, true)
		T.eq(other.overlay.created, 0, "processed input does not toggle")
		Mock.press(other.env, KeyCode.F8)
		T.eq(other.overlay.created, 1, "Studio: opens immediately")
		other.lh.stop()
		T.check(other.overlay.last.destroyed, "stop destroys the overlay")
	end)

	T.test("overlay: the real Overlay module opens with live numbers; a missing one is contained", function()
		local GuiMock = loadstring(readfile(T.ROOT .. "/tests/gui_mock.luau"))()
		local world, _, clients = setup(2, nil, function(world)
			world.lh.studio = true
		end)
		local c = clients[1]
		c.env.modules[OVERLAY_PATH] = nil -- use src/Overlay/Overlay.luau
		local gui = GuiMock.install(Mock, c.env)
		local ok, err = pcall(function()
			run(world, 1)
			c.lh.overlay(true)
			T.check(c.rt.Client.overlayVisible(), "real overlay visible")
			run(world, 2)
			T.check(c.rt.serverSnapshot() ~= nil, "Studio: streamed to everyone")
			c.lh.overlay()
			T.check(not c.rt.Client.overlayVisible(), "toggled off")
			c.lh.stop()
		end)
		gui:uninstall()
		T.check(ok, tostring(err))

		-- no Overlay module at all: a warning, never an error
		local other = clients[2]
		local overlayFolder = world.lighthouseModule:FindFirstChild("Overlay")
		overlayFolder.Parent = nil
		other.env.modules[OVERLAY_PATH] = nil
		other.lh.overlay(true)
		T.check(not other.rt.Client.overlayVisible())
		T.check(string.find(table.concat(world.warnings, "\n"), "overlay unavailable", 1, true) ~= nil)
	end)

	T.test("telemetry: reports aggregate by device class with real percentiles", function()
		local reports = {}
		local world, server, clients = setup(3, { telemetry = { sample = 1, every = 10 } }, function(world)
			world.lh.devices[1] = { touch = true, viewport = { 844, 390 }, ping = 0.15 }
			world.lh.devices[2] = { tenFoot = true, ping = 0.05 }
		end)
		server.lh.onReport(function(r)
			table.insert(reports, r)
		end)
		local probe = clients[1].lh.probe("Mobile.Work")
		run(world, 25.5, function()
			probe:begin()
			probe:finish()
		end)
		T.eq(#reports, 6, "3 clients x 2 reports")
		T.eq(reports[1].player ~= nil, true)
		local agg = server.rt.telemetry()
		T.check(agg ~= nil, "aggregate")
		T.eq(agg.reports, 6)
		T.eq(agg.players, 3)
		T.eq(#agg.devices, 3)
		local byName = {}
		for _, d in agg.devices do
			byName[d.device] = d
		end
		T.check(byName.Mobile and byName.Console and byName.Desktop, "three device classes")
		T.eq(byName.Mobile.players, 1)
		T.eq(byName.Mobile.reports, 2)
		T.near(byName.Mobile.frameP50, 1000 / 60, 0.12 * 1000 / 60, "merged frame p50")
		T.near(byName.Mobile.pingMs, 150, 1, "avg ping")
		T.near(byName.Console.pingMs, 50, 1)
		T.eq(byName.Mobile.memoryMb, 512)
		T.eq(byName.Mobile.probes[1].name, "Mobile.Work")
		-- merged histograms count every reported frame: 2 reports x 10 s x 60 fps
		local Telemetry = server.rt.Telemetry
		T.eq(Telemetry.server.devices.Mobile.frame.total, 1200)
		-- analytics: low-cardinality fields, rate limited to one batch per player per minute
		local events = world.lh.analytics
		T.eq(#events, 6, "3 players x 2 events (second report inside the 60 s gap)")
		T.eq(events[1].event, "LH_FrameP50")
		local fields = events[1].fields
		T.check(fields.CustomField01 ~= nil and fields.CustomField02 == "4242", "device + place fields")
		-- viewers see the aggregate in the streamed snapshot
		T.eq(clients[1].rt.telemetry(), nil, "not subscribed yet")
		run(world, 2)
		local copy = clients[1].rt.telemetry()
		T.check(copy ~= nil, "viewer copy of the aggregate")
		T.eq(copy.reports, 6)
		T.eq(#copy.devices, 3)
		T.eq(clients[1].lh.snapshot().side, "client")
		T.eq(server.lh.snapshot().reports.reports, 6, "server snapshot carries reports")
	end)

	T.test("telemetry: sampling, rate limits and hostile payloads never throw", function()
		local world, server, clients = setup(2, { telemetry = { sample = 0, every = 10 } })
		local Telemetry = server.rt.Telemetry
		local Server = server.rt.Server
		local CTelemetry = clients[1].rt.Telemetry
		T.eq(CTelemetry.client.sampled, false, "not in the sample (decided once per session)")
		run(world, 0.5)
		local remote = world:replica(1, server.rt.Server.remote())
		local Wire = clients[1].rt.Wire
		-- a valid report, fired 5 times in a row: one accepted (1 per every/2 s)
		local fh = clients[1].core.histogram()
		fh:add(16.6, 100)
		local payload = Wire.encodeReport({
			device = "Mobile",
			pingMs = 100,
			memoryMb = 900,
			heapMb = 60,
			frameP50 = 16.6,
			frameP95 = 16.6,
			frameP99 = 16.6,
			scriptP50 = 2,
			frames = 100,
			probes = {},
		}, fh:encode(), fh:encode())
		local before = Telemetry.stats().reports
		for _ = 1, 5 do
			remote:FireServer(payload)
		end
		run(world, 0.2)
		T.eq(Telemetry.stats().reports - before, 1, "rate limited")
		T.eq(Telemetry.stats().rateLimited, 4)
		run(world, 5.1)
		remote:FireServer(payload)
		run(world, 0.2)
		T.eq(Telemetry.stats().reports - before, 2, "accepted after every/2")

		-- forged histogram: absurd frame count
		local forged = clients[1].core.histogram()
		forged:add(16.6, 4000000000)
		run(world, 6)
		remote:FireServer(Wire.encodeReport({ device = "Desktop", probes = {} }, forged:encode(), nil))
		run(world, 0.2)
		T.eq(Telemetry.stats().reports - before, 2, "forged histogram dropped")

		-- hostile payloads from player 2
		local evil = world:replica(2, server.rt.Server.remote())
		local dropped = Telemetry.stats().dropped
		local junk = {
			"hello",
			42,
			nil,
			{ 1, 2, 3 },
			true,
			buffer.create(0),
			buffer.create(1),
			buffer.create(5000),
			buffer.fromstring("\1\9"),
			buffer.fromstring("\2\3"),
			buffer.fromstring("\1\4extra"),
			buffer.fromstring("\1\3\1\0\0\0"),
		}
		for i = 1, #junk do
			evil:FireServer(junk[i])
		end
		evil:FireServer()
		evil:FireServer(payload, "extra", 1)
		run(world, 0.2)
		T.eq(Server.counters.errors, 0, "nothing threw")
		T.check(Telemetry.stats().dropped - dropped >= #junk, "junk dropped and counted")
		-- hello flood: 4 per minute
		for _ = 1, 8 do
			evil:FireServer(Wire.encodeHello())
		end
		run(world, 0.2)
		T.eq(Server.counters.helloLimited, 4, "4 hellos per minute")
		T.eq(#world.warnings, 0, "no warnings: " .. table.concat(world.warnings, "; "))
	end)

	T.test("telemetry: a server-only option reaches clients (they pass nothing)", function()
		local world, server, clients = setup(2, { telemetry = { sample = 1, every = 10 } }, nil, {})
		local reports = 0
		server.lh.onReport(function()
			reports += 1
		end)
		run(world, 11)
		T.eq(clients[1].rt.Telemetry.client.sampled, true, "sample from the server's option")
		T.eq(reports, 2, "both clients reported with only Lighthouse.start() on their side")
		-- an explicit client option still wins
		local _, _, others = setup(1, { telemetry = { sample = 1, every = 10 } }, nil, { telemetry = false })
		T.eq(others[1].rt.Telemetry.client.cfg.enabled, false)
		-- server telemetry off: clients stay off
		local _, _, quiet = setup(1, nil, nil, {})
		T.eq(quiet[1].rt.Telemetry.client.cfg.enabled, false)
	end)

	T.test("server stop drops per-player state (PlayerRemoving is disconnected while stopped)", function()
		local world, server = setup(1, { telemetry = { sample = 1, every = 10 } })
		run(world, 11)
		local Telemetry = server.rt.Telemetry
		T.check(next(Telemetry.server.lastReport) ~= nil, "a report was rate-limit tracked")
		server.lh.stop()
		T.eq(next(Telemetry.server.lastReport), nil, "nothing kept per player after stop")
	end)

	T.test("hello: a player who leaves while the viewer check yields is not kept", function()
		local gate: thread? = nil
		local world, server = setup(1, {
			viewers = function()
				gate = coroutine.running()
				coroutine.yield() -- like GetRankInGroup or a DataStore read
				return true
			end,
		})
		local Server = server.rt.Server
		local Wire = server.rt.Wire
		local player = world.players[1]
		local co = coroutine.create(function()
			Server.receive(player, Wire.encodeHello())
		end)
		coroutine.resume(co)
		T.check(gate ~= nil, "viewer check is waiting")
		world:removePlayer(player)
		coroutine.resume(co)
		T.eq(coroutine.status(co), "dead")
		T.eq(#Server.viewers(), 0, "no viewer entry for a player who left")
		local before = Server.counters.snapshots
		run(world, 3)
		T.eq(Server.counters.snapshots, before, "nothing streamed to them")
		T.eq(Server.counters.errors, 0)
	end)

	T.test("telemetry: HTTP export of the aggregate, failures contained", function()
		local world, server = setup(2, {
			telemetry = { sample = 1, every = 10, analytics = false, http = { url = "https://example.test/lh", every = 30 } },
		})
		run(world, 31)
		local posts = world.lh.http
		T.eq(#posts, 1, "one POST after 30 s")
		T.eq(posts[1].url, "https://example.test/lh")
		T.check(string.find(posts[1].body, '"devices"', 1, true) ~= nil, "aggregate JSON")
		T.check(string.find(posts[1].body, '"lighthouse":1', 1, true) ~= nil)
		T.eq(#world.lh.analytics, 0, "analytics off")
		world.lh.httpFail = true
		run(world, 31)
		T.eq(server.rt.Telemetry.stats().httpFailed, 1, "failure counted, not thrown")
	end)

	T.test("analytics failures are contained", function()
		local world, server = setup(1, { telemetry = { sample = 1, every = 10 } }, function(world)
			world.lh.analyticsFail = true
		end)
		run(world, 11)
		T.eq(server.rt.Telemetry.stats().reports, 1)
		T.check(server.rt.Telemetry.stats().analyticsFailed >= 1)
	end)

	T.test("Runtime.remote counts bytes both ways", function()
		local world, server, clients = setup(2)
		local remoteInst = world.server.InstanceLib.new("RemoteEvent", world.server.ReplicatedStorage)
		remoteInst.Name = "Shop"
		local wrapped = server.lh.remote(remoteInst)
		local got = {}
		wrapped.OnServerEvent:Connect(function(player, a, b)
			table.insert(got, { player, a, b })
		end)
		run(world, 0.1)
		local creplica = world:replica(1, remoteInst)
		local cwrapped = clients[1].lh.remote(creplica)
		local cgot = 0
		cwrapped.OnClientEvent:Connect(function()
			cgot += 1
		end)
		for _ = 1, 180 do
			wrapped:FireAllClients(buffer.create(100))
			cwrapped:FireServer("buy", 3)
			world:frame(DT)
		end
		run(world, 0.1)
		T.eq(#got, 180)
		T.eq(got[1][2], "buy")
		T.eq(cgot, 180)
		local function channel(snap, dir)
			for _, c in snap.net do
				if c.lib == "Remote" and c.channel == "Shop" and c.dir == dir then
					return c
				end
			end
			return nil
		end
		local s = server.core.snapshot("server")
		local out = channel(s, "out")
		T.check(out ~= nil, "server out channel")
		T.near(out.avg, 102, 1e-6, "buffer measured exactly (+2)")
		T.near(out.pps, 120, 15, "two players per FireAllClients")
		local inn = channel(s, "in")
		T.check(inn ~= nil, "server in channel")
		T.near(inn.avg, 5 + 9, 1e-6, "string + number estimate")
		local c = channel(clients[1].core.snapshot("client"), "in")
		T.check(c ~= nil and math.abs(c.avg - 102) < 1e-6, "client in channel")
		T.eq(clients[1].rt.sizeOf({ a = 1, b = { 1, 2 } }, Vector3.new(1, 2, 3), true), (2 + 3 + 9 + 3 + 2 + 9 + 9) + 13 + 1)
	end)
end
