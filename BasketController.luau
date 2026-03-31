-- Basketball shooting system
-- Handles possession, shot meter, physics and goal detection

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local ServerStorage     = game:GetService("ServerStorage")
local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")

local GameSettings = ReplicatedStorage:FindFirstChild("GameSettings")
local Remotes      = GameSettings:FindFirstChild("Remotes")

local Config = {
	GoalName         = "Goal",
	CollisionBall    = "Ball",
	CollisionPlayer  = "Player",

	FlightBase       = 1.1,    -- base flight time in seconds
	FlightDist       = 110,    -- divisor for distance-based flight time
	GravityDiv       = math.pi, -- dividing gravity by pi gives a natural arc
	VelocityDiv      = 1.035,  -- slight velocity reduction for realistic feel
	MaxOffset        = 0,
	MinOffset        = 1.25,   -- max curve on a bad release
	WaitAfterShot    = 1.25,   -- seconds before resetting ball ownership

	GyroDamping      = 275,
	GyroPower        = 5000,

	DefaultWalkSpeed = 16,
	ShotWalkSpeed    = 0,      -- freeze player during shot animation

	CooldownTime     = 1.5,    -- seconds between allowed shots
	AccuracyBonus    = 5,      -- flat accuracy boost added to every shot
}

-- tracks last shot time per player to prevent spamming
local CooldownManager = {}
CooldownManager.__index = CooldownManager

function CooldownManager.new()
	local Self = setmetatable({}, CooldownManager)
	Self.Cooldowns = {}
	return Self
end

function CooldownManager:Check(Player)
	local Last = self.Cooldowns[Player.UserId]
	if not Last then return true end
	return (os.clock() - Last) >= Config.CooldownTime
end

function CooldownManager:Set(Player)
	self.Cooldowns[Player.UserId] = os.clock()
end

function CooldownManager:Remove(Player)
	self.Cooldowns[Player.UserId] = nil
end

local Cooldowns = CooldownManager.new()

-- scans workspace to find the closest goal part to a given root
local GoalFinder = {}
GoalFinder.__index = GoalFinder

function GoalFinder.new(GoalName)
	local Self = setmetatable({}, GoalFinder)
	Self.GoalName = GoalName
	return Self
end

function GoalFinder:FindNearest(Root)
	local ClosestDist = math.huge
	local ClosestGoal = nil

	for _, Part in ipairs(workspace:GetDescendants()) do
		if Part.Name == self.GoalName and Part:IsA("BasePart") then
			local Dist = (Part.Position - Root.Position).Magnitude
			if Dist < ClosestDist then
				ClosestDist = Dist
				ClosestGoal = Part
			end
		end
	end

	return ClosestGoal
end

local Finder = GoalFinder.new(Config.GoalName)

-- ball and player are in separate collision groups so they dont block each other
-- but Touched events still fire normally
PhysicsService:RegisterCollisionGroup(Config.CollisionBall)
PhysicsService:RegisterCollisionGroup(Config.CollisionPlayer)
PhysicsService:CollisionGroupSetCollidable(Config.CollisionBall, Config.CollisionPlayer, false)

local function SetBallCollision(Part)
	Part.CollisionGroup = Config.CollisionBall
end

local function SetPlayerCollision(Part)
	Part.CollisionGroup = Config.CollisionPlayer
end

-- assign collision group to any balls already in workspace on startup
for _, Part in ipairs(workspace:GetDescendants()) do
	if Part:IsA("BasePart") and Part.Name == "Ball" then
		SetBallCollision(Part)
	end
end

-- converts bar fill into a 0-100 accuracy score, reduced by how close a defender is
local function CalculatePercent(BarSize, ContestValue)
	-- mirror the value if player released late so both sides score the same
	if BarSize > 0.5 then
		BarSize = 0.5 - (0.5 - BarSize) * -1
	end

	local BasePercent = (BarSize / 0.5) * 100
	local Percent     = math.clamp(BasePercent + Config.AccuracyBonus - ContestValue, 0, 100)

	if RunService:IsStudio() then
		warn(string.format("[Shot] Accuracy: %d%% | Contest: %d", math.floor(Percent), ContestValue))
	end

	return math.floor(Percent)
