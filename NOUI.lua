--[[
    Elysium — HEADLESS TEST BUILD (fixed)
    No WindUI. All features hardcoded ON. Debug prints live.

    Fixes applied:
      REACH   — xzDist → 3D Magnitude
      AUTOAIM — RenderStepped → Heartbeat, HRP.CFrame → mousemoverel
      AUTOJUMP— StateChanged → AssemblyLinearVelocity.Y spike detection
--]]

-- ================================================================
-- CONFIG — ALL FORCED ON FOR TESTING
-- ================================================================
local state = {
    -- Reach
    reachOn         = true,
    reachDist       = 15,
    damageAmp       = 0,
    invisCheck      = false,
    ftiAllParts     = false,
    ftiLungeOnly    = false,
    ignoreForceField= false,
    tabCheck        = false,
    lastSwingAt     = 0,
    SWING_DEBOUNCE  = 0.05,

    -- AutoAim
    autoAimOn           = true,
    autoAimDelayMs      = 0,
    autoAimDistance     = 20,
    autoAimJitter       = false,
    autoAimJitterAmt    = 5,
    autoAimSensitivity  = 0.35,   -- tune: higher = snappier rotation

    -- AutoJump
    autoJumpOn          = true,
    autoJumpTeamCheck   = false,
    autoJumpDelayMs     = 0,
    autoJumpDistance    = 50,
    JUMP_VEL_THRESHOLD  = 10,     -- studs/s upward to count as a jump
    jumpCooldown        = 0.15,

    debug = true,
}
getgenv().elysium = state

-- ================================================================
-- SERVICES
-- ================================================================
local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local lp       = Players.LocalPlayer
local HAS_FTI  = (type(firetouchinterest) == "function")
local HAS_MMR  = (type(mousemoverel) == "function")

local function log(tag, msg)
    if state.debug then
        print(("[%s] %s"):format(tag, tostring(msg)))
    end
end

log("BOOT", "headless build loaded (fixed)")
log("BOOT", "FTI available: "  .. tostring(HAS_FTI))
log("BOOT", "MMR available: "  .. tostring(HAS_MMR))
log("BOOT", "LocalPlayer: "    .. lp.Name)

-- ================================================================
-- SHARED HELPERS
-- ================================================================
local function getMyChar()     return lp.Character end
local function getMyHRP()
    local c = getMyChar()
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end
local function getMyHumanoid()
    local c = getMyChar()
    return c and c:FindFirstChildOfClass("Humanoid") or nil
end
local function hrpOf(char)
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end
local function humOf(char)
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

-- FIX 1: full 3D distance (was XZ-only)
local function dist3d(a, b)
    return (a - b).Magnitude
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
-- REACH MODULE
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

    -- fallback: FakeHandle → Handle itself
    local fake = handle:FindFirstChild("FakeHandle")
    if fake and fake:IsA("BasePart") then return fake end
    return handle
end

local function fireTouchOnChar(hitbox, enemyChar)
    local hrp = hrpOf(enemyChar)
           or enemyChar:FindFirstChild("UpperTorso")
           or enemyChar:FindFirstChild("Torso")
    if not hrp then return false end
    local ok = pcall(function()
        firetouchinterest(hitbox, hrp, 0)
        firetouchinterest(hitbox, hrp, 1)
    end)
    return ok
end

local function executeReach()
    if not state.reachOn then return end
    if not HAS_FTI then log("REACH", "FTI not available"); return end

    local now = os.clock()
    if now - state.lastSwingAt < state.SWING_DEBOUNCE then return end
    state.lastSwingAt = now

    local hitbox = getSwordHitbox()
    if not hitbox then
        log("REACH", "no swordHitbox — tool not equipped?")
        return
    end

    local myHRP = getMyHRP()
    if not myHRP then log("REACH", "no myHRP"); return end

    local hits = 0
    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local echar = player.Character
            local eHRP  = hrpOf(echar)
            if eHRP then
                -- FIX 1: use 3D distance
                local d = dist3d(myHRP.Position, eHRP.Position)
                if d <= state.reachDist then
                    if fireTouchOnChar(hitbox, echar) then
                        hits = hits + 1
                        log("REACH", ("FTI -> %s  d=%.1f"):format(player.Name, d))
                    end
                end
            end
        end
    end
    log("REACH", "swing fired — " .. hits .. " target(s) hit")
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
    log("REACH", "character respawned — re-hooking")
    task.defer(function() watchCharacter(c) end)
end)
if lp.Character then watchCharacter(lp.Character) end

-- ================================================================
-- AUTO AIM MODULE
-- FIX 2a: Heartbeat instead of RenderStepped (controller ran first)
-- FIX 2b: mousemoverel instead of setting HRP.CFrame (camera follows)
-- ================================================================
local aimTargetChar = nil
local aimSeenAt     = 0
local aimLastLog    = 0

local function pickAimTarget()
    local myHRP = getMyHRP()
    if not myHRP then return nil, math.huge end
    local best, bestD = nil, math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local eHRP = hrpOf(player.Character)
            if eHRP then
                local d = dist3d(myHRP.Position, eHRP.Position)
                if d <= state.autoAimDistance and d < bestD then
                    bestD, best = d, player.Character
                end
            end
        end
    end
    return best, bestD
