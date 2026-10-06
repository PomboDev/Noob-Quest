--!strict

--[=[
	Upgrades player data saved by older versions of the game.

	`schemaVersion` in PlayerData.TEMPLATE is the current version, and
	MIGRATIONS[n] turns version n data into version n + 1. When a profile
	loads, PlayerService runs the ones it is missing, in order, before
	Reconcile fills in missing fields.

	Adding a field needs no migration: Reconcile copies it from the template.
	Renaming, moving or reshaping one does. Append a migration and bump
	TEMPLATE.schemaVersion in the same change:

		local MIGRATIONS: { Migration } = {
			-- 1 -> 2: `gold` became `coins`
			function(data)
				data.coins = data.gold
				data.gold = nil
			end,
		}

	A migration gets the data as it was saved (untyped, since it predates the
	current Data type) and changes it in place. It must carry everything over,
	including pending trades and auction escrows. Never edit or remove one
	that has shipped: some profile out there still has to run it.

	Migrations run on a copy, so one that errors leaves the saved data as it
	was and the player can load once it's fixed. Data from a newer version
	than this server knows (saved by an updated server during a rollout) is
	never touched either.
]=]

local DeltaCompress = require("@Core/DeltaCompress")
local PlayerData = require("@Features/player/modules/PlayerData")

export type Migration = (data: any) -> ()

local MIGRATIONS: { Migration } = {}

local PlayerMigrations = {
	MIGRATIONS = MIGRATIONS,
}

assert(
	PlayerData.TEMPLATE.schemaVersion == #MIGRATIONS + 1,
	"PlayerData.TEMPLATE.schemaVersion must be one more than the number of migrations"
)

-- Brings saved `data` up to date with `migrations` (default MIGRATIONS).
-- Returns `data` itself if it is current, and a migrated copy otherwise,
-- leaving `data` untouched. Errors if the data is from a newer version, has
-- a malformed version, or a migration errors.
function PlayerMigrations.migrate(data: any, migrations: { Migration }?): any
	local list = migrations or MIGRATIONS
	local latest = #list + 1
	-- Data saved before the field existed is version 1.
	local version = if data.schemaVersion == nil then 1 else data.schemaVersion

	if type(version) ~= "number" or version % 1 ~= 0 or version < 1 then
		error(`malformed schemaVersion {version}`, 0)
	elseif version > latest then
		error(`saved by a newer version ({version}; this server knows up to {latest})`, 0)
	elseif version == latest then
		return data
	end

	local migrated = DeltaCompress.snapshot(data)
	for from = version, latest - 1 do
		-- `:: any`: strict mode has no type for the error of a call that returns nothing
		local ok, err = pcall(list[from] :: any, migrated)
		if not ok then
			error(`migration {from} -> {from + 1} failed: {err}`, 0)
		end
		migrated.schemaVersion = from + 1
	end
	return migrated
end

return PlayerMigrations
