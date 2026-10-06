local EnemyDefs = require("../src/features/enemies/modules/EnemyDefs")
local Expect = require("./Expect")
local LootTables = require("../src/features/loot/modules/LootTables")

local function sequence(values: { number }): () -> number
	local index = 0
	return function()
		index += 1
		return values[(index - 1) % #values + 1]
	end
end

local function totals(drops: { LootTables.Drop }): (number, number)
	local coins, xp = 0, 0
	for _, drop in drops do
		if drop.kind == "coin" then
			coins += drop.amount
		else
			xp += drop.amount
		end
	end
	return coins, xp
end

return {
	["every enemy has a table"] = function()
		for _, def in EnemyDefs.list do
			Expect.equal(LootTables.has(def.id), true, def.id)
		end
	end,

	["an unknown enemy drops nothing"] = function()
		Expect.deepEqual(LootTables.roll("ghost", sequence({ 0.5 })), {})
	end,

	["a kill always drops XP"] = function()
		for _, def in EnemyDefs.list do
			for _, roll in { 0, 0.3, 0.7, 0.999 } do
				local _, xp = totals(LootTables.roll(def.id, sequence({ roll })))
				Expect.equal(xp > 0, true, `{def.id} at {roll}`)
			end
		end
	end,

	["coins drop by chance"] = function()
		local lucky = LootTables.roll("grunt", sequence({ 0.1 }))
		local coins = totals(lucky)
		Expect.equal(coins > 0, true)

		local unlucky = LootTables.roll("grunt", sequence({ 0.99 }))
		coins = totals(unlucky)
		Expect.equal(coins, 0)
	end,

	["amounts stay inside the ranges"] = function()
		for _, roll in { 0, 0.5, 0.999 } do
			for _, drop in LootTables.roll("grunt", sequence({ roll })) do
				if drop.kind == "xp" then
					Expect.equal(drop.amount >= 5 and drop.amount <= 7, true, `xp {drop.amount}`)
				else
					Expect.equal(drop.amount >= 1 and drop.amount <= 3, true, `coin {drop.amount}`)
				end
			end
		end
	end,

	["the boss drops far more than a grunt"] = function()
		local bossCoins, bossXp = totals(LootTables.roll("golem", sequence({ 0.5 })))
		local gruntCoins, gruntXp = totals(LootTables.roll("grunt", sequence({ 0.1 })))
		Expect.equal(bossXp > gruntXp * 10, true)
		Expect.equal(bossCoins > gruntCoins * 10, true)
	end,

	["the same numbers give the same drops"] = function()
		Expect.deepEqual(
			LootTables.roll("spitter", sequence({ 0.2, 0.7, 0.4 })),
			LootTables.roll("spitter", sequence({ 0.2, 0.7, 0.4 }))
		)
	end,

	["split adds up exactly"] = function()
		for _, case in { { 15, 4 }, { 30, 4 }, { 7, 3 }, { 0, 3 }, { 2, 5 } } do
			local piles = LootTables.split(case[1], case[2])
			Expect.equal(#piles, case[2])
			local sum = 0
			for _, pile in piles do
				sum += pile
			end
			Expect.equal(sum, case[1], `{case[1]} in {case[2]}`)
		end
	end,
}
