local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local OriginalWalkSpeed = Humanoid.WalkSpeed

local SHADOW_SETTINGS = {
    Enabled = false,
    SpawnInterval = 0.1,
    LifeTime = 2.5,
    InitialTransparency = 0,
    FinalTransparency = 1,
    SizeMultiplier = 1.0
}

local shadows = {}
local lastSpawnTime = 0
local lastPosition = Character:GetPivot().Position
local globalHighlights = {}
local timerActive = false
local buttonCooldown = false
local sound

-- ColorCorrection Effect
local shadowEffect = Instance.new("ColorCorrectionEffect")
shadowEffect.Name = "ShadowScreenEffect"
shadowEffect.Contrast = 0
shadowEffect.TintColor = Color3.new(1,1,1)
shadowEffect.Parent = Lighting

-- GUI
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ShadowToggleUI"
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
ScreenGui.ResetOnSpawn = false

local ToggleButton = Instance.new("ImageButton")
ToggleButton.Name = "ShadowToggleButton"
ToggleButton.Parent = ScreenGui
ToggleButton.Size = UDim2.new(0, 60, 0, 60)
ToggleButton.Position = UDim2.new(0, 20, 0, 20)
ToggleButton.BackgroundTransparency = 1
ToggleButton.BorderSizePixel = 0
ToggleButton.AutoButtonColor = false
ToggleButton.Image = "rbxassetid://136771252711259"

-- Timer Label
local TimerLabel = Instance.new("TextLabel")
TimerLabel.Parent = ScreenGui
TimerLabel.AnchorPoint = Vector2.new(0.5,0)
TimerLabel.Position = UDim2.new(0.5,0,0,20)
TimerLabel.Size = UDim2.new(0,200,0,40)
TimerLabel.TextScaled = true
TimerLabel.Visible = false
TimerLabel.Font = Enum.Font.SciFi
TimerLabel.TextStrokeTransparency = 0
TimerLabel.BackgroundTransparency = 1

-- Button Sound
local function playSound()
    if sound then sound:Stop(); sound:Destroy() end
    sound = Instance.new("Sound")
    sound.SoundId = "rbxassetid://91010981512264"
    sound.PlaybackSpeed = 1
    sound.Parent = ToggleButton
    sound:Play()
end

-- Update Button Icon
local function updateButtonIcon()
    if SHADOW_SETTINGS.Enabled then
        ToggleButton.Image = "rbxassetid://126704965850899"
    else
        ToggleButton.Image = "rbxassetid://136771252711259"
    end
end

-- Tween ColorCorrection
local function tweenScreenEffect(targetContrast,targetTint)
    TweenService:Create(shadowEffect,TweenInfo.new(0.5),{Contrast=targetContrast,TintColor=targetTint}):Play()
end

-- Clear Shadows
local function clearShadows()
    for _, shadowData in ipairs(shadows) do
        if shadowData.Model and shadowData.Model.Parent then shadowData.Model:Destroy() end
    end
    shadows = {}
    for _, highlight in ipairs(globalHighlights) do
        if highlight and highlight.Parent then highlight:Destroy() end
    end
    globalHighlights = {}
end

-- Shadow Functions
local function clonePartAppearance(originalPart, shadowPart)
    shadowPart.Transparency = SHADOW_SETTINGS.InitialTransparency
    shadowPart.Color = Color3.new(1,1,1)
    shadowPart.Material = Enum.Material.SmoothPlastic
    shadowPart.Anchored = true
    shadowPart.CanCollide = false
    shadowPart.CanQuery = false
    shadowPart.CanTouch = false
    for _, child in ipairs(originalPart:GetChildren()) do  
        if child:IsA("SpecialMesh") then  
            local clone = child:Clone()  
            clone.TextureId = ""  
            clone.VertexColor = Vector3.new(1,1,1)  
            clone.Parent = shadowPart  
        elseif child:IsA("Decal") or child:IsA("Texture") or child:IsA("SurfaceAppearance") then  
            child:Destroy()  
        end  
    end  
    if originalPart:IsA("MeshPart") then  
        shadowPart.TextureID = ""  
        shadowPart.VertexColor = Vector3.new(1,1,1)  
    end
