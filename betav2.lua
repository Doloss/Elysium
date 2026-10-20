--[[
    Elysium — CustomDuels
    WindUI integrated script
    Built by Owner / AlphA

    Features:
        Reach    — firetouchinterest on swordHitbox-* Part, gated by filters
        AutoAim  — capped angular velocity lock-on, forward-cone selection
        AutoJump — StateChanged -> Jumping sync on closest opponent (confirmed working)

    Protection:
        - No hookfunction / trampolines
        - All reach-loop work pcall-wrapped
        - Single global env table (getgenv().elysium)
        - FTI call-site isolated in one function

    Debug:
        getgenv().elysium.debug = true   -- enable [AJ]/[AA]/[R] logs
--]]

-- ================================================================
-- USER-PATCHABLE HOOKS
-- ================================================================
local ELYSIUM = {}
ELYSIUM.isTeammate = function(player)
    -- TODO: fill in CustomDuels team logic. Stub returns false for all.
    return false
end

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
        local msg = tostring(result)
        warn("[Elysium] WindUI failed to load: " .. msg)
        error("[Elysium] WindUI load failed — check console. " .. msg, 2)
    end
end

-- ================================================================
-- SERVICES / LOCALS
-- ================================================================
local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer

local HAS_FTI = (type(firetouchinterest) == "function")
if not HAS_FTI then
    warn("[Elysium] firetouchinterest not available on this executor — Reach disabled.")
end

local ENV = getgenv and getgenv() or _G
ENV.elysium = ENV.elysium or {}
local state = ENV.elysium

-- ================================================================
-- CONFIG DEFAULTS
-- ================================================================
state.reachOn             = false
state.reachDist           = 10
state.damageAmp           = 0
state.invisCheck          = false
state.ftiAllParts         = false
state.ftiLungeOnly        = false
state.ignoreForceField    = false
state.tabCheck            = false
state.lastSwingAt         = 0
state.SWING_DEBOUNCE      = 0.05

state.autoAimOn           = false
state.autoAimDelayMs      = 0
state.autoAimDistance     = 6
state.autoAimJitter       = false
state.autoAimJitterAmt    = 5
state.autoAimMaxDegPerSec = 240
state.autoAimFOV          = 120

state.autoJumpOn          = false
state.autoJumpTeamCheck   = false
state.autoJumpDelayMs     = 0
state.autoJumpDistance    = 15
state.jumpDetectCooldown  = 0.15

state.debug               = state.debug or false

local function dbg(tag, msg)
    if not state.debug then return end
    warn(("["..tag.."] ") .. tostring(msg))
end

-- ================================================================
-- FOCUS / TAB CHECK
-- ================================================================
local FOCUS_API_OK = false
do
    local ok, res = pcall(function() return typeof(UIS.IsWindowFocused) end)
    FOCUS_API_OK = ok and res == "function"
end

state.focused = true
if not FOCUS_API_OK then
    pcall(function() UIS.WindowFocused:Connect(function() state.focused = true end) end)
    pcall(function() UIS.WindowFocusReleased:Connect(function() state.focused = false end) end)
end

local function tabCheckPasses()
    if not state.tabCheck then return true end
    if FOCUS_API_OK then
        local ok, focused = pcall(function() return UIS:IsWindowFocused() end)
        if ok then return focused end
        return true
    end
    return state.focused
end

-- ================================================================
-- SHARED HELPERS
-- ================================================================
local function getMyChar()     return lp.Character end
local function getMyHRP()
    local c = getMyChar(); return c and c:FindFirstChild("HumanoidRootPart") or nil
end
local function getMyHumanoid()
    local c = getMyChar(); return c and c:FindFirstChildOfClass("Humanoid") or nil
end
local function hrpOf(char)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end
local function humOf(char)
    if not char then return nil end
    return char:FindFirstChildOfClass("Humanoid")
end
local function xzDist(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx*dx + dz*dz)
end

local function isValidTarget(player, opts)
    opts = opts or {}
    if player == lp then return false end
    local char = player.Character
    if not char then return false end
    local hum = humOf(char)
    if not hum or hum.Health <= 0 then return false end
    if state.invisCheck then
        local hrp = hrpOf(char)
        if hrp and hrp.Transparency >= 0.9 then return false end
    end
    if state.ignoreForceField then
        if char:FindFirstChildOfClass("ForceField") then return false end
    end
    if opts.teamCheck and state.autoJumpTeamCheck then
        if ELYSIUM.isTeammate(player) then return false end
    end
    return true
