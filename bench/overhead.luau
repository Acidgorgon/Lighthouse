--!optimize 2
-- Overhead benchmarks for Lighthouse Core on the luau-bench host.
-- usage: luau-bench [--codegen] bench/overhead.luau <lighthouse root>
-- Every number is the best of TRIALS runs (least disturbed by the machine), in ns per operation
-- unless stated. The host compiles everything at -O2 like Roblox; --codegen adds native code.

local ROOT = arg[1] or "."
local TRIALS = 7

local Mock = loadstring(readfile(ROOT .. "/tests/mock.luau") or error("no mock"), "@mock.luau")()
Mock.installGlobals()

local function newCore()
	local world = Mock.newWorld()
	local inst = world.server:mountTree(ROOT .. "/src/Core", world.server.ReplicatedStorage, "Core")
	return world.server:require(inst)
end

local clock = os.clock

local function best(fn: () -> number): number
	local b = math.huge
	for _ = 1, TRIALS do
		b = math.min(b, fn())
	end
	return b
end

local function noop(_: number) end

-- ns per iteration of body(i), minus the same loop calling an empty function
local function perOp(iters: number, body: (number) -> ()): number
	local empty = best(function()
		local t = clock()
		for i = 1, iters do
			noop(i)
		end
		return clock() - t
	end)
	local full = best(function()
		local t = clock()
		for i = 1, iters do
			body(i)
		end
		return clock() - t
	end)
	return math.max(0, full - empty) / iters * 1e9
end

local rows = {}
local function row(name: string, value: number, unit: string?)
	table.insert(rows, { name, value, unit or "ns" })
end

local Core = newCore()
Core.configure({ frames = 600, budget = 1 })

-- probe pair --------------------------------------------------------------
local p = Core.probe("Bench.Pair")
local baseline = perOp(1e6, function()
	local _ = clock()
	local _ = clock()
end)
row("os.clock() x2 (floor for a pair)", baseline)

Core.setActive(false)
row("begin+finish, off", perOp(2e6, function()
	p:begin()
	p:finish()
end))

Core.setActive(true)
local frames = 0
row("begin+finish, on", perOp(1e6, function(i)
	p:begin()
	p:finish()
	if i % 1000 == 0 then
		frames += 1
		Core.endFrame(1 / 60, 10000 + frames / 60)
	end
end))

local q = Core.probe("Bench.Child")
row("nested pair inside a pair (per inner pair), on", perOp(1e6, function(i)
	p:begin()
	q:begin()
	q:finish()
	p:finish()
	if i % 1000 == 0 then
		frames += 1
		Core.endFrame(1 / 60, 10000 + frames / 60)
	end
end) / 2)

-- wrap ----------------------------------------------------------------------
local function work(a: number, b: number): number
	return a + b
end
local wrapped = Core.wrap("Bench.Wrap", work)
local direct = perOp(1e6, function(i)
	work(i, 1)
end)
row("wrap overhead (wrapped - direct call), on", perOp(1e6, function(i)
	wrapped(i, 1)
	if i % 1000 == 0 then
		frames += 1
		Core.endFrame(1 / 60, 10000 + frames / 60)
	end
end) - direct)
Core.setActive(false)
row("wrap overhead (wrapped - direct call), off", perOp(2e6, function(i)
	wrapped(i, 1)
end) - direct)

-- counters / net ------------------------------------------------------------
Core.setActive(true)
row("count(name)", perOp(2e6, function()
	Core.count("Bench.Count")
end))
row("gauge(name, v)", perOp(2e6, function(i)
	Core.gauge("Bench.Gauge", i)
end))
row("net(lib, channel, dir, bytes)", perOp(2e6, function()
	Core.net("Current", "Move", "out", 120)
end))
local who = { Name = "Player1" }
row("net(..., player)", perOp(2e6, function()
	Core.net("Current", "Move", "out", 120, who)
end))
Core.setActive(false)
row("count / net, off", perOp(4e6, function()
	Core.count("Bench.Count")
end))

-- endFrame --------------------------------------------------------------------
local function endFrameCost(n: number): number
	local C = newCore()
	C.configure({ frames = 600, budget = 1 })
	C.setActive(true)
	local ps = {}
	for i = 1, n do
		ps[i] = C.probe("Sys" .. (i % 8) .. ".P" .. i)
	end
	local now = 20000.005
	local function frame(): number
		for i = 1, n do
			ps[i]:begin()
			ps[i]:finish()
		end
		C.count("Hits")
		C.net("Current", "Move", "out", 100)
		now += 1 / 60
		local t = clock()
		C.endFrame(1 / 60, now)
		return clock() - t
	end
	for _ = 1, 1200 do
		frame()
	end
	local rollWorst = math.huge
	local avg = best(function()
		local total = 0
		local rolls = 0
		for _ = 1, 600 do -- 10 s of frames, 10 window rolls
			local sec = math.floor(now)
			local dt = frame()
			total += dt
			if math.floor(now) ~= sec then
				rolls = math.max(rolls, dt)
			end
		end
		rollWorst = math.min(rollWorst, rolls)
		return total / 600
	end)
	return avg * 1e6, rollWorst * 1e6
end

for _, n in { 10, 50, 200 } do
	local avg, roll = endFrameCost(n)
	row(string.format("endFrame, %d probes touched (avg incl. 1 Hz rolls)", n), avg, "us")
	row(string.format("endFrame, %d probes, frame that rolls a second", n), roll, "us")
end

-- snapshot (4 Hz at most) ------------------------------------------------------
do
	local C = newCore()
	C.setActive(true)
	local ps = {}
	for i = 1, 200 do
		ps[i] = C.probe("Sys.P" .. i)
	end
	local now = 30000.005
	for _ = 1, 600 do
		for i = 1, 200 do
			ps[i]:begin()
			ps[i]:finish()
		end
		now += 1 / 60
		C.endFrame(1 / 60, now)
	end
	row("snapshot(), 200 probes", best(function()
		local t = clock()
		for _ = 1, 20 do
			C.snapshot("client")
		end
		return (clock() - t) / 20
	end) * 1e6, "us")
	local snap = C.snapshot("client")
	row("Json.encode(snapshot), 200 probes", best(function()
		local t = clock()
		for _ = 1, 20 do
			C.Json.encode(snap)
		end
		return (clock() - t) / 20
	end) * 1e6, "us")
end

-- memory per probe (series + ring entries), from the VM heap after a full GC ----------------
do
	local C = newCore()
	C.configure({ frames = 600 })
	C.setActive(true)
	local now = 40000.005
	local function run(ps)
		for _ = 1, 700 do
			for _, pr in ps do
				pr:begin()
				pr:finish()
			end
			now += 1 / 60
			C.endFrame(1 / 60, now)
		end
	end
	run({})
	__gc("collect")
	local before = __live_bytes()
	local ps = {}
	for i = 1, 100 do
		ps[i] = C.probe("Mem.P" .. i)
	end
	run(ps)
	__gc("collect")
	row("memory per probe (stats series + 600-frame ring entries)", (__live_bytes() - before) / 100 / 1024, "KB")
end

print(string.format("Lighthouse overhead (%s, -O%d)", if __native() then "native codegen" else "interpreted", __optlevel()))
for _, r in rows do
	print(string.format("  %-52s %10.1f %s", r[1], r[2], r[3]))
end