end
local function createCharacterShadowModel()
    if not Character then return nil end
    local shadowModel = Instance.new("Model")
    shadowModel.Name = "PlayerShadow"
    for _, originalPart in ipairs(Character:GetDescendants()) do  
        if originalPart:IsA("BasePart") and originalPart.Transparency < 0.9 then  
            local shadowPart = Instance.new("Part")  
            shadowPart.Name = originalPart.Name  
            shadowPart.Size = originalPart.Size * SHADOW_SETTINGS.SizeMultiplier  
            shadowPart.CFrame = originalPart.CFrame  
            clonePartAppearance(originalPart, shadowPart)  
            shadowPart.Parent = shadowModel  
        end  
    end  
    for _, accessory in ipairs(Character:GetChildren()) do  
        if accessory:IsA("Accessory") and accessory:FindFirstChild("Handle") then  
            local shadowPart = Instance.new("Part")  
            shadowPart.Name = accessory.Name  
            shadowPart.Size = accessory.Handle.Size * SHADOW_SETTINGS.SizeMultiplier  
            shadowPart.CFrame = accessory.Handle.CFrame  
            clonePartAppearance(accessory.Handle, shadowPart)  
            shadowPart.Parent = shadowModel  
        end  
    end  
    local highlight = Instance.new("Highlight")  
    highlight.Name = "ShadowHighlight"  
    highlight.FillColor = Color3.fromRGB(0,255,255)  
    highlight.OutlineColor = Color3.fromRGB(0,255,255)  
    highlight.FillTransparency = 0.5  
    highlight.OutlineTransparency = 0.7  
    highlight.Adornee = shadowModel  
    highlight.Parent = shadowModel  
    table.insert(globalHighlights, highlight)
    shadowModel.Parent = workspace  
    return shadowModel
end

local function createCharacterShadow()
    if not SHADOW_SETTINGS.Enabled or not Character then return end
    local currentTime = tick()
    if currentTime - lastSpawnTime < SHADOW_SETTINGS.SpawnInterval then return end
    local currentPosition = Character:GetPivot().Position
    if (currentPosition - lastPosition).Magnitude < 0.1 then return end
    lastSpawnTime = currentTime
    lastPosition = currentPosition
    local shadowModel = createCharacterShadowModel()
    if shadowModel then
        table.insert(shadows, {Model = shadowModel, CreatedTime = currentTime})
    end
end

local function updateShadows()
    local currentTime = tick()
    local indicesToRemove = {}
    for i, shadowData in ipairs(shadows) do  
        local age = currentTime - shadowData.CreatedTime  
        if age >= SHADOW_SETTINGS.LifeTime then  
            table.insert(indicesToRemove, i)  
        else  
            local transparency = SHADOW_SETTINGS.InitialTransparency  
            if age > 2 then  
                local t = (age - 2) / 0.5  
                transparency = SHADOW_SETTINGS.InitialTransparency + t*(SHADOW_SETTINGS.FinalTransparency - SHADOW_SETTINGS.InitialTransparency)  
            end  
            for _, part in ipairs(shadowData.Model:GetDescendants()) do  
                if part:IsA("BasePart") then  
                    part.Transparency = transparency  
                end  
            end  
        end  
    end  
    for i = #indicesToRemove,1,-1 do  
        local shadowData = shadows[indicesToRemove[i]]  
        if shadowData.Model and shadowData.Model.Parent then  
            shadowData.Model:Destroy()  
        end  
        table.remove(shadows, indicesToRemove[i])  
    end
end

local function onMovementUpdate()
    if SHADOW_SETTINGS.Enabled and Character and Humanoid and Humanoid.MoveDirection.Magnitude > 0 then
        createCharacterShadow()
    end
    updateShadows()
