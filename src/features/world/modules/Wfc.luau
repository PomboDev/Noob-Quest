--!strict

--[=[
	Step 3 of act generation: wave function collapse over the tile grid.

	Every cell starts with all the variants that may be chosen, cells in
	`fixed` with only theirs. The cell with the fewest options collapses to a
	random one (weighted by tile weight) and the choice propagates: a variant
	stays only if some variant still possible next door has the same socket on
	the touching sides.

	Ties between equally constrained cells are broken by a noise value drawn
	once per cell, so the order doesn't favour any corner. No logarithms:
	entropy would need `math.log`, whose last digit may differ between
	platforms, and the grid has to be identical on server and clients.
]=]

local ActTypes = require("@Features/world/modules/ActTypes")
local Rng = require("@Core/Rng")

type TileSet = ActTypes.TileSet

local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }

local Wfc = {}

-- A variant id per cell, or nil on a contradiction (a cell with no variant
-- left). `fixed` maps cell indices to the variant they must be.
function Wfc.solve(
	width: number,
	height: number,
	tileSet: TileSet,
	fixed: { [number]: number },
	rng: Rng.Rng
): { number }?
	local variants = tileSet.variants
	local variantCount = #variants
	local cellCount = width * height

	local possible: { { boolean } } = {}
	local count: { number } = {}
	local noise: { number } = {}

	for cell = 1, cellCount do
		local row = table.create(variantCount, false)
		local remaining = 0
		local pinned = fixed[cell]
		for v = 1, variantCount do
			local allowed = if pinned then v == pinned else variants[v].weight > 0
			if allowed then
				row[v] = true
				remaining += 1
			end
		end
		if remaining == 0 then
			return nil
		end
		possible[cell] = row
		count[cell] = remaining
		noise[cell] = Rng.next(rng)
	end

	local stack: { number } = {}
	local queued: { [number]: boolean } = {}

	local function enqueue(cell: number)
		if not queued[cell] then
			queued[cell] = true
			table.insert(stack, cell)
		end
	end

	-- False if this left the cell with nothing.
	local function ban(cell: number, v: number): boolean
		local row = possible[cell]
		if row[v] then
			row[v] = false
			count[cell] -= 1
			if count[cell] == 0 then
				return false
			end
			enqueue(cell)
		end
		return true
	end

	local function propagate(): boolean
		while #stack > 0 do
			local cell = table.remove(stack) :: number
			queued[cell] = false

			local x, y = (cell - 1) % width, (cell - 1) // width
			local row = possible[cell]
			for d = 1, 4 do
				local nx, ny = x + DX[d], y + DY[d]
				if nx >= 0 and nx < width and ny >= 0 and ny < height then
					-- Sockets this cell can still show towards the neighbour.
					local supported: { [string]: boolean } = {}
					for v = 1, variantCount do
						if row[v] then
							supported[variants[v].sockets[d]] = true
						end
					end

					local neighbor = ny * width + nx + 1
					local neighborRow = possible[neighbor]
					-- The side of the neighbour that touches this cell.
					local opposite = (d + 1) % 4 + 1
					for v = 1, variantCount do
						if neighborRow[v] and not supported[variants[v].sockets[opposite]] then
							if not ban(neighbor, v) then
								return false
							end
						end
					end
				end
			end
		end
		return true
	end

	for cell = 1, cellCount do
		enqueue(cell)
	end
	if not propagate() then
		return nil
	end

	while true do
		local best: number? = nil
		local bestScore = math.huge
		for cell = 1, cellCount do
			local options = count[cell]
			if options > 1 then
				local score = options + noise[cell]
				if score < bestScore then
					best, bestScore = cell, score
				end
			end
		end
		if not best then
			break
		end

		local row = possible[best]
		local weights: { number } = {}
		for v = 1, variantCount do
			weights[v] = if row[v] then variants[v].weight else 0
		end
		local chosen = Rng.weighted(rng, weights)
		for v = 1, variantCount do
			if v ~= chosen and row[v] and not ban(best, v) then
				return nil
			end
		end
		if not propagate() then
			return nil
		end
	end

	local tiles: { number } = {}
	for cell = 1, cellCount do
		local row = possible[cell]
		for v = 1, variantCount do
			if row[v] then
				tiles[cell] = v
				break
			end
		end
	end
	return tiles
end

return Wfc
