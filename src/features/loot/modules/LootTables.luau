--!strict

--[=[
	What enemies drop. Pure: the server passes the random numbers in, so the
	same numbers give the same drops.

	A drop is a pile of coins or an orb of XP. Each enemy kind rolls its own
	table: a number of XP orbs, and for coins a chance and a number of piles.
	Bigger enemies give bigger and more drops, and the boss showers the arena.

	Gear and runes join this table once items exist (kind "item").
]=]

local LootTables = {}

export type Kind = "coin" | "xp"

export type Drop = {
	kind: Kind,
	amount: number,
}

type Range = { number }

type Table = {
	-- XP orbs: how many (a range), and how much each is worth (a range).
	xpOrbs: Range,
	xpEach: Range,
	-- Coin piles: the chance there are any, how many (a range) and each one's worth (a range).
	coinChance: number,
	coinPiles: Range,
	coinEach: Range,
}

-- The kinds travel as a small number.
LootTables.KINDS = { "coin", "xp" } :: { Kind }

local TABLES: { [string]: Table } = {
	grunt = {
		xpOrbs = { 1, 1 },
		xpEach = { 5, 7 },
		coinChance = 0.65,
		coinPiles = { 1, 1 },
		coinEach = { 1, 3 },
	},
	runner = {
		xpOrbs = { 1, 1 },
		xpEach = { 6, 8 },
		coinChance = 0.6,
		coinPiles = { 1, 1 },
		coinEach = { 1, 3 },
	},
	spitter = {
		xpOrbs = { 1, 2 },
		xpEach = { 6, 9 },
		coinChance = 0.85,
		coinPiles = { 1, 2 },
		coinEach = { 2, 5 },
	},
	golem = {
		xpOrbs = { 5, 6 },
		xpEach = { 40, 60 },
		coinChance = 1,
		coinPiles = { 7, 9 },
		coinEach = { 8, 14 },
	},
}

function LootTables.has(defId: string): boolean
	return TABLES[defId] ~= nil
end

local function between(range: Range, random: () -> number): number
	local low, high = range[1], range[2]
	return low + math.floor(random() * (high - low + 1))
end

-- The drops of one kill. `random` gives numbers in [0, 1). An enemy without a table drops nothing.
function LootTables.roll(defId: string, random: () -> number): { Drop }
	local drops: { Drop } = {}
	local entry = TABLES[defId]
	if entry == nil then
		return drops
	end

	for _ = 1, between(entry.xpOrbs, random) do
		table.insert(drops, { kind = "xp", amount = between(entry.xpEach, random) })
	end

	if random() < entry.coinChance then
		for _ = 1, between(entry.coinPiles, random) do
			table.insert(drops, { kind = "coin", amount = between(entry.coinEach, random) })
		end
	end
	return drops
end

-- Splits `total` into `piles` piles that add up to it exactly (some may be a coin bigger).
function LootTables.split(total: number, piles: number): { number }
	local count = math.max(1, math.floor(piles))
	local whole = math.max(0, math.floor(total))
	local base, extra = whole // count, whole % count

	local result: { number } = {}
	for index = 1, count do
		table.insert(result, base + (if index <= extra then 1 else 0))
	end
	return result
end

return LootTables
