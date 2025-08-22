local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local HIGHLIGHT_COLOR = Color3.fromRGB(0, 170, 255)
local TEXT_COLOR = Color3.fromRGB(0, 0, 0)
local MAX_DISTANCE = 20

local highlights = {}

local function createHighlight(part)
	if highlights[part] then return end
	
	local highlight = Instance.new("Highlight")
	highlight.Adornee = part
	highlight.FillTransparency = 1
	highlight.OutlineColor = HIGHLIGHT_COLOR
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = workspace
	
	local billboard = Instance.new("BillboardGui")
	billboard.Adornee = part
	billboard.Size = UDim2.new(0, 100, 0, 25)
	billboard.StudsOffset = Vector3.new(0, part.Size.Y/2 + 0.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Name = "ClickMarker"
	billboard.Parent = part
	
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1,0,1,0)
	label.BackgroundTransparency = 1
	label.Text = "可点击"
	label.TextColor3 = HIGHLIGHT_COLOR -- 主体蓝色
	label.TextStrokeColor3 = TEXT_COLOR -- 描边黑色
	label.TextStrokeTransparency = 0 -- 描边不透明
	label.TextScaled = true
	label.TextSize = 14 -- 字体稍小
	label.Font = Enum.Font.SourceSansBold
	label.Parent = billboard
	
	highlights[part] = {highlight = highlight, billboard = billboard}
end

local function removeHighlight(part)
	local data = highlights[part]
	if data then
		if data.highlight then data.highlight:Destroy() end
		if data.billboard then data.billboard:Destroy() end
		highlights[part] = nil
	end
end

RunService.RenderStepped:Connect(function()
	local character = LocalPlayer.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end
	local hrp = character.HumanoidRootPart
	local nearbyParts = {}
	
	for _, cd in pairs(workspace:GetDescendants()) do
		if cd:IsA("ClickDetector") and cd.Parent:IsA("BasePart") then
			local dist = (hrp.Position - cd.Parent.Position).Magnitude
			if dist <= MAX_DISTANCE then
				nearbyParts[cd.Parent] = true
				createHighlight(cd.Parent)
			end
		end
	end
	
	for part, _ in pairs(highlights) do
		if not nearbyParts[part] then
			removeHighlight(part)
		end
	end
end)