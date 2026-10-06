--!strict

--[=[
	Plays the idle and walk animations on a hero's character, from how fast
	it is moving. The character is only a puppet (anchored, placed by the
	client every frame), so Roblox's own Animate script, which waits for the
	Humanoid's state machine, is switched off.
]=]

local HeroAnimator = {}

type Puppet = {
	walk: AnimationTrack?,
	idle: AnimationTrack?,
	animator: Animator,
}

-- Studs a second at which the walk animation plays at its normal speed.
local WALK_REFERENCE_SPEED = 16
-- Slower than this counts as standing still.
local STILL_SPEED = 0.5

local ANIMATIONS = {
	R15 = { idle = "rbxassetid://507766666", walk = "rbxassetid://507777826" },
	R6 = { idle = "rbxassetid://180435571", walk = "rbxassetid://180426354" },
}

local puppets: { [Model]: Puppet } = setmetatable({}, { __mode = "k" }) :: any

local function load(animator: Animator, id: string, priority: Enum.AnimationPriority): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = animator:LoadAnimation(animation)
	track.Priority = priority
	track.Looped = true
	return track
end

local function setup(character: Model): Puppet?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if humanoid == nil or animator == nil then
		return nil
	end

	local animate = character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		animate.Enabled = false
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		track:Stop(0)
	end

	local ids = ANIMATIONS[if humanoid.RigType == Enum.HumanoidRigType.R6 then "R6" else "R15"]
	local puppet: Puppet = {
		animator = animator,
		idle = load(animator, ids.idle, Enum.AnimationPriority.Idle),
		walk = load(animator, ids.walk, Enum.AnimationPriority.Movement),
	}
	if puppet.idle then
		puppet.idle:Play(0)
	end
	return puppet
end

-- Call every frame with the hero's speed in studs a second.
function HeroAnimator.update(character: Model, speed: number)
	local puppet = puppets[character]
	if puppet == nil then
		local created = setup(character)
		if created == nil then
			return
		end
		puppets[character] = created
		puppet = created
	end

	-- The engine plays its own state animations (a fallen-over pose, since the
	-- anchored puppet never stands on anything): only ours may play.
	for _, track in puppet.animator:GetPlayingAnimationTracks() do
		if track ~= puppet.idle and track ~= puppet.walk then
			track:Stop(0)
		end
	end

	local walk = puppet.walk
	if walk == nil then
		return
	end
	if speed > STILL_SPEED then
		if not walk.IsPlaying then
			walk:Play(0.1)
		end
		walk:AdjustSpeed(math.clamp(speed / WALK_REFERENCE_SPEED, 0.5, 2.5))
	elseif walk.IsPlaying then
		walk:Stop(0.15)
	end
end

return HeroAnimator
