--[[
    Elysium — CustomDuels
    WindUI integrated script
    Built By Carlos

    Features:
        Reach   — firetouchinterest on swordHitbox-* Part
        AutoAim — (scaffolded, implementation next session)
        AutoJump— (scaffolded, implementation next session)
--]]

-- ================================================================
-- WINDUI LOADER
-- ================================================================
local WindUI

do
    local ok, result = pcall(function()
        return loadstring(
            game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua")
        )()
    end)

    if ok and result then
        WindUI = result
    else
        -- surface the error clearly before dying
        local msg = tostring(result)
        warn("[Elysium] WindUI failed to load: " .. msg)
        error("[Elysium] WindUI load failed — check console. " .. msg, 2)
    end
end

-- ================================================================
-- SHARED VARIABLE DEFAULTS
-- ================================================================
-- Reach
shared.reachon          = false
shared.reachdist        = 10
shared.DamageAmplifier  = 0
shared.InvisCheck       = false
shared.FTIAllParts      = false
shared.FTILungeOnly     = false
shared.IgnoreForceField = false
shared.TabCheck         = false

-- AutoAim
shared.AutoAim            = false
shared.AutoAimDelay       = 0
shared.AutoAimDistance    = 6
shared.AutoAimJitter      = false
shared.AutoAimJitterAmount= 5

-- AutoJump
shared.AutoJump          = false
shared.AutoJumpTeamCheck = false
shared.AutoJumpDelay     = 0
shared.AutoJumpDistance  = 10

-- ================================================================
-- REACH MODULE (inlined)
-- ================================================================
local _Players    = game:GetService("Players")
local _UIS        = game:GetService("UserInputService")
local _lp         = _Players.LocalPlayer
local _fti        = firetouchinterest

local _toolConn   = nil
local _charConn   = nil

local function _getHitbox()
    local char = _lp.Character
    if not char then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return nil end
    local handle = tool:FindFirstChild("Handle")
    if not handle then return nil end

    for _, child in ipairs(handle:GetChildren()) do
        if child:IsA("BasePart") and child.Name:sub(1, 11) == "swordHitbox" then
            return child
        end
    end

    local fake = handle:FindFirstChild("FakeHandle")
    if fake and fake:IsA("BasePart") then return fake end
    return handle
end

local function _isWindowFocused()
    if not shared.TabCheck then return true end
    return _UIS:IsWindowFocused()
end

local function _isLunging()
    local char = _lp.Character
    if not char then return false end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    return hrp.AssemblyLinearVelocity.Magnitude >= 28
end

local function _isValidTarget(player)
    if player == _lp then return false end
    local char = player.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if shared.InvisCheck then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and hrp.Transparency >= 0.9 then return false end
    end
    if shared.IgnoreForceField then
        if char:FindFirstChildOfClass("ForceField") then return false end
    end
    return true
end

local function _getDistance(enemyChar)
    local myChar = _lp.Character
    if not myChar then return math.huge end
    local a = myChar:FindFirstChild("HumanoidRootPart")
    local b = enemyChar:FindFirstChild("HumanoidRootPart")
    if not a or not b then return math.huge end
    return (a.Position - b.Position).Magnitude
end

local function _fireTouchOnChar(hitbox, enemyChar)
    if shared.FTIAllParts then
        for _, part in ipairs(enemyChar:GetDescendants()) do
            if part:IsA("BasePart") then
                _fti(hitbox, part, 0)
                _fti(hitbox, part, 1)
            end
        end
    else
        local hrp = enemyChar:FindFirstChild("HumanoidRootPart")
               or  enemyChar:FindFirstChild("UpperTorso")
               or  enemyChar:FindFirstChild("Torso")
        if hrp then
            _fti(hitbox, hrp, 0)
            _fti(hitbox, hrp, 1)
        end
    end
end

local function _executeReach()
    if not shared.reachon     then return end
    if not _isWindowFocused() then return end
    if shared.FTILungeOnly and not _isLunging() then return end

    local hitbox = _getHitbox()
    if not hitbox then return end

    local dist = tonumber(shared.reachdist) or 10
    local amp  = math.clamp(tonumber(shared.DamageAmplifier) or 0, 0, 17)

    for _, player in ipairs(_Players:GetPlayers()) do
        if _isValidTarget(player) and player.Character then
            if _getDistance(player.Character) <= dist then
                _fireTouchOnChar(hitbox, player.Character)
                if amp > 0 then
                    local char_ref = player.Character
                    for i = 1, amp do
                        task.delay(i * 0.055, function()
                            if not shared.reachon then return end
                            if char_ref and char_ref.Parent then
                                _fireTouchOnChar(hitbox, char_ref)
                            end
                        end)
                    end
                end
            end
        end
    end