end

local function inForwardCone(myHRP, targetPos, fovDeg)
    local look = myHRP.CFrame.LookVector
    local to = targetPos - myHRP.Position
    local flatTo = Vector3.new(to.X, 0, to.Z)
    if flatTo.Magnitude < 0.01 then return true end
    if flatTo.Magnitude < 3 then return true end
    local flatLook = Vector3.new(look.X, 0, look.Z).Unit
    local cosA = flatLook:Dot(flatTo.Unit)
    local angle = math.deg(math.acos(math.clamp(cosA, -1, 1)))
    return angle <= (fovDeg * 0.5)
end

-- ================================================================
-- REACH
-- ================================================================
local reachToolConn = nil

local function getSwordHitbox()
    local char = getMyChar()
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

local function isLunging()
    local hrp = getMyHRP()
    if not hrp then return false end
    return hrp.AssemblyLinearVelocity.Magnitude >= 28
end

local function fireTouchOrdered(a, b)
    firetouchinterest(a, b, 0)
    firetouchinterest(a, b, 1)
end

local function fireTouchOnChar(hitbox, enemyChar)
    if state.ftiAllParts then
        for _, part in ipairs(enemyChar:GetDescendants()) do
            if part:IsA("BasePart") then
                pcall(fireTouchOrdered, hitbox, part)
            end
        end
    else
        local hrp = hrpOf(enemyChar)
               or enemyChar:FindFirstChild("UpperTorso")
               or enemyChar:FindFirstChild("Torso")
        if hrp then pcall(fireTouchOrdered, hitbox, hrp) end
    end
end

local function executeReach()
    if not state.reachOn then return end
    if not HAS_FTI then return end
    if not tabCheckPasses() then return end
    if state.ftiLungeOnly and not isLunging() then return end

    local now = os.clock()
    if now - state.lastSwingAt < state.SWING_DEBOUNCE then return end
    state.lastSwingAt = now

    local hitbox = getSwordHitbox()
    if not hitbox then return end

    local dist = tonumber(state.reachDist) or 10
    local amp  = math.clamp(tonumber(state.damageAmp) or 0, 0, 17)
    local myHRP = getMyHRP()
    if not myHRP then return end

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local echar = player.Character
            local ehRP  = hrpOf(echar)
            if echar and ehRP and xzDist(myHRP.Position, ehRP.Position) <= dist then
                fireTouchOnChar(hitbox, echar)
                if amp > 0 then
                    for i = 1, amp do
                        local delay = i * (math.random(40, 90) / 1000)
                        task.delay(delay, function()
                            if not state.reachOn then return end
                            if not tabCheckPasses() then return end
                            if echar and echar.Parent then
                                fireTouchOnChar(hitbox, echar)
                            end
                        end)
                    end
                end
            end
        end
    end
end

local function hookTool(tool)
    if reachToolConn then reachToolConn:Disconnect(); reachToolConn = nil end
    if not tool then return end
    task.defer(function()
        if tool.Parent then
            reachToolConn = tool.Activated:Connect(function()
                pcall(executeReach)
            end)
        end
    end)
end

local function watchCharacter(char)
    char.ChildAdded:Connect(function(c)
        if c:IsA("Tool") then hookTool(c) end
    end)
    char.ChildRemoved:Connect(function(c)
        if c:IsA("Tool") then
            if reachToolConn then reachToolConn:Disconnect(); reachToolConn = nil end
        end
    end)
    local existing = char:FindFirstChildOfClass("Tool")
    if existing then hookTool(existing) end
end

lp.CharacterAdded:Connect(function(c)
    task.defer(function() watchCharacter(c) end)
end)
if lp.Character then watchCharacter(lp.Character) end

-- ================================================================
-- AUTO AIM
-- ================================================================
local aimRenderConn = nil
local aimTargetChar = nil
local aimSeenAt     = 0

local function pickAimTarget()
    local myHRP = getMyHRP()
    if not myHRP then return nil end
    local limit = tonumber(state.autoAimDistance) or 6
    local best, bestD = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local echar = player.Character
            local ehRP  = hrpOf(echar)
            if ehRP then
                local d = xzDist(myHRP.Position, ehRP.Position)
                if d <= limit
                and inForwardCone(myHRP, ehRP.Position, state.autoAimFOV) then
                    if d < bestD then bestD, best = d, echar end
                end
            end
        end
    end
    return best
end

local function shiftLockActive()
    return UIS.MouseBehavior == Enum.MouseBehavior.LockCenter
