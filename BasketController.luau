-- Basketball shooting system
-- Handles ball possession, shot meter, physics and goal detection

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local ServerStorage     = game:GetService("ServerStorage")
local PhysicsService    = game:GetService("PhysicsService")
local Players           = game:GetService("Players")

local GameSettings = ReplicatedStorage:FindFirstChild("GameSettings")
local Remotes      = GameSettings:FindFirstChild("Remotes")

-- GoalFinder class
local GoalFinder  = {}
GoalFinder.__index = GoalFinder

function GoalFinder.new(goalName)
	local self = setmetatable({}, GoalFinder)
	self.goalName = goalName
	return self
end

function GoalFinder:findNearest(root)
	local closestDist = math.huge
	local closestGoal = nil

	for _, part in ipairs(workspace:GetDescendants()) do
		if part.Name == self.goalName and part:IsA("BasePart") then
			local dist = (part.Position - root.Position).Magnitude
			if dist < closestDist then
				closestDist = dist
				closestGoal = part
			end
		end
	end

	return closestGoal
end

local goalFinder = GoalFinder.new("Goal")

-- ball doesnt physically collide with players but touched still fires
PhysicsService:CreateCollisionGroup("Ball")
PhysicsService:CreateCollisionGroup("Player")
PhysicsService:CollisionGroupsAreCollidable("Ball", "Player", false)

for _, part in ipairs(workspace:GetDescendants()) do
	if part:IsA("BasePart") and part.Name == "Ball" then
		PhysicsService:SetPartCollisionGroup(part, "Ball")
	end
end

-- welder.Value stores the owner name empty string means nobody has it
local function registerBallTouched(ball)
	ball.Touched:Connect(function(hit)
		local char = hit.Parent
		if not char or not char:FindFirstChild("Humanoid") then return end
		if char:FindFirstChild("Ball") then return end

		local settings = ball:FindFirstChild("Settings")
		if not settings then return end

		local welder = settings:FindFirstChild("Welder")
		if not welder or welder.Value ~= "" then return end

		local root         = char:FindFirstChild("HumanoidRootPart")
		local scriptFolder = char:FindFirstChild("Scripts")
		if not root or not scriptFolder then return end

		local animations = scriptFolder.Animations.Get:Invoke()

		ball.Parent        = char
		ball.Connect.Part0 = root
		welder.Value       = char.Name

		if animations["Right-Dribble"] then
			animations["Right-Dribble"]:Play()
		end
	end)
end

for _, obj in ipairs(workspace:GetDescendants()) do
	if obj:IsA("BasePart") and obj.Name == "Ball" then
		registerBallTouched(obj)
	end
end

-- maps bar fill to accuracy % contest value lowers it if defender is close
local function calculatePercent(barSize, contestValue)
	if barSize > 0.5 then
		barSize = 0.5 - (0.5 - barSize) * -1
	end

	local basePercent = (barSize / 0.5) * 100
	local percent     = math.clamp(basePercent + 5 - contestValue, 0, 100)

	warn(string.format("[ShotSystem] Accuracy: %d%%", math.floor(percent)))
	return math.floor(percent)
end

-- early release curves positive late release curves negative
local function calculateOffset(barSize, percent)
	local maxOffset = 0
	local minOffset = 1.25

	if barSize > 0.5 then
		return (percent * (maxOffset - minOffset) / 100) + minOffset
	else
		return (percent * (maxOffset - -minOffset) / 100) + -minOffset
	end
end

-- kinematic solve for launch velocity: v0 = (target - x0 - 0.5*g*t^2) / t
-- gravity divided by pi gives a natural looking arc
local function onRelease(ball, goal, barSize, percent)
	local dist       = (ball.Position - goal.Position).Magnitude
	local flightTime = 1.1 + (dist / 110)
	local gravityVec = Vector3.new(0, -workspace.Gravity / math.pi, 0)

	local x0 = ball.Position
	local v0 = (goal.Position - x0 - 0.5 * gravityVec * flightTime ^ 2) / flightTime / 1.035

	local offset = calculateOffset(barSize, percent)

	ball.Connect.Part0 = nil
	ball.Parent        = workspace
	ball.Velocity      = v0 + Vector3.new(offset, offset, offset)
	ball.RotVelocity   = Vector3.new(0, 0, 15)
	ball:SetNetworkOwner(nil)

	task.wait(1.25)

	local s = ball:FindFirstChild("Settings")
	if s and s:FindFirstChild("Welder") then
		s.Welder.Value = ""
	end
