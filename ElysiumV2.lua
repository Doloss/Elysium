--// HBE, HANDLE TP, RESIZE, FTI, PACKAGED ANTI-CHEAT, DISCLOSE DAMAGE --// V1 FTI, V2 FTI, KILL BOTS
--// .wl[player], table.find and table.insert [player]
--// .unwl[player], remove player from table
--// .tp[player], find player and goto player's position, make a setting for Position teleporting on Tweening
--// .pan[player], teleport infront of and then behind the player with rapid speeds
--// .frame[player]. find the anti-cheat, depending on such anti-cheat a certain frame will be ran
--// .reach[mode], switch reach mode, legit or blatant
--//.kill[player], find the player and teleport to the player, teleport back to the original CFrame
--// .cbring[player], bring the player to you, and kill them
--// whitelist, lists the players in your whitelist

--// DEV CONSOLE VISIBLE
local DevConsoleHook
DevConsoleHook = hookfunction(StarterGui.SetCore, newcclosure(function(self, ...)
	local Args = table.pack(...)
	if self == StarterGui then
		if Args[1] == "DevConsoleVisible" then
			Args[1] = nil
		end
	end
end))
game:GetService("StarterGui"):SetCore("DevConsoleVisible", true);
rconsoleprint("REPORT ANY ERRORS OCCURING IN HERE TO THE DEV TEAM.")

--// PLR VARIABLES
local Players = game.Players
local lplr = game:GetService("Players")["LocalPlayer"]
local Tool =  lplr.Character and lplr.Character:FindFirstChildOfClass("Tool")
local TestTool

lplr.Character.ChildAdded:Connect(function(tool)
    if tool:IsA("Tool") then
        TestTool = tool
    end
end)
--// REMOTE VARIABLES
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local prnt = getrenv().print
local acversion = "u2.6.1"
local oldUbubbles
--// MISC VARIABLES
local call = getrenv().pcall
local call2 = getrenv().xpcall
local startgui = game:GetService("StarterGui") --// [string]
--// ANTI-CHEAT GLOBAL VARIABLES
shared.Warden = false; --// [bool]
shared.Cents = false; --// [bool]
shared.ModernuBubbles = false; --// [bool]
shared.uBubbles = false; --// [bool]
shared.MiscCbring = false; --// [bool]
shared.Kujo = false; --// [bool]
shared.WhatAntiCheat = false; --// [bool]

--// CENTS CHECK
local function IsCents() --// Returns True(if Cents is being used) or False(if not) [function]
    local isC = false --// Whats returning
    local mainAc = nil
    for i, v in pairs(getnilinstances()) do
        if v:IsA("ModuleScript") then
            if v:GetAttribute("Name") ~= nil then
                if rawget(table.clone(require(v)), "Initiate") ~= nil then
                    isC = true
                    shared.Cents = true
                    mainAc = v
                end
            end
        end
    end
    return isC, mainAc
end

--// UBUBBLES CHECK
local function isModernuBubbles() --// Returns True (if uBubbles is being used) or False (if not) [function]
    HookingPrint = hookfunction(prnt, function(...)
        local isMU = false --// Whats returning
        local args = {...}
        local version = args[1]
        if args[1] == acversion then
            isMU = true
            shared.ModernuBubbles = true
        end
        return HookingPrint(...)
    end)
    return isMU
end

--// OLD UBUBBLES BYP
local old
if ReplicatedStorage.exploit then
    old = hookmetamethod(game,"__namecall", function(self, ...)
        oldUbubbles = ReplicatedStorage.exploit
        shared.uBubbles = true;
        if self == ReplicatedStorage.exploit and getnamecallmethod():lower() == "fireserver" then
            return nil
        end
        return old(self,...)
    end)
end

--// MISC CBRING BYP
for i,v in pairs(getreg()) do
    if type(v) == 'function' then
        local miscinfo = getinfo(v)
        if miscinfo.name == 'u5' then
            shared.MiscCbring = true;
            hookfunction(miscinfo.func, function(...) return nil end)
        else
            shared.MiscCbring = false
      end
   end
