local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "PlayerMarkerUI"
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
ScreenGui.ResetOnSpawn = false

local MarkerButton = Instance.new("ImageButton")
MarkerButton.Name = "MarkerButton"
MarkerButton.Parent = ScreenGui
MarkerButton.Size = UDim2.new(0, 60, 0, 60)
MarkerButton.Position = UDim2.new(0, 20, 0.5, -30)
MarkerButton.BackgroundTransparency = 1
MarkerButton.BorderSizePixel = 0
MarkerButton.AutoButtonColor = false
MarkerButton.Image = "rbxassetid://108171505803150"

local currentMarkedPlayer = nil
local markerIcons = {}
local fireEffects = {}

local isDragging = false
local dragStartPosition = nil
local buttonStartPosition = nil

MarkerButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        MarkerButton.Image = "rbxassetid://96713068426054"
        dragStartPosition = Vector2.new(input.Position.X, input.Position.Y)
        buttonStartPosition = MarkerButton.Position
        isDragging = false

        local connection
        connection = UserInputService.InputChanged:Connect(function(inputChanged)
            if inputChanged.UserInputType == Enum.UserInputType.MouseMovement or inputChanged.UserInputType == Enum.UserInputType.Touch then
                local currentPosition = Vector2.new(inputChanged.Position.X, inputChanged.Position.Y)
                local delta = currentPosition - dragStartPosition
                if not isDragging and delta.Magnitude > 5 then
                    isDragging = true
                end
                if isDragging then
                    MarkerButton.Position = UDim2.new(
                        buttonStartPosition.X.Scale,
                        buttonStartPosition.X.Offset + delta.X,
                        buttonStartPosition.Y.Scale,
                        buttonStartPosition.Y.Offset + delta.Y
                    )
                end
            end
        end)

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                if connection then
                    connection:Disconnect()
                end
                MarkerButton.Image = "rbxassetid://108171505803150"
                isDragging = false
            end
        end)
    end
end)

local function CreateMarkerIcon(player)
    if markerIcons[player] then return end
    if player.Character then
        local head = player.Character:FindFirstChild("Head")
        if head then
            local billboard = Instance.new("BillboardGui")
            billboard.Name = "PlayerMarker"
            billboard.Size = UDim2.new(1.8,0,1.8,0)
            billboard.AlwaysOnTop = true
            billboard.Adornee = head
            billboard.MaxDistance = 100
            billboard.StudsOffset = Vector3.new(0, 3, 0)
            billboard.Parent = head

            local image = Instance.new("ImageLabel")
            image.Size = UDim2.new(1,0,1,0)
            image.BackgroundTransparency = 1
            image.Image = "rbxassetid://116955222297518"
            image.Parent = billboard

            markerIcons[player] = billboard
        end
    end
end

local function RemoveMarkerIcon(player)
    if markerIcons[player] then
        markerIcons[player]:Destroy()
        markerIcons[player] = nil
    end
end

local function CreateFireEffect(player)
    if player.Character then
        local fires = {}
        for _, part in ipairs(player.Character:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                local outer = Instance.new("Fire")
                outer.Color = Color3.new(0,0,0)
                outer.SecondaryColor = Color3.new(0,0,0)
                outer.Size = 10
                outer.Heat = 10
                outer.Parent = part

                local inner = Instance.new("Fire")
                inner.Color = Color3.fromRGB(50,0,80)
                inner.SecondaryColor = Color3.fromRGB(50,0,80)
                inner.Size = 6
                inner.Heat = 10
                inner.Parent = part

                table.insert(fires, outer)
                table.insert(fires, inner)
            end
        end
        fireEffects[player] = fires
    end
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        local unitRay
        if input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            unitRay = Camera:ScreenPointToRay(pos.X, pos.Y)
        else
            local mouse = LocalPlayer:GetMouse()
            unitRay = Camera:ScreenPointToRay(mouse.X, mouse.Y)
        end

        local raycastParams = RaycastParams.new()
        raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
        raycastParams.FilterType = Enum.RaycastFilterType.Blacklist

        local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 1000, raycastParams)
        if result and result.Instance then
            local hitPart = result.Instance
            local player = Players:GetPlayerFromCharacter(hitPart.Parent)
            if player then
                if currentMarkedPlayer and currentMarkedPlayer ~= player then
                    RemoveMarkerIcon(currentMarkedPlayer)
                end
                currentMarkedPlayer = player
                CreateMarkerIcon(player)
            end
        end
    end
end)

MarkerButton.MouseButton1Click:Connect(function()
    if currentMarkedPlayer then
        CreateFireEffect(currentMarkedPlayer)
    end
end)

Players.PlayerRemoving:Connect(function(player)
    RemoveMarkerIcon(player)
    if fireEffects[player] then
        for _, f in ipairs(fireEffects[player]) do
            f:Destroy()
        end
        fireEffects[player] = nil
    end
    if currentMarkedPlayer == player then
        currentMarkedPlayer = nil
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    if currentMarkedPlayer then
        CreateMarkerIcon(currentMarkedPlayer)
    end
end)