end

-- FIX 2a: moved to Heartbeat
RunService.Heartbeat:Connect(function(dt)
    if not state.autoAimOn then return end
    if not HAS_MMR then return end

    local ok, err = pcall(function()
        local hum = getMyHumanoid()
        if not hum or hum.Health <= 0 then return end

        local target, tdist = pickAimTarget()

        -- new target acquired — log and apply delay
        if target ~= aimTargetChar then
            aimTargetChar = target
            aimSeenAt = os.clock()
            if target then
                log("AIM", ("acquired %s  d=%.1f"):format(target.Name, tdist))
            end
        end
        if not target then return end

        -- delay gate
        if (os.clock() - aimSeenAt) * 1000 < state.autoAimDelayMs then return end

        local cam  = workspace.CurrentCamera
        local eHRP = hrpOf(target)
        if not eHRP then return end

        -- FIX 2b: project target onto screen, compute delta, apply via mousemoverel
        local screenPos, onScreen = cam:WorldToScreenPoint(eHRP.Position)
        if not onScreen then return end

        local center = cam.ViewportSize / 2
        local dx = (screenPos.X - center.X) * state.autoAimSensitivity * dt
        local dy = (screenPos.Y - center.Y) * state.autoAimSensitivity * dt

        -- optional jitter
        if state.autoAimJitter then
            local jAmt = state.autoAimJitterAmt
            dx = dx + (math.random() * 2 - 1) * jAmt * dt
            dy = dy + (math.random() * 2 - 1) * jAmt * dt
        end

        mousemoverel(dx, dy)

        -- periodic log (once per second max)
        local now = os.clock()
        if now - aimLastLog > 1.0 then
            aimLastLog = now
            log("AIM", ("moving toward %s  d=%.1f  dx=%.2f dy=%.2f"):format(
                target.Name, tdist, dx, dy))
        end
    end)

    if not ok then log("AIM", "err: " .. tostring(err)) end
end)

log("AIM", "Heartbeat connected" .. (HAS_MMR and "" or " [WARNING: mousemoverel not found]"))

-- ================================================================
-- AUTO JUMP MODULE
-- FIX 3: AssemblyLinearVelocity.Y spike detection (StateChanged
--         does not fire reliably on remote player humanoids)
-- ================================================================
local jmp_prevY     = {}   -- [playerName] = previous frame Y velocity
local jmp_lastFired = 0
local jmp_lastLog   = 0

local function doJump(reason)
    if not state.autoJumpOn then return end

    local now = os.clock()
    if now - jmp_lastFired < state.jumpCooldown then
        log("JUMP", ("cooldown active (%.3fs since last)"):format(now - jmp_lastFired))
        return
    end
    jmp_lastFired = now

    local hum = getMyHumanoid()
    if not hum then log("JUMP", "no local humanoid"); return end

    local s = hum:GetState()
    if s == Enum.HumanoidStateType.Running
    or s == Enum.HumanoidStateType.Landed
    or s == Enum.HumanoidStateType.RunningNoPhysics then
        hum.Jump = true
        log("JUMP", ("fired  reason=%s  state=%s"):format(reason, tostring(s)))
    else
        log("JUMP", ("rejected  reason=%s  my state=%s"):format(reason, tostring(s)))
    end
end

RunService.Heartbeat:Connect(function()
    if not state.autoJumpOn then return end

    local myHRP = getMyHRP()
    if not myHRP then return end

    -- find closest enemy within distance
    local closest, closestHRP = nil, nil
    local bestD = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        if isValidTarget(player) then
            local eHRP = hrpOf(player.Character)
            if eHRP then
                local d = dist3d(myHRP.Position, eHRP.Position)
                if d <= state.autoJumpDistance and d < bestD then
                    bestD       = d
                    closest     = player
                    closestHRP  = eHRP
                end
            end
        end
    end

    -- clear stale prev-Y entries when we have no target
    if not closest then
        jmp_prevY = {}
        return
    end

    -- FIX 3: Y-velocity spike — enemy went from below threshold to above
    local curY  = closestHRP.AssemblyLinearVelocity.Y
    local prevY = jmp_prevY[closest.Name] or 0
    jmp_prevY[closest.Name] = curY

    if curY > state.JUMP_VEL_THRESHOLD and prevY <= state.JUMP_VEL_THRESHOLD then
        log("JUMP", ("Y-spike  %s  %.1f→%.1f  d=%.1f"):format(
            closest.Name, prevY, curY, bestD))

        if state.autoJumpDelayMs > 0 then
            task.delay(state.autoJumpDelayMs / 1000, function()
                doJump("Y-spike-delayed")
            end)
        else
            doJump("Y-spike")
        end
    end

    -- periodic status log
    local now = os.clock()
    if now - jmp_lastLog > 1.0 then
        jmp_lastLog = now
        log("JUMP", ("tracking %s  d=%.1f  curY=%.1f"):format(
            closest.Name, bestD, curY))
    end
end)

log("JUMP", "Heartbeat connected (Y-spike detection active)")

-- ================================================================
log("BOOT", "all modules active — watching for [REACH] [AIM] [JUMP]")
