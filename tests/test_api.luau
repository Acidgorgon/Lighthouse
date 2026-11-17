-- Public API (src/init.luau): off state before start, shared.Lighthouse, enabled = false,
-- start / stop, wrap / bind, snapshot and export.
return function(T)
	T.test("require sets shared.Lighthouse and starts off", function()
		local world = T.world()
		local LH = T.serverLighthouse(world)
		T.eq(world.server.shared.Lighthouse, LH, "shared.Lighthouse")
		T.eq(LH.isActive(), false)
		local p = LH.probe("Before.Start")
		p:begin()
		p:finish()
		LH.count("x")
		LH.gauge("y", 1)
		LH.net("Game", "c", "out", 1)
		T.eq(LH.Core.misuse(), 0)
		local snap = LH.snapshot()
		T.eq(snap.side, "server")
		T.eq(#snap.probes, 0)
		-- hook API frozen for libraries
		for _, k in { "probe", "net", "count", "gauge" } do
			T.eq(type(world.server.shared.Lighthouse[k]), "function", k)
		end
	end)

	T.test("wrap before start measures once started; enabled = false returns fn itself", function()
		local world = T.world()
		local LH = T.serverLighthouse(world)
		local function fn(a, b)
			return a + b, "ok"
		end
		local wrapped = LH.wrap("Early", fn)
		T.check(wrapped ~= fn, "wrapped while not yet started")
		local a, b = wrapped(1, 2)
		T.eq(a, 3)
		T.eq(b, "ok")
		T.eq(LH.start({ enabled = false }), false)
		T.eq(LH.isActive(), false)
		T.eq(LH.wrap("Disabled", fn), fn, "untouched when disabled")
		local conn = LH.bind(world.server.RunService.Heartbeat, "Bound", function() end)
		T.check(conn ~= nil and conn.Disconnect ~= nil, "bind returns the connection")
		conn:Disconnect()
	end)

	T.test("start / stop flip the measuring state and keep the data", function()
		local world = T.world()
		local LH = T.serverLighthouse(world)
		T.eq(LH.start({ budget = 1 / 30, microprofiler = false }), true)
		T.eq(LH.isActive(), true)
		local p = LH.probe("Live")
		for i = 1, 3 do
			p:begin()
			p:finish()
			LH.Core.endFrame(1 / 60, 200 + i * 0.6)
		end
		T.eq(LH.snapshot().frame.budget, 1000 / 30, "opts reach Core")
		T.eq(LH.start({ frames = 300 }), true, "start again merges opts")
		LH.stop()
		T.eq(LH.isActive(), false)
		p:begin()
		p:finish()
		T.eq(LH.Core.misuse(), 0)
		T.check(LH.snapshot().frame.budget == 1000 / 30, "earlier opts kept")
		if #world.warnings > 0 then
			print("    runtime warnings: " .. table.concat(world.warnings, " | "))
		end
	end)

	T.test("export is JSON with the documented top-level keys", function()
		local world = T.world()
		local LH = T.serverLighthouse(world)
		LH.start({ microprofiler = false })
		local p = LH.probe("Export.Me")
		for i = 1, 90 do
			p:begin()
			p:finish()
			LH.Core.endFrame(1 / 60, 300 + i / 60)
		end
		local text = LH.export(1)
		local doc, err = LH.Core.Json.decode(text)
		T.check(doc ~= nil, tostring(err))
		T.eq(doc.lighthouse, 1)
		T.eq(doc.side, "server")
		T.eq(type(doc.server), "table")
		T.eq(doc.server.v, 1)
		T.eq(type(doc.recording), "table")
		T.eq(doc.recording.probes[1], "Export.Me")
		LH.stop()
	end)
end
