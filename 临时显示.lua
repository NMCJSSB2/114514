local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ScreenGui = Instance.new("ScreenGui", LocalPlayer:WaitForChild("PlayerGui"))
ScreenGui.Name = "SearchDisplay"
ScreenGui.ResetOnSpawn = false

local MainFrame = Instance.new("Frame", ScreenGui)
MainFrame.Size = UDim2.new(0, 300, 0, 120)
MainFrame.Position = UDim2.new(0.5, -150, 0, 50)
MainFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
MainFrame.BackgroundTransparency = 0.2
MainFrame.Active = true
MainFrame.Draggable = true
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 8)

local function addBillboard(part)
    if not part:FindFirstChild("NameBillboard") then
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "NameBillboard"
        billboard.Size = UDim2.new(0, 100, 0, 30)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.AlwaysOnTop = true
        billboard.MaxDistance = math.huge
        billboard.Adornee = part
        billboard.Parent = part

        local label = Instance.new("TextLabel", billboard)
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        label.TextStrokeTransparency = 0
        label.TextScaled = true
        label.Font = Enum.Font.SourceSansBold
        label.Text = part.Name
    end
end

local groupBox = Instance.new("TextBox", MainFrame)
groupBox.Size = UDim2.new(1, -20, 0, 30)
groupBox.Position = UDim2.new(0, 10, 0, 10)
groupBox.PlaceholderText = "输入组/文件夹名"
groupBox.Text = ""
groupBox.TextScaled = true
groupBox.Font = Enum.Font.SourceSans
groupBox.PlaceholderColor3 = Color3.fromRGB(0, 0, 0)
Instance.new("UICorner", groupBox).CornerRadius = UDim.new(0, 6)

groupBox.FocusLost:Connect(function(enterPressed)
    if enterPressed and groupBox.Text ~= "" then
        local targetGroup = workspace:FindFirstChild(groupBox.Text)
        if targetGroup and (targetGroup:IsA("Folder") or targetGroup:IsA("Model")) then
            for _, obj in ipairs(targetGroup:GetDescendants()) do
                if obj:IsA("BasePart") then
                    addBillboard(obj)
                end
            end
        end
    end
end)

local partBox = Instance.new("TextBox", MainFrame)
partBox.Size = UDim2.new(1, -20, 0, 30)
partBox.Position = UDim2.new(0, 10, 0, 60)
partBox.PlaceholderText = "输入方块名"
partBox.Text = ""
partBox.TextScaled = true
partBox.Font = Enum.Font.SourceSans
partBox.PlaceholderColor3 = Color3.fromRGB(0, 0, 0)
Instance.new("UICorner", partBox).CornerRadius = UDim.new(0, 6)

partBox.FocusLost:Connect(function(enterPressed)
    if enterPressed and partBox.Text ~= "" then
        local targetPart = workspace:FindFirstChild(partBox.Text, true)
        if targetPart and targetPart:IsA("BasePart") then
            addBillboard(targetPart)
        end
    end
end)