end

local function _hookTool(tool)
    if _toolConn then _toolConn:Disconnect(); _toolConn = nil end
    if not tool then return end
    task.defer(function()
        _toolConn = tool.Activated:Connect(_executeReach)
    end)
end

local function _watchCharacter(char)
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then _hookTool(child) end
    end)
    char.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") then
            if _toolConn then _toolConn:Disconnect(); _toolConn = nil end
        end
    end)
    local existing = char:FindFirstChildOfClass("Tool")
    if existing then _hookTool(existing) end
end

-- start reach watcher
_charConn = _lp.CharacterAdded:Connect(function(char)
    task.defer(function() _watchCharacter(char) end)
end)
if _lp.Character then _watchCharacter(_lp.Character) end

-- ================================================================
-- AUTOJUMP MODULE (inlined)
-- ================================================================
local _RunService        = game:GetService("RunService")

local _jmp_heartbeat     = nil   -- polling loop
local _jmp_stateConn     = nil   -- StateChanged on current target humanoid
local _jmp_currentTarget = nil   -- currently tracked Humanoid instance

-- returns the closest enemy Humanoid within AutoJumpDistance, or nil
local function _getClosestEnemyHumanoid()
    local myChar = _lp.Character
    if not myChar then return nil end
    local myHRP = myChar:FindFirstChild("HumanoidRootPart")
    if not myHRP then return nil end

    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    -- don't try to jump if already in air
    if myHum and myHum:GetState() ~= Enum.HumanoidStateType.Running
              and myHum:GetState() ~= Enum.HumanoidStateType.Landed
              and myHum:GetState() ~= Enum.HumanoidStateType.RunningNoPhysics then
        -- still allow tracking while standing, but gate the actual jump later
    end

    local dist_limit = tonumber(shared.AutoJumpDistance) or 10
    local best_dist  = math.huge
    local best_hum   = nil

    for _, player in ipairs(_Players:GetPlayers()) do
        if player == _lp then continue end
        local char = player.Character
        if not char then continue end

        local hum = char:FindFirstChildOfClass("Humanoid")
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp then continue end
        if hum.Health <= 0 then continue end

        -- TeamCheck stub: proximity only for now
        -- (shared.AutoJumpTeamCheck filtering goes here once match data is available)

        local d = (myHRP.Position - hrp.Position).Magnitude
        if d <= dist_limit and d < best_dist then
            best_dist = d
            best_hum  = hum
        end
    end

    return best_hum
end

-- fires the local player's jump after the configured delay
local function _doJump()
    local delay_ms = tonumber(shared.AutoJumpDelay) or 0
    local function jump()
        local char = _lp.Character
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        -- only jump if on ground — avoids double-jump spam
        local state = hum:GetState()
        if state == Enum.HumanoidStateType.Running
        or state == Enum.HumanoidStateType.Landed
        or state == Enum.HumanoidStateType.RunningNoPhysics then
            hum.Jump = true
        end
    end

    if delay_ms > 0 then
        task.delay(delay_ms / 1000, jump)
    else
        jump()
    end
end

-- hook StateChanged on a specific humanoid
local function _hookJumpTarget(humanoid)
    if _jmp_stateConn then
        _jmp_stateConn:Disconnect()
        _jmp_stateConn = nil
    end
    if not humanoid then return end

    _jmp_currentTarget = humanoid

    _jmp_stateConn = humanoid.StateChanged:Connect(function(_, newState)
        if not shared.AutoJump then return end
        if newState == Enum.HumanoidStateType.Jumping then
            _doJump()
        end
    end)
end

-- heartbeat: re-evaluate closest enemy ~10 times/sec
local _jmp_tick = 0
local function _startAutoJump()
    if _jmp_heartbeat then return end  -- already running

    _jmp_heartbeat = _RunService.Heartbeat:Connect(function(dt)
        if not shared.AutoJump then return end

        _jmp_tick += dt
        if _jmp_tick < 0.1 then return end  -- check 10 Hz
        _jmp_tick = 0

        local closest = _getClosestEnemyHumanoid()

        -- re-hook only if the target changed or the old one is gone
        if closest ~= _jmp_currentTarget then
            _hookJumpTarget(closest)
        end

        -- if current target died or left, clear it
        if _jmp_currentTarget then
            if _jmp_currentTarget.Health <= 0
            or not _jmp_currentTarget.Parent then
                _hookJumpTarget(nil)
                _jmp_currentTarget = nil
            end
        end
    end)
