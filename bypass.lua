--[[

    STAGES:
      [1] __namecall hook  — swallows future FireServer AC reports
                           — feeds dummy signal to GetPropertyChangedSignal
      [2] getconnections   — kills EXISTING WalkSpeed/JumpPower/HipHeight
                             connections (the ones already wired at char load)
      [3] GC scan          — finds & no-ops every AC closure holding the
                             snitch remote as an upvalue
      [4] Reach watcher    — nukes LLeft Aarm trap parts + their Touched conns
      [5] Heartbeat loop   — keeps WalkSpeed locked to your target value
]]

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local lp         = Players.LocalPlayer

-- ── CONFIG ─────────────────────────────────────────────────────────
local TARGET_WALKSPEED = 50   -- change this to whatever you want
-- ───────────────────────────────────────────────────────────────────

local Remotes   = RepStorage:WaitForChild("Remotes", 10)
local snitchRem = Remotes and Remotes:FindFirstChild("2Event")

if not snitchRem then
    warn("[bypass] 2Event remote not found — run after character loads")
    return
end

local AC_FLAGS = {
    ["reach? whats reach? i dont use reach?"] = true,
    ["walkspeed/jumppower"]                   = true,
    ["hh"]                                    = true,
    ["fly"]                                   = true,
    ["fly 4"]                                 = true,
    ["fly 5"]                                 = true,
    ["changing handle size"]                  = true,
    ["remote removing"]                       = true,
    ["deleting/disabling anti"]               = true,
    ["sim rad"]                               = true,
}

local WATCHED_PROPS = { WalkSpeed = true, JumpPower = true, HipHeight = true }

-- dummy RBXScriptSignal-like object — AC's :Connect() goes nowhere
local dummySignal = setmetatable({}, {
    __index = function(_, k)
        if k == "Connect" or k == "Once" or k == "Wait" then
            return function()
                return { Disconnect = function() end, Connected = false }
            end
        end
    end
})

-- ── [1] __namecall HOOK ────────────────────────────────────────────
-- Key fix over v1/v2: varargs captured as locals BEFORE any closure,
-- no nested function touches ... (LuaU vararg scoping rule)
local origNamecall
origNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local a1     = select(1, ...)           -- capture arg1 immediately
    local method = getnamecallmethod()

    -- swallow AC snitch calls on 2Event remote
    if method == "FireServer" and self == snitchRem then
        if AC_FLAGS[a1] then
            return  -- 🤫 gone
        end
    end

    -- intercept GetPropertyChangedSignal for future char spawns
    if method == "GetPropertyChangedSignal" and WATCHED_PROPS[a1] then
        local char = lp.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum and self == hum then
            return dummySignal
        end
    end

    return origNamecall(self, ...)
end)

-- ── [2] KILL EXISTING CONNECTIONS ─────────────────────────────────
-- The AC wired these when the character loaded — before our hook ran.
-- getconnections lets us reach in and pull them out.
local function killExistingConns()
    local char = lp.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    for prop in pairs(WATCHED_PROPS) do
        local signal = hum:GetPropertyChangedSignal(prop)
        for _, conn in ipairs(getconnections(signal)) do
            pcall(function() conn:Disable() end)
            pcall(function() conn:Disconnect() end)
        end
    end

    -- kill the fly-detection StateChanged hook too
    for _, conn in ipairs(getconnections(hum.StateChanged)) do
        pcall(function() conn:Disable() end)
    end
end

killExistingConns()

-- ── [3] GC SCAN — hook every AC closure by upvalue ────────────────
-- The AC callbacks all hold snitchRem (u1) as an upvalue.
-- Find them in GC, replace with no-ops. Covers Touched, loops, everything.
local gcHooked = 0
for _, fn in ipairs(getgc(true)) do
    if type(fn) == "function" then
        local isExec = isexecutorclosure and isexecutorclosure(fn)
        if not isExec then
            local ok, ups = pcall(getupvalues, fn)
            if ok and ups then
                for _, uv in pairs(ups) do
                    if uv == snitchRem then
                        pcall(hookfunction, fn, function() end)
                        gcHooked = gcHooked + 1
                        break
                    end
                end
            end
        end
    end
end

