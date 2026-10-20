--[[
    Elysium — CustomDuels
    WindUI integrated script
    Built by Owner / AlphA

    Features:
        Reach    — firetouchinterest on swordHitbox-* Part, weighted 3D distance
        AutoAim  — Heartbeat camera yaw slerp, 120° forward cone
        AutoJump — Y-velocity spike on tracked target HRP

    v1.2:
        - Y-weighted distance (0.4) for Reach + AutoAim
        - AutoAim on Heartbeat, camera CFrame rotation
        - AutoJump rewritten: velocity spike detector, no StateChanged

    Debug:
        getgenv().elysium.debug = true
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
local workspaceRef = workspace

local lp = Players.LocalPlayer
local HAS_FTI = (type(firetouchinterest) == "function")
if not HAS_FTI then
    warn("[Elysium] firetouchinterest not available — Reach disabled.")
end

local ENV = getgenv and getgenv() or _G
ENV.elysium = ENV.elysium or {}
local state = ENV.elysium

-- ================================================================
-- CONFIG
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
state.distYWeight         = 0.4

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
state.jumpVelocityThreshold = 67
state.jumpDetectCooldown  = 0.15

state.debug               = state.debug or false

local function dbg(tag, msg)
    if not state.debug then return end
    warn(("["..tag.."] ") .. tostring(msg))
end

-- ================================================================
-- FOCUS / TAB
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
-- HELPERS
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

-- flat XZ distance — used for AutoJump target *selection*
local function xzDist(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx*dx + dz*dz)
end

-- weighted 3D distance — Y contributes at yWeight (0.4 default)
-- used for Reach + AutoAim distance filters
local function weightedDist(a, b, yWeight)
    yWeight = yWeight or state.distYWeight or 0.4
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    local flat = math.sqrt(dx*dx + dz*dz)
    local vert = math.abs(dy)
    local vy = vert * yWeight
    return math.sqrt(flat*flat + vy*vy)
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
            if part:IsA("BasePart") then pcall(fireTouchOrdered, hitbox, part) end
        end
    else
        local target = hrpOf(enemyChar)
                    or enemyChar:FindFirstChild("UpperTorso")
                    or enemyChar:FindFirstChild("Torso")
        if target then pcall(fireTouchOrdered, hitbox, target) end
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
            if echar and ehRP and weightedDist(myHRP.Position, ehRP.Position) <= dist then
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
-- AUTO AIM  (Heartbeat, camera CFrame yaw)
-- ================================================================
local aimBeatConn  = nil
local aimTargetChar = nil
local aimSeenAt    = 0

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
                local d = weightedDist(myHRP.Position, ehRP.Position)
                if d <= limit and inForwardCone(myHRP, ehRP.Position, state.autoAimFOV) then
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
    if aimBeatConn then aimBeatConn:Disconnect(); aimBeatConn = nil end
    aimTargetChar = nil
end

local function stepAutoAim(dt)
    if not state.autoAimOn then stopAutoAim(); return end
    if not tabCheckPasses() then return end

    local hum = getMyHumanoid()
    if not hum or hum.Health <= 0 then stopAutoAim(); return end
    if shiftLockActive() then stopAutoAim(); return end

    local cam = workspaceRef.CurrentCamera
    if not cam then return end

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

    local dir = to - cam.CFrame.Position
    local flatDir = Vector3.new(dir.X, 0, dir.Z)
    if flatDir.Magnitude < 0.01 then return end
    flatDir = flatDir.Unit

    local maxDeltaRad = math.rad(state.autoAimMaxDegPerSec) * dt

    local camLook = cam.CFrame.LookVector
    local currentYaw = math.atan2(camLook.X, camLook.Z)
    local desiredYaw = math.atan2(flatDir.X, flatDir.Z)

    local delta = desiredYaw - currentYaw
    while delta >  math.pi do delta = delta - 2*math.pi end
    while delta < -math.pi do delta = delta + 2*math.pi end

    local newYaw = currentYaw + math.clamp(delta, -maxDeltaRad, maxDeltaRad)

    -- preserve current pitch, only change yaw
    local pitch = math.asin(math.clamp(camLook.Y, -1, 1))
    local newLook = Vector3.new(
        math.sin(newYaw) * math.cos(pitch),
        math.sin(pitch),
        math.cos(newYaw) * math.cos(pitch)
    )
    cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + newLook)
end

local function startAutoAim()
    if aimBeatConn then return end
    aimBeatConn = RunService.Heartbeat:Connect(function(dt)
        pcall(stepAutoAim, dt)
    end)
end

-- ================================================================
-- AUTO JUMP  (velocity spike detector)
-- ================================================================
local jmp_beatConn     = nil
local jmp_scanConn     = nil
local jmp_currentHum   = nil
local jmp_currentHRP   = nil
local jmp_prevAirborne = false
local jmp_tick         = 0
local jmp_lastFired    = 0

local function closestEnemyHumanoid()
    local myHRP = getMyHRP()
    if not myHRP then return nil end
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
    return best
end

local function doJump(reason)
    if not state.autoJumpOn then return end
    if not tabCheckPasses() then return end

    local now = os.clock()
    if now - jmp_lastFired < state.jumpDetectCooldown then
        dbg("AJ", ("cooldown %.3fs"):format(now - jmp_lastFired))
        return
    end
    jmp_lastFired = now
    dbg("AJ", "fire reason=" .. reason)

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
            dbg("AJ", "rejected my state=" .. tostring(s))
        end
    end

    if delayMs > 0 then
        task.delay(delayMs / 1000, jump)
    else
        jump()
    end
end

local function hookJumpTarget(hum)
    jmp_currentHum = hum
    jmp_currentHRP = hum and hum.Parent and hrpOf(hum.Parent) or nil
    jmp_prevAirborne = false
    dbg("AJ", "hookJumpTarget " .. (hum and (hum.Parent and hum.Parent.Name or "?") or "nil"))
end

local function startAutoJump()
    if jmp_beatConn then return end

    -- 10 Hz target scan
    jmp_scanConn = RunService.Heartbeat:Connect(function(dt)
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

    -- per-frame velocity check on the tracked target
    jmp_beatConn = RunService.Heartbeat:Connect(function()
        if not state.autoJumpOn then return end
        if not jmp_currentHum or not jmp_currentHRP then return end
        if not jmp_currentHum.Parent or not jmp_currentHRP.Parent then return end

        local v = jmp_currentHRP.AssemblyLinearVelocity
        local airborne = (jmp_currentHum.FloorMaterial == Enum.Material.Air)

        if airborne
        and not jmp_prevAirborne
        and v.Y > (tonumber(state.jumpVelocityThreshold) or 67) then
            doJump(("velocity Y=%.1f"):format(v.Y))
        end
        jmp_prevAirborne = airborne
    end)
end

local function stopAutoJump()
    if jmp_beatConn then jmp_beatConn:Disconnect(); jmp_beatConn = nil end
    if jmp_scanConn then jmp_scanConn:Disconnect(); jmp_scanConn = nil end
    jmp_currentHum   = nil
    jmp_currentHRP   = nil
    jmp_prevAirborne = false
    jmp_tick         = 0
end

-- ================================================================
-- WINDOW
-- ================================================================
local Window = WindUI:CreateWindow({
    Title = "Elysium  |  Custom Duels",
    Folder = "elysium", Icon = "sword",
    NewElements = true, HideSearchBar = false,
    OpenButton = {
        Title = "Elysium", CornerRadius = UDim.new(1, 0),
        StrokeThickness = 2, Enabled = true, Draggable = true,
        OnlyMobile = false, Scale = 0.5,
        Color = ColorSequence.new(
            Color3.fromHex("#c0392b"),
            Color3.fromHex("#8e1a0e")
        ),
    },
    Topbar = { Height = 44, ButtonsType = "Mac" },
})

Window:Tag({ Title = "v1.2", Color = Color3.fromHex("#1c1c1c"), Border = true })

local Red    = Color3.fromHex("#e74c3c")
local Orange = Color3.fromHex("#e67e22")
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
        Desc = "FireTouchInterest on swordHitbox within weighted distance.",
        Value = false,
        Callback = function(v)
            if v and not HAS_FTI then
                WindUI:Notify({ Title = "Reach unavailable",
                    Content = "firetouchinterest not present on this executor.",
                    Icon = "alert-triangle", Duration = 5 })
                return
            end
            state.reachOn = v
        end,
    })
    ReachTab:Space()
    ReachTab:Slider({
        Title = "Reach Distance",
        Desc = "Weighted 3D distance (Y at 40%).",
        Step = 1, Value = { Min = 1, Max = 20, Default = 10 },
        Callback = function(v) state.reachDist = v end,
    })
    ReachTab:Space()
    ReachTab:Slider({
        Title = "Damage Amplifier",
        Desc = "Jittered extra FTI fires per target per swing.",
        Step = 1, Value = { Min = 0, Max = 17, Default = 0 },
        Callback = function(v) state.damageAmp = v end,
    })
    ReachTab:Space()
    ReachTab:Section({ Title = "Filters", Box = true, BoxBorder = true, Opened = true })
    ReachTab:Toggle({ Title = "Invisible Check",
        Desc = "Skip players with HRP transparency ≥ 0.9.",
        Value = false, Callback = function(v) state.invisCheck = v end })
    ReachTab:Space()
    ReachTab:Toggle({ Title = "FTI All Parts",
        Desc = "Fire touch on every body part.",
        Value = false, Callback = function(v) state.ftiAllParts = v end })
    ReachTab:Space()
    ReachTab:Toggle({ Title = "Reach on Lunge Only",
        Desc = "Only fire on velocity-spike lunges.",
        Value = false, Callback = function(v) state.ftiLungeOnly = v end })
    ReachTab:Space()
    ReachTab:Toggle({ Title = "Ignore ForceFielded Players",
        Desc = "Skip players with active ForceField.",
        Value = false, Callback = function(v) state.ignoreForceField = v end })
    ReachTab:Space()
    ReachTab:Toggle({ Title = "Tab Check",
        Desc = "Only fire when window is focused. Gates ALL features.",
        Value = false, Callback = function(v) state.tabCheck = v end })
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
        Desc = "Rotates camera toward closest target in forward cone.",
        Value = false,
        Callback = function(v)
            state.autoAimOn = v
            if v then startAutoAim() else stopAutoAim() end
        end,
    })
    AutoAimTab:Space()
    AutoAimTab:Slider({
        Title = "Auto Aim Delay",
        Desc = "Delay (ms) after acquisition before lock engages.",
        Step = 10, Value = { Min = 0, Max = 500, Default = 0 },
        Callback = function(v) state.autoAimDelayMs = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Slider({
        Title = "Auto Aim Distance",
        Desc = "Weighted 3D distance (Y at 40%).",
        Step = 1, Value = { Min = 1, Max = 13, Default = 6 },
        Callback = function(v) state.autoAimDistance = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Section({ Title = "Jitter", Box = true, BoxBorder = true, Opened = true })
    AutoAimTab:Toggle({ Title = "Auto Aim Jitter",
        Desc = "Adds random offset to humanize.",
        Value = false, Callback = function(v) state.autoAimJitter = v end })
    AutoAimTab:Space()
    AutoAimTab:Slider({
        Title = "Jitter Amount",
        Desc = "Max offset (thousandths of a stud).",
        Step = 1, Value = { Min = 0, Max = 20, Default = 5 },
        Callback = function(v) state.autoAimJitterAmt = v end,
    })
    AutoAimTab:Space()
    AutoAimTab:Section({
        Title = "Camera yaw capped at 240°/s. Disables on shift-lock or death.",
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
        Desc = "Jumps when the tracked opponent's Y-velocity spikes.",
        Value = false,
        Callback = function(v)
            state.autoJumpOn = v
            if v then startAutoJump() else stopAutoJump() end
        end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Toggle({
        Title = "Team Check",
        Desc = "Skip teammates (ELYSIUM.isTeammate — stub).",
        Value = false, Callback = function(v) state.autoJumpTeamCheck = v end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Slider({
        Title = "Auto Jump Delay",
        Desc = "Delay (ms) after velocity detection.",
        Step = 10, Value = { Min = 0, Max = 500, Default = 0 },
        Callback = function(v) state.autoJumpDelayMs = v end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Slider({
        Title = "Auto Jump Distance",
        Desc = "Max horizontal stud range to track target.",
        Step = 1, Value = { Min = 1, Max = 50, Default = 15 },
        Callback = function(v) state.autoJumpDistance = v end,
    })
    AutoJumpTab:Space()
    AutoJumpTab:Slider({
        Title = "Jump Velocity Threshold",
        Desc = "Y-velocity (studs/s) required to trigger. Stock JumpPower=50 → ~55-60.",
        Step = 1, Value = { Min = 20, Max = 115, Default = 67 },
        Callback = function(v) state.jumpVelocityThreshold = v end,
    })
end

-- ================================================================
-- NOTIFY
-- ================================================================
WindUI:Notify({
    Title = "Elysium loaded",
    Content = "v1.2 — weighted distance, Heartbeat AutoAim, velocity AutoJump."
        .. (HAS_FTI and "" or " (Reach disabled)"),
    Icon = "check", Duration = 4,
})