end

-- early release curves shot one way, late release curves it the other
local function CalculateOffset(BarSize, Percent)
	if BarSize > 0.5 then
		return (Percent * (Config.MaxOffset - Config.MinOffset) / 100) + Config.MinOffset
	else
		return (Percent * (Config.MaxOffset - (-Config.MinOffset)) / 100) + (-Config.MinOffset)
	end
end

-- kinematic formula: v0 = (target - x0 - 0.5*g*t^2) / t
local function SolveLaunchVelocity(Origin, Target, FlightTime)
	local GravityVec = Vector3.new(0, -workspace.Gravity / Config.GravityDiv, 0)
	return (Target - Origin - 0.5 * GravityVec * FlightTime ^ 2) / FlightTime / Config.VelocityDiv
end

-- unwelds ball from character and launches it toward the goal
local function OnRelease(Ball, Goal, BarSize, Percent)
	local Dist       = (Ball.Position - Goal.Position).Magnitude
	local FlightTime = Config.FlightBase + (Dist / Config.FlightDist)
	local Offset     = CalculateOffset(BarSize, Percent)
	local V0         = SolveLaunchVelocity(Ball.Position, Goal.Position, FlightTime)

	local Connect = Ball:FindFirstChild("Connect")
	if Connect then
		Connect.Part0 = nil
	end

	Ball.Parent                  = workspace
	Ball.AssemblyLinearVelocity  = V0 + Vector3.new(Offset, Offset, Offset)
	Ball.AssemblyAngularVelocity = Vector3.new(0, 0, 15)
	Ball:SetNetworkOwner(nil)

	-- wait for ball to finish traveling then clear ownership so someone else can grab it
	task.wait(Config.WaitAfterShot)

	local Settings = Ball:FindFirstChild("Settings")
	if Settings and Settings:FindFirstChild("Welder") then
		Settings.Welder.Value = ""
	end
end

-- when a ball is touched by a player who doesnt already have one, give them possession
local function RegisterBallTouched(Ball)
	Ball.Touched:Connect(function(Hit)
		local Char = Hit.Parent
		if not Char or not Char:FindFirstChildOfClass("Humanoid") then return end
		if Char:FindFirstChild("Ball") then return end

		local Settings = Ball:FindFirstChild("Settings")
		if not Settings then return end

		local Welder = Settings:FindFirstChild("Welder")
		if not Welder or Welder.Value ~= "" then return end

		local Root         = Char:FindFirstChild("HumanoidRootPart")
		local ScriptFolder = Char:FindFirstChild("Scripts")
		if not Root or not ScriptFolder then return end

		local Animations = ScriptFolder.Animations.Get:Invoke()

		-- weld ball to the character root part
		local Connect = Ball:FindFirstChild("Connect")
		if Connect then
			Connect.Part0 = Root
		end

		Ball.Parent  = Char
		Welder.Value = Char.Name

		if Animations["Right-Dribble"] then
			Animations["Right-Dribble"]:Play()
		end
	end)
end

for _, Obj in ipairs(workspace:GetDescendants()) do
	if Obj:IsA("BasePart") and Obj.Name == "Ball" then
		RegisterBallTouched(Obj)
	end
end