end

local function _stopAutoJump()
    if _jmp_heartbeat  then _jmp_heartbeat:Disconnect();  _jmp_heartbeat  = nil end
    if _jmp_stateConn  then _jmp_stateConn:Disconnect();  _jmp_stateConn  = nil end
    _jmp_currentTarget = nil
    _jmp_tick          = 0
end

-- ================================================================
-- WINDOW
-- ================================================================
local Window = WindUI:CreateWindow({
    Title  = "Elysium  |  Custom Duels",
    Folder = "elysium",
    Icon   = "sword",
    NewElements = true,
    HideSearchBar = false,

    OpenButton = {
        Title         = "Elysium",
        CornerRadius  = UDim.new(1, 0),
        StrokeThickness = 2,
        Enabled       = true,
        Draggable     = true,
        OnlyMobile    = false,
        Scale         = 0.5,
        Color = ColorSequence.new(
            Color3.fromHex("#c0392b"),
            Color3.fromHex("#8e1a0e")
        ),
    },

    Topbar = {
        Height      = 44,
        ButtonsType = "Mac",
    },
})

-- version tag
Window:Tag({
    Title = "v1.0",
    Color = Color3.fromHex("#1c1c1c"),
    Border = true,
})

-- ================================================================
-- COLORS
-- ================================================================
local Red    = Color3.fromHex("#e74c3c")
local Orange = Color3.fromHex("#e67e22")
local Green  = Color3.fromHex("#2ecc71")
local Blue   = Color3.fromHex("#3498db")
local Grey   = Color3.fromHex("#7f8c8d")
local Purple = Color3.fromHex("#9b59b6")

-- ================================================================
-- SECTIONS
-- ================================================================
local CombatSection = Window:Section({ Title = "Combat" })
local MovementSection = Window:Section({ Title = "Movement" })

-- ================================================================
-- TAB: REACH
-- ================================================================
do
    local ReachTab = CombatSection:Tab({
        Title     = "Reach",
        Icon      = "sword",
        IconColor = Red,
        Border    = true,
    })

    -- master toggle
    ReachTab:Toggle({
        Title = "Sword Reach",
        Desc  = "Fires touch on swordHitbox against enemies within distance.",
        Value = false,
        Callback = function(v)
            shared.reachon = v
        end,
    })

    ReachTab:Space()

    -- reach distance
    ReachTab:Slider({
        Title = "Reach Distance",
        Desc  = "Stud distance — how far the hitbox fires.",
        Step  = 1,
        Value = { Min = 1, Max = 50, Default = 10 },
        Callback = function(v)
            shared.reachdist = v
        end,
    })

    ReachTab:Space()

    -- damage amplifier
    ReachTab:Slider({
        Title = "Damage Amplifier",
        Desc  = "Extra FTI fires per swing (0 = off, 17 = max).",
        Step  = 1,
        Value = { Min = 0, Max = 17, Default = 0 },
        Callback = function(v)
            shared.DamageAmplifier = v
        end,
    })

    ReachTab:Space()

    -- section: filters
    ReachTab:Section({
        Title = "Filters",
        Box      = true,
        BoxBorder= true,
        Opened   = true,
    })

    ReachTab:Toggle({
        Title = "Invisible Check",
        Desc  = "Skip players with HRP transparency ≥ 0.9.",
        Value = false,
        Callback = function(v)
            shared.InvisCheck = v
        end,
    })

    ReachTab:Space()

    ReachTab:Toggle({
        Title = "FTI All Parts",
        Desc  = "Fire touch on every body part (more reliable, louder footprint).",
        Value = false,
        Callback = function(v)
            shared.FTIAllParts = v
        end,
    })

    ReachTab:Space()

    ReachTab:Toggle({
        Title = "Reach on Lunge Only",
        Desc  = "Only fires when local HRP velocity spike detects a lunge.",
        Value = false,
        Callback = function(v)
            shared.FTILungeOnly = v
        end,
    })

    ReachTab:Space()

    ReachTab:Toggle({
        Title = "Ignore ForceFielded Players",
        Desc  = "Skip players with an active ForceField.",
        Value = false,
        Callback = function(v)
            shared.IgnoreForceField = v
        end,
    })

    ReachTab:Space()

    ReachTab:Toggle({
        Title = "Tab Check",
        Desc  = "Only fire reach when Roblox window is focused.",
        Value = false,
        Callback = function(v)
            shared.TabCheck = v
        end,
    })
