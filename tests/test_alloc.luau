-- Hot paths allocate nothing in steady state (exact VM allocation counts from the host):
-- probe begin/finish, count, gauge, net, and Core.endFrame with ~50 probes touched per frame,
-- across second boundaries (window rolls) and flares without listeners.
return function(T)
	local DT = 1 / 60
	local N = 50

	local function allocs(fn: () -> ()): number
		local before = __alloc_count()
		fn()
		return __alloc_count() - before
	end

	-- Smallest count over up to 5 windows. A GC step that lands inside a window can shrink and
	-- regrow a Lua stack or table (one VM allocation that is not garbage from Lighthouse); a real
	-- per-call allocation shows in every window.
	local function steady(measure: () -> number): number
		local best = math.huge
		for _ = 1, 5 do
			local m = measure()
			if m > 0 then
				print("    window allocations: " .. m)
			end
			best = math.min(best, m)
			if best == 0 then
				break
			end
		end
		return best
	end

	local function world()
		local Core = T.core()
		Core.configure({ frames = 120, budget = 1 / 60 })
		Core.setActive(true)
		local probes = {}
		for i = 1, N do
			probes[i] = Core.probe("Sys" .. (i % 5) .. ".P" .. i)
		end
		local players = {}
		for i = 1, 12 do
			players[i] = { Name = "P" .. i }
		end
		local now = 1000.005
		local f = 0
		local function frame(dt: number?)
			f += 1
			-- 50 probes, nested in groups of 5, two calls each for the first ten
			for g = 0, N / 5 - 1 do
				local top = probes[g * 5 + 1]
				top:begin()
				for k = 2, 5 do
					local p = probes[g * 5 + k]
					p:begin()
					p:finish()
				end
				top:finish()
			end
			for i = 1, 10 do
				probes[i]:begin()
				probes[i]:finish()
			end
			Core.count("Hits")
			Core.count("Bytes", 12)
			Core.gauge("Npcs", f % 40)
			Core.net("Current", "Move", "out", 120, players[f % 12 + 1])
			Core.net("Current", "Move", "in", 40)
			Core.net("Ripple", "State", "out", 300)
			local d = dt or DT
			now += d
			Core.endFrame(d, now)
		end
		return Core, probes, frame, players
	end

	T.test("begin/finish, count, gauge, net: zero allocations", function()
		local Core, probes, frame, players = world()
		for _ = 1, 300 do
			frame()
		end
		local p, q = probes[1], probes[2]
		local n = steady(function()
			return allocs(function()
				for i = 1, 10000 do
					p:begin()
					q:begin()
					q:finish()
					p:finish()
					Core.count("Hits")
					Core.gauge("Npcs", i)
					Core.net("Current", "Move", "out", 64, players[i % 12 + 1])
				end
			end)
		end)
		T.eq(n, 0, "allocations in 10000 iterations")
	end)

	T.test("endFrame with 50 probes (and window rolls): zero allocations per frame", function()
		local _, _, frame = world()
		for _ = 1, 400 do
			frame() -- warm: ring slots (120 frames), series, every second slot
		end
		local n = steady(function()
			return allocs(function()
				for _ = 1, 300 do -- 5 s: 5 rolls of every window
					frame()
				end
			end)
		end)
		T.eq(n, 0, "allocations in 300 frames")
	end)

	T.test("flares without listeners: zero allocations", function()
		local Core, _, frame = world()
		for _ = 1, 400 do
			frame()
		end
		for _ = 1, 40 do
			frame(0.1) -- fill all 32 flare records
		end
		local before = #Core.flares()
		local n = steady(function()
			return allocs(function()
				for i = 1, 120 do
					frame(if i % 4 == 0 then 0.1 else DT)
				end
			end)
		end)
		T.eq(n, 0, "allocations with flares every 4th frame")
		T.eq(before, 32)
	end)

	T.test("off state: zero allocations and wrap still runs", function()
		local Core, probes, _, players = world()
		Core.setActive(false)
		local w = Core.wrap("Off", function(x)
			return x
		end)
		local p = probes[1]
		local n = steady(function()
			return allocs(function()
				for i = 1, 10000 do
					p:begin()
					p:finish()
					Core.count("Hits")
					Core.gauge("Npcs", i)
					Core.net("Current", "Move", "out", 64, players[1])
					w(i)
				end
				Core.endFrame(DT, 5000)
			end)
		end)
		T.eq(n, 0)
	end)
end
