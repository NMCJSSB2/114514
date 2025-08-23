local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local Button = Instance.new("ImageButton")
Button.Size = UDim2.new(0, 60, 0, 60)
Button.Position = UDim2.new(0.9, 0, 0.1, 0)
Button.AnchorPoint = Vector2.new(0.5, 0.5)
Button.BackgroundTransparency = 1
Button.Image = "rbxassetid://95118959634082"
Button.ImageColor3 = Color3.fromRGB(255,255,255)
Button.Parent = ScreenGui

local dragging = false
local dragReady = false
local dragStart, startPos
local longPressTime = 1

local function triggerLongPress()
	task.wait(longPressTime)
	if dragging then
		dragReady = true
		task.spawn(function()
			Button.ImageColor3 = Color3.fromRGB(180,180,180)
			task.wait(0.1)
			Button.ImageColor3 = Color3.fromRGB(255,255,255)
		end)
	end
end

Button.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = Button.Position
		dragReady = false
		Button.ImageColor3 = Color3.fromRGB(180,180,180)
		Button.Size = UDim2.new(0, 55, 0, 55)
		task.spawn(triggerLongPress)
	end
end)

Button.InputChanged:Connect(function(input)
	if dragging and dragReady and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		Button.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if dragging then
			dragging = false
			dragReady = false
			Button.ImageColor3 = Color3.fromRGB(255,255,255)
			Button.Size = UDim2.new(0, 60, 0, 60)
		end
	end
end)

local shiftLockEnabled = false
local targetOffset = Vector3.new(0,0,0)
local cameraOffsetSpeed = 0.1

local function enableShiftLock()
	shiftLockEnabled = true
	targetOffset = Vector3.new(2, 1, 0)
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
end

local function disableShiftLock()
	shiftLockEnabled = false
	targetOffset = Vector3.new(0,0,0)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

Button.MouseButton1Click:Connect(function()
	if shiftLockEnabled then
		disableShiftLock()
	else
		enableShiftLock()
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		enableShiftLock()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		disableShiftLock()
	end
end)

RunService.RenderStepped:Connect(function()
	local character = LocalPlayer.Character
	if character and character:FindFirstChild("Humanoid") and character:FindFirstChild("HumanoidRootPart") then
		local humanoid = character.Humanoid
		local rootPart = character.HumanoidRootPart
		humanoid.CameraOffset = humanoid.CameraOffset:Lerp(targetOffset, cameraOffsetSpeed)
		if shiftLockEnabled then
			local lookVector = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z)
			if lookVector.Magnitude > 0 then
				rootPart.CFrame = CFrame.new(rootPart.Position, rootPart.Position + lookVector.Unit)
			end
		end
	end
end)