end

local function stopAutoAim()
    if aimRenderConn then aimRenderConn:Disconnect(); aimRenderConn = nil end
    aimTargetChar = nil
end

local function stepAutoAim(dt)
    if not state.autoAimOn then stopAutoAim(); return end
    if not tabCheckPasses() then return end

    local hum = getMyHumanoid()
    if not hum or hum.Health <= 0 then stopAutoAim(); return end
    if shiftLockActive() then stopAutoAim(); return end

    local target = pickAimTarget()
    if target ~= aimTargetChar then
        aimTargetChar = target
        aimSeenAt = os.clock()
        return
    end
    if not target then return end

    local myHRP = getMyHRP()
    local ehRP  = hrpOf(target)
    if not myHRP or not ehRP then return end

    if (os.clock() - aimSeenAt) * 1000 < state.autoAimDelayMs then return end

    local to = ehRP.Position
    if state.autoAimJitter then
        local amt = (tonumber(state.autoAimJitterAmt) or 0) / 1000
        to = to + Vector3.new(
            (math.random() * 2 - 1) * amt,
            (math.random() * 2 - 1) * amt,
            (math.random() * 2 - 1) * amt
        )
    end

    local dir = to - myHRP.Position
    if dir.Magnitude < 0.01 then return end
    dir = dir.Unit

    local maxDeltaRad = math.rad(state.autoAimMaxDegPerSec) * dt

    local currentLook = myHRP.CFrame.LookVector
    local currentYaw  = math.atan2(currentLook.X, currentLook.Z)
    local desiredYaw  = math.atan2(dir.X, dir.Z)

    local delta = desiredYaw - currentYaw
    while delta >  math.pi do delta = delta - 2*math.pi end
    while delta < -math.pi do delta = delta + 2*math.pi end

    local newYaw = currentYaw + math.clamp(delta, -maxDeltaRad, maxDeltaRad)

    local newCF = CFrame.new(myHRP.Position) * CFrame.Angles(0, newYaw, 0)
    if myHRP.Parent then
        myHRP.CFrame = newCF
    end
end

local function startAutoAim()
    if aimRenderConn then return end
    aimRenderConn = RunService.RenderStepped:Connect(function(dt)
        pcall(stepAutoAim, dt)
    end)
end

-- ================================================================
-- AUTO JUMP
-- ================================================================
local jmp_heartbeat  = nil
local jmp_stateConn  = nil
local jmp_currentHum = nil
local jmp_tick       = 0
local jmp_lastFired  = 0

local function closestEnemyHumanoid()
    local myHRP = getMyHRP()
    if not myHRP then dbg("AJ", "no myHRP"); return nil end
    local limit = tonumber(state.autoJumpDistance) or 15
    local best, bestD = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player, {teamCheck=true}) then
            local char = player.Character
            local hum  = humOf(char)
            local ehRP = hrpOf(char)
            if hum and ehRP then
                local d = xzDist(myHRP.Position, ehRP.Position)
                if d <= limit and d < bestD then bestD, best = d, hum end
            end
        end
    end
    dbg("AJ", ("scan -> %s (teamCheck=%s)"):format(tostring(best ~= nil), tostring(state.autoJumpTeamCheck)))
    return best
end

local function doJumpWithDelay(firedByHum, reason)
    if not state.autoJumpOn then return end
    if firedByHum and firedByHum ~= jmp_currentHum then
        dbg("AJ", "doJump ignored — stale target")
        return
    end
    if not tabCheckPasses() then dbg("AJ", "doJump blocked — tabCheck"); return end

    local now = os.clock()
    if now - jmp_lastFired < state.jumpDetectCooldown then
        dbg("AJ", ("doJump cooldown %.3fs"):format(now - jmp_lastFired))
        return
    end
    jmp_lastFired = now
    dbg("AJ", "doJump FIRED reason=" .. tostring(reason))

    local delayMs = tonumber(state.autoJumpDelayMs) or 0
    local function jump()
        if not state.autoJumpOn then return end
        if not tabCheckPasses() then return end
        local hum = getMyHumanoid()
        if not hum then return end
        local s = hum:GetState()
        if s == Enum.HumanoidStateType.Running
        or s == Enum.HumanoidStateType.Landed
        or s == Enum.HumanoidStateType.RunningNoPhysics then
            hum.Jump = true
        else
            dbg("AJ", "jump rejected, my state=" .. tostring(s))
        end
    end

    if delayMs > 0 then
        task.delay(delayMs / 1000, jump)
    else
        jump()
    end
