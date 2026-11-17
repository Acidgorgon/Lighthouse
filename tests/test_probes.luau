-- Probe stack: self vs total time, misuse repair, wrap, off state, microprofiler.
return function(T)
	local DT = 1 / 60

	T.test("nesting: self and total time, script time, calls", function()
		local h = T.harness()
		local Core = h.Core
		local outer = Core.probe("Outer")
		local inner = Core.probe("Outer.Inner")
		T.check(Core.probe("Outer") == outer, "interned")
		T.check(outer.id ~= inner.id and outer.name == "Outer", "ids and names")
		h.seconds(2, DT, function()
			outer:begin()
			h.spend(0.001)
			inner:begin()
			h.spend(0.003)
			inner:finish()
			inner:begin()
			h.spend(0.001)
			inner:finish()
			h.spend(0.002)
			outer:finish()
		end)
		local o = Core.probeStats("Outer", 1)
		local i = Core.probeStats("Outer.Inner", 1)
		T.near(o.selfAvg, 3, 1e-6, "outer self ms")
		T.near(o.totalAvg, 7, 1e-6, "outer total ms")
		T.near(i.selfAvg, 4, 1e-6, "inner self ms (two calls)")
		T.near(i.totalAvg, 4, 1e-6, "inner total ms")
		T.near(i.calls, 2, 1e-9, "inner calls per frame")
		T.near(o.calls, 1, 1e-9, "outer calls per frame")
		T.near(o.max, 3, 0.3, "outer self max")
		T.near(Core.scriptStats(1).avg, 7, 1e-6, "script ms = top-level totals")
		T.eq(Core.misuse(), 0, "misuse")
	end)

	T.test("recursion: the same probe nested in itself", function()
		local h = T.harness()
		local Core = h.Core
		local p = Core.probe("Rec")
		h.seconds(2, DT, function()
			p:begin()
			h.spend(0.001)
			p:begin()
			h.spend(0.002)
			p:finish()
			h.spend(0.001)
			p:finish()
		end)
		local s = Core.probeStats("Rec", 1)
		T.near(s.selfAvg, 4, 1e-6, "self adds up to the outer total")
		T.near(s.totalAvg, 6, 1e-6, "total counts both levels")
		T.near(Core.scriptStats(1).avg, 4, 1e-6, "script time counts the outermost only")
		T.eq(Core.misuse(), 0)
	end)

	T.test("misuse: finish without begin is ignored and counted", function()
		local h = T.harness()
		local Core = h.Core
		local p = Core.probe("Lonely")
		p:finish()
		p:finish()
		T.eq(Core.misuse(), 2)
		h.frame(DT)
		T.eq(Core.probeStats("Lonely", 1), nil, "no time recorded")
	end)

	T.test("misuse: finishing an outer probe unwinds the inner ones", function()
		local h = T.harness()
		local Core = h.Core
		local a, b, c = Core.probe("A"), Core.probe("B"), Core.probe("C")
		h.seconds(2, DT, function()
			a:begin()
			h.spend(0.001)
			b:begin()
			h.spend(0.001)
			c:begin()
			h.spend(0.002)
			a:finish() -- b and c never finished
		end)
		T.eq(Core.misuse(), 120, "one misuse per unwind (120 frames)")
		T.near(Core.probeStats("C", 1).selfAvg, 2, 1e-6, "c finished at a's finish")
		T.near(Core.probeStats("B", 1).selfAvg, 1, 1e-6, "b self = its time minus c")
		T.near(Core.probeStats("B", 1).totalAvg, 3, 1e-6)
		T.near(Core.probeStats("A", 1).totalAvg, 4, 1e-6)
		T.near(Core.probeStats("A", 1).selfAvg, 1, 1e-6)
	end)

	T.test("misuse: probes left open are repaired at the frame boundary", function()
		local h = T.harness()
		local Core = h.Core
		local open = Core.probe("Open")
		local ok = Core.probe("Ok")
		open:begin()
		open:begin()
		h.frame(DT)
		T.eq(Core.misuse(), 2, "two open entries dropped")
		-- the stack is clean: a normal pair works and lands at the top level
		h.seconds(2, DT, function()
			ok:begin()
			h.spend(0.002)
			ok:finish()
		end)
		T.near(Core.scriptStats(1).avg, 2, 1e-6, "ok is top level again")
		T.eq(Core.misuse(), 2)
	end)

	T.test("misuse: nesting deeper than the stack is counted, not an error", function()
		local h = T.harness()
		local Core = h.Core
		local ps = {}
		for i = 1, 70 do
			ps[i] = Core.probe("Deep" .. i)
		end
		for i = 1, 70 do
			ps[i]:begin()
		end
		for i = 70, 1, -1 do
			ps[i]:finish()
		end
		T.eq(Core.misuse(), 6, "6 begins past depth 64")
		-- the 64 that fit were finished normally
		local p = Core.probe("After")
		p:begin()
		p:finish()
		T.eq(Core.misuse(), 6)
		h.frame(DT)
		T.eq(Core.misuse(), 6, "nothing left open")
	end)

	T.test("misuse: recursion of one probe past the stack keeps outer timing", function()
		local h = T.harness()
		local Core = h.Core
		local r = Core.probe("Rec70")
		-- begin k at (k - 1) * 0.1 ms; finish j at 7 + (j - 1) * 0.1 ms. The outermost entry
		-- must close at the 70th finish (13.9 ms), not the 64th: the first 6 finishes belong
		-- to the 6 begins that did not fit.
		h.seconds(2, DT, function()
			for _ = 1, 70 do
				r:begin()
				h.spend(0.0001)
			end
			for _ = 1, 70 do
				r:finish()
				h.spend(0.0001)
			end
		end)
		T.near(Core.scriptStats(1).avg, 13.9, 1e-6, "script ms = outermost begin to last finish")
		T.eq(Core.misuse() % 6, 0, "only the 6 overflowed begins per frame are misuse")
	end)

	T.test("wrap returns every result and passes every argument", function()
		local h = T.harness()
		local Core = h.Core
		local f = Core.wrap("Wrapped", function(a, b, ...)
			h.spend(0.001)
			return a + b, nil, select("#", ...), ...
		end)
		local r1, r2, r3, r4, r5 = f(1, 2, "x", "y")
		T.eq(r1, 3)
		T.eq(r2, nil)
		T.eq(r3, 2)
		T.eq(r4, "x")
		T.eq(r5, "y")
		T.eq(select("#", f(1, 2)), 3, "result count kept")
		h.seconds(2, DT, function()
			f(1, 2)
		end)
		T.near(Core.probeStats("Wrapped", 1).selfAvg, 1, 1e-6)
	end)

	T.test("wrap: an error propagates and the stack stays sane", function()
		local h = T.harness()
		local Core = h.Core
		local boom = Core.wrap("Boom", function()
			h.spend(0.001)
			error("bad")
		end)
		local outer = Core.probe("Outer")
		local ok, err = pcall(boom)
		T.check(not ok and string.find(tostring(err), "bad"), "error propagates")
		h.frame(DT) -- repairs the open Boom entry
		T.eq(Core.misuse(), 1)
		-- error inside an outer probe: outer's finish unwinds the stale entry
		h.seconds(2, DT, function()
			outer:begin()
			h.spend(0.001)
			pcall(boom)
			h.spend(0.001)
			outer:finish()
		end)
		local o = Core.probeStats("Outer", 1)
		T.near(o.totalAvg, 3, 1e-6, "outer total includes the failed call")
		T.near(Core.scriptStats(1).avg, 3, 1e-6, "nothing double counted at the top level")
		-- and everything still nests normally
		local m0 = Core.misuse()
		local fine = Core.wrap("Fine", function(x)
			return x * 2
		end)
		outer:begin()
		T.eq(fine(21), 42)
		outer:finish()
		T.eq(Core.misuse(), m0, "no new misuse")
	end)

	T.test("off state: probes, wrap, count, gauge, net and endFrame do nothing", function()
		local Core = T.core()
		local p = Core.probe("Off")
		p:begin()
		p:finish()
		p:finish()
		Core.count("C")
		Core.gauge("G", 1)
		Core.net("L", "c", "out", 10)
		local f = Core.wrap("OffWrap", function(x)
			return x + 1
		end)
		T.eq(f(1), 2, "wrapped function still runs")
		Core.endFrame(DT, 100.5)
		Core.endFrame(DT, 101.5)
		T.eq(Core.misuse(), 0, "nothing counted while off")
		local s = Core.snapshot("client")
		T.eq(#s.probes, 0)
		T.eq(#s.counters, 0)
		T.eq(#s.gauges, 0)
		T.eq(#s.net, 0)
		T.eq(s.frames, 0, "endFrame ignored while off")
		-- begin while off, finish after turning on: not on the stack -> one misuse, no error
		p:begin()
		Core.setActive(true)
		p:finish()
		T.eq(Core.misuse(), 1)
	end)

	T.test("microprofiler: profilebegin/end pair up with probes, including unwinds", function()
		local dbg: any = debug
		local log = {}
		dbg.profilebegin = function(name)
			table.insert(log, "+" .. name)
		end
		dbg.profileend = function()
			table.insert(log, "-")
		end
		local ok, err = pcall(function()
			local h = T.harness({ microprofiler = true })
			local Core = h.Core
			local a, b = Core.probe("A"), Core.probe("B")
			a:begin()
			b:begin()
			b:finish()
			a:finish()
			a:begin()
			b:begin()
			a:finish() -- unwinds b
			b:finish() -- not on the stack: no profileend
			T.eq(table.concat(log, " "), "+A +B - - +A +B - -")
			Core.configure({ microprofiler = false })
			table.clear(log)
			a:begin()
			a:finish()
			T.eq(#log, 0, "off when microprofiler = false")
		end)
		dbg.profilebegin = nil
		dbg.profileend = nil
		if not ok then
			error(err, 0)
		end
	end)
end
