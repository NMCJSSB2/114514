local Players = game:GetService("Players")
local player = Players.LocalPlayer

local function createBillboard(part, text, color)
    if not part:FindFirstChild("NameBillboard") then
        local billboard = Instance.new("BillboardGui")
        billboard.Name = "NameBillboard"
        billboard.Size = UDim2.new(0, 100, 0, 30)
        billboard.StudsOffset = Vector3.new(0, 3, 0)
        billboard.AlwaysOnTop = true
        billboard.MaxDistance = math.huge
        billboard.Adornee = part
        billboard.Parent = part

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, 0, 1, 0)
        label.BackgroundTransparency = 1
        label.TextColor3 = color
        label.TextStrokeTransparency = 0
        label.TextScaled = true
        label.Font = Enum.Font.SourceSansBold
        label.Text = text
        label.Parent = billboard
    end
end

local function checkObject(obj)
    if obj.Name == "SheerHeart" then
        if obj:IsA("BasePart") then
            createBillboard(obj, "小车", Color3.fromRGB(0, 170, 255))
        elseif obj:FindFirstChildWhichIsA("BasePart") then
            createBillboard(obj:FindFirstChildWhichIsA("BasePart"), "小车", Color3.fromRGB(0, 170, 255))
        end
    elseif obj.Name == "Coin" then
        if obj:IsA("BasePart") then
            createBillboard(obj, "硬币", Color3.fromRGB(255, 215, 0))
        elseif obj:FindFirstChildWhichIsA("BasePart") then
            createBillboard(obj:FindFirstChildWhichIsA("BasePart"), "硬币", Color3.fromRGB(255, 215, 0))
        end
    end
end

workspace.DescendantAdded:Connect(function(obj)
    checkObject(obj)
end)

for _, obj in ipairs(workspace:GetDescendants()) do
    checkObject(obj)
end