end

-- num 1 = shot press num 2 = early release
Remotes.Shoot.OnServerEvent:Connect(function(plr, _bool, num)
	local char = plr.Character
	if not char then return end

	local humanoid     = char:FindFirstChildOfClass("Humanoid")
	local root         = char:FindFirstChild("HumanoidRootPart")
	local ball         = char:FindFirstChild("Ball")
	local values       = char:FindFirstChild("Values")
	local scriptFolder = char:FindFirstChild("Scripts")
	if not humanoid or not root or not ball or not values or not scriptFolder then return end

	local shooting = values:FindFirstChild("Shooting")
	local contest  = values:FindFirstChild("Contest")
	if not shooting or not contest then return end

	local animations = scriptFolder.Animations.Get:Invoke()
	local goal       = goalFinder:findNearest(root)
	if not goal then return end

	local shotmeterUI = root:FindFirstChild("ShotmeterUI")
	local bar         = shotmeterUI and shotmeterUI:FindFirstChild("Meter") and shotmeterUI.Meter:FindFirstChild("Bar")
	if not bar then return end

	local animLength    = animations["Jumpshot-1"] and animations["Jumpshot-1"].Length or 1
	local barTweenInfo  = TweenInfo.new(animLength / 2, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
	local stopTweenInfo = TweenInfo.new(0, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
	local barTween      = TweenService:Create(bar, barTweenInfo,  { Size = UDim2.new(1, 0, -1, 0) })
	local stopTween     = TweenService:Create(bar, stopTweenInfo, { Size = UDim2.new(1, 0, bar.Size.Y.Scale, 0) })

	if num == 1 then
		shooting.Value = true

		for _, track in pairs(animations) do
			if track.Name == "Right-Dribble" then track:Stop() end
		end

		-- bodyGyro smoothly locks rotation toward the goal without teleporting
		local bodyGyro     = Instance.new("BodyGyro", root)
		bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		bodyGyro.D         = 275
		bodyGyro.P         = 5000
		bodyGyro.CFrame    = CFrame.lookAt(
			root.Position,
			Vector3.new(goal.Position.X, root.Position.Y, goal.Position.Z)
		)
		humanoid.WalkSpeed = 0

		task.wait()
		animations["Jumpshot-1"]:Play(0.5)

		animations["Jumpshot-1"].KeyframeReached:Connect(function(frame)
			if frame == "Release" then
				local barSize = -bar.Size.Y.Scale
				local percent = calculatePercent(barSize, contest.Value)
				onRelease(ball, goal, barSize, percent)
				shooting.Value = false
				contest.Value  = 0
			end
		end)

		barTween:Play()

		task.wait(animLength + 0.25)
		bodyGyro:Destroy()
		humanoid.WalkSpeed = 16
		bar.Size = UDim2.new(1, 0, 0, 0)

	elseif num == 2 then
		stopTween:Play()
	end
end)

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		local root       = char:WaitForChild("HumanoidRootPart")
		local meterClone = ServerStorage:FindFirstChild("ShotmeterUI"):Clone()
		meterClone.Parent = root

		for _, part in ipairs(char:GetChildren()) do
			if part:IsA("BasePart") then
				PhysicsService:SetPartCollisionGroup(part, "Player")
			end
		end
	end)

	plr.Chatted:Connect(function(msg)
		if msg == ":ball" then
			local char = plr.Character
			if not char or char:FindFirstChild("Ball") then return end

			local newBall    = ServerStorage:FindFirstChild("Ball"):Clone()
			newBall.Parent   = workspace
			newBall.Position = char.HumanoidRootPart.Position

			PhysicsService:SetPartCollisionGroup(newBall, "Ball")
			registerBallTouched(newBall)
		end
	end)
end)
