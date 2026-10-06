--!strict

--[=[
	Greedy meshing for a grid: merges neighbouring cells with the same value
	into as few rectangles as it can, so a map of thousands of tiles is drawn
	with a few hundred Frames. Pure, so Lune can test it.

	It scans row by row. At the first free cell of a value it grows the
	rectangle to the right as far as the value goes, then downwards for as long
	as the whole row below holds the same value, and marks everything it took.
	The result doesn't depend on anything but the grid.
]=]

local GreedyMesh = {}

-- A rectangle of cells: top-left corner (`x`, `y`, from 0), size in cells, and the value it holds.
export type Rect = {
	x: number,
	y: number,
	w: number,
	h: number,
	value: number,
}

-- `cells` holds one value per cell, row by row (`y * width + x + 1`). Value 0
-- is empty and never part of a rectangle. Every other cell is in exactly one
-- rectangle.
function GreedyMesh.merge(width: number, height: number, cells: { number }): { Rect }
	local used: { boolean } = table.create(width * height, false)
	local rects: { Rect } = {}

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local index = y * width + x + 1
			local value = cells[index] or 0
			if value == 0 or used[index] then
				continue
			end

			local w = 1
			while x + w < width and cells[index + w] == value and not used[index + w] do
				w += 1
			end

			local h = 1
			local growing = true
			while growing and y + h < height do
				for dx = 0, w - 1 do
					local below = (y + h) * width + x + dx + 1
					if cells[below] ~= value or used[below] then
						growing = false
						break
					end
				end
				if growing then
					h += 1
				end
			end

			for dy = 0, h - 1 do
				for dx = 0, w - 1 do
					used[(y + dy) * width + x + dx + 1] = true
				end
			end
			table.insert(rects, { x = x, y = y, w = w, h = h, value = value })
		end
	end

	return rects
end

return GreedyMesh