end

local function onCharacterAdded(newCharacter)
    Character = newCharacter
    Humanoid = newCharacter:WaitForChild("Humanoid")
    lastPosition = Character:GetPivot().Position
    clearShadows()
end

LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
RunService.RenderStepped:Connect(onMovementUpdate)
updateButtonIcon()

-- Dragging
local dragging = false
local dragStartPos
local buttonStartPos
local holdTime = 0.5
local holdStartTime = nil
local canDrag = false
local shortPressTriggered = false

ToggleButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragStartPos = input.Position
        buttonStartPos = ToggleButton.Position
        holdStartTime = tick()
        canDrag = false
        shortPressTriggered = false
    end
end)

ToggleButton.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        if holdStartTime and not canDrag then
            if tick() - holdStartTime >= holdTime then
                canDrag = true
                dragging = true
            end
        end
        if dragging then
            local delta = input.Position - dragStartPos
            ToggleButton.Position = UDim2.new(
                buttonStartPos.X.Scale,
                buttonStartPos.X.Offset + delta.X,
                buttonStartPos.Y.Scale,
                buttonStartPos.Y.Offset + delta.Y
            )
        end
    end
end)

-- Toggle + Timer
ToggleButton.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if not canDrag and not shortPressTriggered and not buttonCooldown then
            buttonCooldown = true
            task.delay(1,function() buttonCooldown = false end)

            if SHADOW_SETTINGS.Enabled then
                -- Turn off
                SHADOW_SETTINGS.Enabled = false
                Humanoid.WalkSpeed = OriginalWalkSpeed
                tweenScreenEffect(0, Color3.new(1,1,1))
                clearShadows()
                TimerLabel.Visible = false
                timerActive = false
            else
                -- Turn on
                SHADOW_SETTINGS.Enabled = true
                Humanoid.WalkSpeed = 30
                tweenScreenEffect(-2, Color3.fromRGB(0,255,0))
                playSound()
                timerActive = true
                TimerLabel.Visible = true
                local countdown = 10
                local startColor = Color3.fromRGB(0,255,255)
                local endColor = Color3.fromRGB(128,0,128)

                spawn(function()
                    while timerActive and countdown > 0 do
                        TimerLabel.Text = string.format("%.2f", countdown)
                        local alpha = (10 - countdown)/10
                        TimerLabel.TextColor3 = startColor:Lerp(endColor, alpha)
                        task.wait(0.05)
                        countdown = countdown - 0.05
                    end
                    if timerActive then
                        -- Auto turn off
                        SHADOW_SETTINGS.Enabled = false
                        updateButtonIcon()
                        Humanoid.WalkSpeed = OriginalWalkSpeed
                        tweenScreenEffect(0, Color3.new(1,1,1))
                        clearShadows()
                        TimerLabel.Visible = false
                        timerActive = false
                    end
                end)
            end
            updateButtonIcon()
            shortPressTriggered = true
        end
        dragging = false
        holdStartTime = nil
        canDrag = false
    end
end)

-- Shadow color cycling
local gradientColors = {
    Color3.fromRGB(0,255,255),
    Color3.fromRGB(0,0,255),
    Color3.fromRGB(128,0,128),
    Color3.fromRGB(255,0,0),
    Color3.fromRGB(255,165,0),
    Color3.fromRGB(255,255,0),
    Color3.fromRGB(0,255,255)
}

RunService.RenderStepped:Connect(function()
    local t = (tick() % 60) / 60
    local segment = t * (#gradientColors - 1)
    local index = math.floor(segment) + 1
    local nextIndex = index + 1
    if nextIndex > #gradientColors then nextIndex = 1 end
    local alpha = segment - math.floor(segment)
    local color = gradientColors[index]:Lerp(gradientColors[nextIndex], alpha)
    for _, highlight in ipairs(globalHighlights) do  
        highlight.FillColor = color  
        highlight.OutlineColor = color  
    end
end)