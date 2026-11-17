-- Log histogram accuracy, merge, encode/decode, and the 1 s / 10 s / 60 s windows.
return function(T)
	local DT = 1 / 60

	-- deterministic generator (the host has no Random)
	local function rng(seed: number)
		local state = seed
		local r = {}
		function r:NextNumber(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
		function r:NextInteger(lo: number, hi: number): number
			return lo + math.floor(self:NextNumber() * (hi - lo + 1))
		end
		return r
	end

	local function rel(a: number, b: number): number
		return math.abs(a - b) / math.abs(b)
	end

	T.test("histogram quantiles within 10% (uniform, exponential, constant)", function()
		local Core = T.core()
		local h = Core.histogram()
		local values = {}
		local rng = rng(7)
		for i = 1, 20000 do
			local v = 1 + 9 * rng:NextNumber()
			values[i] = v
			h:add(v)
		end
		table.sort(values)
		for _, q in { 0.5, 0.9, 0.95, 0.99 } do
			local exact = values[math.ceil(q * #values)]
			local got = h:quantile(q)
			T.check(rel(got, exact) < 0.1, string.format("uniform q%.2f: %.4f vs %.4f", q, got, exact))
		end
		T.near(h:mean(), 5.5, 0.1, "mean from the exact sum")
		T.eq(h.total, 20000)

		local e = Core.histogram()
		local ev = {}
		for i = 1, 20000 do
			local v = -2 * math.log(1 - rng:NextNumber()) + 0.01 -- exponential, mean 2 ms
			ev[i] = v
			e:add(v)
		end
		table.sort(ev)
		for _, q in { 0.5, 0.95, 0.99 } do
			local exact = ev[math.ceil(q * #ev)]
			local got = e:quantile(q)
			T.check(rel(got, exact) < 0.1, string.format("exponential q%.2f: %.4f vs %.4f", q, got, exact))
		end

		local c = Core.histogram()
		for _ = 1, 600 do
			c:add(16.667)
		end
		T.check(rel(c:quantile(0.5), 16.667) < 0.07, "constant p50")
		T.eq(c:quantile(1), 16.667, "q = 1 is the max")
		T.eq(c.max, 16.667)

		-- range: tiny, huge, zero, garbage
		local r = Core.histogram()
		r:add(0)
		r:add(0.0001)
		r:add(1e6)
		r:add(0 / 0)
		r:add(math.huge)
		r:add(-1)
		r:add("x" :: any)
		T.eq(r.total, 3, "invalid values ignored")
		T.eq(r:quantile(1), 1e6)
		T.check(r:quantile(0.1) < 0.001)
	end)

	T.test("histogram merge equals one histogram of everything", function()
		local Core = T.core()
		local a, b, all = Core.histogram(), Core.histogram(), Core.histogram()
		for i = 1, 1000 do
			local v = i * 0.01
			if i % 3 == 0 then
				a:add(v)
			else
				b:add(v)
			end
			all:add(v)
		end
		a:merge(b)
		T.eq(a.total, all.total)
		T.near(a.sum, all.sum, 1e-6)
		T.eq(a.max, all.max)
		for _, q in { 0.1, 0.5, 0.9, 0.99 } do
			T.near(a:quantile(q), all:quantile(q), 1e-9, "q" .. q)
		end
		a:clear()
		T.eq(a.total, 0)
		T.eq(a:quantile(0.5), 0, "empty histogram")
	end)

	T.test("histogram encode/decode round trip and validation", function()
		local Core = T.core()
		local h = Core.histogram()
		for i = 1, 500 do
			h:add(10 + (i % 17) * 0.7)
		end
		h:add(0)
		h:add(5000)
		local b = h:encode()
		local k = buffer.readu8(b, 0)
		T.eq(buffer.len(b), 9 + 5 * k, "size = 9 + 5k")
		local d = Core.histogram()
		local ok, nextOff = d:decode(b)
		T.check(ok, "decodes")
		T.eq(nextOff, buffer.len(b))
		T.eq(d.total, h.total)
		for _, q in { 0.01, 0.5, 0.95, 1 } do
			T.near(d:quantile(q), h:quantile(q), h:quantile(q) * 1e-6 + 1e-6, "q" .. q)
		end
		-- at an offset inside a bigger buffer
		local big = buffer.create(buffer.len(b) + 7)
		buffer.copy(big, 3, b)
		local e = Core.histogram()
		local ok2, off2 = e:decode(big, 3)
		T.check(ok2 and off2 == 3 + buffer.len(b), "offset decode")
		-- bad input: never throws, leaves the histogram unchanged
		local before = e.total
		T.check(not (e:decode(buffer.create(3))), "too short")
		local trunc = buffer.create(buffer.len(b) - 1)
		buffer.copy(trunc, 0, b, 0, buffer.len(trunc))
		T.check(not (e:decode(trunc)), "truncated")
		local bad = buffer.create(buffer.len(b))
		buffer.copy(bad, 0, b)
		buffer.writeu8(bad, 9, 200) -- bucket out of range
		T.check(not (e:decode(bad)), "bucket range")
		T.check(not (e:decode("nope" :: any)), "not a buffer")
		T.check(not (e:decode(b, -1)), "bad offset")
		T.eq(e.total, before, "unchanged after failures")
		local rng = rng(3)
		for _ = 1, 2000 do
			local n = rng:NextInteger(0, 64)
			local f = buffer.create(n)
			for i = 0, n - 1 do
				buffer.writeu8(f, i, rng:NextInteger(0, 255))
			end
			local okF = pcall(function()
				e:decode(f, rng:NextInteger(0, 4))
			end)
			T.check(okF, "fuzz decode threw")
		end
	end)

	T.test("windows: 1 s reacts next second, 10 s and 60 s roll over", function()
		local h = T.harness()
		local Core = h.Core
		h.seconds(20, DT) -- frames of 16.7 ms
		local f1 = Core.frameStats(1)
		T.near(f1.avg, 1000 / 60, 1e-6)
		T.eq(f1.frames, 60, "frames in the last completed second")
		-- 3 s of 50 ms frames
		h.seconds(3, 0.05)
		T.near(Core.frameStats(1).avg, 50, 1e-6, "1 s window moved")
		local w10 = Core.frameStats(10)
		T.near(w10.max, 50, 1e-9, "max10 sees the slow frames")
		T.check(rel(w10.p50, 1000 / 60) < 0.07, "10 s median still 16.7")
		T.check(rel(w10.p99, 50) < 0.07, "10 s p99 = slow frames")
		-- 12 s later the 10 s window has only fast frames, the 60 s window still has the slow ones
		h.seconds(12, DT)
		local w10b = Core.frameStats(10)
		T.near(w10b.max, 1000 / 60, 1e-9, "slow frames left the 10 s window")
		T.check(rel(w10b.p99, 1000 / 60) < 0.07)
		local w60 = Core.frameStats(60)
		T.near(w60.max, 50, 1e-9, "60 s window keeps them")
		T.check(w60.frames > 1900 and w60.frames <= 60 * 35, "60 s frames")
		-- 61 s later the 60 s window forgot them too
		h.seconds(61, DT)
		local w60b = Core.frameStats(60)
		T.near(w60b.max, 1000 / 60, 1e-9, "slow frames left the 60 s window")
		T.eq(w60b.frames, 3600)
		T.check(rel(w60b.p99, 1000 / 60) < 0.07)
		-- histogram of a window matches the window's own numbers
		local fh = Core.frameHistogram(60)
		T.eq(fh.total, 3600)
		T.near(fh:quantile(0.5), w60b.p50, 1e-9)
	end)

	T.test("windows: a clock jump clears them instead of looping", function()
		local h = T.harness()
		local Core = h.Core
		h.seconds(5, DT)
		h.frame(500) -- 500 s hitch
		h.seconds(2, DT)
		local w = Core.frameStats(60)
		T.eq(w.max, 500000, "the hitch frame ends after the jump, so it is kept")
		T.check(w.frames <= 121, "frames from before the jump are gone")
		T.eq(Core.frameStats(1).frames, 60)
	end)

	T.test("probe windows: per frame averages vs percentiles of frames it ran", function()
		local h = T.harness()
		local Core = h.Core
		local p = Core.probe("Sometimes")
		local n = 0
		h.seconds(12, DT, function()
			n += 1
			if n % 4 == 0 then
				p:begin()
				h.spend(0.004)
				p:finish()
			end
		end)
		local s = Core.probeStats("Sometimes", 10)
		T.near(s.selfAvg, 1, 0.02, "4 ms every 4th frame = 1 ms per frame")
		T.check(rel(s.p50, 4) < 0.07, "p50 of frames it ran")
		T.near(s.max, 4, 1e-6)
		T.near(s.calls, 0.25, 0.01)
	end)
end
