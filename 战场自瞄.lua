local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local DEFAULT_CONFIG = {
    Active = false,
    Prediction = 0.145,
    TargetPart = "HumanoidRootPart",
    Smoothness = 0.5,
    MaxRadius = 300,
    MinimumDistance = 10
}

local State = {
    LockedTarget = nil
}

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local function IsTargetValid(player)
    if not player or not player.Character then return false end
    local char = player.Character
    local humanoid = char:FindFirstChild("Humanoid")
    local part = char:FindFirstChild(DEFAULT_CONFIG.TargetPart)
    return part and humanoid and humanoid.Health > 0
end

local function CalculateDistanceToCenter(position)
    local viewportPos = Camera:WorldToViewportPoint(position)
    local screenCenter = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
    return (Vector2.new(viewportPos.X, viewportPos.Y) - screenCenter).Magnitude
end

local function FindNearestPlayerToCenter()
    local shortestDistance = DEFAULT_CONFIG.MaxRadius
    local target = nil
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and IsTargetValid(player) then
            local part = player.Character[DEFAULT_CONFIG.TargetPart]
            local dist = CalculateDistanceToCenter(part.Position)
            if dist < shortestDistance then
                shortestDistance = dist
                target = player
            end
        end
    end
    return target
end

local function UpdateAimLock()
    if not DEFAULT_CONFIG.Active then return end
    if not State.LockedTarget or not IsTargetValid(State.LockedTarget) then
        State.LockedTarget = FindNearestPlayerToCenter()
        if not State.LockedTarget then return end
    end
    local targetPart = State.LockedTarget.Character[DEFAULT_CONFIG.TargetPart]
    local prediction = targetPart.Velocity * DEFAULT_CONFIG.Prediction
    local targetPosition = targetPart.Position + prediction
    Camera.CFrame = Camera.CFrame:Lerp(CFrame.lookAt(Camera.CFrame.Position, targetPosition), DEFAULT_CONFIG.Smoothness)
end

local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CustomButtonGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local button = Instance.new("ImageButton")
button.Size = UDim2.new(0, 60, 0, 60)
button.Position = UDim2.new(0, 10, 0.5, -30)
button.Image = "rbxassetid://136690890096213"
button.BackgroundTransparency = 1
button.Parent = screenGui
button.ZIndex = 5

button.MouseButton1Click:Connect(function()
    DEFAULT_CONFIG.Active = not DEFAULT_CONFIG.Active
    if DEFAULT_CONFIG.Active then
        State.LockedTarget = FindNearestPlayerToCenter()
        button.Image = "rbxassetid://129639557986886"
    else
        State.LockedTarget = nil
        button.Image = "rbxassetid://136690890096213"
    end
end)

local dragging = false
local dragInput, dragStart, startPos

local function update(input)
    local delta = input.Position - dragStart
    button.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end

button.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = button.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

button.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        update(input)
    end
end)

RunService.RenderStepped:Connect(function()
    UpdateAimLock()
end)
