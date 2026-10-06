--!strict

--[=[
	Where the lobby is and which parts of it a hero can stand on, on plain
	numbers (Lune can test it). The lobby is a square platform on its own
	patch of the world, far along X so it never overlaps an act. Its walls are
	a ring of cells nobody can enter.
]=]

local NavGrid = require("@Features/enemies/modules/NavGrid")

local LobbySpace = {}

LobbySpace.X = 1500
LobbySpace.Z = 0
LobbySpace.SIZE = 120
LobbySpace.PORTAL_Z = LobbySpace.Z - 20
LobbySpace.SPAWN_Z = LobbySpace.Z + 15

-- Cells are 2 studs across, so the walls stop a hero close to the glass.
local CELL = 2

local cached: NavGrid.Grid? = nil

-- Whether a point is over the lobby platform (acts are never near it).
function LobbySpace.contains(x: number, z: number): boolean
	local half = LobbySpace.SIZE / 2
	return math.abs(x - LobbySpace.X) <= half and math.abs(z - LobbySpace.Z) <= half
end

function LobbySpace.navGrid(): NavGrid.Grid
	if cached then
		return cached
	end

	local cells = LobbySpace.SIZE // CELL
	local walkable = table.create(cells * cells, true)
	for cy = 0, cells - 1 do
		for cx = 0, cells - 1 do
			if cx == 0 or cy == 0 or cx == cells - 1 or cy == cells - 1 then
				walkable[cy * cells + cx + 1] = false
			end
		end
	end

	local half = LobbySpace.SIZE / 2
	local grid = NavGrid.new(cells, cells, CELL, LobbySpace.X - half, LobbySpace.Z - half, walkable)
	cached = grid
	return grid
end

return LobbySpace
