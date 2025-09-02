local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Player = Players.LocalPlayer

local MaxLength = 900000
local ThirdPersonOffset = CFrame.new(1.7, 0.5, 0)
local FirstPersonOffset = CFrame.new(0, 0, 0)
local Active

local ShiftLockScreenGui = Instance.new("ScreenGui")
ShiftLockScreenGui.Name = "Shiftlock"
ShiftLockScreenGui.Parent = game:GetService("CoreGui")
ShiftLockScreenGui.ResetOnSpawn = false

local ShiftLockButton = Instance.new("ImageButton")
ShiftLockButton.Parent = ShiftLockScreenGui
ShiftLockButton.BackgroundTransparency = 1
ShiftLockButton.Position = UDim2.new(0.9, -60, 0.05, 0)
ShiftLockButton.Size = UDim2.fromOffset(60, 60)
ShiftLockButton.Image = "rbxassetid://111590748521247"
ShiftLockButton.ZIndex = 10

local dragging = false
local dragInput, dragStart, startPos

local function isFirstPerson()
    local cam = workspace.CurrentCamera
    return cam.CameraSubject and cam.CameraSubject:IsA("Humanoid") 
        and cam.CameraType == Enum.CameraType.Custom 
        and (cam.CFrame.Position - cam.Focus.Position).Magnitude < 1
end

ShiftLockButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = ShiftLockButton.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

ShiftLockButton.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input == dragInput) then
        local delta = input.Position - dragStart
        ShiftLockButton.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

ShiftLockButton.MouseButton1Click:Connect(function()
    if dragging then return end

    if not Active then
        Active = RunService.RenderStepped:Connect(function()
            if Player.Character and Player.Character:FindFirstChild("HumanoidRootPart") and Player.Character:FindFirstChild("Humanoid") then
                local humanoid = Player.Character.Humanoid
                humanoid.AutoRotate = false
                local root = Player.Character.HumanoidRootPart
                local camLook = workspace.CurrentCamera.CFrame.LookVector
                root.CFrame = CFrame.new(root.Position, Vector3.new(camLook.X * MaxLength, root.Position.Y, camLook.Z * MaxLength))
                
                if isFirstPerson() then
                    workspace.CurrentCamera.CFrame = workspace.CurrentCamera.CFrame * FirstPersonOffset
                else
                    workspace.CurrentCamera.CFrame = workspace.CurrentCamera.CFrame * ThirdPersonOffset
                end
            end
        end)
    else
        if Player.Character and Player.Character:FindFirstChild("Humanoid") then
            Player.Character.Humanoid.AutoRotate = true
        end
        workspace.CurrentCamera.CFrame = workspace.CurrentCamera.CFrame * ThirdPersonOffset
        pcall(function()
            Active:Disconnect()
            Active = nil
        end)
    end
end)
