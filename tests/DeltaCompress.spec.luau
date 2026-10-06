local DeltaCompress = require("../src/core/DeltaCompress")
local Expect = require("./Expect")

-- Sends `new` to a receiver holding `old`, the way PlayerService does.
local function replicate(old: any, new: any, context: DeltaCompress.Context?): any
	local delta = DeltaCompress.createDelta(DeltaCompress.snapshot(old), new, context)
	assert(delta, "expected a delta")
	return DeltaCompress.applyDelta(old, delta, context)
end

return {
	["identical tables produce no delta"] = function()
		local delta = DeltaCompress.createDelta({ a = 1, b = { c = "x" } }, { a = 1, b = { c = "x" } })
		Expect.equal(delta, nil)
	end,

	["applies nested changes, additions and removals"] = function()
		local old = { coins = 10, inventory = { sword = 1, shield = 2 }, flags = { tutorial = true } }
		local new = { coins = 15, inventory = { sword = 1, bow = 3 }, flags = { tutorial = true }, title = "Rookie" }
		Expect.deepEqual(replicate(old, new), new)
	end,

	["replaces values that change type"] = function()
		local old = { slot = 5, gear = { hat = true } }
		local new = { slot = { id = 5, level = 2 }, gear = "none" }
		Expect.deepEqual(replicate(old, new), new)
	end,

	["leaves old untouched and shares unchanged branches"] = function()
		local old = { a = { x = 1 }, b = { y = 2 } }
		local before = DeltaCompress.snapshot(old)
		local result = replicate(old, { a = { x = 1 }, b = { y = 3 } })

		Expect.deepEqual(old, before, "old")
		Expect.equal(result.a, old.a, "unchanged branch")
		Expect.equal(result.b.y, 3)
	end,

	["returns the next snapshot, copied only where it changed"] = function()
		local old = { coins = 1, inventory = { rod = 1 }, stats = { caught = 0 } }
		local live = { coins = 2, inventory = { rod = 1 }, stats = { caught = 0 }, bait = { worm = 3 } }

		local delta, snapshot = DeltaCompress.createDelta(old, live)
		assert(delta, "expected a delta")
		Expect.deepEqual(snapshot, live)
		Expect.equal(snapshot.inventory, old.inventory, "unchanged branch is shared")

		-- Mutating the live data must not leak into the snapshot.
		live.bait.worm = 4
		Expect.equal(snapshot.bait.worm, 3, "added table is copied")

		-- The next diff against the snapshot sees exactly that change.
		local nextDelta = DeltaCompress.createDelta(snapshot, live)
		assert(nextDelta, "expected a delta")
		Expect.deepEqual(DeltaCompress.applyDelta(snapshot, nextDelta), live)
	end,

	["returns old as the snapshot when nothing changed"] = function()
		local old = { a = { b = 1 } }
		local delta, snapshot = DeltaCompress.createDelta(old, { a = { b = 1 } })
		Expect.equal(delta, nil)
		Expect.equal(snapshot, old)
	end,

	["handles arrays that grow, shrink and shift"] = function()
		Expect.deepEqual(replicate({ 1, 2 }, { 1, 2, 3 }), { 1, 2, 3 })
		Expect.deepEqual(replicate({ 1, 2, 3, 4 }, { 1, 3, 4 }), { 1, 3, 4 })
		Expect.deepEqual(replicate({ "a", "b" }, {}), {})
	end,

	["round-trips numbers exactly"] = function()
		local values = {
			0,
			1,
			127,
			128,
			300,
			65535,
			2 ^ 31,
			2 ^ 32 - 1,
			2 ^ 32,
			2 ^ 53,
			-1,
			-300,
			-(2 ^ 32 - 1),
			-(2 ^ 32),
			0.5,
			-0.1,
			1 / 3,
			math.huge,
			-math.huge,
		}
		Expect.deepEqual(replicate({}, values), values)
	end,

	["interns context strings and still sends unknown ones"] = function()
		local context = DeltaCompress.createContext({ name = "default", items = { apple = 0 } })
		local new = { name = "custom", items = { apple = 1, pear = 2 } }

		local interned = DeltaCompress.createDelta({}, new, context)
		local raw = DeltaCompress.createDelta({}, new)
		assert(interned and raw, "expected deltas")
		assert(buffer.len(interned) < buffer.len(raw), "context should shrink the delta")

		Expect.deepEqual(DeltaCompress.applyDelta({}, interned, context), new)
	end,

	["contexts are deterministic"] = function()
		local template = { zeta = 1, alpha = { beta = true, gamma = "delta" }, [1] = "one" }
		local first = DeltaCompress.createContext(template)
		local second = DeltaCompress.createContext(table.clone(template))
		Expect.deepEqual(first.stringToId, second.stringToId)
	end,

	["unknown string ids error"] = function()
		local context = DeltaCompress.createContext({ known = true })
		local delta = DeltaCompress.createDelta({}, { known = 1 }, context)
		assert(delta, "expected a delta")

		Expect.errors(function()
			DeltaCompress.applyDelta({}, delta, DeltaCompress.createContext())
		end, "Unknown string id")
	end,

	["rejects values it cannot serialize"] = function()
		Expect.errors(function()
			DeltaCompress.createDelta({}, { callback = function() end })
		end, "cannot serialize")
	end,

	["malformed deltas error"] = function()
		Expect.errors(function()
			DeltaCompress.applyDelta({}, buffer.fromstring("\255"))
		end, "Unknown tag")
	end,
}