end

local function hookJumpTarget(hum)
    if jmp_stateConn then jmp_stateConn:Disconnect(); jmp_stateConn = nil end
    jmp_currentHum = hum
    if not hum then dbg("AJ", "hookJumpTarget: nil"); return end
    dbg("AJ", "hookJumpTarget: " .. (hum.Parent and hum.Parent.Name or "?"))
    if not hrpOf(hum.Parent) then return end

    jmp_stateConn = hum.StateChanged:Connect(function(_, newState)
        if not state.autoJumpOn then return end
        if hum ~= jmp_currentHum then return end
        if newState == Enum.HumanoidStateType.Jumping then
            doJumpWithDelay(hum, "StateChanged")
        end
    end)
end

local function startAutoJump()
    if jmp_heartbeat then return end
    dbg("AJ", "startAutoJump")
    jmp_heartbeat = RunService.Heartbeat:Connect(function(dt)
        if not state.autoJumpOn then return end
        jmp_tick = jmp_tick + dt
        if jmp_tick < 0.1 then return end
        jmp_tick = 0

        local closest = closestEnemyHumanoid()
        if closest ~= jmp_currentHum then
            hookJumpTarget(closest)
        end
        if jmp_currentHum and (jmp_currentHum.Health <= 0 or not jmp_currentHum.Parent) then
            hookJumpTarget(nil)
        end
    end)
end

local function stopAutoJump()
    if jmp_heartbeat then jmp_heartbeat:Disconnect(); jmp_heartbeat = nil end
    if jmp_stateConn then jmp_stateConn:Disconnect(); jmp_stateConn = nil end
    jmp_currentHum = nil
    jmp_tick       = 0
end

-- ================================================================
-- WINDOW
-- ================================================================
local Window = WindUI:CreateWindow({
    Title         = "Elysium  |  Custom Duels",
    Folder        = "elysium",
    Icon          = "sword",
    NewElements   = true,
    HideSearchBar = false,
    OpenButton = {
        Title = "Elysium",
        CornerRadius = UDim.new(1, 0),
        StrokeThickness = 2,
        Enabled = true,
        Draggable = true,
        OnlyMobile = false,
        Scale = 0.5,
        Color = ColorSequence.new(
            Color3.fromHex("#c0392b"),
            Color3.fromHex("#8e1a0e")
        ),
    },
    Topbar = { Height = 44, ButtonsType = "Mac" },
})

Window:Tag({ Title = "v1.1", Color = Color3.fromHex("#1c1c1c"), Border = true })

local Red    = Color3.fromHex("#e74c3c")
local Orange = Color3.fromHex("#e67e22")
local Green  = Color3.fromHex("#2ecc71")
local Blue   = Color3.fromHex("#3498db")

local CombatSection   = Window:Section({ Title = "Combat" })
local MovementSection = Window:Section({ Title = "Movement" })

-- ================================================================
-- TAB: REACH
-- ================================================================
do
    local ReachTab = CombatSection:Tab({
        Title = "Reach", Icon = "sword", IconColor = Red, Border = true,
    })

    ReachTab:Toggle({
        Title = "Sword Reach",
        Desc  = "FireTouchInterest on swordHitbox against enemies within distance.",
        Value = false,
        Callback = function(v)
            if v and not HAS_FTI then
                WindUI:Notify({
                    Title = "Reach unavailable",
                    Content = "firetouchinterest is not present on this executor.",
                    Icon = "alert-triangle", Duration = 5,
                })
                return
            end
            state.reachOn = v
        end,
    })

    ReachTab:Space()
    ReachTab:Slider({
        Title = "Reach Distance",
        Desc  = "Horizontal stud distance — how far the hitbox fires.",
        Step = 1, Value = { Min = 1, Max = 20, Default = 10 },
        Callback = function(v) state.reachDist = v end,
    })

    ReachTab:Space()
    ReachTab:Slider({
        Title = "Damage Amplifier",
        Desc  = "Jittered extra FTI fires per target per swing (0 = off, 17 = max).",
        Step = 1, Value = { Min = 0, Max = 17, Default = 0 },
        Callback = function(v) state.damageAmp = v end,
    })

    ReachTab:Space()
    ReachTab:Section({ Title = "Filters", Box = true, BoxBorder = true, Opened = true })

    ReachTab:Toggle({
        Title = "Invisible Check",
        Desc  = "Skip players with HRP transparency ≥ 0.9.",
        Value = false,
        Callback = function(v) state.invisCheck = v end,
    })
    ReachTab:Space()
    ReachTab:Toggle({
        Title = "FTI All Parts",
        Desc  = "Fire touch on every body part (louder footprint).",
        Value = false,
        Callback = function(v) state.ftiAllParts = v end,
    })
    ReachTab:Space()
    ReachTab:Toggle({
        Title = "Reach on Lunge Only",
        Desc  = "Only fire when local HRP velocity spike detects a lunge.",
        Value = false,
        Callback = function(v) state.ftiLungeOnly = v end,
    })
    ReachTab:Space()
    ReachTab:Toggle({
        Title = "Ignore ForceFielded Players",
        Desc  = "Skip players with an active ForceField.",
        Value = false,
        Callback = function(v) state.ignoreForceField = v end,
    })
    ReachTab:Space()
    ReachTab:Toggle({
        Title = "Tab Check",
        Desc  = "Only fire when the Roblox window is focused. Gates ALL features.",
        Value = false,
        Callback = function(v) state.tabCheck = v end,
    })