end

--// WARDEN CHECK
local function FindWarden()
    local isWard = false
    for i,v in pairs(getreg()) do
        if type(v) == 'function' then
            local WardenInfo = getinfo(v)
      if WardenInfo.name == 'Vector' then
        isWard = true
        shared.Warden = true 
      end
    end
    return isWard
end

--// IF MODERNUBUBBLES BYPASS
local isMU = isModernuBubbles()

if isMU then
    for i, v in pairs(debug.getstack(1)) do
        if type(v) == 'table' then
            setmetatable(v, {
                __newindex = function(self, i, v)
                    return nil;
                end
            })
    end
end

--// IF CENTS BYPASS
local isC, acmodule = IsCents()

if isC then
    print(IsC)
    local oldCents = nil
    oldCents = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local args = {...}
        if getnamecallmethod():lower() == 'fireserver' then
            if args[1] == 'exploit' and getcallingscript() == acmodule then
                return nil 
            end
        end
        return oldCents(self, ...)
    end))
end

--// IF WARDEN BYPASS
local isWard = FindWarden()
if isWard and shared.Warden == true then
    for i,v in pairs(getreg()) do
        if type(v) == 'function' then
            local WardenInfo = getinfo(v)
            if WardenInfo.name == 'Vector' then
                hookfunction(WardenInfo.func, function(...) return nil end)
            end
        end
    end
end


--// IF MISC BYPASS
local isCbring = FindCbring()

if isCbring and shared.MiscCbring == true then
    for i,v in pairs(getreg()) do
        if type(v) == 'function' then
            local miscinfo = getinfo(v)
            if miscinfo.name == 'u5' then
                hookfunction(miscinfo.func, function(...) return nil end)
            end
        end
    end
end

--// ANIT XPCALL, PCALL
hookfunction(call, function() return nil end)
hookfunction(call2, function() return nil end)

repeat task.wait() until game:IsLoaded()
    --// REACH UI VARIABLES
    shared.reachon = false --//True or False [bool]
    shared.reachdist = nil  
    shared.InvisCheck = false --// True or False [bool]
    shared.FTIAllParts = false --// True or False [bool]
    shared.FTILungeOnly = false --// True or False [bool]
    shared.IgnoreForceField = false --// True or False [bool]
    shared.AngularFTI = false --// True or False [bool]
    shared.AngleAccepted = nil --// [number]
    shared.TabCheck = false --// True or False [bool]
    --// AUTOAIM UI VARIABLES   
    shared.AutoAim = false --// True or False [bool]
    shared.AutoAimDelay = nil --// [integer]
    shared.AutoAimDistance = nil --// [integer]
    --// AUTOJUMP UI VARIABLES
    shared.AutoJump = false --// True or False [bool]
    shared.AutoJumpTeamCheck = false --// True or False [bool]
    shared.AutoJumpDelay = nil --// [integer]
    shared.AutoJumpDistance = nil --// [integer, number], // "Should this even be edited? We might want to make it reachdist"
    --// VISUALIZER UI VARIABLES[MEDAL-FRIENDLY]
    shared.VisualizerOn = false --// VisualizerSize will be reachdist [bool], [number, integer]
    shared.VisualizerTransparency = nil --// [number]
    shared.Highlights = false --// [bool]
    shared.HighlightsTeam = false --// [bool]
    --// TP KILL UI VARIABLES[BLATANT]
    shared.TPKill = false --// TP Kill Distance will be reachdist [bool], [number, integer]
    shared.DistanceFromBack = nil --// [integer]
    --// MISC UI VARIABLES
    shared.AutoClicker = false --// True or False [bool]
    shared.NearAutoClicker = false --// NearAutoClickerDistance will be reachdist [bool], [number, integer]
    shared.antiAutoclickerBypass = false --// True or False [bool]
