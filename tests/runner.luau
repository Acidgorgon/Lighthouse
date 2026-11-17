--!optimize 2
-- Test runner for the luau-bench host.
-- usage: luau-bench [--codegen] tests/runner.luau <lighthouse root> [name filter]

local ROOT = arg[1] or "."
local FILTER = arg[2]

local function load(path: string)
	local src = readfile(path) or error("cannot read " .. path)
	local fn, err = loadstring(src, "@" .. path)
	if not fn then
		error(err)
	end
	return fn()
end

local Mock = load(ROOT .. "/tests/mock.luau")
Mock.installGlobals()

local T = {}
T.Mock = Mock
T.ROOT = ROOT
T.SRC = ROOT .. "/src"

local results = { passed = 0, failed = 0, failures = {} }
local current = ""

function T.test(name: string, fn: () -> ())
	local full = current .. " :: " .. name
	if FILTER and not string.find(full, FILTER, 1, true) then
		return
	end
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		results.passed += 1
		print("  ok   " .. name)
	else
		results.failed += 1
		table.insert(results.failures, full .. "\n" .. tostring(err))
		print("  FAIL " .. name .. "\n" .. tostring(err))
	end
end

function T.check(cond: any, msg: string?)
	if not cond then
		error(msg or "check failed", 2)
	end
end

function T.near(a: number, b: number, tol: number, msg: string?)
	if not (math.abs(a - b) <= tol) then
		error(string.format("%s: %.6f vs %.6f (tol %.6f)", msg or "near", a, b, tol), 2)
	end
end

function T.eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2)
	end
end

-- A fresh Core (its own module instances, so tests do not share state) and its world.
function T.core()
	local world = Mock.newWorld()
	local inst = world.server:mountTree(T.SRC .. "/Core", world.server.ReplicatedStorage, "Core")
	return world.server:require(inst), world
end

-- A world with Lighthouse mounted at ReplicatedStorage.Lighthouse on the server.
function T.world(opts: any?)
	local world = Mock.newWorld(opts)
	world.lighthouseModule = world.server:mountTree(T.SRC, world.server.ReplicatedStorage, "Lighthouse")
	return world
end

function T.serverLighthouse(world)
	return world.server:require(world.lighthouseModule)
end

function T.clientLighthouse(world, index: number)
	local client = world.clients[index]
	local module = client.ReplicatedStorage:FindFirstChild("Lighthouse")
	return client:require(module)
end

-- Fake clock for deterministic probe timing: returns (clockFn, advance(seconds), set(t)).
function T.fakeClock(start: number?)
	local now = start or 100
	local function clock()
		return now
	end
	local function advance(dt: number)
		now += dt
	end
	local function set(t: number)
		now = t
	end
	return clock, advance, set
end

-- An active Core on a fake clock. h.frame(dt) ends a frame dt seconds after the previous one;
-- h.spend(seconds) moves the clock inside the current frame (probe timing); h.seconds(n, dt, fn?)
-- runs n seconds of frames, calling fn(h) inside each frame.
function T.harness(opts: any?, start: number?)
	local Core = T.core()
	local clock, _, set = T.fakeClock(start or 100.005)
	Core.setClock(clock)
	Core.configure(opts or {})
	Core.setActive(true)
	local h = { Core = Core, frameStart = start or 100.005, now = start or 100.005 }
	function h.spend(seconds: number)
		h.now += seconds
		set(h.now)
	end
	function h.frame(dt: number)
		h.frameStart += dt
		h.now = h.frameStart
		set(h.now)
		Core.endFrame(dt, h.now)
	end
	function h.seconds(n: number, dt: number, fn: ((any) -> ())?)
		for _ = 1, math.floor(n / dt + 0.5) do
			if fn then
				fn(h)
			end
			h.frame(dt)
		end
	end
	return h
end

local files = {}
for _, entry in listdir(ROOT .. "/tests") or {} do
	if not entry.dir and string.match(entry.name, "^test_.*%.luau$") then
		table.insert(files, entry.name)
	end
end
table.sort(files)

local t0 = os.clock()
for _, name in files do
	current = name
	print(name)
	local ok, err = xpcall(function()
		local fn = load(ROOT .. "/tests/" .. name)
		fn(T)
	end, debug.traceback)
	if not ok then
		results.failed += 1
		table.insert(results.failures, name .. " (load)\n" .. tostring(err))
		print("  FAIL (load) " .. tostring(err))
	end
end

print(string.format("\n%d passed, %d failed (%.2f s, native=%s)", results.passed, results.failed, os.clock() - t0, tostring(__native())))
if results.failed > 0 then
	print("\nFailures:")
	for _, f in results.failures do
		print("- " .. f)
	end
	error("tests failed", 0)
end
