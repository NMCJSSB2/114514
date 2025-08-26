local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Humanoid
local function setupCharacter(char)
    Humanoid = char:WaitForChild("Humanoid")
end
setupCharacter(LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait())
LocalPlayer.CharacterAdded:Connect(setupCharacter)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "CustomUI"
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
ScreenGui.ResetOnSpawn = false

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 175, 0, 105)
MainFrame.Position = UDim2.new(0.5, -87.5, 0.5, -52.5)
MainFrame.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
MainFrame.BackgroundTransparency = 0.3
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui
MainFrame.Active = true
MainFrame.Draggable = true

local MainUICorner = Instance.new("UICorner")
MainUICorner.CornerRadius = UDim.new(0, 8)
MainUICorner.Parent = MainFrame

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 21)
TitleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame
TitleBar.Active = false
TitleBar.Draggable = false

local TitleUICorner = Instance.new("UICorner")
TitleUICorner.CornerRadius = UDim.new(0, 6)
TitleUICorner.Parent = TitleBar

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -28, 1, 0)
Title.Position = UDim2.new(0, 3.5, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "动作速度控制"
Title.TextColor3 = Color3.fromRGB(255,255,255)
Title.TextSize = 14
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Font = Enum.Font.SourceSansBold
Title.Parent = TitleBar

local MinimizeButton = Instance.new("TextButton")
MinimizeButton.Size = UDim2.new(0, 21, 0, 21)
MinimizeButton.Position = UDim2.new(1, -24.5, 0, 0)
MinimizeButton.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
MinimizeButton.Text = "-"
MinimizeButton.TextColor3 = Color3.fromRGB(255,255,255)
MinimizeButton.TextSize = 14
MinimizeButton.Font = Enum.Font.SourceSansBold
MinimizeButton.BorderSizePixel = 0
MinimizeButton.Parent = TitleBar
MinimizeButton.AutoButtonColor = true
MinimizeButton.TextScaled = true

local MinUICorner = Instance.new("UICorner")
MinUICorner.CornerRadius = UDim.new(0, 10.5)
MinUICorner.Parent = MinimizeButton

local TextBox = Instance.new("TextBox")
TextBox.Size = UDim2.new(0.8, 0, 0, 28)
TextBox.Position = UDim2.new(0.1, 0, 0, 35)
TextBox.BackgroundColor3 = Color3.fromRGB(0,0,0)
TextBox.BackgroundTransparency = 0.5
TextBox.BorderColor3 = Color3.fromRGB(255,255,255)
TextBox.Text = ""
TextBox.PlaceholderText = "输入加速倍率"
TextBox.TextColor3 = Color3.fromRGB(255,255,255)
TextBox.TextSize = 12.6
TextBox.Font = Enum.Font.SourceSans
TextBox.Parent = MainFrame

local TextBoxCorner = Instance.new("UICorner")
TextBoxCorner.CornerRadius = UDim.new(0, 5.6)
TextBoxCorner.Parent = TextBox

local Button = Instance.new("TextButton")
Button.Size = UDim2.new(0.8, 0, 0, 28)
Button.Position = UDim2.new(0.1, 0, 0, 70)
Button.BackgroundColor3 = Color3.fromRGB(150,0,0)
Button.Text = "开关"
Button.TextColor3 = Color3.fromRGB(255,255,255)
Button.TextSize = 14
Button.Font = Enum.Font.SourceSansBold
Button.Parent = MainFrame

local ButtonCorner = Instance.new("UICorner")
ButtonCorner.CornerRadius = UDim.new(0, 5.6)
ButtonCorner.Parent = Button

local minimized = false
local childrenToToggle = {TextBox, Button}
MinimizeButton.MouseButton1Click:Connect(function()
    minimized = not minimized
    for _, child in pairs(childrenToToggle) do
        child.Visible = not minimized
    end
    if minimized then
        MainFrame.Size = UDim2.new(0, 175, 0, 21)
    else
        MainFrame.Size = UDim2.new(0, 175, 0, 105)
    end
end)

local enabled = false
local speedMultiplier = 1

Button.MouseButton1Click:Connect(function()
    enabled = not enabled
    if enabled then
        speedMultiplier = tonumber(TextBox.Text) or 1
        Button.Text = "开启"
        Button.BackgroundColor3 = Color3.fromRGB(0,150,0)
    else
        Button.Text = "关闭"
        Button.BackgroundColor3 = Color3.fromRGB(150,0,0)
        speedMultiplier = 1
    end
end)

task.spawn(function()
    while true do
        task.wait(0.2)
        if Humanoid and Humanoid:FindFirstChildOfClass("Animator") then
            for _, track in pairs(Humanoid:FindFirstChildOfClass("Animator"):GetPlayingAnimationTracks()) do
                if enabled then
                    track:AdjustSpeed(speedMultiplier)
                else
                    track:AdjustSpeed(1)
                end
            end
        end
    end
end)