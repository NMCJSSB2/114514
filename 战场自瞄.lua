local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DEFAULT_CONFIG = {
    Active = false,
    Prediction = 0.1,
    TargetPart = "HumanoidRootPart",
    Smoothness = 0.7,
    MaxRadius = 300,
    MaxPredictionDistance = 20,
    ClickThreshold = 5,
    TargetMode = "Player",
    NPCSearchInterval = 0.5
}

local State = {
    LockedTarget = nil,
    DragStartPos = nil,
    DragDistance = 0,
    DragConnection = nil,
    ModeDragStartPos = nil,
    ModeDragDistance = 0,
    ModeDragConnection = nil,
    LastNPCSearchTime = 0,
    CachedNPCList = {},
    NPCCacheTime = 0
}

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local function IsTargetValid(target)
    if not target or not target.Parent then return false end
    local humanoid = target:FindFirstChild("Humanoid")
    local part = target:FindFirstChild(DEFAULT_CONFIG.TargetPart)
    return part and humanoid and humanoid.Health > 0
end

local function IsPlayerTarget(target)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character == target then
            return true
        end
    end
    return false
end

local function CalculateDistanceToCenter(position)
    local viewportPos = Camera:WorldToViewportPoint(position)
    if viewportPos.Z <= 0 then
        return math.huge
    end
    local screenCenter = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y/2)
    return (Vector2.new(viewportPos.X, viewportPos.Y) - screenCenter).Magnitude
end

local function FindNearestPlayerToCenter()
    local shortestDistance = DEFAULT_CONFIG.MaxRadius
    local target = nil
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and IsTargetValid(player.Character) then
            local part = player.Character[DEFAULT_CONFIG.TargetPart]
            local dist = CalculateDistanceToCenter(part.Position)
            if dist < shortestDistance then
                shortestDistance = dist
                target = player.Character
            end
        end
    end
    return target
end

local function GetNPCList()
    local currentTime = tick()
    
    if currentTime - State.NPCCacheTime > 1 then
        State.CachedNPCList = {}
        for _, npc in ipairs(Workspace:GetDescendants()) do
            if IsTargetValid(npc) and not IsPlayerTarget(npc) and npc ~= LocalPlayer.Character then
                table.insert(State.CachedNPCList, npc)
            end
        end
        State.NPCCacheTime = currentTime
    end
    
    return State.CachedNPCList
end

local function FindNearestNPCToCenter()
    local shortestDistance = DEFAULT_CONFIG.MaxRadius
    local target = nil
    
    local npcList = GetNPCList()
    
    for _, npc in ipairs(npcList) do
        if IsTargetValid(npc) then
            local part = npc[DEFAULT_CONFIG.TargetPart]
            local dist = CalculateDistanceToCenter(part.Position)
            if dist < shortestDistance then
                shortestDistance = dist
                target = npc
            end
        end
    end
    
    return target
end

local function FindTarget()
    if DEFAULT_CONFIG.TargetMode == "Player" then
        return FindNearestPlayerToCenter()
    else
        return FindNearestNPCToCenter()
    end
end

local function GetPredictedPosition(targetPart)
    local prediction = targetPart.Velocity * DEFAULT_CONFIG.Prediction
    if prediction.Magnitude > DEFAULT_CONFIG.MaxPredictionDistance then
        prediction = prediction.Unit * DEFAULT_CONFIG.MaxPredictionDistance
    end
    return targetPart.Position + prediction
end

local function UpdateAimLock()
    if not DEFAULT_CONFIG.Active then return end
    
    if not State.LockedTarget or not IsTargetValid(State.LockedTarget) then
        local currentTime = tick()
        
        if DEFAULT_CONFIG.TargetMode == "NPC" then
            if currentTime - State.LastNPCSearchTime < DEFAULT_CONFIG.NPCSearchInterval then
                return
            end
            State.LastNPCSearchTime = currentTime
        end
        
        State.LockedTarget = FindTarget()
        if not State.LockedTarget then return end
    end
    
    local targetPart = State.LockedTarget[DEFAULT_CONFIG.TargetPart]
    local targetPosition = GetPredictedPosition(targetPart)
    
    local targetCFrame = CFrame.lookAt(Camera.CFrame.Position, targetPosition)
    Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, DEFAULT_CONFIG.Smoothness)
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

