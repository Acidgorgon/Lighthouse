-- Runtime/Wire: round trips, sizes, and hostile input (never throws, never accepts garbage).
return function(T)
	local Mock = T.Mock
	Mock.extendLighthouse()
	local world = Mock.newWorld()
	local Wire = world.server:requireFile(T.SRC .. "/Runtime/Wire.luau")
	local Stats = world.server:requireFile(T.SRC .. "/Core/Stats.luau")

	local function sampleSnapshot(nProbes: number?)
		local s = {
			v = 1,
			side = "server",
			t = 1234.5,
			serverTime = 1.7e9 + 0.25,
			device = "Desktop",
			players = 12,
			misuse = 3,
			frames = 7200,
			frame = {
				last = 16.7,
				avg1 = 16.4,
				p50 = 16.6,
				p95 = 21.3,
				p99 = 33.3,
				max10 = 812.5,
				fps = 60,
				budget = 16.667,
				scriptMs = 4.21,
				history = {},
			},
			probes = {},
			counters = { { name = "Pathfinds", perSec = 42.5 }, { name = "Spawns", perSec = 0.5 } },
			gauges = { { name = "Npcs", value = 120, min = 100, max = 140 }, { name = "Temp", value = -3.5, min = -10, max = 0 } },
			net = {
				{ lib = "Current", channel = "Shop", dir = "out", bps = 1200, pps = 30, avg = 40, peak = 2400 },
				{ lib = "Tide", channel = "Relay", dir = "in", bps = 800.5, pps = 60, avg = 13.34, peak = 900 },
			},
			memory = { totalMb = 812, luaHeapMb = 64.5, gcKb = 66000, gcKbPerSec = 120, tags = { LuaHeap = 64.5, Gui = 12 } },
			engine = { heartbeatMs = 2.5, physicsMs = 1.25, recvKbps = 3, sendKbps = 4, instances = 5000, physicsFps = 60 },
			flares = {
				{ t = 1234.0, frameMs = 50.25, top = { { name = "Crowd.Step", ms = 30.5 }, { name = "Tide.Relay", ms = 4 } } },
				{ t = 1230.0, frameMs = 2100, top = {} },
			},
			netTop = { { who = "Player1", bps = 1000 } },
			reports = {
				reports = 40,
				players = 9,
				dropped = 2,
				devices = {
					{
						device = "Mobile",
						players = 6,
						reports = 30,
						frameP50 = 22.5,
						frameP95 = 40.25,
						frameP99 = 66.6,
						scriptP50 = 5.5,
						memoryMb = 1400.5,
						heapMb = 120.25,
						pingMs = 140,
						quality = 3.5,
						probes = { { name = "Crowd.Step", ms = 3.2 } },
					},
					{
						device = "Console",
						players = 3,
						reports = 10,
						frameP50 = 16.6,
						frameP95 = 17.5,
						frameP99 = 20,
						scriptP50 = 3,
						memoryMb = 900,
						heapMb = 80,
						pingMs = 60,
						quality = 10,
						probes = {},
					},
				},
			},
		}
		for i = 1, 120 do
			s.frame.history[i] = 10 + (i % 17) * 1.5
		end
		for i = 1, nProbes or 40 do
			s.probes[i] = {
				name = "System" .. (i // 5) .. ".Stage" .. i,
				selfAvg = 2 / i,
				selfP95 = 3 / i,
				selfMax = 9 / i,
				totalAvg = 2.5 / i,
				calls = i * 1.5,
			}
		end
		return s
	end

	local function encodeDecode(s)
		local names = Wire.interner()
		local payload = Wire.encodeSnapshot(s, names)
		local list = {}
		T.check(Wire.decodeNames(Wire.encodeNames(names.list, 0), list), "names decode")
		return Wire.decodeSnapshot(payload, list), payload, names, list
	end

	T.test("ms16 and log8 number codes", function()
		for _, ms in { 0, 0.01, 0.5, 16.67, 299.99, 300, 1234, 35000 } do
			T.near(Wire.unms16(Wire.ms16(ms)), ms, if ms < 300 then 0.005 else 0.5, "ms16 " .. ms)
		end
		T.eq(Wire.ms16(-5), 0)
		T.eq(Wire.ms16(0 / 0), 0)
		T.eq(Wire.ms16(math.huge), 65535)
		T.eq(Wire.ms16(1e9), 65535)
		for _, ms in { 0.05, 1, 16.7, 100, 2000 } do
			local back = Wire.unlog8(Wire.log8(ms))
			T.check(math.abs(back - ms) / ms < 0.03, "log8 " .. ms .. " -> " .. back)
		end
		T.eq(Wire.log8(0), 0)
		T.eq(Wire.log8(1e12), 255)
	end)

	T.test("snapshot round trip keeps every field", function()
		local s = sampleSnapshot()
		local d, payload = encodeDecode(s)
		T.check(d ~= nil, "decoded")
		T.eq(d.v, 1)
		T.eq(d.side, "server")
		T.near(d.t, s.t, 1e-9)
		T.near(d.serverTime, s.serverTime, 1e-6, "serverTime keeps f64 precision")
		T.eq(d.device, "Desktop")
		T.eq(d.players, 12)
		T.eq(d.misuse, 3)
		T.eq(d.frames, 7200)
		for _, k in { "last", "avg1", "p50", "p95", "p99", "max10", "budget", "scriptMs" } do
			T.near(d.frame[k], s.frame[k], if s.frame[k] < 300 then 0.006 else 0.5, "frame." .. k)
		end
		T.eq(d.frame.fps, 60)
		T.eq(#d.frame.history, 120)
		for i = 1, 120 do
			T.check(math.abs(d.frame.history[i] - s.frame.history[i]) / s.frame.history[i] < 0.03, "history " .. i)
		end
		T.eq(#d.probes, 40)
		for i = 1, 40 do
			local a, b = d.probes[i], s.probes[i]
			T.eq(a.name, b.name)
			T.near(a.selfAvg, b.selfAvg, 0.006)
			T.near(a.selfP95, b.selfP95, 0.006)
			T.near(a.selfMax, b.selfMax, 0.006)
			T.near(a.totalAvg, b.totalAvg, 0.006)
			T.near(a.calls, b.calls, 1e-4)
		end
		T.eq(d.counters[1].name, "Pathfinds")
		T.near(d.counters[1].perSec, 42.5, 1e-5)
		T.eq(d.gauges[2].name, "Temp")
		T.near(d.gauges[2].value, -3.5, 1e-6)
		T.near(d.gauges[2].min, -10, 1e-6)
		T.eq(d.net[1].lib, "Current")
		T.eq(d.net[1].channel, "Shop")
		T.eq(d.net[1].dir, "out")
		T.eq(d.net[2].dir, "in")
		T.near(d.net[2].bps, 800.5, 1e-3)
		T.near(d.net[2].avg, 13.34, 1e-4)
		T.near(d.memory.totalMb, 812, 1e-3)
		T.near(d.memory.luaHeapMb, 64.5, 1e-4)
		T.near(d.memory.tags.Gui, 12, 1e-5)
		T.near(d.memory.tags.LuaHeap, 64.5, 1e-5)
		T.near(d.engine.heartbeatMs, 2.5, 1e-6)
		T.eq(d.engine.instances, 5000)
		T.eq(d.engine.ping, nil, "absent engine keys stay nil")
		T.eq(#d.flares, 2)
		T.near(d.flares[1].t, 1234.0, 1e-3)
		T.near(d.flares[1].frameMs, 50.25, 0.006)
		T.eq(d.flares[1].top[1].name, "Crowd.Step")
		T.near(d.flares[1].top[1].ms, 30.5, 0.006)
		T.near(d.flares[2].frameMs, 2100, 0.5)
		T.eq(d.netTop[1].who, "Player1")
		local r = d.reports
		T.check(r ~= nil, "reports section")
		T.eq(r.reports, 40)
		T.eq(r.players, 9)
		T.eq(r.dropped, 2)
		T.eq(#r.devices, 2)
		T.eq(r.devices[1].device, "Mobile")
		T.near(r.devices[1].frameP95, 40.25, 0.006)
		T.near(r.devices[1].memoryMb, 1400.5, 1e-3)
		T.near(r.devices[1].quality, 3.5, 0.05)
		T.eq(r.devices[1].probes[1].name, "Crowd.Step")
		T.eq(r.devices[2].device, "Console")
		print(string.format("    full snapshot: %d bytes (40 probes, 120 history, 2 flares, 2 device rows)", buffer.len(payload)))
		T.check(buffer.len(payload) < 1500, "full snapshot under 1.5 KB: " .. buffer.len(payload))
	end)

	T.test("snapshot sizes: typical and worst case", function()
		local small = sampleSnapshot(10)
		small.reports = nil
		small.flares = {}
		local _, p1 = encodeDecode(small)
		print(string.format("    10 probes, no flares: %d bytes", buffer.len(p1)))
		T.check(buffer.len(p1) < 600, "small snapshot")

		local big = sampleSnapshot(60)
		for i = 1, 40 do
			big.counters[i] = { name = "C" .. i, perSec = i }
			big.gauges[i] = { name = "G" .. i, value = i, min = 0, max = i }
			big.net[i] = { lib = "L" .. (i % 3), channel = "Ch" .. i, dir = "out", bps = i, pps = i, avg = 1, peak = i }
		end
		for i = 1, 32 do
			big.flares[i] = { t = 1200 + i, frameMs = 40, top = {} }
			for j = 1, 5 do
				big.flares[i].top[j] = { name = "P" .. j, ms = j }
			end
		end
		for i = 1, 5 do
			big.reports.devices[i] = table.clone(big.reports.devices[1])
			big.reports.devices[i].device = Wire.DEVICES[i]
			big.reports.devices[i].probes = { { name = "a", ms = 1 }, { name = "b", ms = 1 }, { name = "c", ms = 1 }, { name = "d", ms = 1 }, { name = "e", ms = 1 } }
		end
		local d, p2 = encodeDecode(big)
		print(string.format("    worst case (every section at its cap): %d bytes", buffer.len(p2)))
		T.check(d ~= nil, "worst case decodes")
		T.eq(#d.probes, Wire.CAP_PROBES)
		T.eq(#d.counters, Wire.CAP_COUNTERS)
		T.eq(#d.flares, Wire.CAP_FLARES)
		T.near(d.flares[1].t, 1201, 1e-3, "flares newest first, first kept")
		T.check(buffer.len(p2) < 2600, "worst case bounded")
	end)

	T.test("name table: deltas, reset, out of order", function()
		local names = Wire.interner()
		local list = {}
		Wire.intern(names, "a")
		Wire.intern(names, "b")
		T.check(Wire.decodeNames(Wire.encodeNames(names.list, 0), list))
		T.eq(#list, 2)
		Wire.intern(names, "c")
		T.eq(Wire.intern(names, "a"), 1, "interned once")
		T.check(Wire.decodeNames(Wire.encodeNames(names.list, 2), list))
		T.eq(list[3], "c")
		-- a delta that starts past what we have is refused
		Wire.intern(names, "d")
		Wire.intern(names, "e")
		local short = { "a" }
		T.check(not Wire.decodeNames(Wire.encodeNames(names.list, 3), short), "gap refused")
		T.eq(#short, 1)
		-- first = 0 replaces
		local fresh = Wire.interner()
		Wire.intern(fresh, "x")
		T.check(Wire.decodeNames(Wire.encodeNames(fresh.list, 0), list))
		T.eq(#list, 1)
		T.eq(list[1], "x")
		-- long names are cut to MAX_NAME
		local long = string.rep("n", 300)
		local id = Wire.intern(names, long)
		T.eq(#names.list[id], Wire.MAX_NAME)
		-- unknown ids decode as "?"
		local s = sampleSnapshot(3)
		local n2 = Wire.interner()
		local payload = Wire.encodeSnapshot(s, n2)
		local d = Wire.decodeSnapshot(payload, {})
		T.check(d ~= nil)
		T.eq(d.probes[1].name, "?")
	end)

	local function sampleReport()
		local fh = Stats.histogram()
		local sh = Stats.histogram()
		for i = 1, 600 do
			fh:add(14 + (i % 10))
			sh:add(3 + (i % 4) * 0.5)
		end
		local r = {
			device = "Tablet",
			quality = 7,
			pingMs = 95.5,
			memoryMb = 1500.4,
			heapMb = 88.25,
			frameP50 = fh:quantile(0.5),
			frameP95 = fh:quantile(0.95),
			frameP99 = fh:quantile(0.99),
			scriptP50 = sh:quantile(0.5),
			frames = fh.total,
			probes = { { name = "Crowd.Step", ms = 1.5 }, { name = "UI.Render", ms = 0.75 } },
		}
		return r, Wire.encodeReport(r, fh:encode(), sh:encode()), fh, sh
	end

	T.test("report round trip with histograms", function()
		local r, payload, fh = sampleReport()
		print(string.format("    report: %d bytes (2 histograms, 2 probes)", buffer.len(payload)))
		T.check(buffer.len(payload) <= Wire.MAX_IN)
		local d = Wire.decodeReport(payload, Stats.histogram)
		T.check(d ~= nil, "decoded")
		T.eq(d.device, "Tablet")
		T.eq(d.quality, 7)
		T.near(d.pingMs, 95.5, 0.006)
		T.eq(d.memoryMb, 1500)
		T.near(d.heapMb, 88.2, 0.11)
		T.near(d.frameP50, r.frameP50, 0.006)
		T.eq(d.frames, 600)
		T.eq(d.frameHist.total, 600)
		T.near(d.frameHist:quantile(0.95), fh:quantile(0.95), 1e-6)
		T.eq(d.scriptHist.total, 600)
		T.eq(#d.probes, 2)
		T.eq(d.probes[2].name, "UI.Render")
		-- without a histogram constructor the blobs are skipped but the rest decodes
		local d2 = Wire.decodeReport(payload, nil)
		T.check(d2 ~= nil and d2.frameHist == nil)
		-- no histograms at all
		local d3 = Wire.decodeReport(Wire.encodeReport(r, nil, nil), Stats.histogram)
		T.check(d3 ~= nil and d3.frameHist == nil and d3.scriptHist == nil)
		-- unknown quality
		r.quality = nil
		T.eq(Wire.decodeReport(Wire.encodeReport(r), Stats.histogram).quality, nil)
	end)

	T.test("report validation rejects malformed input", function()
		local r, payload = sampleReport()
		T.eq(Wire.decodeReport("hello", Stats.histogram), nil, "string")
		T.eq(Wire.decodeReport(nil, Stats.histogram), nil, "nil")
		T.eq(Wire.decodeReport({}, Stats.histogram), nil, "table")
		T.eq(Wire.decodeReport(buffer.create(0), Stats.histogram), nil, "empty")
		T.eq(Wire.decodeReport(buffer.create(3000), Stats.histogram), nil, "oversize")
		local function mutate(offset, value)
			local b = buffer.create(buffer.len(payload))
			buffer.copy(b, 0, payload, 0)
			buffer.writeu8(b, offset, value)
			return b
		end
		T.eq(Wire.decodeReport(mutate(0, 9), Stats.histogram), nil, "version")
		T.eq(Wire.decodeReport(mutate(1, Wire.SNAPSHOT), Stats.histogram), nil, "tag")
		T.eq(Wire.decodeReport(mutate(2, 0), Stats.histogram), nil, "device 0")
		T.eq(Wire.decodeReport(mutate(2, 77), Stats.histogram), nil, "device 77")
		T.eq(Wire.decodeReport(mutate(3, 11), Stats.histogram), nil, "quality 11")
		-- trailing garbage
		local longer = buffer.create(buffer.len(payload) + 1)
		buffer.copy(longer, 0, payload, 0)
		T.eq(Wire.decodeReport(longer, Stats.histogram), nil, "trailing byte")
		-- control characters in a probe name
		r.probes = { { name = "bad\0name", ms = 1 } }
		T.eq(Wire.decodeReport(Wire.encodeReport(r), Stats.histogram), nil, "control char")
		r.probes = { { name = "\255\254", ms = 1 } }
		T.eq(Wire.decodeReport(Wire.encodeReport(r), Stats.histogram), nil, "invalid utf8")
		r.probes = { { name = "", ms = 1 } }
		T.eq(Wire.decodeReport(Wire.encodeReport(r), Stats.histogram), nil, "empty name")
		-- non-finite numbers are written as 0, never NaN
		r.probes = {}
		r.pingMs = 0 / 0
		r.memoryMb = math.huge
		local d = Wire.decodeReport(Wire.encodeReport(r), Stats.histogram)
		T.check(d ~= nil)
		T.eq(d.pingMs, 0)
		T.eq(d.memoryMb, 65535)
	end)

	T.test("fuzz: truncated, bit-flipped and random buffers never throw", function()
		local _, report = sampleReport()
		local names = Wire.interner()
		local snap = Wire.encodeSnapshot(sampleSnapshot(), names)
		local namesPayload = Wire.encodeNames(names.list, 0)
		math.randomseed(42)
		local rng = {
			NextInteger = function(_self, a, b)
				return math.random(a, b)
			end,
		}
		local accepted = 0
		local function try(b)
			local ok1, r1 = pcall(Wire.decodeReport, b, Stats.histogram)
			T.check(ok1, "decodeReport threw: " .. tostring(r1))
			local list = table.clone(names.list)
			local ok2, r2 = pcall(Wire.decodeSnapshot, b, list)
			T.check(ok2, "decodeSnapshot threw: " .. tostring(r2))
			local ok3, r3 = pcall(Wire.decodeNames, b, list)
			T.check(ok3, "decodeNames threw: " .. tostring(r3))
			local ok4, r4 = pcall(Wire.decodeAllow, b)
			T.check(ok4, "decodeAllow threw: " .. tostring(r4))
			if r1 then
				accepted += 1
				-- whatever is accepted is sane
				T.check(r1.pingMs == r1.pingMs and r1.pingMs >= 0 and r1.pingMs < 40000)
				T.check(#r1.probes <= Wire.CAP_REPORT_PROBES)
				for _, p in r1.probes do
					T.check(#p.name <= Wire.MAX_REPORT_NAME and not string.find(p.name, "%c"))
				end
			end
			if r2 then
				T.check(#r2.probes <= Wire.CAP_PROBES)
			end
		end
		for _, base in { report, snap, namesPayload } do
			local n = buffer.len(base)
			-- every truncation
			for cut = 0, n - 1 do
				local b = buffer.create(cut)
				buffer.copy(b, 0, base, 0, cut)
				try(b)
			end
			-- random byte flips
			for _ = 1, 1500 do
				local b = buffer.create(n)
				buffer.copy(b, 0, base, 0)
				for _ = 1, rng:NextInteger(1, 4) do
					buffer.writeu8(b, rng:NextInteger(0, n - 1), rng:NextInteger(0, 255))
				end
				try(b)
			end
		end
		-- random buffers with a valid header
		for _ = 1, 3000 do
			local n = rng:NextInteger(2, 400)
			local b = buffer.create(n)
			for i = 0, n - 1 do
				buffer.writeu8(b, i, rng:NextInteger(0, 255))
			end
			buffer.writeu8(b, 0, Wire.VERSION)
			buffer.writeu8(b, 1, rng:NextInteger(1, 5))
			try(b)
		end
		-- hostile: claims 255 probes / 255 buckets with no data
		local h = buffer.create(40)
		buffer.writeu8(h, 0, Wire.VERSION)
		buffer.writeu8(h, 1, Wire.REPORT)
		buffer.writeu8(h, 2, 1)
		for i = 3, 39 do
			buffer.writeu8(h, i, 255)
		end
		try(h)
		T.check(accepted < 1500, "most corrupted reports are refused")
	end)

	T.test("hello, bye and allow messages", function()
		local hello = Wire.encodeHello()
		T.eq(buffer.len(hello), 2)
		local v, tag = Wire.header(hello)
		T.eq(v, Wire.VERSION)
		T.eq(tag, Wire.HELLO)
		local _, byeTag = Wire.header(Wire.encodeBye())
		T.eq(byeTag, Wire.BYE)
		T.eq(Wire.decodeAllow(Wire.encodeAllow(true)), true)
		T.eq(Wire.decodeAllow(Wire.encodeAllow(false)), false)
		T.eq(Wire.decodeAllow(hello), nil)
		T.eq(Wire.header("x"), nil)
		T.eq(Wire.header(buffer.create(1)), nil)
	end)
end
