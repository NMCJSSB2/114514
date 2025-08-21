local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local NOTIFICATION_COOLDOWN = 1.5
local DEFAULT_CONFIG = {
    Active = false,
    Prediction = 0.145,
    TargetPart = "HumanoidRootPart",
    Smoothness = 0.5,
    MaxRadius = 300,
    MinimumDistance = 10
}

local State = {
    LastNotification = 0,
    LockedTarget = nil
}

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()
local Camera = workspace.CurrentCamera

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local LockButton = Instance.new("ImageButton")
LockButton.Parent = ScreenGui
LockButton.Size = UDim2.new(0, 60, 0, 60)
LockButton.Position = UDim2.new(0, 20, 0.5, -30)
LockButton.BackgroundTransparency = 1
LockButton.BorderSizePixel = 0
LockButton.AutoButtonColor = false
LockButton.Image = "rbxassetid://" .. 136690890096213
local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 12)
UICorner.Parent = LockButton

local function SendNotification(active, target)
    local currentTime = tick()
    if currentTime - State.LastNotification >= NOTIFICATION_COOLDOWN then
        StarterGui:SetCore("SendNotification", {
            Title = "提示",
            Text = active and ("正在锁定 " .. target.Name .. " 玩家") or "关闭",
            Duration = 1
        })
        State.LastNotification = currentTime
    end
end

local function IsTargetValid(player)
    if not player or not player.Character then return false end
    local character = player.Character
    local humanoid = character:FindFirstChild("Humanoid")
    local targetPart = character:FindFirstChild(DEFAULT_CONFIG.TargetPart)
    return targetPart and humanoid and humanoid.Health > 0
end

local function CalculateDistance(position)
    local viewportPosition = Camera:WorldToViewportPoint(position)
    return (Vector2.new(viewportPosition.X, viewportPosition.Y) - Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)).Magnitude
end

local function FindNearestPlayer()
    if State.LockedTarget and IsTargetValid(State.LockedTarget) then
        return State.LockedTarget
    end
    local shortestDistance = DEFAULT_CONFIG.MaxRadius
    local target = nil
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and IsTargetValid(player) then
            local targetPart = player.Character[DEFAULT_CONFIG.TargetPart]
            local distance = CalculateDistance(targetPart.Position)
            if distance >= DEFAULT_CONFIG.MinimumDistance and distance < shortestDistance then
                shortestDistance = distance
                target = player
            end
        end
    end
    return target
end

local function UpdateAimLock()
    if not DEFAULT_CONFIG.Active or not State.LockedTarget then return end
    if not IsTargetValid(State.LockedTarget) then
        DEFAULT_CONFIG.Active = false
        State.LockedTarget = nil
        SendNotification(false)
        return
    end
    local targetPart = State.LockedTarget.Character[DEFAULT_CONFIG.TargetPart]
    local prediction = targetPart.Velocity * DEFAULT_CONFIG.Prediction
    local targetPosition = targetPart.Position + prediction
    local newCFrame = CFrame.lookAt(Camera.CFrame.Position, targetPosition)
    Camera.CFrame = Camera.CFrame:Lerp(newCFrame, DEFAULT_CONFIG.Smoothness)
end

LockButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        LockButton.Image = "rbxassetid://" .. 129639557986886
        local dragStart = input.Position
        local startPos = LockButton.Position
        local dragging = false
        local connection
        connection = UserInputService.InputChanged:Connect(function(inputChanged)
            if inputChanged.UserInputType == Enum.UserInputType.MouseMovement or inputChanged.UserInputType == Enum.UserInputType.Touch then
                local delta = inputChanged.Position - dragStart
                if delta.Magnitude > 5 then
                    dragging = true
                end
                LockButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end)
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                connection:Disconnect()
                if not dragging then
                    DEFAULT_CONFIG.Active = not DEFAULT_CONFIG.Active
                    if DEFAULT_CONFIG.Active then
                        State.LockedTarget = FindNearestPlayer()
                        if State.LockedTarget then
                            SendNotification(true, State.LockedTarget)
                        end
                    else
                        State.LockedTarget = nil
                        SendNotification(false)
                    end
                end
            end
        end)
    end
end)

LockButton.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        LockButton.Image = "rbxassetid://" .. 136690890096213
    end
end)

RunService.RenderStepped:Connect(function()
    UpdateAimLock()
end)