end

-- ================================================================
-- TAB: AUTO AIM
-- ================================================================
do
    local AutoAimTab = CombatSection:Tab({
        Title = "Auto Aim", Icon = "crosshair", IconColor = Orange, Border = true,
    })

    AutoAimTab:Toggle({
        Title = "Auto Aim",
        Desc  = "Locks HRP onto the closest target in a 120° forward cone.",
        Value = false,
        Callback = function(v)
            state.autoAimOn = v
            if v then startAutoAim() else stopAutoAim() end
        end,
    })
    AutoAimTab:Space()
    AutoAimTab:Slider({
        Title = "Auto Aim Delay",
        Desc  = "Delay (ms) after acquiring a target before the lock engages.",
        Step = 10, Value = { Min = 0, Max = 500, Default = 0 },
        Callback = function(v) state.autoAimDelayMs = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Slider({
        Title = "Auto Aim Distance",
        Desc  = "Max horizontal stud distance (1–13).",
        Step = 1, Value = { Min = 1, Max = 13, Default = 6 },
        Callback = function(v) state.autoAimDistance = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Section({ Title = "Jitter", Box = true, BoxBorder = true, Opened = true })
    AutoAimTab:Toggle({
        Title = "Auto Aim Jitter",
        Desc  = "Adds random aim offset to humanize lock-on.",
        Value = false,
        Callback = function(v) state.autoAimJitter = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Slider({
        Title = "Jitter Amount",
        Desc  = "Max offset magnitude (thousandths of a stud).",
        Step = 1, Value = { Min = 0, Max = 20, Default = 5 },
        Callback = function(v) state.autoAimJitterAmt = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Section({
        Title = "HRP yaw capped at 240°/s. Disables on shift-lock or death.",
        TextSize = 14, TextTransparency = 0.45,
    })
end

-- ================================================================
-- TAB: AUTO JUMP
-- ================================================================
do
    local AutoJumpTab = MovementSection:Tab({
        Title = "Auto Jump", Icon = "arrow-up", IconColor = Blue, Border = true,
    })

    AutoJumpTab:Toggle({
        Title = "Auto Jump",
        Desc  = "Jumps when the closest opponent jumps (StateChanged).",
        Value = false,
        Callback = function(v)
            state.autoJumpOn = v
            if v then startAutoJump() else stopAutoJump() end
        end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Toggle({
        Title = "Team Check",
        Desc  = "Skip teammates (see ELYSIUM.isTeammate hook — currently a stub).",
        Value = false,
        Callback = function(v) state.autoJumpTeamCheck = v end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Slider({
        Title = "Auto Jump Delay",
        Desc  = "Delay (ms) after opponent jump detected.",
        Step = 10, Value = { Min = 0, Max = 500, Default = 0 },
        Callback = function(v) state.autoJumpDelayMs = v end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Slider({
        Title = "Auto Jump Distance",
        Desc  = "Max horizontal stud range to detect opponent jumps.",
        Step = 1, Value = { Min = 1, Max = 50, Default = 15 },
        Callback = function(v) state.autoJumpDistance = v end,
    })
end

-- ================================================================
-- NOTIFY
-- ================================================================
WindUI:Notify({
    Title = "Elysium loaded",
    Content = "v1.1 — Reach + AutoAim + AutoJump. TabCheck gates all."
        .. (HAS_FTI and "" or " (Reach disabled — no FTI)"),
    Icon = "check", Duration = 4,
})