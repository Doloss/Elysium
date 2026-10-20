--[[
    Elysium — HEADLESS TEST BUILD
    No WindUI. All features hardcoded ON. Debug prints live from load.
    Purpose: isolate whether the core logic works, independent of UI.
    Delete this file when done.
--]]

-- ================================================================
-- CONFIG — ALL FORCED ON FOR TESTING
-- ================================================================
local state = {
    -- Reach
    reachOn = true, reachDist = 15, damageAmp = 0,
    invisCheck = false, ftiAllParts = false, ftiLungeOnly = false,
    ignoreForceField = false, tabCheck = false,
    lastSwingAt = 0, SWING_DEBOUNCE = 0.05,

    -- AutoAim
    autoAimOn = true, autoAimDelayMs = 0, autoAimDistance = 20,
    autoAimJitter = false, autoAimJitterAmt = 5,
    autoAimMaxDegPerSec = 240, autoAimFOV = 180,  -- 180° cone for testing = basically everywhere

    -- AutoJump
    autoJumpOn = true, autoJumpTeamCheck = false,
    autoJumpDelayMs = 0, autoJumpDistance = 50,
    jumpDetectCooldown = 0.15,

    debug = true,
}
getgenv().elysium = state

-- ================================================================
-- SERVICES
-- ================================================================
local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
local HAS_FTI = (type(firetouchinterest) == "function")

local function log(tag, msg)
    print(("[%s] %s"):format(tag, tostring(msg)))
end

log("BOOT", "headless build loaded")
log("BOOT", "FTI available: " .. tostring(HAS_FTI))
log("BOOT", "LocalPlayer: " .. lp.Name)

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
local function xzDist(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx*dx + dz*dz)
end

local function isValidTarget(player)
    if player == lp then return false end
    local char = player.Character
    if not char then return false end
    local hum = humOf(char)
    if not hum or hum.Health <= 0 then return false end
    return true
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
    return handle
end

local function fireTouchOnChar(hitbox, enemyChar)
    local hrp = hrpOf(enemyChar)
           or enemyChar:FindFirstChild("UpperTorso")
           or enemyChar:FindFirstChild("Torso")
    if hrp then
        pcall(function()
            firetouchinterest(hitbox, hrp, 0)
            firetouchinterest(hitbox, hrp, 1)
        end)
        return true
    end
    return false
end

local function executeReach()
    if not state.reachOn then return end
    if not HAS_FTI then return end

    local now = os.clock()
    if now - state.lastSwingAt < state.SWING_DEBOUNCE then return end
    state.lastSwingAt = now

    local hitbox = getSwordHitbox()
    if not hitbox then log("REACH", "no swordHitbox — tool not equipped?"); return end

    local myHRP = getMyHRP()
    if not myHRP then log("REACH", "no myHRP"); return end

    local hits = 0
    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local echar = player.Character
            local ehRP  = hrpOf(echar)
            if ehRP then
                local d = xzDist(myHRP.Position, ehRP.Position)
                if d <= state.reachDist then
                    if fireTouchOnChar(hitbox, echar) then
                        hits = hits + 1
                        log("REACH", ("FTI on %s d=%.1f"):format(player.Name, d))
                    end
                end
            end
        end
    end
    log("REACH", "swing -> " .. hits .. " targets hit")
end

local function hookTool(tool)
    if reachToolConn then reachToolConn:Disconnect(); reachToolConn = nil end
    if not tool then return end
    log("REACH", "hooking tool: " .. tool.Name)
    task.defer(function()
        if tool.Parent then
            reachToolConn = tool.Activated:Connect(function()
                log("REACH", "Activated fired")
                pcall(executeReach)
            end)
        end
    end)
end

local function watchCharacter(char)
    char.ChildAdded:Connect(function(c)
        if c:IsA("Tool") then hookTool(c) end
    end)
    local existing = char:FindFirstChildOfClass("Tool")
    if existing then hookTool(existing) end
end

lp.CharacterAdded:Connect(function(c)
    log("REACH", "character respawned")
    task.defer(function() watchCharacter(c) end)
end)
if lp.Character then watchCharacter(lp.Character) end

-- ================================================================
-- AUTO AIM
-- ================================================================
local aimRenderConn = nil
local aimTargetChar = nil
local aimSeenAt     = 0
local aimLastLog    = 0

local function pickAimTarget()
    local myHRP = getMyHRP()
    if not myHRP then return nil end
    local best, bestD = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local echar = player.Character
            local ehRP  = hrpOf(echar)
            if ehRP then
                local d = xzDist(myHRP.Position, ehRP.Position)
                if d <= state.autoAimDistance and d < bestD then
                    bestD, best = d, echar
                end
            end
        end
    end
    return best, bestD
