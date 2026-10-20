
--// Old Bypass
local Event = game:GetService("ReplicatedStorage").Remotes.NPCStuff
Event:FireServer(
    "CompleteQuest",
    75000,
    7,
    0
)
------
local Event = game:GetService("ReplicatedStorage").Remotes.DragonStoneExchange
Event:FireServer(
    "IncreaseBaseMelee",
    75000
)

--// New Bypass
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
local Event = game:GetService("ReplicatedStorage").Remotes.NPCStuff
local Event2 = game:GetService("ReplicatedStorage").Remotes.DragonStoneExchange
local DragonStoneExchange = Remotes:WaitForChild("DragonStoneExchange")

task.spawn(function()
	while task.wait(0.05) do
        Event:FireServer("CompleteQuest",75000,7,0)
		Event2:FireServer("IncreaseBaseMelee", 5000) --// IncreaseBaseDamage, IncreaseBaseMelee, IncreaseBaseKi, IncreaseBaseHealth, IncreaseBaseStamina
	end
end)