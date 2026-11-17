--!strict
--!native
--!optimize 2
-- Time source and frame boundaries.
-- `Clock.now` is os.clock unless a test installs a fake clock with Clock.set; modules that read
-- the clock in hot paths keep it in a local upvalue and are told about changes through onSet.

local Clock = {}

Clock.now = os.clock :: () -> number
Clock.frame = 0 -- number of Core.endFrame calls
Clock.frameEnd = 0 -- `now` passed to the last endFrame
Clock.frameSeconds = 0 -- last frame time (seconds)

local listeners: { (fn: () -> number) -> () } = {}

-- Registers fn(clockFn), called now and whenever the clock is replaced.
function Clock.onSet(fn: (clockFn: () -> number) -> ())
	table.insert(listeners, fn)
	fn(Clock.now)
end

-- Replaces the time source (tests). nil restores os.clock.
function Clock.set(fn: (() -> number)?)
	local f = fn or os.clock
	Clock.now = f
	for _, listener in listeners do
		listener(f)
	end
end

function Clock.markFrame(frameSeconds: number, now: number)
	Clock.frame += 1
	Clock.frameEnd = now
	Clock.frameSeconds = frameSeconds
end

function Clock.reset()
	Clock.frame = 0
	Clock.frameEnd = 0
	Clock.frameSeconds = 0
end

return Clock