end

local function stepAutoAim(dt)
    if not state.autoAimOn then return end

    local hum = getMyHumanoid()
    if not hum or hum.Health <= 0 then return end

    local target, tdist = pickAimTarget()
    if target ~= aimTargetChar then
        aimTargetChar = target
        aimSeenAt = os.clock()
        if target then
            log("AIM", ("acquired %s d=%.1f"):format(target.Name, tdist or -1))
        end
        return
    end
    if not target then return end

    local myHRP = getMyHRP()
    local ehRP  = hrpOf(target)
    if not myHRP or not ehRP then return end

    if (os.clock() - aimSeenAt) * 1000 < state.autoAimDelayMs then return end

    local dir = ehRP.Position - myHRP.Position
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

    -- log at most once per second
    local now = os.clock()
    if now - aimLastLog > 1.0 then
        aimLastLog = now
        log("AIM", ("rotating toward %s d=%.1f yawDelta=%.1f°"):format(
            target.Name, tdist or -1, math.deg(delta)))
    end
end

aimRenderConn = RunService.RenderStepped:Connect(function(dt)
    pcall(stepAutoAim, dt)
end)
log("AIM", "RenderStepped connected")

-- ================================================================
-- AUTO JUMP
-- ================================================================
local jmp_heartbeat  = nil
local jmp_stateConn  = nil
local jmp_currentHum = nil
local jmp_tick       = 0
local jmp_lastFired  = 0
local jmp_lastLog    = 0

local function closestEnemyHumanoid()
    local myHRP = getMyHRP()
    if not myHRP then return nil end
    local best, bestD = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local char = player.Character
            local hum  = humOf(char)
            local ehRP = hrpOf(char)
            if hum and ehRP then
                local d = xzDist(myHRP.Position, ehRP.Position)
                if d <= state.autoJumpDistance and d < bestD then
                    bestD, best = d, hum
                end
            end
        end
    end
    return best, bestD
end

local function doJump(reason)
    if not state.autoJumpOn then return end
    local now = os.clock()
    if now - jmp_lastFired < state.jumpDetectCooldown then
        log("JUMP", ("cooldown (%.3fs since last)"):format(now - jmp_lastFired))
        return
    end
    jmp_lastFired = now
    log("JUMP", "firing reason=" .. reason)

    local hum = getMyHumanoid()
    if not hum then log("JUMP", "no my humanoid"); return end
    local s = hum:GetState()
    if s == Enum.HumanoidStateType.Running
    or s == Enum.HumanoidStateType.Landed
    or s == Enum.HumanoidStateType.RunningNoPhysics then
        hum.Jump = true
        log("JUMP", "set Jump=true (state was " .. tostring(s) .. ")")
    else
        log("JUMP", "rejected — my state=" .. tostring(s))
    end
end

local function hookJumpTarget(hum)
    if jmp_stateConn then jmp_stateConn:Disconnect(); jmp_stateConn = nil end
    jmp_currentHum = hum
    if not hum then log("JUMP", "hookJumpTarget: nil"); return end
    log("JUMP", "hooked " .. (hum.Parent and hum.Parent.Name or "?"))
    jmp_stateConn = hum.StateChanged:Connect(function(_, newState)
        if hum ~= jmp_currentHum then return end
        if newState == Enum.HumanoidStateType.Jumping then
            log("JUMP", "target " .. hum.Parent.Name .. " Jumping")
            doJump("StateChanged")
        end
    end)
end

jmp_heartbeat = RunService.Heartbeat:Connect(function(dt)
    if not state.autoJumpOn then return end
    jmp_tick = jmp_tick + dt
    if jmp_tick < 0.1 then return end
    jmp_tick = 0

    local closest, dist = closestEnemyHumanoid()
    if closest ~= jmp_currentHum then
        hookJumpTarget(closest)
    end
    if jmp_currentHum and (jmp_currentHum.Health <= 0 or not jmp_currentHum.Parent) then
        hookJumpTarget(nil)
    end

    local now = os.clock()
    if now - jmp_lastLog > 1.0 then
        jmp_lastLog = now
        log("JUMP", ("scan -> %s%s"):format(
            closest and "target" or "none",
            closest and (" d=" .. string.format("%.1f", dist or -1)) or ""))
    end
end)
log("JUMP", "Heartbeat connected")

log("BOOT", "all modules active — watch for [REACH], [AIM], [JUMP] prints")