--!strict

--[=[
	Pure bookkeeping that grants each developer product purchase exactly once,
	applied to the buyer's data.

	Roblox names every purchase with a PurchaseId and keeps calling
	ProcessReceipt for it, on any server, until one call returns
	PurchaseGranted. So the grant and the record of its PurchaseId go into
	the data together, in one step that can't yield: any later call for the
	same purchase finds the record and grants nothing. MonetizationService
	only answers PurchaseGranted once a save holding the record has reached
	the DataStore. If the server dies first, neither the grant nor the record
	was saved, and the next call starts over.

	A grant that errors (or yields) is undone, so a purchase is never half
	granted, and isn't recorded, so Roblox retries it.

	Only the newest MAX_RECEIPTS ids are kept. Roblox stops retrying a
	purchase once it's acknowledged, so a record only has to outlive that.
]=]

local DeltaCompress = require("@Core/DeltaCompress")
local PlayerData = require("@Features/player/modules/PlayerData")

type Data = PlayerData.Data

-- "duplicate": recorded earlier, so nothing was granted this time.
export type Status = "granted" | "duplicate" | "failed"

local MAX_RECEIPTS = 50

local PurchaseReceipts = {
	MAX_RECEIPTS = MAX_RECEIPTS,
}

-- Makes `target` match `backup` again, in place: tables the grant changed
-- keep their identity, since other code may hold on to them.
local function restore(target: any, backup: any)
	for key in target do
		if backup[key] == nil then
			target[key] = nil
		end
	end
	for key, value in backup do
		local current = target[key]
		if type(value) == "table" and type(current) == "table" then
			restore(current, value)
		else
			target[key] = value
		end
	end
end

-- Records `purchaseId`, then drops the oldest others past MAX_RECEIPTS.
local function record(data: Data, purchaseId: string, now: number)
	local receipts = data.receipts
	receipts[purchaseId] = now

	while true do
		local count = 0
		local oldestId: string? = nil
		local oldestAt = math.huge
		for id, at in receipts do
			count += 1
			-- Never the new one, even if another server's clock ran ahead.
			if id ~= purchaseId and at < oldestAt then
				oldestId, oldestAt = id, at
			end
		end

		if count <= MAX_RECEIPTS or oldestId == nil then
			return
		end
		receipts[oldestId] = nil
	end
end

-- Whether `data` (e.g. a profile's last saved data) has granted `purchaseId`.
function PurchaseReceipts.isRecorded(data: Data, purchaseId: string): boolean
	return data.receipts[purchaseId] ~= nil
end

-- Runs `grant` on `data` and records `purchaseId` as granted at `now`
-- (os.time()), unless it already is ("duplicate"). If `grant` errors or
-- yields, every change it made to `data` is undone and nothing is recorded
-- ("failed", with the reason).
function PurchaseReceipts.grant(
	data: Data,
	purchaseId: string,
	now: number,
	grant: (data: Data) -> ()
): (Status, string?)
	if PurchaseReceipts.isRecorded(data, purchaseId) then
		return "duplicate", nil
	end

	local backup = DeltaCompress.snapshot(data)
	local thread = coroutine.create(grant)
	local ok, err = coroutine.resume(thread, data)
	if ok and coroutine.status(thread) ~= "dead" then
		-- The rest of it would run after the receipt was saved.
		coroutine.close(thread)
		ok, err = false, "the grant yielded"
	end

	if not ok then
		restore(data, backup)
		return "failed", tostring(err)
	end

	record(data, purchaseId, now)
	return "granted", nil
end

return PurchaseReceipts
