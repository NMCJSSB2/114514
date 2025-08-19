local Players = game:GetService("Players")
local player = Players.LocalPlayer
local mouse = player:GetMouse()

local scriptEnabled = true

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ClickNameGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.new(0.6, 0, 0.1, 0)
label.Position = UDim2.new(0.2, 0, 0.1, 0)
label.BackgroundTransparency = 0.3
label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.TextWrapped = true
label.TextScaled = true
label.Text = "点击方块"
label.Parent = screenGui

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.new(0.1, 0, 0.06, 0)
closeButton.Position = UDim2.new(0.88, 0, 0.02, 0)
closeButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.Text = "关闭"
closeButton.Font = Enum.Font.SourceSansBold
closeButton.TextScaled = true
closeButton.Parent = screenGui

local function getFullPath(obj)
	local path = {}
	local current = obj
	while current and current ~= game do
		table.insert(path, 1, current.Name)
		current = current.Parent
	end
	return table.concat(path, " > ")
end

local currentHighlight = nil
local lastInvisiblePart = nil
local lastTransparency = nil

closeButton.MouseButton1Click:Connect(function()
	scriptEnabled = false
	if currentHighlight then
		currentHighlight:Destroy()
		currentHighlight = nil
	end
	if lastInvisiblePart and lastInvisiblePart.Parent then
		lastInvisiblePart.Transparency = lastTransparency
		lastInvisiblePart = nil
		lastTransparency = nil
	end
	screenGui:Destroy()
end)

label.InputBegan:Connect(function(input)
	if not scriptEnabled then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if label.Text ~= "" then
			setclipboard(label.Text)
		end
	end
end)

mouse.Button1Down:Connect(function()
	if not scriptEnabled then return end
	if mouse.Target then
		local part = mouse.Target
		local fullPath = getFullPath(part)
		label.Text = "名称: " .. part.Name .. "\n路径: " .. fullPath

		if currentHighlight then
			currentHighlight:Destroy()
			currentHighlight = nil
		end

		if lastInvisiblePart and lastInvisiblePart.Parent then
			lastInvisiblePart.Transparency = lastTransparency
			lastInvisiblePart = nil
			lastTransparency = nil
		end

		if part:IsA("BasePart") then
			if part.Transparency == 1 then
				lastInvisiblePart = part
				lastTransparency = part.Transparency
				part.Transparency = 0.9
			end
		end

		local highlight = Instance.new("Highlight")
		highlight.Name = "ClickHighlight"
		highlight.FillColor = Color3.fromRGB(255, 255, 255)
		highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 0
		highlight.Adornee = part
		highlight.Parent = part

		currentHighlight = highlight
	end
end)