local modeButton = Instance.new("TextButton")
modeButton.Size = UDim2.new(0, 80, 0, 30)
modeButton.Position = UDim2.new(0, 10, 0.5, 40)
modeButton.Text = "玩家模式"
modeButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
modeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
modeButton.BackgroundTransparency = 0.3
modeButton.BorderSizePixel = 0
modeButton.Parent = screenGui
modeButton.ZIndex = 5

modeButton.MouseButton1Click:Connect(function()
    if State.ModeDragDistance <= DEFAULT_CONFIG.ClickThreshold then
        if DEFAULT_CONFIG.TargetMode == "Player" then
            DEFAULT_CONFIG.TargetMode = "NPC"
            modeButton.Text = "NPC模式"
            modeButton.BackgroundColor3 = Color3.fromRGB(60, 40, 40)
        else
            DEFAULT_CONFIG.TargetMode = "Player"
            modeButton.Text = "玩家模式"
            modeButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        end
        
        if DEFAULT_CONFIG.Active then
            State.LockedTarget = nil
            State.LastNPCSearchTime = 0
        end
    end
end)

button.MouseButton1Click:Connect(function()
    if State.DragDistance <= DEFAULT_CONFIG.ClickThreshold then
        DEFAULT_CONFIG.Active = not DEFAULT_CONFIG.Active
        if DEFAULT_CONFIG.Active then
            State.LockedTarget = FindTarget()
            State.LastNPCSearchTime = 0
            button.Image = "rbxassetid://129639557986886"
        else
            State.LockedTarget = nil
            button.Image = "rbxassetid://136690890096213"
        end
    end
end)

local dragging = false
local dragInput, dragStart, startPos
local modeDragging = false
local modeDragInput, modeDragStart, modeStartPos

local function update(input)
    local delta = input.Position - dragStart
    button.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
end

local function updateModeButton(input)
    local delta = input.Position - modeDragStart
    modeButton.Position = UDim2.new(modeStartPos.X.Scale, modeStartPos.X.Offset + delta.X,
                                    modeStartPos.Y.Scale, modeStartPos.Y.Offset + delta.Y)
end

button.InputBegan:Connect(function(input)
    if input.UserInputState == Enum.UserInputState.Begin then
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = button.Position
            State.DragDistance = 0
            State.DragStartPos = input.Position
            
            if State.DragConnection then
                State.DragConnection:Disconnect()
            end
            
            State.DragConnection = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    State.DragConnection:Disconnect()
                    State.DragConnection = nil
                end
            end)
        end
    end
end)

button.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
        if dragging and State.DragStartPos then
            State.DragDistance = (input.Position - State.DragStartPos).Magnitude
        end
    end
end)

modeButton.InputBegan:Connect(function(input)
    if input.UserInputState == Enum.UserInputState.Begin then
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            modeDragging = true
            modeDragStart = input.Position
            modeStartPos = modeButton.Position
            State.ModeDragDistance = 0
            State.ModeDragStartPos = input.Position
            
            if State.ModeDragConnection then
                State.ModeDragConnection:Disconnect()
            end
            
            State.ModeDragConnection = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    modeDragging = false
                    State.ModeDragConnection:Disconnect()
                    State.ModeDragConnection = nil
                end
            end)
        end
    end
end)

modeButton.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        modeDragInput = input
        if modeDragging and State.ModeDragStartPos then
            State.ModeDragDistance = (input.Position - State.ModeDragStartPos).Magnitude
        end
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        update(input)
    elseif input == modeDragInput and modeDragging then
        updateModeButton(input)
    end
end)

RunService.RenderStepped:Connect(function()
    UpdateAimLock()
end)