-- num 1 = shot press, num 2 = early release
Remotes.Shoot.OnServerEvent:Connect(function(Plr, _Bool, Num)
	if not Cooldowns:Check(Plr) then return end

	local Char = Plr.Character
	if not Char then return end

	local Humanoid     = Char:FindFirstChildOfClass("Humanoid")
	local Root         = Char:FindFirstChild("HumanoidRootPart")
	local Ball         = Char:FindFirstChild("Ball")
	local Values       = Char:FindFirstChild("Values")
	local ScriptFolder = Char:FindFirstChild("Scripts")
	if not Humanoid or not Root or not Ball or not Values or not ScriptFolder then return end

	local Shooting = Values:FindFirstChild("Shooting")
	local Contest  = Values:FindFirstChild("Contest")
	if not Shooting or not Contest then return end

	local Animations = ScriptFolder.Animations.Get:Invoke()
	local Goal       = Finder:FindNearest(Root)
	if not Goal then return end

	local ShotmeterUI = Root:FindFirstChild("ShotmeterUI")
	local Bar         = ShotmeterUI and ShotmeterUI:FindFirstChild("Meter") and ShotmeterUI.Meter:FindFirstChild("Bar")
	if not Bar then return end

	local AnimLength    = (Animations["Jumpshot-1"] and Animations["Jumpshot-1"].Length) or 1
	local BarTweenInfo  = TweenInfo.new(AnimLength / 2, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
	local StopTweenInfo = TweenInfo.new(0, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
	local BarTween      = TweenService:Create(Bar, BarTweenInfo,  { Size = UDim2.new(1, 0, -1, 0) })
	local StopTween     = TweenService:Create(Bar, StopTweenInfo, { Size = UDim2.new(1, 0, Bar.Size.Y.Scale, 0) })

	if Num == 1 then
		Cooldowns:Set(Plr)
		Shooting.Value = true

		-- stop dribble before playing jump shot animation
		for _, Track in pairs(Animations) do
			if Track.Name == "Right-Dribble" then
				Track:Stop()
			end
		end

		-- rotate character to face the goal smoothly without teleporting
		local BodyGyro     = Instance.new("BodyGyro", Root)
		BodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		BodyGyro.D         = Config.GyroDamping
		BodyGyro.P         = Config.GyroPower
		BodyGyro.CFrame    = CFrame.lookAt(
			Root.Position,
			Vector3.new(Goal.Position.X, Root.Position.Y, Goal.Position.Z)
		)

		Humanoid.WalkSpeed = Config.ShotWalkSpeed
		task.wait()

		Animations["Jumpshot-1"]:Play(0.5)

		-- release the ball when the animation hits the Release keyframe
		Animations["Jumpshot-1"].KeyframeReached:Connect(function(Frame)
			if Frame == "Release" then
				local BarSize = -Bar.Size.Y.Scale
				local Percent = CalculatePercent(BarSize, Contest.Value)
				OnRelease(Ball, Goal, BarSize, Percent)
				Shooting.Value = false
				Contest.Value  = 0
			end
		end)

		BarTween:Play()

		task.wait(AnimLength + 0.25)
		BodyGyro:Destroy()
		Humanoid.WalkSpeed = Config.DefaultWalkSpeed
		Bar.Size = UDim2.new(1, 0, 0, 0)

	elseif Num == 2 then
		-- freeze bar at current position for early release
		StopTween:Play()
	end
end)

Players.PlayerAdded:Connect(function(Plr)
	Plr.CharacterAdded:Connect(function(Char)
		local Root          = Char:WaitForChild("HumanoidRootPart")
		local MeterTemplate = ServerStorage:FindFirstChild("ShotmeterUI")

		-- attach shot meter UI to root so it follows the player
		if MeterTemplate then
			MeterTemplate:Clone().Parent = Root
		end

		for _, Part in ipairs(Char:GetChildren()) do
			if Part:IsA("BasePart") then
				SetPlayerCollision(Part)
			end
		end
	end)

	Plr.Chatted:Connect(function(Msg)
		if Msg:lower() == ":ball" then
			local Char = Plr.Character
			if not Char or Char:FindFirstChild("Ball") then return end

			local BallTemplate = ServerStorage:FindFirstChild("Ball")
			if not BallTemplate then return end

			local NewBall    = BallTemplate:Clone()
			NewBall.Parent   = workspace
			NewBall.Position = Char.HumanoidRootPart.Position

			SetBallCollision(NewBall)
			RegisterBallTouched(NewBall)
		end
	end)
end)

-- clean up cooldown data when player leaves to avoid memory leaks
Players.PlayerRemoving:Connect(function(Plr)
	Cooldowns:Remove(Plr)
end)