-- ── [4] REACH TRAP WATCHER ────────────────────────────────────────
-- The AC plants invisible "LLeft Aarm" parts on other players' chars
-- far out in space — touching one = reach flag. We teleport them to
-- math.huge and disconnect their Touched connections.
local function nukeReachPart(inst)
    if inst.Name ~= "LLeft Aarm" then return end
    pcall(function() inst.CFrame = CFrame.new(1e18, 1e18, 1e18) end)
    pcall(function()
        for _, c in ipairs(getconnections(inst.Touched)) do
            c:Disable()
        end
    end)
end

local function watchChar(char)
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do nukeReachPart(d) end
    char.DescendantAdded:Connect(nukeReachPart)
end

for _, plr in ipairs(Players:GetPlayers()) do
    if plr ~= lp then
        watchChar(plr.Character)
        plr.CharacterAdded:Connect(watchChar)
    end
end
Players.PlayerAdded:Connect(function(plr)
    if plr ~= lp then
        watchChar(plr.Character)
        plr.CharacterAdded:Connect(watchChar)
    end
end)

-- ── [5] PERSISTENT WALKSPEED LOOP ─────────────────────────────────
-- Game resets WalkSpeed server-side on respawn. Heartbeat re-applies
-- faster than the server can stomp it back. Also re-kills connections
-- on character respawn (fresh char = fresh AC connections).
local lastChar = lp.Character

RunService.Heartbeat:Connect(function()
    local char = lp.Character
    if not char then return end

    -- on respawn: new char means new AC connections, kill them again
    if char ~= lastChar then
        lastChar = char
        task.defer(function()
            task.wait(0.5)          -- give AC script a moment to wire up
            killExistingConns()     -- then kill its fresh connections
            watchChar(char)         -- watch for new LLeft Aarm plants
        end)
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed ~= TARGET_WALKSPEED then
        hum.WalkSpeed = TARGET_WALKSPEED
    end
end)

-- ── DONE ───────────────────────────────────────────────────────────
game:GetService("StarterGui"):SetCore("SendNotification", {
    Title    = "bypass v3",
    Text     = "AC dead | WalkSpeed locked to " .. TARGET_WALKSPEED,
    Duration = 8
})


local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local TeleportToSafezone = ReplicatedStorage:WaitForChild("TeleportToSafezone")

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")
	local lastHealth = humanoid.Health

	humanoid.HealthChanged:Connect(function(health)
		local tookDamage = health < lastHealth
		lastHealth = health

		if not tookDamage or health <= 0 then
			return
		end

		TeleportToSafezone:FireServer()
	end)
end

local lplr = game:GetService("Players")["LocalPlayer"]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local teleportRemote = game:GetService("ReplicatedStorage").TeleportToSafezone
local targetBlock = game:GetService("Workspace").Platform.SpawnLocation

teleportRemote.OnClientEvent:Connect(function(player)
	local character = lplr.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local offset = Vector3.new(0, targetBlock.Size.Y / 2 + 3, 0)
	character:PivotTo(CFrame.new(targetBlock.Position + offset))
end)

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")
	local lastHealth = humanoid.Health

	humanoid.HealthChanged:Connect(function(health)
		local tookDamage = health < lastHealth
		lastHealth = health

		if not tookDamage or health <= 0 then
			return
		end

		teleportRemote:FireServer()
	end)
end

if lplr.Character then
	onCharacterAdded(lplr.Character)
end
lplr.CharacterAdded:Connect(onCharacterAdded)



local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local teleportRemote = ReplicatedStorage:WaitForChild("TeleportToSafezone")
local targetBlock = workspace:WaitForChild("Platform"):WaitForChild("SpawnLocation")

local REQUEST_COOLDOWN = 1
local lastRequest = 0

teleportRemote.OnClientEvent:Connect(function()
	local character = localPlayer.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local offset = Vector3.new(0, targetBlock.Size.Y / 2 + 3, 0)
	character:PivotTo(targetBlock.CFrame + offset)
end)

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")
	local lastHealth = humanoid.Health
	local connection

	connection = humanoid.HealthChanged:Connect(function(health)
		local tookDamage = health < lastHealth
		lastHealth = health

		if not tookDamage or health <= 0 then
			return
		end

		local now = os.clock()
		if now - lastRequest < REQUEST_COOLDOWN then
			return
		end

		lastRequest = now
		teleportRemote:FireServer()
	end)

	humanoid.Died:Connect(function()
		connection:Disconnect()
	end)
end

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)