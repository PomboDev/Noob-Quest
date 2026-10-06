--!strict

--[=[
	Decides when and what to spawn. Pure: the run feature asks it every
	tick, and passes the random numbers in, so the same inputs give the same
	waves.

	The director earns credits every second while the teleporter charges and
	during the boss fight (more as the difficulty coefficient grows) and spends them on enemies
	that cost credits. It picks the next enemy first, by weight, and saves up
	for it, so a costly kind still turns up between cheap ones. It never
	spawns past the alive cap, and credits stop piling up once there is a good
	stock, so a quiet minute doesn't turn into one huge wave.
]=]

local Angle = require("@Core/Angle")
local NavGrid = require("@Features/enemies/modules/NavGrid")

local WaveDirector = {}

export type Phase = string

export type Entry = {
	defId: string,
	cost: number,
	weight: number,
	-- The run must be at least this many minutes old before it appears.
	minMinutes: number,
}

export type State = {
	credits: number,
	-- The enemy it is saving up for.
	next: Entry?,
}

-- Credits per second at difficulty 1, for each phase of a run. Other phases earn
-- nothing: while exploring, the camps placed on the map are the enemies.
local RATES: { [string]: number } = {
	Charging = 8,
	Boss = 1,
}

WaveDirector.ENTRIES = {
	{ defId = "grunt", cost = 10, weight = 6, minMinutes = 0 },
	{ defId = "runner", cost = 14, weight = 3, minMinutes = 1 },
	{ defId = "spitter", cost = 20, weight = 2, minMinutes = 2 },
} :: { Entry }

-- Enemies alive at once, leaving room under the server's cap for a boss and its summons.
WaveDirector.ALIVE_CAP = 34
WaveDirector.MAX_CREDITS = 60
-- Spawns in one update, so a long frame doesn't spill out a whole wave at once.
WaveDirector.MAX_PER_UPDATE = 3

function WaveDirector.new(): State
	return { credits = 0, next = nil }
end

-- A weighted pick among the entries old enough to appear.
local function pickNext(entries: { Entry }, minutes: number, random: () -> number): Entry?
	local eligible: { Entry } = {}
	local total = 0
	for _, entry in entries do
		if entry.minMinutes <= minutes and entry.weight > 0 then
			table.insert(eligible, entry)
			total += entry.weight
		end
	end
	if #eligible == 0 then
		return nil
	end

	local roll = random() * total
	for _, entry in eligible do
		roll -= entry.weight
		if roll < 0 then
			return entry
		end
	end
	return eligible[#eligible]
end

function WaveDirector.rate(phase: Phase, coefficient: number): number
	return (RATES[phase] or 0) * math.max(1, coefficient)
end

-- Earns credits for `dt` seconds and returns the def ids to spawn now. `random`
-- gives numbers in [0, 1). `alive` is how many enemies there are.
function WaveDirector.update(
	state: State,
	dt: number,
	phase: Phase,
	coefficient: number,
	alive: number,
	minutes: number,
	random: () -> number,
	entries: { Entry }?
): { string }
	local available = entries or WaveDirector.ENTRIES
	state.credits = math.min(WaveDirector.MAX_CREDITS, state.credits + WaveDirector.rate(phase, coefficient) * dt)

	local spawns: { string } = {}
	while #spawns < WaveDirector.MAX_PER_UPDATE and alive + #spawns < WaveDirector.ALIVE_CAP do
		local chosen = state.next or pickNext(available, minutes, random)
		state.next = chosen
		if chosen == nil or chosen.cost > state.credits then
			break
		end

		state.credits -= chosen.cost
		state.next = nil
		table.insert(spawns, chosen.defId)
	end
	return spawns
end

-- A walkable spot between `minDistance` and `maxDistance` from a hero, or nil
-- if none turns up in a few tries (a hero in a corner, say): ask again later.
function WaveDirector.pickSpawnPoint(
	grid: NavGrid.Grid,
	heroX: number,
	heroZ: number,
	minDistance: number,
	maxDistance: number,
	random: () -> number
): (number?, number?)
	for _ = 1, 30 do
		local angle = math.floor(random() * Angle.TURN)
		local distance = minDistance + random() * (maxDistance - minDistance)
		local sine, cosine = Angle.direction(angle)
		local x, z = heroX + sine * distance, heroZ + cosine * distance
		if NavGrid.walkableAt(grid, x, z) then
			return x, z
		end
	end
	return nil, nil
end

return WaveDirector
