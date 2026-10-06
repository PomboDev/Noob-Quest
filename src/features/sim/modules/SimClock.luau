--!strict

--[=[
	The simulation's clock. Everything that happens in a run happens on a
	numbered tick, never at an os.clock() time, so a run can be played back.
]=]

local SimClock = {}

-- Ticks per second.
SimClock.RATE = 20
-- Seconds per tick.
SimClock.TICK = 1 / SimClock.RATE

-- A duration in seconds as whole ticks, rounded up so it never gets shorter.
-- (A small bias keeps 0.2 s from becoming 7 ticks through float error.)
function SimClock.ticks(seconds: number): number
	return math.max(0, math.ceil(seconds * SimClock.RATE - 1e-9))
end

return SimClock
