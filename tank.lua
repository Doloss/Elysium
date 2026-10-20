getgenv().S_Hold = {
    Enabled = false,
    Notifications = true,
    Keybind = "K"
}

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UIS = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer


local function Notify(text)
    if not S_Hold.Notifications then
        return
    end

    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "S Hold",
            Text = text,
            Duration = 2
        })
    end)
end


local function OnToolAdded(child)
    if not S_Hold.Enabled then
        return
    end

    if not child:IsA("Tool") then
        return
    end

    local handle = child:FindFirstChild("Handle")
    if not handle then
        return
    end

    for _, v in ipairs(handle:GetDescendants()) do
        if v:IsA("TouchTransmitter") then
            v:Destroy()
        end
    end
end


local function SetupCharacter(character)
    character.ChildAdded:Connect(OnToolAdded)
end

local function SetupPlayer(player)
    if player == LocalPlayer then
        return
    end

    if player.Character then
        SetupCharacter(player.Character)
    end

    player.CharacterAdded:Connect(SetupCharacter)
end

for _, player in ipairs(Players:GetPlayers()) do
    SetupPlayer(player)
end

Players.PlayerAdded:Connect(SetupPlayer)


UIS.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.UserInputType == Enum.UserInputType.Keyboard then
        if input.KeyCode.Name:lower() == S_Hold.Keybind:lower() then
            S_Hold.Enabled = not S_Hold.Enabled

            Notify("S Hold: " .. (S_Hold.Enabled and "Enabled" or "Disabled"))

            print("S_Hold =", S_Hold.Enabled)
        end
    end
end)