--!strict

--[=[
	Token-bucket rate limiting, one bucket per key (usually a Player).

	A bucket holds up to `burst` tokens and refills at `perSecond` tokens a
	second. Each request takes a token (or `cost` tokens) and is refused if
	the bucket holds too few, so a key can make `burst` requests at once and
	`perSecond` a second after that.

		local tradeRequests = RateLimit.new({ burst = 3, perSecond = 0.5 })

		function TradeService.requestTrade(player: Player, ...)
			if not RateLimit.take(tradeRequests, player) then
				return
			end
			-- ...
		end

	One request every N seconds is `{ burst = 1, perSecond = 1 / N }`.

	A full bucket behaves like no bucket at all, so buckets that have
	refilled are dropped from time to time. Keys need no cleanup: a player
	who leaves is forgotten once their bucket refills.
]=]

export type Options = {
	-- Tokens a full bucket holds: the most requests allowed at once.
	burst: number,
	-- Tokens regained per second.
	perSecond: number,
	-- Current time in seconds. Defaults to os.clock; tests pass their own.
	clock: (() -> number)?,
}

type Bucket = {
	tokens: number,
	-- When `tokens` was last brought up to date.
	at: number,
}

export type Limiter = {
	burst: number,
	perSecond: number,
	clock: () -> number,
	buckets: { [any]: Bucket },
	-- Seconds between passes that drop full buckets, and when the last one ran.
	pruneInterval: number,
	prunedAt: number,
}

-- Shortest time between pruning passes, for limiters that refill quickly.
local MIN_PRUNE_INTERVAL = 10

local RateLimit = {}

local function isPositive(value: number): boolean
	return value > 0 and value < math.huge
end

local function tokensAt(limiter: Limiter, bucket: Bucket, now: number): number
	return math.min(limiter.burst, bucket.tokens + (now - bucket.at) * limiter.perSecond)
end

local function prune(limiter: Limiter, now: number)
	limiter.prunedAt = now
	for key, bucket in limiter.buckets do
		if tokensAt(limiter, bucket, now) >= limiter.burst then
			limiter.buckets[key] = nil
		end
	end
end

function RateLimit.new(options: Options): Limiter
	assert(isPositive(options.burst), "burst must be a positive number")
	assert(isPositive(options.perSecond), "perSecond must be a positive number")

	local clock = options.clock or os.clock
	return {
		burst = options.burst,
		perSecond = options.perSecond,
		clock = clock,
		buckets = {},
		pruneInterval = math.max(options.burst / options.perSecond, MIN_PRUNE_INTERVAL),
		prunedAt = clock(),
	}
end

-- Takes `cost` tokens (default 1) from `key`'s bucket. Returns false, taking
-- nothing, if the bucket holds fewer.
function RateLimit.take(limiter: Limiter, key: any, cost: number?): boolean
	local now = limiter.clock()
	if now - limiter.prunedAt >= limiter.pruneInterval then
		prune(limiter, now)
	end

	local needed = cost or 1
	local bucket = limiter.buckets[key]
	local tokens = if bucket then tokensAt(limiter, bucket, now) else limiter.burst
	if tokens < needed then
		return false
	end

	if bucket then
		bucket.tokens = tokens - needed
		bucket.at = now
	else
		limiter.buckets[key] = { tokens = tokens - needed, at = now }
	end
	return true
end

return RateLimit