end

-- ================================================================
-- TAB: AUTO AIM
-- ================================================================
do
    local AutoAimTab = CombatSection:Tab({
        Title     = "Auto Aim",
        Icon      = "crosshair",
        IconColor = Orange,
        Border    = true,
    })

    AutoAimTab:Toggle({
        Title = "Auto Aim",
        Desc  = "Locks camera onto nearest opponent. Disables on shift-lock or death.",
        Value = false,
        Callback = function(v)
            shared.AutoAim = v
        end,
    })

    AutoAimTab:Space()

    AutoAimTab:Slider({
        Title = "Auto Aim Delay",
        Desc  = "Delay (ms) before locking onto a target after detection.",
        Step  = 10,
        Value = { Min = 0, Max = 500, Default = 0 },
        Callback = function(v)
            shared.AutoAimDelay = v
        end,
    })

    AutoAimTab:Space()

    AutoAimTab:Slider({
        Title = "Auto Aim Distance",
        Desc  = "Max stud distance to lock on (1–13).",
        Step  = 1,
        Value = { Min = 1, Max = 13, Default = 6 },
        Callback = function(v)
            shared.AutoAimDistance = v
        end,
    })

    AutoAimTab:Space()

    -- jitter section
    AutoAimTab:Section({
        Title    = "Jitter",
        Box      = true,
        BoxBorder= true,
        Opened   = true,
    })

    AutoAimTab:Toggle({
        Title = "Auto Aim Jitter",
        Desc  = "Adds random aim offset to humanize the lock-on.",
        Value = false,
        Callback = function(v)
            shared.AutoAimJitter = v
        end,
    })

    AutoAimTab:Space()

    AutoAimTab:Slider({
        Title = "Jitter Amount",
        Desc  = "Max pixel offset applied per frame.",
        Step  = 1,
        Value = { Min = 0, Max = 20, Default = 5 },
        Callback = function(v)
            shared.AutoAimJitterAmount = v
        end,
    })

    -- coming soon notice
    AutoAimTab:Space()
    AutoAimTab:Section({
        Title       = "Implementation coming next session.",
        TextSize    = 14,
        TextTransparency = 0.45,
    })
end

-- ================================================================
-- TAB: AUTO JUMP
-- ================================================================
do
    local AutoJumpTab = MovementSection:Tab({
        Title     = "Auto Jump",
        Icon      = "arrow-up",
        IconColor = Blue,
        Border    = true,
    })

    AutoJumpTab:Toggle({
        Title = "Auto Jump",
        Desc  = "Jumps in sync with the closest opponent's jump.",
        Value = false,
        Callback = function(v)
            shared.AutoJump = v
            if v then
                _startAutoJump()
            else
                _stopAutoJump()
            end
        end,
    })

    AutoJumpTab:Space()

    AutoJumpTab:Toggle({
        Title = "Team Check",
        Desc  = "Only syncs with opponents, not teammates.",
        Value = false,
        Callback = function(v)
            shared.AutoJumpTeamCheck = v
        end,
    })

    AutoJumpTab:Space()

    AutoJumpTab:Slider({
        Title = "Auto Jump Delay",
        Desc  = "Delay (ms) after detecting opponent jump before jumping.",
        Step  = 10,
        Value = { Min = 0, Max = 500, Default = 0 },
        Callback = function(v)
            shared.AutoJumpDelay = v
        end,
    })

    AutoJumpTab:Space()

    AutoJumpTab:Slider({
        Title = "Auto Jump Distance",
        Desc  = "Max stud range to detect an opponent jump.",
        Step  = 1,
        Value = { Min = 1, Max = 50, Default = 10 },
        Callback = function(v)
            shared.AutoJumpDistance = v
        end,
    })

end

-- ================================================================
-- NOTIFY ON LOAD
-- ================================================================
WindUI:Notify({
    Title   = "Elysium loaded",
    Content = "Custom Duels  —  Reach + AutoJump ready.",
    Icon    = "check",
    Duration = 4,
})
