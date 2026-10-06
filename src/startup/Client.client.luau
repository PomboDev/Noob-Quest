--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require("@Core/Loader")

-- Feature modules replicate as part of the initial snapshot; scanning before
-- it completes could miss some of them.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local features = ReplicatedStorage:WaitForChild("Source"):FindFirstChild("Features")
if features then
	Loader.load(features, "Client")
end