--// AUTOPLAY UI VARIABLES
--// shared.AutoPlay = false --// True or False, turns on the Auto Play AI
--// shared.AutoClicker = false --// AutoPlay AutoClicker true or false, must be anti autoclicker.
--// shared.AimAngle = math.rad --// The angle that your player will face the target
--// shared.AllowJitter = false --// Basically Auto Wiggle
--// shared.JitterAmount = nil
--// shared.JitterSpeed = nil --// Between 0 and 100
--// shared.AutoPlayFormats = {"W Hold", "Perfected Baiting", "Programmed", "Adaptive"} --The AutoPlay Formats that will be aviabvle
--// shared.AutoPlayFormat = nil --// Decided by Player
--// shared.LimbsAv = {"Torso", "Left Arm", "Right Arm", "Desc Attachments"} --// Decided by Player, It will get the position
--// shared.LimbToPath = nil
--// W HOLD - Rushing everybody
--// PERFECTED BAITING - Acting as if you are W holding, but switching to S holding when in x magnitude within milliseconds.
--// PROGRAMMED -  Following a sequence of keys under specific conditions
--// ADAPTIVE - Doing the same as your opponent

--// FUNCTIONS(Make them Secure in the future)
function autostudgame() --// FutureSecure [function]
    for p,r in pairs(lplr.Backpack:GetChildren()) do
        if r:IsA("Tool") then
            r.Parent = lplr.Character
            reachdist = 1000
        end
    end
    local txxxlplr = game:GetService("Players")
    for i,v in pairs(txxxlplr:GetPlayers()) do
        for i, 10 do
            task.spawn(function()
            firetouchinterest(lplr.Character:FindFirstChildWhichIsA("Tool").Handle, v.Character.Torso, 0)
            firetouchinterest(lplr.Character:FindFirstChildWhichIsA("Tool").Handle, v.Character.Torso, 1)
            firetouchinterest(lplr.Character:FindFirstChildWhichIsA("Tool").Handle, v.Character.Head, 0)
            firetouchinterest(lplr.Character:FindFirstChildWhichIsA("Tool").Handle, v.Character.Head, 1)
            end)
        end
    end
end

function rejoin() --// [function]
    game:GetService("TeleportService"):Teleport(game.PlaceId, lplr)
end

function FramePlr() --// FutureSecure [function]
    for i, v in pairs(getconnections(game.Players.LocalPlayer.Character.Humanoid.Changed)) do
        v:Disable()
    end
    for i, v in pairs(getconnections(game.Players.LocalPlayer.Character.HumanoidRootPart:GetPropertyChangedSignal("Size"))) do
            v:Disable()
        end
        for i, v in pairs(getconnections(game.Players.LocalPlayer.Character.Humanoid:GetPropertyChangedSignal("HipHeight"))) do
            v:Disable()
        end
        lplr.Character.HumanoidRootPart.Size = Vector3.new(50, 0, 50)
        lplr.Character.Humanoid.HipHeight = 1
    end
function CustomTOD(time) --// FutureSecure [function]
    game.Lighting.ClockTime = time
end

function Forcereset() --// [function]
local ForceResetLocalPlayer = game:GetService("Players")["LocalPlayer"]
ForceResetLocalPlayer.Character.Humanoid.Health = 0
ForceResetLocalPlayer.Character.Parent = game.TouchInputService
task.wait(0.5)
ForceResetLocalPlayer.Character.Parent = nil
ForceResetLocalPlayer.Character.Parent = workspace
end


--// (LUNGE ONLY)if Tool.Orientation == "0.302, 180, 90" and Tool.Position == "20.513, 3.484, -8.364" then FTI else continue end
--// (TAB CHECK)if iswindowactive then FTI else continue end
--// AUTOCLICKER: TYPECHECK, TABCHECK, DELAY
--// (FORCEFIELD(Reach Check)) getChildren, if not forecefield then FTI else continue end
--// (INVISIBLE(Reach Check)) getChildren, if not Transparency <= 0.2 then FTI else continue end
--// (ANGULAR(Reach Check)) ?