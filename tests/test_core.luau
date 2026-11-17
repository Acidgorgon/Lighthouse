-- Counters, gauges, network channels, flares, snapshot shape, recording.
return function(T)
	local DT = 1 / 60

	local function find(list, key, value)
		for _, e in list do
			if e[key] == value then
				return e
			end
		end
		return nil
	end

	T.test("counters report per second over the last completed second", function()
		local h = T.harness()
		local Core = h.Core
		h.seconds(3, DT, function()
			Core.count("Pathfinds")
			Core.count("Pathfinds")
			Core.count("Spawns", 0.5)
		end)
		T.near(Core.counterRate("Pathfinds"), 120, 1e-9)
		T.near(Core.counterRate("Spawns"), 30, 1e-9)
		h.seconds(2, DT)
		T.eq(Core.counterRate("Pathfinds"), 0, "quiet second -> 0")
		-- bad input is ignored, never an error
		Core.count(nil :: any)
		Core.count("Pathfinds", 0 / 0)
		Core.count("Pathfinds", "3" :: any)
		Core.count("Pathfinds", math.huge)
		h.seconds(1, DT)
		T.eq(Core.counterRate("Pathfinds"), 0)
		local snap = Core.snapshot("server")
		local c = find(snap.counters, "name", "Spawns")
		T.check(c and c.perSec == 0, "listed with perSec")
	end)

	T.test("gauges keep the last value and the 10 s min / max", function()
		local h = T.harness()
		local Core = h.Core
		Core.gauge("Npcs", 50)
		h.seconds(1, DT)
		Core.gauge("Npcs", 10)
		Core.gauge("Npcs", 30)
		h.seconds(2, DT)
		local g = find(Core.snapshot("client").gauges, "name", "Npcs")
		T.eq(g.value, 30)
		T.eq(g.min, 10)
		T.eq(g.max, 50)
		h.seconds(12, DT)
		g = find(Core.snapshot("client").gauges, "name", "Npcs")
		T.eq(g.min, 30, "old extremes leave after 10 s")
		T.eq(g.max, 30)
		Core.gauge("Npcs", 0 / 0)
		Core.gauge(nil :: any, 1)
		T.eq(find(Core.snapshot("client").gauges, "name", "Npcs").value, 30, "NaN ignored")
	end)

	T.test("net: bytes/s, packets/s, avg size, peak, grouped by lib", function()
		local h = T.harness()
		local Core = h.Core
		h.seconds(3, DT, function()
			Core.net("Current", "Move", "out", 100)
			Core.net("Current", "Move", "in", 20)
			Core.net("Current", "Move", "in", 40)
			Core.net("Ripple", "State", "out", 300)
		end)
		local early = find(Core.snapshot("server").net, "dir", "in")
		h.seconds(1, DT, function()
			Core.net("Current", "Move", "out", 400) -- a busy second
		end)
		h.seconds(1, DT, function()
			Core.net("Current", "Move", "out", 100)
		end)
		T.near(early.avg, 30, 1e-9, "avg bytes per packet")
		T.near(early.pps, 120, 1e-9)
		local net = Core.snapshot("server").net
		T.eq(#net, 2 + 0 + 1, "Current.Move in/out + Ripple.State out (Ripple in had no traffic)")
		T.eq(net[1].lib, "Current")
		T.eq(net[1].dir, "in", "in before out")
		local out
		for _, c in net do
			if c.lib == "Current" and c.dir == "out" then
				out = c
			end
		end
		T.near(out.bps, 6000, 1e-6)
		T.near(out.pps, 60, 1e-9)
		T.near(out.avg, 100, 1e-9)
		T.near(out.peak, 24000, 1e-6, "peak over 10 s")
		T.near(net[1].pps, 0, 1e-9, "in is quiet now, still listed for its 10 s peak")
		-- invalid calls are ignored
		Core.net("Current", "Move", "sideways", 10)
		Core.net("Current", "Move", "out", -1)
		Core.net("Current", "Move", "out", 0 / 0)
		Core.net(nil :: any, "x", "out", 1)
		Core.net("Current", nil :: any, "out", 1)
		h.seconds(1, DT)
		T.check(find(Core.snapshot("server").net, "channel", "Move").bps == 0)
	end)

	T.test("net: top senders by bytes out when a key is passed", function()
		local h = T.harness()
		local Core = h.Core
		local players = {}
		for i = 1, 8 do
			players[i] = setmetatable({}, {
				__tostring = function()
					return "Player" .. i
				end,
			})
		end
		h.seconds(20, DT, function()
			for i = 1, 8 do
				Core.net("Current", "Move", "out", i * 10, players[i])
			end
			Core.net("Current", "Move", "in", 999, players[1]) -- in is not ranked
		end)
		local top = Core.snapshot("server").netTop
		T.eq(#top, 5, "top 5")
		T.eq(top[1].who, "Player8")
		T.eq(top[5].who, "Player4")
		T.check(math.abs(top[1].bps - 4800) / 4800 < 0.15, "about 10 s average: " .. top[1].bps)
		-- players that stop sending fade out of the list
		h.seconds(120, DT)
		T.eq(#Core.snapshot("server").netTop, 0)
	end)

	T.test("flares: over budget and over 1.5x the 10 s median, with top probes", function()
		local h = T.harness({ budget = 1 / 60 })
		local Core = h.Core
		local ps = {}
		for i = 1, 7 do
			ps[i] = Core.probe("P" .. i)
		end
		h.seconds(3, DT)
		T.eq(#Core.flares(), 0, "frames at budget are not flares")
		-- a slow frame: probes with distinct self times
		for i = 1, 7 do
			ps[i]:begin()
			h.spend(i * 0.001)
			ps[i]:finish()
		end
		h.frame(0.05)
		local fl = Core.flares()
		T.eq(#fl, 1)
		T.near(fl[1].frameMs, 50, 1e-9)
		T.eq(#fl[1].top, 5, "top 5 probes")
		T.eq(fl[1].top[1].name, "P7")
		T.near(fl[1].top[1].ms, 7, 1e-6)
		T.eq(fl[1].top[5].name, "P3")
		-- steady 20 ms frames: over budget, but a 25 ms frame is not 1.5x the median
		h.seconds(12, 0.02)
		local n = #Core.flares()
		h.frame(0.025)
		T.eq(#Core.flares(), n, "25 ms vs 20 ms median: not a flare")
		h.frame(0.04)
		T.eq(#Core.flares(), n + 1, "40 ms is")
		T.eq(Core.flares()[1].frameMs, 40, "newest first")
		-- only the last 32 are kept
		for _ = 1, 40 do
			h.frame(0.1)
		end
		T.eq(#Core.flares(), 32)
	end)

	T.test("onFlare fires at most 2 per second and gets its own copy", function()
		local h = T.harness({ budget = 1 / 60 })
		local Core = h.Core
		local got = {}
		local off = Core.onFlare(function(f)
			table.insert(got, f)
		end)
		Core.onFlare(function()
			error("listener errors are contained")
		end)
		h.seconds(2, DT)
		for _ = 1, 10 do
			h.frame(0.06) -- 10 flares inside 0.6 s
		end
		T.eq(#got, 2, "rate limited")
		T.near(got[1].frameMs, 60, 1e-9)
		T.check(type(got[1].top) == "table")
		local first = got[1]
		for _ = 1, 20 do
			h.frame(0.06)
		end
		T.check(#got <= 2 * 3 + 2, "about 2 per second: " .. #got)
		T.near(first.frameMs, 60, 1e-9, "copy not overwritten")
		local n = #got
		off()
		h.frame(0.5)
		h.frame(0.5)
		T.eq(#got, n, "unregistered")
	end)

	T.test("snapshot shape", function()
		local h = T.harness({ budget = 1 / 60 })
		local Core = h.Core
		local probes = {}
		for i = 1, 50 do
			probes[i] = Core.probe("Sys.P" .. i)
		end
		Core.setEngine({ heartbeatMs = 3 }, { totalMb = 900, luaHeapMb = 80, tags = { Script = 12 }, gcKb = 1, gcKbPerSec = 2 }, {
			device = "Desktop",
			players = 12,
			serverTime = function()
				return 12345
			end,
		})
		local function work()
			for i = 1, 50 do
				probes[i]:begin()
				h.spend(i * 0.00001)
				probes[i]:finish()
			end
			Core.count("Hits")
			Core.gauge("Npcs", 4)
			Core.net("Game", "Shop", "out", 50)
		end
		h.seconds(3, DT, work)
		work()
		h.frame(0.1) -- one flare, with its top probes
		h.seconds(1, DT, work) -- windows cover completed seconds
		local s = Core.snapshot("server")
		T.eq(s.v, 1)
		T.eq(s.side, "server")
		T.eq(type(s.t), "number")
		T.eq(s.serverTime, 12345)
		T.eq(s.device, "Desktop")
		T.eq(s.players, 12)
		T.eq(s.misuse, 0)
		local f = s.frame
		for _, k in { "last", "avg1", "p50", "p95", "p99", "max10", "fps", "budget", "scriptMs" } do
			T.eq(type(f[k]), "number", "frame." .. k)
		end
		T.near(f.last, 1000 / 60, 1e-9)
		T.near(f.budget, 1000 / 60, 1e-9, "budget in ms")
		T.check(f.fps >= 50 and f.fps <= 60, "fps " .. f.fps)
		T.near(f.max10, 100, 1e-9)
		T.eq(#f.history, 120, "last 120 frames")
		T.near(f.history[120 - 60], 100, 1e-9, "oldest first: the slow frame is 60 frames back")
		T.check(f.scriptMs > 0)
		T.eq(#s.probes, 40, "top 40")
		local p1 = s.probes[1]
		T.eq(p1.name, "Sys.P50", "sorted by selfAvg desc")
		for _, k in { "selfAvg", "selfP95", "selfMax", "totalAvg", "calls" } do
			T.eq(type(p1[k]), "number", "probe." .. k)
		end
		for i = 2, #s.probes do
			T.check(s.probes[i - 1].selfAvg >= s.probes[i].selfAvg, "sorted")
		end
		T.near(p1.selfAvg, 0.5, 0.02, "per frame (the slow frame had no probes)")
		T.near(p1.calls, 1, 0.03)
		T.eq(s.counters[1].name, "Hits")
		T.check(s.counters[1].perSec > 50 and s.counters[1].perSec <= 60, "per second")
		T.eq(s.gauges[1].value, 4)
		T.eq(s.net[1].channel, "Shop")
		T.eq(s.memory.totalMb, 900)
		T.eq(s.engine.heartbeatMs, 3)
		T.eq(#s.flares, 1)
		T.eq(#s.flares[1].top, 5)
		T.eq(type(s.flares[1].top[1].name), "string")
		T.eq(type(s.flares[1].top[1].ms), "number")
		T.check(type(s.netTop) == "table")
		-- before any second completes the snapshot still has numbers
		local h2 = T.harness()
		h2.frame(DT)
		local s2 = h2.Core.snapshot("client")
		T.near(s2.frame.avg1, 1000 / 60, 1e-9, "avg1 falls back to the last frame")
		T.eq(#s2.memory == 0 and type(s2.memory), "table", "memory defaults to {}")
	end)

	T.test("recording: explicit capture and ring columns", function()
		local h = T.harness({ frames = 600 })
		local Core = h.Core
		local a, b = Core.probe("A"), Core.probe("B")
		local n = 0
		local function work()
			n += 1
			a:begin()
			h.spend(0.001)
			a:finish()
			if n % 2 == 0 then
				b:begin()
				h.spend(0.002)
				b:finish()
			end
		end
		h.seconds(2, DT, work)
		T.eq(Core.recording(1) ~= nil, true)
		local ring = Core.recording(1) :: any
		T.eq(ring.source, "ring")
		T.check(#ring.frames.dt >= 60 and #ring.frames.dt <= 61, "about 1 s of frames: " .. #ring.frames.dt)
		T.eq(#ring.probes, 2)
		for p = 1, 2 do
			T.eq(#ring.frames.self[p], #ring.frames.dt, "dense columns")
		end
		T.near(ring.frames.t[1], 0, 1e-9, "t relative to t0")
		Core.record(0.5)
		h.seconds(2, DT, work)
		local rec = Core.recording() :: any
		T.eq(rec.source, "record")
		T.eq(rec.done, true)
		T.check(#rec.frames.dt >= 30 and #rec.frames.dt <= 32, "0.5 s recorded: " .. #rec.frames.dt)
		local ia = table.find(rec.probes, "A")
		local ib = table.find(rec.probes, "B")
		T.check(ia and ib, "both probes")
		T.near(rec.frames.self[ia][1], 1, 1e-6)
		local sumB = 0
		for _, v in rec.frames.self[ib] do
			sumB += v
		end
		T.near(sumB, 2 * #rec.frames.dt / 2, 2.01, "B runs every other frame")
		T.near(rec.frames.dt[1], 1000 / 60, 1e-9, "frame ms")
		T.eq(#rec.frames.script, #rec.frames.dt)
		-- recording(seconds) still reads the ring
		T.eq((Core.recording(1) :: any).source, "ring")
		-- the ring wraps
		local h2 = T.harness({ frames = 30 })
		h2.seconds(2, DT)
		T.eq(#(h2.Core.recording() :: any).frames.dt, 30)
		T.eq(T.core().recording(), nil, "nothing recorded yet")
	end)

	T.test("reset clears measurements and keeps probe objects valid", function()
		local h = T.harness()
		local Core = h.Core
		local p = Core.probe("Keep")
		h.seconds(2, DT, function()
			p:begin()
			p:finish()
			Core.count("C")
		end)
		Core.reset()
		T.eq(#Core.snapshot("client").probes, 0)
		T.eq(#Core.snapshot("client").counters, 0)
		h.seconds(2, DT, function()
			p:begin()
			h.spend(0.001)
			p:finish()
		end)
		T.near(Core.probeStats("Keep", 1).selfAvg, 1, 1e-6)
	end)

	T.test("frame ring log: varying probe counts, wraps and growth keep every entry", function()
		local h = T.harness({ frames = 50 })
		local Core = h.Core
		local ps = {}
		for i = 1, 300 do
			ps[i] = Core.probe("V" .. i)
		end
		local expect = {} -- [frame] = { [name] = ms }
		local seed = 11
		local function rand(n)
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n
		end
		for f = 1, 400 do
			local count = if f < 200 then rand(20) else rand(300) -- growth after frame 200
			local e = {}
			for k = 1, count do
				local p = ps[k]
				p:begin()
				h.spend(0.0001 * ((f + k) % 7 + 1))
				p:finish()
				e[p.name] = 0.1 * ((f + k) % 7 + 1)
			end
			expect[f] = e
			h.frame(1 / 60)
		end
		local cols = Core.recording() :: any
		T.eq(#cols.frames.dt, 50)
		for fi = 1, 50 do
			local e = expect[350 + fi]
			for name in e do
				T.check(table.find(cols.probes, name) ~= nil, "missing column " .. name)
			end
			for col, name in cols.probes do
				local got = cols.frames.self[col][fi]
				local want = e[name] or 0
				if math.abs(got - want) > 1e-4 then
					error(`frame {350 + fi} {name}: {got} vs {want}`)
				end
			end
		end
	end)
end
