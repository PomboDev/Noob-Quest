local Expect = require("./Expect")
local PlayerData = require("../src/features/player/modules/PlayerData")
local PlayerMigrations = require("../src/features/player/modules/PlayerMigrations")

-- 1 -> 2 renames `gold` to `coins`, 2 -> 3 moves `level` into `stats`.
local MIGRATIONS = {
	function(data)
		data.coins = data.gold
		data.gold = nil
	end,
	function(data)
		data.stats = { level = data.level }
		data.level = nil
	end,
}

return {
	["the template is at the latest version"] = function()
		Expect.equal(PlayerData.TEMPLATE.schemaVersion, #PlayerMigrations.MIGRATIONS + 1)
		local data = table.clone(PlayerData.TEMPLATE)
		Expect.equal(PlayerMigrations.migrate(data), data, "current data is returned as is")
	end,

	["runs every missing migration in order"] = function()
		local saved = { schemaVersion = 1, gold = 50, level = 4, inventory = { sword = 1 } }
		local migrated = PlayerMigrations.migrate(saved, MIGRATIONS)

		Expect.deepEqual(migrated, { schemaVersion = 3, coins = 50, stats = { level = 4 }, inventory = { sword = 1 } })
	end,

	["starts from the saved version"] = function()
		local saved = { schemaVersion = 2, coins = 50, level = 4 }
		Expect.deepEqual(
			PlayerMigrations.migrate(saved, MIGRATIONS),
			{ schemaVersion = 3, coins = 50, stats = { level = 4 } }
		)
	end,

	["treats a missing version as 1"] = function()
		local migrated = PlayerMigrations.migrate({ gold = 5, level = 1 }, MIGRATIONS)
		Expect.deepEqual(migrated, { schemaVersion = 3, coins = 5, stats = { level = 1 } })
	end,

	["leaves the saved data untouched"] = function()
		local saved = { schemaVersion = 1, gold = 50, level = 4, inventory = { sword = 1 } }
		local migrated = PlayerMigrations.migrate(saved, MIGRATIONS)

		Expect.deepEqual(saved, { schemaVersion = 1, gold = 50, level = 4, inventory = { sword = 1 } })
		Expect.equal(migrated.inventory ~= saved.inventory, true, "nested tables are copied")
	end,

	["returns current data as is"] = function()
		local saved = { schemaVersion = 3, coins = 1 }
		Expect.equal(PlayerMigrations.migrate(saved, MIGRATIONS), saved)
	end,

	["refuses data from a newer version"] = function()
		local saved = { schemaVersion = 4, coins = 1 }
		Expect.errors(function()
			PlayerMigrations.migrate(saved, MIGRATIONS)
		end, "newer version")
		Expect.deepEqual(saved, { schemaVersion = 4, coins = 1 })
	end,

	["refuses malformed versions"] = function()
		for _, bad in { 0, -1, 1.5, 0 / 0, math.huge, "1" } do
			Expect.errors(function()
				PlayerMigrations.migrate({ schemaVersion = bad }, MIGRATIONS)
			end, "malformed")
		end
	end,

	["a failing migration changes nothing"] = function()
		local saved = { schemaVersion = 1, gold = 50, level = 4 }
		local failing = {
			MIGRATIONS[1],
			function(data)
				data.level = nil
				error("boom")
			end,
		}

		Expect.errors(function()
			PlayerMigrations.migrate(saved, failing)
		end, "migration 2 -> 3 failed")
		Expect.deepEqual(saved, { schemaVersion = 1, gold = 50, level = 4 })
	end,
}
