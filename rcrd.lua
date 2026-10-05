--
-- BUNDLED SCRIPT

local _MODULES = {}

_MODULES["combat.lua"] = function()
-- combat.lua — Combat + NPC utilities
-- Receives: ctx { C, State, Util, Move, LocalPlayer, RunService }

local function build(ctx)
    local C            = ctx.C
    local State        = ctx.State
    local Util         = ctx.Util
    local Move         = ctx.Move
    local LocalPlayer  = ctx.LocalPlayer
    local RunService   = ctx.RunService

    local Combat = {}

    -- Find a Tool by name in the character or backpack.
    -- Returns (tool, isEquipped).
    function Combat.findTool(name)
        local char = LocalPlayer.Character
        local bp   = LocalPlayer:FindFirstChild("Backpack")
        for _, container in ipairs({ char, bp }) do
            if container then
                for _, t in ipairs(container:GetChildren()) do
                    if t:IsA("Tool") and (name == nil or t.Name == name) then
                        return t, container == char
                    end
                end
            end
        end
        return nil, false
    end

    function Combat.ensureMelee()
        local tool, equipped = Combat.findTool(C.MELEE_TOOL_NAME)
        if not tool then
            Util.log("Melee '" .. C.MELEE_TOOL_NAME .. "' not found")
            return false
        end
        if equipped then return true end
        local hum = Util.getHumanoid()
        if not hum then return false end
        for _ = 1, 2 do
            Util.try(function() hum:EquipTool(cloneref(tool)) end)
            task.wait(C.EQUIP_WAIT)
            _, equipped = Combat.findTool(C.MELEE_TOOL_NAME)
            if equipped then return true end
        end
        return false
    end

    -- Real M1: the game's own Attack callback (InputCallbacks.Callbacks.Attack).
    -- The game builds swingsfx/damage itself, honouring cooldown, combo and hitbox.
    function Combat.getM1()
        local bp  = LocalPlayer:FindFirstChild("Backpack")
        local mod = bp and bp:FindFirstChild("InputCallbacks")
        if not mod then return nil end
        local ok, ic = pcall(require, mod)
        if ok and type(ic) == "table" and ic.Callbacks and ic.Callbacks.Attack and ic.Utils then
            return ic
        end
        return nil
    end

    -- Kill ONE npc with the real M1: follow it from above, swing until dead.
    -- cfg.hitHeight = minimum studs above the npc. isActive() is polled to allow cancelling.
    -- Returns true if the npc died.
    function Combat.killNPC(npc, cfg, isActive)
        local npcHRP = npc:FindFirstChild("HumanoidRootPart")
        local npcHum = npc:FindFirstChildOfClass("Humanoid")
        if not npcHRP or not npcHum or npcHum.Health <= 0 then return false end

        if isActive and not isActive() then return false end
        if not Combat.ensureMelee() then return false end
        local ic = Combat.getM1()
        if not ic then Util.log("M1: InputCallbacks not found"); return false end
        if not State.mover then Move.setup() end

        local height = cfg.hitHeight or 7
        local follow = true
        local function active() return not isActive or isActive() end

        -- Follow every frame instead of with tweens, so the target never goes stale.
        -- Horizontal moves at TWEEN_SPEED_HIT. Height = max(npc height, standing height) + height:
        --  * npc jumps / gets knocked up  -> we rise with it, then come back to standing + height
        --  * npc falls / gets knocked down -> standing height is kept, so we do NOT go down
        --    (it gets back up and would reach us)
        -- The standing height only changes once the npc has stayed still at a new height on the
        -- ground for STABLE_TIME (so jumps / knock-ups never raise it), and it only goes down for
        -- drops of at least MIN_DROP (a knock-down lowers the npc ~1 stud: that never counts).
        Move.cancelTween()
        local STABLE_TIME, STABLE_TOL = 0.4, 0.3
        local MIN_RISE, MIN_DROP = 0.3, 1.5
        local DESCEND_SPEED = 120
        local standY = npcHRP.Position.Y
        local stableY, stableSince = standY, os.clock()

        -- On the ground (not mid-jump). The humanoid state is useless here: idle fishman report
        -- FallingDown while standing, so only the floor material is checked.
        local function isStanding()
            return npcHum.FloorMaterial ~= Enum.Material.Air
        end

        local followConn
        followConn = RunService.Heartbeat:Connect(function(dt)
            local hrp = Util.getHRP()
            if not (follow and active() and hrp and npcHRP.Parent and npcHum.Health > 0) then
                followConn:Disconnect()
                return
            end
            local npcPos = npcHRP.Position
            local pos    = hrp.Position

            -- track how long the npc has been still (on the ground) at its current height
            if not isStanding() or math.abs(npcPos.Y - stableY) > STABLE_TOL then
                stableY, stableSince = npcPos.Y, os.clock()
            elseif os.clock() - stableSince >= STABLE_TIME then
                local diff = stableY - standY
                if diff >= MIN_RISE or -diff >= MIN_DROP then
                    standY = stableY
                end
            end
            local hoverY = math.max(npcPos.Y, standY) + height

            local flat = Vector3.new(npcPos.X - pos.X, 0, npcPos.Z - pos.Z)
            local step = C.TWEEN_SPEED_HIT * dt
            local newXZ = flat.Magnitude <= step and Vector3.new(npcPos.X, 0, npcPos.Z)
                or Vector3.new(pos.X, 0, pos.Z) + flat.Unit * step

            -- below the hover height: snap up; above it (arriving from higher): glide down to it
            local newY = pos.Y < hoverY and hoverY or math.max(hoverY, pos.Y - DESCEND_SPEED * dt)

            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.CFrame = CFrame.new(newXZ.X, newY, newXZ.Z) * hrp.CFrame.Rotation
        end)

        -- wait until we are above it (distance / speed + margin)
        local myHRP = Util.getHRP()
        local t0 = os.clock()
        local limit = myHRP and ((myHRP.Position - npcHRP.Position).Magnitude / C.TWEEN_SPEED_HIT + 6) or 6
        while follow and active() and myHRP and npcHRP.Parent
            and (myHRP.Position - (npcHRP.Position + Vector3.new(0, height, 0))).Magnitude > 2
            and os.clock() - t0 < limit do
            task.wait(0.1)
        end

        local tAtk = os.clock()
        while npcHRP.Parent and npcHum.Health > 0
            and os.clock() - tAtk < C.KILL_TIMEOUT
            and active() do
            if ic.Utils.canAutoM1() == true then
                pcall(function() ic.Callbacks.Attack:PC_Activate() end)
            end
            task.wait()
        end

        follow = false
        if followConn.Connected then followConn:Disconnect() end
        return npcHum.Health <= 0
    end

    -- NPC utility functions (formerly npc.lua)

    -- Returns all living NPCs with the given name from workspace.NPCs.
    function Combat.getAlive(npcName)
        local folder = workspace:FindFirstChild("NPCs")
        if not folder then return {} end
        local result = {}
        for _, n in ipairs(folder:GetChildren()) do
            if n.Name == npcName then
                local hum = n:FindFirstChildOfClass("Humanoid")
                local hrp = n:FindFirstChild("HumanoidRootPart")
                if hum and hum.Health > 0 and hrp then
                    table.insert(result, n)
                end
            end
        end
        return result
    end

    return Combat
end

return build

end

_MODULES["config.lua"] = function()
-- config.lua — Constants, FarmConfigs, FishRarities

local C = {
    -- Movement
    TWEEN_SPEED_NORMAL   = 35,
    TWEEN_SPEED_FAST     = 60,
    TWEEN_SPEED_MERCHANT = 35,
    TWEEN_SPEED_HIT      = 25,   -- speed while following an npc with the real M1
    KILL_TIMEOUT         = 20,   -- max seconds spent on a single npc
    FALL_ANIM_ID         = "10001705684",  -- game's Fall animation (stopped while hovering)
    EQUIP_WAIT           = 0.15,

    -- Combat
    MELEE_TOOL_NAME    = "Melee",
    MAX_STAT           = 500,

    -- Levels
    FISHMAN_MIN_LEVEL = 25,

    -- Fishing
    BITE_TIMEOUT      = 30,
    REEL_TIMEOUT      = 20,
    FISH_ROD_DEFAULT  = "Fishing Rod",
    BAIT_DEFAULT      = "Common Fish Bait",

    -- World
    TRAVEL_SEA_SURFACE = Vector3.new(1837, 4, -12175),
    TRAVEL_SEA_DIVE    = Vector3.new(1793, -92, -12333),
    FISHMAN_SPAWN      = Vector3.new(7977, -2153, -17075),
    FISHMAN_EXIT       = Vector3.new(8585, -2136, -17087),
    FISHMAN_RADIUS     = 1000,
    SURFACE_RADIUS     = 800,

    -- Waypoints to reach the Fishman Island teleporter from the main island
    FISHMAN_TRAVEL_PATH = {
        Vector3.new(-559,   5,  -3462),
        Vector3.new(-550,   6,  -3649),
        Vector3.new(1831,   4, -12142),
        Vector3.new(1732,   3, -12153),
        Vector3.new(1731,   3, -12363),
        Vector3.new(1797, -92, -12358),
    },

    -- Position used to set the spawn point on arrival at Fishman Island
    FISHMAN_SETSPAWN_POS = Vector3.new(7976, -2153, -17074),

    -- Waypoints from the teleport landing pad to the NPC farm area
    FISHMAN_TO_NPCS = {
        Vector3.new(7999, -2154, -17149),
        Vector3.new(7859, -2154, -17166),
        Vector3.new(7761, -2177, -17203),
    },

    -- Waypoints to safely exit Fishman Island without noclip.
    -- If near the quest area, start from FISHMAN_EXIT_FROM_QUEST[1].
    -- If near spawn, skip directly to FISHMAN_EXIT_SHARED[1].
    FISHMAN_EXIT_JUNCTION   = Vector3.new(8010, -2154, -17119),
    FISHMAN_EXIT_FROM_QUEST = {
        Vector3.new(7780, -2177, -17179),
        Vector3.new(7852, -2154, -17166),
        Vector3.new(8004, -2154, -17118),
    },
    FISHMAN_EXIT_SHARED = {
        Vector3.new(8010, -2154, -17119),
        Vector3.new(8187, -2139, -17078),
        Vector3.new(8247, -2140, -17040),
        Vector3.new(8398, -2126, -17051),
        Vector3.new(8492, -2126, -17070),
    },

    -- Coco Island path (Sky Walk 2 purchase) — phase 1: approach
    COCO_PATH_1 = {
        Vector3.new(1832,  1, -12121),
        Vector3.new( 589,  6, -12308),
        Vector3.new(  69,  3, -12318),
        Vector3.new(-2941, 6, -11891),
    },
    -- Coco Island path — phase 2: climb to Sky Walk trainer NPC
    COCO_PATH_2 = {
        Vector3.new(-2960,  6, -11683),
        Vector3.new(-3202,  6, -11684),
        Vector3.new(-3164,  6, -11730),
        Vector3.new(-3110, 47, -11733),
        Vector3.new(-3074, 88, -11736),
        Vector3.new(-3087, 93, -11757),
    },

    -- Sea 2 / Shrine
    SEA2_LEVEL        = 325,
    SHRINE_PIVOT      = CFrame.new(-7348, 3, -14949),
    SHRINE_RADIUS     = 200,
    WORLD_SCROLL_WAIT = 60,
    PROMPT_RADIUS     = 30,

    -- Anti-AFK
    AFK_INTERVAL   = 240,

    -- Webhook colours
    WEBHOOK_COLOR_FARM     = 0x9B59B6,
    WEBHOOK_COLOR_FISHMAN  = 0x3498DB,
    WEBHOOK_COLOR_MERCHANT = 0xF1C40F,
    WEBHOOK_COLOR_HALLOWEEN = 0xE67E22,
    WEBHOOK_COLOR_REPORT   = 0x2ECC71,
}

local FarmConfigs = {
    bandit = {
        npcName      = "Bandit",
        gatherPos    = Vector3.new(-638, 15, -3471),
        questPos     = Vector3.new(-576, 5, -3431),
        questName    = "Help Daph",
        minLevel     = 0,
        floatHeight  = 8,
        hitHeight    = 7,   -- studs above the npc while hitting it with the real M1
    },
    fishman = {
        npcName      = "Fishman Karate User",
        gatherPos    = Vector3.new(7715, -2170, -17334),
        questPos     = Vector3.new(7732, -2176, -17222),
        questName    = "Help becky",
        minLevel     = 190,
        floatHeight  = 8,
        hitHeight    = 7,
    },
}

local FishRarities = {
    ["Blue-Lip Grouper"]        = "Common",
    ["Tigerfin"]                = "Common",
    ["Crimson Polka Puffer"]    = "Rare",
    ["Crimson Snapper"]         = "Rare",
    ["Exotic Tigerfin"]         = "Rare",
    ["Fangfish"]                = "Rare",
    ["Zebra Ribbon Angelfish"]  = "Rare",
    ["Candy Corn Squid"]        = "Rare",
    ["Skeletal Shark"]          = "Epic",
    ["Anglerfish"]              = "Legendary",
    ["Swordfish"]               = "Legendary",
    ["Golden Polka Puffer"]     = "Legendary",
    ["Golden Ribbon Angelfish"] = "Legendary",
    ["Golden Tigerfin"]         = "Legendary",
    ["Dark Skeletal Shark"]     = "Legendary",
    ["Jack-O'-Bite"]            = "Legendary",
}

return C, FarmConfigs, FishRarities

end

_MODULES["esp.lua"] = function()
-- esp.lua — ESP module (island names)
-- Receives: ctx { Util, RunService }
--
-- Every island is a Model in workspace.Islands that is always present on the client (only its
-- parts stream in) and carries its centre as the islandCFrame attribute, so far islands can be
-- labelled without loading them. Names are drawn as screen text placed over that point.

local function build(ctx)
    local Util       = ctx.Util
    local RunService = ctx.RunService

    local Esp = {}

    local COLOR = Color3.fromRGB(120, 220, 255)

    local screen  = nil   -- ScreenGui holding the labels
    local labels  = {}    -- [model] = { label, point }
    local renderConn

    local function islandPoint(model)
        local cf = model:GetAttribute("islandCFrame")
        if typeof(cf) == "CFrame" then return cf.Position end
        local ok, pivot = pcall(function() return model:GetPivot().Position end)
        return ok and pivot or nil
    end

    local function addIsland(model)
        if labels[model] or not model:IsA("Model") then return end
        local point = islandPoint(model)
        if not point then return end
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.AnchorPoint            = Vector2.new(0.5, 0.5)
        label.Size                   = UDim2.fromOffset(200, 20)
        label.Font                   = Enum.Font.GothamBold
        label.TextSize               = 14
        label.TextColor3             = COLOR
        label.TextStrokeTransparency = 0.3
        label.Text                   = model.Name
        label.Visible                = false
        label.Parent                 = screen
        labels[model] = { label = label, point = point }
    end

    local function removeIsland(model)
        local e = labels[model]
        if e then e.label:Destroy() end
        labels[model] = nil
    end

    function Esp.setIslands(on)
        if renderConn then renderConn:Disconnect(); renderConn = nil end
        if screen then screen:Destroy(); screen = nil end
        table.clear(labels)
        if not on then return end

        local folder = workspace:FindFirstChild("Islands")
        if not folder then Util.log("ESP: workspace.Islands not found."); return end

        screen = Instance.new("ScreenGui")
        screen.Name           = "IslandEsp"
        screen.IgnoreGuiInset = true
        screen.ResetOnSpawn   = false
        screen.Parent         = (gethui and gethui()) or game:GetService("CoreGui")

        for _, m in ipairs(folder:GetChildren()) do addIsland(m) end

        local cam = workspace.CurrentCamera
        renderConn = RunService.RenderStepped:Connect(function()
            cam = workspace.CurrentCamera
            for model, e in pairs(labels) do
                if not model.Parent then
                    removeIsland(model)
                else
                    local p, onScreen = cam:WorldToViewportPoint(e.point)
                    e.label.Visible = onScreen
                    if onScreen then e.label.Position = UDim2.fromOffset(p.X, p.Y) end
                end
            end
            -- islands added later (e.g. another sea)
            for _, m in ipairs(folder:GetChildren()) do
                if not labels[m] then addIsland(m) end
            end
        end)
    end

    return Esp
end

return build

end

_MODULES["farm.lua"] = function()
-- farm.lua — Farm module + main farm state machine
-- Receives: ctx { C, State, Util, Move, Combat, Webhook,
--               FarmConfigs, QuestRemote, SetSpawnRemote, Win, LocalPlayer, VIM }

local function build(ctx)
    local C              = ctx.C
    local State          = ctx.State
    local Util           = ctx.Util
    local Move           = ctx.Move
    local Combat         = ctx.Combat
    local Webhook        = ctx.Webhook
    local FarmConfigs    = ctx.FarmConfigs
    local QuestRemote    = ctx.QuestRemote
    local SetSpawnRemote = ctx.SetSpawnRemote
    local Win            = ctx.Win
    local LocalPlayer    = ctx.LocalPlayer
    local VIM            = ctx.VIM

    local Farm = {}

    local function pressInteractKey(holdDuration)
        holdDuration = holdDuration or 0.1
        pcall(function() VIM:SendKeyEvent(true,  Enum.KeyCode.LeftAlt, false, game) end)
        task.wait(holdDuration)
        pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.LeftAlt, false, game) end)
    end

    local function fireNearbyPrompts(radius)
        radius = radius or C.PROMPT_RADIUS
        local hrp = Util.getHRP()
        if not hrp then return end

        local hrpPos    = hrp.Position
        local triggered = false
        for _, v in ipairs(workspace:GetDescendants()) do
            if v:IsA("ProximityPrompt") and v.Enabled then
                local part = v.Parent
                if not (part and part:IsA("BasePart")) then
                    part = part and (
                        part:FindFirstAncestorWhichIsA("BasePart") or
                        part:FindFirstChildWhichIsA("BasePart", true)
                    )
                end
                if part and (part.Position - hrpPos).Magnitude <= radius then
                    pressInteractKey(math.max(v.HoldDuration + 0.05, 0.1))
                    triggered = true
                end
            end
        end
        return triggered
    end

    -- One-by-one kill with the real M1 (same for every farm: bandits, fishman, yetis).
    -- Returns (ranToCompletion: bool, shouldRestart: bool)
    function Farm.runOneByOne(cfg, flagName, useQuest)
        local lastProgress = useQuest and Util.getQuestProgress() or nil
        -- dying ends the cycle so the main loop can take the route back
        local isActive = function()
            return Win.Flags[flagName] and not State.diedInFarm and not State.isBuying
        end

        while isActive() do
            local progress = useQuest and Util.getQuestProgress() or nil
            if useQuest and not Util.isQuestActive() and lastProgress ~= nil then
                Util.log(flagName .. " — quest complete"); break
            end
            if useQuest then lastProgress = progress end

            local alive = Combat.getAlive(cfg.npcName)
            if #alive == 0 then
                if not useQuest then Util.log(flagName .. " — all dead"); break end
                Util.log(flagName .. " — waiting for respawn...")
                while isActive() and #Combat.getAlive(cfg.npcName) == 0 do
                    task.wait(1)
                end
            else
                local myHRP = Util.getHRP()
                local target, best
                for _, n in ipairs(alive) do
                    local h = n:FindFirstChild("HumanoidRootPart")
                    local d = (myHRP and h) and (h.Position - myHRP.Position).Magnitude or math.huge
                    if not best or d < best then target, best = n, d end
                end
                if target then
                    Util.log(("Farm | %s | Alive: %d"):format(progress or "-", #alive))
                    Combat.killNPC(target, cfg, isActive)
                    task.wait(0.1 + math.random() * 0.3)
                end
            end
        end

        return true, false
    end

    -- One full kill cycle for a given farm config.
    -- Returns (ranToCompletion: bool, shouldRestart: bool)
    function Farm.runCycle(cfg, flagName)
        local level    = Util.getLevel()
        local useQuest = cfg.questName and level and level >= (cfg.minLevel or 0)

        Combat.ensureMelee()

        -- Accept quest
        if useQuest and not Util.isQuestActive() then
            Util.log(flagName .. " — heading to quest giver...")
            Move.tweenTo(CFrame.new(cfg.questPos))
            task.wait(0.5)
            Util.invoke(QuestRemote, { "takequest", cfg.questName })
            task.wait(0.5)
            if not Util.isQuestActive() then
                Util.log(flagName .. " — failed to get quest, retrying...")
                task.wait(2)
                return false, true
            end
        end

        if not Win.Flags[flagName] then return false, false end
        return Farm.runOneByOne(cfg, flagName, useQuest)
    end

    -- Walk from the Fishman Island landing/spawn to the NPC area.
    function Farm.walkToFishmanNPCs()
        Util.log("Fishman — navigating to NPC area...")
        for _, pt in ipairs(C.FISHMAN_TO_NPCS) do
            if not Win.Flags["AutoFarm"] or State.isBuying then return end
            Move.tweenTo(CFrame.new(pt), C.TWEEN_SPEED_FAST)
            task.wait(0.4)
        end
    end

    -- Travel to Fishman Island (full route from wherever we are), set the spawn point once,
    -- then walk to the NPC area.
    function Farm.travelToFishman()
        Util.log("heading to Fishman Island...")
        -- drop other quests (bandits), but keep the fishman quest after a death
        local quest = Util.getCurrentQuest()
        if Util.isQuestActive() and quest ~= FarmConfigs.fishman.questName then
            Util.invoke(QuestRemote, { "quit" })
            task.wait(0.5)
        end

        if not Util.isAtFishmanIsland() then
            Move.stopAntiDrop()

            -- Find the nearest waypoint to avoid unnecessary tweens
            local hrp = Util.getHRP()
            local startIndex = 1
            if hrp then
                local closestDist = math.huge
                local currentPos = hrp.Position
                for i, pt in ipairs(C.FISHMAN_TRAVEL_PATH) do
                    local d = (currentPos - pt).Magnitude
                    if d < closestDist then
                        closestDist = d
                        startIndex = i
                    end
                end
                if startIndex > 1 then
                    Util.log(("Fishman travel: starting from waypoint %d/%d (%.0f studs away)"):format(
                        startIndex, #C.FISHMAN_TRAVEL_PATH, closestDist))
                end
            end

            for i = startIndex, #C.FISHMAN_TRAVEL_PATH do
                if not Win.Flags["AutoFarm"] or State.isBuying then return end
                Move.tweenTo(CFrame.new(C.FISHMAN_TRAVEL_PATH[i]), C.TWEEN_SPEED_FAST)
                task.wait(0.4)
            end

            -- Use the AreaTeleporter if available
            local teleporterPart = nil
            local atNode = workspace:FindFirstChild("AreaTeleporters")
            if atNode then
                local firstSea = atNode:FindFirstChild("FirstSea")
                local fishmanNode = firstSea and firstSea:FindFirstChild("Fishman")
                local part = fishmanNode and fishmanNode:FindFirstChild("Part")
                if part and part:IsA("Part") then
                    teleporterPart = part
                end
            end

            if teleporterPart then
                Util.log("Fishman — using AreaTeleporter Part...")
                local hrp = Util.getHRP()
                if hrp then hrp.CFrame = teleporterPart.CFrame end
                task.wait(5)
            else
                Util.log("Fishman — AreaTeleporter not found, trying dive fallback...")
                Move.tweenTo(CFrame.new(C.TRAVEL_SEA_SURFACE)); task.wait(0.3)
                Move.tweenTo(CFrame.new(C.TRAVEL_SEA_DIVE));    task.wait(0.5)
            end
        end

        -- Set spawn point on first visit
        if not State.spawnSet then
            Move.tweenTo(CFrame.new(C.FISHMAN_SETSPAWN_POS))
            task.wait(1)
            for _ = 1, 5 do
                Util.fire(SetSpawnRemote)
                task.wait(0.5)
            end
            State.spawnSet = true
            Util.log("spawn point set at Fishman Island.")
        end
        Farm.walkToFishmanNPCs()

        State.currentCfg = FarmConfigs.fishman
        if not State.fishmanNotified then
            State.fishmanNotified = true
            task.spawn(Webhook.fishmanArrival)
            Win:Notify({
                Title    = "Fishman Island",
                Message  = "farming fishman users",
                Type     = "success",
                Duration = 6,
            })
        end
        Move.startAntiDrop()
    end

    -- Walk out of Fishman Island following the safe exit waypoints.
    function Farm.exitFishman(flag)
        if not Util.isAtFishmanIsland() then return true end
        Util.log("Exiting Fishman Island...")

        local hrp = Util.getHRP()
        if not hrp then return false end

        local fullPath = {}
        for _, pt in ipairs(C.FISHMAN_EXIT_FROM_QUEST) do table.insert(fullPath, pt) end
        for _, pt in ipairs(C.FISHMAN_EXIT_SHARED)     do table.insert(fullPath, pt) end
        table.insert(fullPath, C.FISHMAN_EXIT)

        -- Find the nearest waypoint and start from there
        local startIndex  = 1
        local closestDist = math.huge
        local currentPos  = hrp.Position
        for i, pt in ipairs(fullPath) do
            local d = (currentPos - pt).Magnitude
            if d < closestDist then
                closestDist = d
                startIndex  = i
            end
        end

        Util.log(("Exit: starting from waypoint %d/%d (%.0f studs)"):format(
            startIndex, #fullPath, closestDist))

        for i = startIndex, #fullPath do
            if flag and not Win.Flags[flag] then return false end
            Move.tweenTo(CFrame.new(fullPath[i]), C.TWEEN_SPEED_FAST)
            task.wait(0.3)
        end
        task.wait(0.3)

        local deadline = tick() + 10
        while Util.isAtFishmanIsland() and tick() < deadline do
            if flag and not Win.Flags[flag] then return false end
            task.wait(0.5)
        end

        if Util.isAtFishmanIsland() then
            Util.log("Failed to exit Fishman Island.")
            return false
        end
        Util.log("Exited Fishman Island.")
        return true
    end

    -- Travel to Coco Island and purchase Sky Walk 2.
    function Farm.travelToCocoIslandAndBuySkyWalk()
        local peliCount = 0
        local deadline  = tick() + 10
        repeat
            peliCount = Util.getPelis()
            if peliCount > 0 then break end
            task.wait(0.5)
        until tick() > deadline

        if peliCount < 50000 then
            Util.log(("Coco Island: insufficient Pelis (have %d). Resuming farm..."):format(peliCount))
            return false
        end

        Move.stopAntiDrop()
        Move.startNoclip()

        if Util.isAtFishmanIsland() then
            if not Farm.exitFishman("AutoFarm") then
                Util.log("Coco Island — failed to exit Fishman.")
                return false
            end
        end

        Util.log("Coco Island — phase 1: approach...")
        for _, pt in ipairs(C.COCO_PATH_1) do
            if not Win.Flags["AutoFarm"] or State.isBuying then return false end
            Move.tweenTo(CFrame.new(pt), C.TWEEN_SPEED_FAST)
            task.wait(0.5)
        end

        if not workspace.Islands:FindFirstChild("Coco Island") then
            Util.log("Coco Island not found in workspace, retrying...")
            return false
        end

        Util.log("Coco Island — phase 2: climbing to trainer NPC...")
        for _, pt in ipairs(C.COCO_PATH_2) do
            if not Win.Flags["AutoFarm"] or State.isBuying then return false end
            Move.tweenTo(CFrame.new(pt), C.TWEEN_SPEED_FAST)
            task.wait(0.5)
        end

        Util.log("Coco Island — purchasing Sky Walk 2...")
        local LearnStyleRemote = ctx.LearnStyleRemote
        if not LearnStyleRemote then
            Util.log("Coco Island — LearnStyleRemote not found.")
            return false
        end
        Util.fire(LearnStyleRemote, "skyWalkTrainer")
        task.wait(1.5)
        Util.log("Sky Walk 2 purchased.")
        return true
    end

    -- Travel to the Sea 2 Shrine and pick up the World Scroll.
    function Farm.travelToSea2Shrine()
        Util.log("Sea 2 — traveling to Shrine...")
        Move.stopAntiDrop()
        Move.startNoclip()

        if Util.isAtFishmanIsland() then
            if not Farm.exitFishman("AutoFarm") then
                Util.log("Sea 2 — failed to exit Fishman.")
                return false
            end
        end

        if not Win.Flags["AutoFarm"] or State.isBuying then return false end
        Move.tweenTo(C.SHRINE_PIVOT, C.TWEEN_SPEED_FAST)
        task.wait(0.5)

        local hrp = Util.getHRP()
        if not hrp then return false end
        if (hrp.Position - C.SHRINE_PIVOT.Position).Magnitude > C.SHRINE_RADIUS then
            Util.log("Sea 2 — not close enough to Shrine.")
            return false
        end

        Util.log("Sea 2 — waiting for World Scroll...")
        local scroll      = nil
        local scrollNames = { "World Scroll", "WorldScroll", "world scroll" }

        local function findScroll()
            local containers = { workspace, workspace:FindFirstChild("Effects") }
            for _, container in ipairs(containers) do
                if container then
                    for _, name in ipairs(scrollNames) do
                        local found = container:FindFirstChild(name, true)
                        if found then return found end
                    end
                end
            end
            return nil
        end

        local scrollDeadline = tick() + C.WORLD_SCROLL_WAIT
        while tick() < scrollDeadline do
            scroll = findScroll()
            if scroll then break end
            task.wait(0.5)
        end

        if not scroll then
            Util.log("Sea 2 — World Scroll did not appear.")
            return false
        end

        -- Get the closest BasePart inside the scroll model
        local scrollPart = nil
        if scroll:IsA("BasePart") then
            scrollPart = scroll
        else
            local closest, closestDist = nil, math.huge
            for _, part in ipairs(scroll:GetDescendants()) do
                if part:IsA("BasePart") then
                    local myHRP = Util.getHRP()
                    local d = myHRP and (part.Position - myHRP.Position).Magnitude or math.huge
                    if d < closestDist then
                        closestDist = d
                        closest     = part
                    end
                end
            end
            scrollPart = closest or scroll:FindFirstChildOfClass("BasePart")
        end

        local targetPos = scrollPart and scrollPart.Position or C.SHRINE_PIVOT.Position
        Util.log("Sea 2 — approaching World Scroll...")
        Move.tweenTo(CFrame.new(targetPos), C.TWEEN_SPEED_FAST)
        task.wait(0.3)

        -- Fire prompts until scroll disappears (confirms pickup)
        local pickupDeadline = tick() + 15
        Util.log("Sea 2 — picking up scroll...")
        repeat
            fireNearbyPrompts(C.PROMPT_RADIUS)
            task.wait(0.5)
            scroll = findScroll()
        until scroll == nil or tick() > pickupDeadline

        if scroll ~= nil then
            Util.log("Sea 2 — retrying with wider radius...")
            fireNearbyPrompts(C.PROMPT_RADIUS * 3)
            task.wait(1)
        end

        Util.log("Sea 2 — Shrine complete!")
        Win:Notify({
            Title    = "Sea 2",
            Message  = "World Scroll picked up!",
            Type     = "success",
            Duration = 8,
        })
        return true
    end

    -- Geppo (Sky Walk 2) at gpoConfig.Main.geppoLevel: the Kaitun farm pauses, buys it on Coco
    -- Island, then resumes. Never starts without the 50k Peli it costs. A per-account file marks
    -- it as bought so it isn't bought again in later sessions.
    local GEPPO_PELI_COST = 50000
    local geppoNextCheck  = 0
    local geppoFile       = "gpo_geppo_" .. LocalPlayer.Name .. ".txt"

    -- the game's own flag: ReplicatedStorage.Stats<name>.Skills.skyWalk (BoolValue)
    local function ownsSkyWalk()
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Skills.skyWalk.Value
        end)
        if ok then return v == true end
        return nil -- stats not loaded / unknown
    end

    local function geppoBought()
        if State.skyWalk2Done then return true end
        local owned = ownsSkyWalk()
        if owned == nil then
            -- can't read the skill yet: fall back to the per-account file
            local ok, has = pcall(function() return isfile and isfile(geppoFile) end)
            owned = ok and has or false
        end
        if owned then
            State.skyWalk2Done = true
            getgenv().gpoConfig.Main.geppo = true
        end
        return State.skyWalk2Done
    end

    local function currentPeli()
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Stats.Peli.Value
        end)
        if ok and tonumber(v) then return tonumber(v) end
        return Util.getPelis()
    end

    -- true when it took over this loop iteration (went to buy, or tried to)
    local function tryGetGeppo(level)
        local cfg    = getgenv().gpoConfig
        local target = tonumber(cfg and cfg.Main and cfg.Main.geppoLevel) or 0
        if target <= 0 or level < target or geppoBought() or os.clock() < geppoNextCheck then
            return false
        end
        geppoNextCheck = os.clock() + 60 -- re-check at most once a minute

        local peli = currentPeli()
        if peli < GEPPO_PELI_COST then
            Util.log(("Geppo: level %d reached but only %d/%d Peli — farming until there's enough."):format(
                level, peli, GEPPO_PELI_COST))
            return false
        end

        Util.log(("Geppo: level %d, %d Peli — pausing Kaitun to buy Sky Walk 2..."):format(level, peli))
        Move.cancelTween()
        local ok, bought = pcall(Farm.travelToCocoIslandAndBuySkyWalk)
        Move.stopNoclip()
        -- the trainer remote returns nothing, so confirm with the skill flag
        if ok and bought and ownsSkyWalk() ~= nil then
            local deadline = tick() + 5
            while not ownsSkyWalk() and tick() < deadline do task.wait(0.25) end
            bought = ownsSkyWalk() == true
            if not bought then Util.log("Geppo: trainer didn't give Sky Walk (Skills.skyWalk still false).") end
        end
        if ok and bought then
            State.skyWalk2Done = true
            pcall(writefile, geppoFile, os.date("%Y-%m-%d %H:%M:%S"))
            cfg.Main.geppo = true
            Util.log("Geppo: bought, resuming Kaitun.")
            task.spawn(Webhook.geppoBought, level)
        else
            Util.log("Geppo: purchase didn't finish (" .. tostring(ok and "aborted" or bought) .. "), retrying later.")
        end
        State.travelDone = false -- take the full route back to the farm
        return true
    end

    -- Main AutoFarm state machine (FASE 1-4).
    -- Runs forever; call inside task.spawn.
    function Farm.runLoop()
        while true do
            if not Win.Flags["AutoFarm"] or State.isBuying then
                task.wait(0.2) -- off, or paused while the merchant cycle runs
            else
                local level = Util.getLevel() or 0

                if level <= 0 then
                    task.wait(1) -- HUD not loaded yet: don't pick a phase (or skip the geppo) on a bad read
                elseif tryGetGeppo(level) then
                    task.wait(1)
                -- FASE 2: Fishman Island (level 25+)
                elseif level >= C.FISHMAN_MIN_LEVEL then
                    if State.diedInFarm then
                        -- died: walk the whole route back (sea path + teleporter if we
                        -- respawned outside, then the walk from the landing to the NPCs)
                        State.diedInFarm = false
                        task.wait(1.5) -- let the new character load
                        Util.log("[Farm] died — taking the route back to the fishman...")
                        Farm.travelToFishman()
                        State.travelDone = true
                    elseif not State.travelDone then
                        Util.log("[Farm] Traveling to Fishman Island...")
                        Farm.travelToFishman()
                        State.travelDone = true
                    elseif Util.isAtFishmanIsland() then
                        State.currentCfg = FarmConfigs.fishman
                        local _, restart = Farm.runCycle(FarmConfigs.fishman, "AutoFarm")
                        if Win.Flags["AutoFarm"] and not restart then task.wait(2) end
                    else
                        Util.log("[Farm] Lost Fishman Island, re-traveling...")
                        State.travelDone = false
                        task.wait(1)
                    end

                -- FASE 1: Bandits (level 0-24)
                else
                    State.diedInFarm = false
                    State.currentCfg = FarmConfigs.bandit
                    local _, restart = Farm.runCycle(FarmConfigs.bandit, "AutoFarm")
                    if Win.Flags["AutoFarm"] and not restart then task.wait(2) end
                end
            end
        end
    end

    return Farm
end

return build

end

_MODULES["fish.lua"] = function()
-- fish.lua — Fishing module
-- Receives: ctx { C, State, Util, Move, Combat, Win,
--               RunService, FishRarities, RepStorage, LocalPlayer }
--
-- Drives the game's own rod client (ReplicatedStorage.Fishing.Assets.Client) instead of
-- faking remote calls, so the game sends Throw/Landed/Reel with valid session keys itself.

local function build(ctx)
    local C            = ctx.C
    local State        = ctx.State
    local Util         = ctx.Util
    local Move         = ctx.Move
    local Combat       = ctx.Combat
    local Win          = ctx.Win
    local RunService   = ctx.RunService
    local FishRarities = ctx.FishRarities
    local RepStorage   = ctx.RepStorage

    local Fish = {}

    -- Rod client

    -- The rod's client object (has Bobble, FishCaught, Velocity, _charge, _throw, ...)
    local clientCache = setmetatable({}, { __mode = "k" })
    local function getClient(tool)
        local c = clientCache[tool]
        if c then return c end
        for _, v in ipairs(getgc(true)) do
            if type(v) == "table" and rawget(v, "FishingBaitGui") and rawget(v, "Tool") == tool then
                clientCache[tool] = v
                return v
            end
        end
        return nil
    end

    -- Cast aim
    -- The game reads its own _G.MouseCF (getrenv()._G) when the throw fires. MouseCF is moved
    -- behind a metatable so it can be overridden only while casting.
    local aimGoal = nil
    local aimHook = nil
    local function installAimHook()
        local GG = getrenv()._G
        local mt = getmetatable(GG)
        if mt and mt == aimHook then return end
        -- keep the current mouse value (also when replacing a hook from an earlier run)
        local shadow = rawget(GG, "MouseCF")
        if shadow == nil and mt and mt.__index then
            local prevAim = aimGoal
            aimGoal = nil
            pcall(function() shadow = GG.MouseCF end)
            aimGoal = prevAim
        end
        rawset(GG, "MouseCF", nil)
        aimHook = {
            __index = function(_, k)
                if k ~= "MouseCF" then return nil end
                if aimGoal then return CFrame.new(aimGoal) end
                return shadow
            end,
            __newindex = function(t, k, v)
                if k == "MouseCF" then shadow = v else rawset(t, k, v) end
            end,
        }
        setmetatable(GG, aimHook)
    end

    -- Water finder
    -- The hook lands once it drops below Env.WaterStuff.Falls.Y without touching Islands/Ships/Env.
    -- A point is water if, looking down from above, the first surface is under the water level (sea floor).
    -- The hook leaves BobbleSpawn at dir(Goal) * 100 * charge (charge caps at 1.5s => 150), so with a
    -- full charge the launch angle can be solved so the arc lands on the water point.
    local CAST_SPEED  = 150
    local CHARGE_TIME = 1.6
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include

    local function updateRayFilter()
        local list = {}
        for _, n in ipairs({ "Islands", "Ships", "Env" }) do
            local f = workspace:FindFirstChild(n)
            if f then table.insert(list, f) end
        end
        rayParams.FilterDescendantsInstances = list
    end

    local function getWaterY()
        local env = workspace:FindFirstChild("Env")
        local falls = env and env:FindFirstChild("WaterStuff") and env.WaterStuff:FindFirstChild("Falls")
        return falls and falls.Position.Y
    end

    local function isWater(x, z, waterY)
        -- check a 6-stud margin around the point so the hook doesn't clip a shore or dock
        for _, o in ipairs({ Vector3.zero, Vector3.new(6, 0, 0), Vector3.new(-6, 0, 0), Vector3.new(0, 0, 6), Vector3.new(0, 0, -6) }) do
            local hit = workspace:Raycast(Vector3.new(x, waterY + 300, z) + o, Vector3.new(0, -600, 0), rayParams)
            if hit and hit.Position.Y > waterY - 1.5 then return false end
        end
        return true
    end

    local function solveDir(from, to, high)
        local g = workspace.Gravity
        local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
        local x, y, v2 = flat.Magnitude, to.Y - from.Y, CAST_SPEED * CAST_SPEED
        local disc = v2 * v2 - g * (g * x * x + 2 * y * v2)
        if disc < 0 or x < 1 then return nil end
        local angle = math.atan((v2 + (high and 1 or -1) * math.sqrt(disc)) / (g * x))
        return flat.Unit * math.cos(angle) + Vector3.yAxis * math.sin(angle)
    end

    local function arcClear(from, dir, to)
        local vel, g = dir * CAST_SPEED, Vector3.new(0, -workspace.Gravity, 0)
        local p, dt = from, 1 / 30
        for _ = 1, 300 do
            local np = p + vel * dt + 0.5 * g * dt * dt
            vel = vel + g * dt
            if workspace:Raycast(p, np - p, rayParams) then return false end
            if np.Y <= to.Y then
                return (Vector3.new(np.X, 0, np.Z) - Vector3.new(to.X, 0, to.Z)).Magnitude < 8
            end
            p = np
        end
        return false
    end

    local function spawnPos(tool)
        local bs = tool and tool:FindFirstChild("BobbleSpawn", true)
        if bs then return bs.WorldPosition end
        local hrp = Util.getHRP()
        return hrp and hrp.Position + Vector3.new(0, 4, 0)
    end

    -- Goal to send so the arc lands on `water` (low arc if clear, else high arc)
    local function aimAt(tool, water)
        local from = spawnPos(tool)
        if not from then return nil end
        for _, high in ipairs({ false, true }) do
            local dir = solveDir(from, water, high)
            if dir and arcClear(from, dir, water) then return from + dir * 100 end
        end
        return nil
    end

    -- Nearest reachable water point (20-90 studs), preferring where the character faces
    function Fish.findWaterGoal(tool)
        local hrp, waterY = Util.getHRP(), getWaterY()
        if not hrp or not waterY then return nil end
        updateRayFilter()
        local look = hrp.CFrame.LookVector
        local cands = {}
        for dist = 20, 90, 5 do
            for a = 0, 345, 15 do
                local d = CFrame.Angles(0, math.rad(a), 0).LookVector
                local p = hrp.Position + d * dist
                if isWater(p.X, p.Z, waterY) then
                    table.insert(cands, { pos = Vector3.new(p.X, waterY, p.Z), score = dist - d:Dot(look) * 20 })
                end
            end
        end
        table.sort(cands, function(a, b) return a.score < b.score end)
        for _, cand in ipairs(cands) do
            local goal = aimAt(tool, cand.pos)
            if goal then return goal end
        end
        return nil
    end

    -- Minigame
    -- Holding moves the bar up (Y.Scale down). The rod listens to Tool.Activated/Deactivated.
    -- Executors differ: some firesignal silently skip the rod's connection, so each method is
    -- verified (does the bar actually rise while "holding"?) and the next one is tried if not.
    -- The method that works is remembered for later casts.
    local VIM = game:GetService("VirtualInputManager")
    local HOLD_METHODS = {
        {
            name = "firesignal",
            available = function() return type(firesignal) == "function" end,
            set = function(tool, state) firesignal(state and tool.Activated or tool.Deactivated) end,
        },
        {
            name = "getconnections",
            available = function() return type(getconnections) == "function" end,
            set = function(tool, state)
                for _, conn in ipairs(getconnections(state and tool.Activated or tool.Deactivated)) do
                    local ok = pcall(function() conn:Fire() end)
                    if not ok and conn.Function then pcall(conn.Function) end
                end
            end,
        },
        {
            name = "mouse click",
            available = function() return VIM ~= nil end,
            set = function(_, state)
                local vp = workspace.CurrentCamera.ViewportSize
                VIM:SendMouseButtonEvent(vp.X / 2, vp.Y / 2, 0, state, game, 0)
            end,
        },
    }
    local holdIndex, holdConfirmed = 1, false
    local VERIFY_TIME = 0.6 -- seconds of holding with no rise before a method counts as broken

    local function nextHoldMethod()
        for i = holdIndex + 1, #HOLD_METHODS do
            if HOLD_METHODS[i].available() then holdIndex = i; return true end
        end
        return false
    end

    local function playMinigame(tool, c)
        local gui = ctx.LocalPlayer:FindFirstChild("PlayerGui")
        local bill
        local deadline = tick() + 3
        repeat
            bill = gui and gui:FindFirstChild("FishingUIBill")
            if not bill then task.wait() end
        until bill or tick() > deadline
        if not bill then return false end

        local bar, goal = bill.Frame.Player, bill.Frame.Goal
        if not HOLD_METHODS[holdIndex].available() then nextHoldMethod() end

        local holding = false
        -- Verifying the current method, in screen pixels (works whether the bar moves by Scale or
        -- Offset). The bar has momentum, so the test is acceleration: while held, its per-frame
        -- movement must turn more upward than it was just before the press.
        local function barY() return bar.AbsolutePosition.Y end
        local prevY = barY()
        local frameDy = 0          -- last per-frame movement (pixels, + = down)
        local pressAt, dyAtPress, rose
        local function setHold(state)
            if holding == state then return end
            holding = state
            local m = HOLD_METHODS[holdIndex]
            local ok, err = pcall(m.set, tool, state)
            if not ok then Util.log(("fish minigame: %s errored (%s)"):format(m.name, tostring(err))) end
            if state then
                pressAt, dyAtPress, rose = os.clock(), frameDy, false
            else
                pressAt = nil
            end
        end

        local reelDeadline = tick() + C.REEL_TIMEOUT
        while Win.Flags["AutoFish"] and not State.isBuying and c.Bobble and bill.Parent
            and tick() < reelDeadline do
            -- verify: while holding, the bar must rise (Y.Scale goes down) unless it's already at the top
            local y = barY()
            frameDy = y - prevY
            prevY = y
            if holding and not holdConfirmed and pressAt then
                if frameDy < dyAtPress - 0.5 or frameDy < -0.5 then rose = true end
                local topY = bill.Frame.AbsolutePosition.Y
                local atTop = y <= topY + 2
                if rose then
                    holdConfirmed = true
                    Util.log("fish minigame: using " .. HOLD_METHODS[holdIndex].name)
                elseif not atTop and os.clock() - pressAt >= VERIFY_TIME then
                    local failed = HOLD_METHODS[holdIndex].name
                    setHold(false)
                    if nextHoldMethod() then
                        Util.log(("fish minigame: %s had no effect, trying %s"):format(failed, HOLD_METHODS[holdIndex].name))
                    else
                        -- none passed the test: keep playing with the first one instead of giving up
                        holdIndex, holdConfirmed = 1, true
                        for i, m in ipairs(HOLD_METHODS) do
                            if m.available() then holdIndex = i; break end
                        end
                        Util.log("fish minigame: couldn't verify any input method, keeping " .. HOLD_METHODS[holdIndex].name)
                    end
                end
            end
            local predicted = bar.Position.Y.Scale + (c.Velocity or 0) / (c.Max or 2) * 0.25
            setHold(goal.Position.Y.Scale < predicted)
            RunService.RenderStepped:Wait()
        end
        setHold(false)
        return (c.FishTime or 0) >= (c.MaxFishTime or 7.5) - 0.01
    end

    -- Helpers

    local function isCraftTargetEnabled(name)
        if type(State.craftTargets) == "table" then
            if State.craftTargets[name] == true then return true end
            for _, v in pairs(State.craftTargets) do
                if v == name then return true end
            end
        end
        return false
    end

    local function waitUntil(cond, timeout)
        local deadline = tick() + timeout
        while not cond() do
            if tick() > deadline or not Win.Flags["AutoFish"] or State.isBuying then return false end
            task.wait()
        end
        return true
    end

    function Fish.equipRod()
        local tool, equipped = Combat.findTool(State.fishRod)
        if not tool then
            Util.log("rod '" .. State.fishRod .. "' not found")
            return nil
        end
        if equipped then return tool end
        local hum = Util.getHumanoid()
        if not hum then return nil end
        Util.try(function() hum:EquipTool(tool) end)
        task.wait(0.4)
        tool, equipped = Combat.findTool(State.fishRod)
        return equipped and tool or nil
    end

    -- Reels the hook back through the game's client (sends HookReturning + Cancel with valid keys)
    function Fish.cancel()
        aimGoal = nil
        local tool = Combat.findTool(State.fishRod)
        local c = tool and clientCache[tool]
        if c and c.Bobble then
            Util.try(function() c:_reelBack() end)
        end
    end

    -- Bait upkeep (upgrade / buy / craft)

    local function upkeep()
        -- Auto Upgrade Bait: switch to the rarest bait currently in inventory
        if State.autoUpgradeBait then
            local inv       = Util.getInventory()
            local baitOrder = {
                { name = "Legendary Fish Bait", rank = 3 },
                { name = "Rare Fish Bait",      rank = 2 },
                { name = "Common Fish Bait",    rank = 1 },
            }
            local currentRank = 0
            for _, b in ipairs(baitOrder) do
                if State.fishBait == b.name then currentRank = b.rank; break end
            end
            for _, b in ipairs(baitOrder) do
                if b.rank > currentRank and (inv[b.name] or 0) > 0 then
                    State.fishBait = b.name
                    Util.log("Auto Upgrade Bait: switched to " .. b.name)
                    break
                end
            end
        end

        -- Auto Buy Common Bait
        if Win.Flags["AutoBuyCommonBait"] and Util.getBaitCount("Common Fish Bait") < 1 then
            Util.log("Auto Buy: buying Common Fish Bait...")
            local saveCF = Util.getHRP() and Util.getHRP().CFrame
            Move.tweenTo(CFrame.new(State.buyBaitPos), C.TWEEN_SPEED_FAST); task.wait(1)
            Util.try(function()
                local ShopEvent = RepStorage.Events:WaitForChild("Shop", 3)
                local buyItem   = workspace:WaitForChild("BuyableItems", 3)
                    :WaitForChild("Common Fish Bait", 3)
                if ShopEvent and buyItem then ShopEvent:InvokeServer(buyItem, 37) end
            end)
            task.wait(1.5)
            if saveCF then Move.tweenTo(saveCF, C.TWEEN_SPEED_FAST); task.wait(1) end
        end

        -- Auto Craft
        if Win.Flags["AutoCraft"] then
            local inv      = Util.getInventory()
            local craftMap = {
                ["Common Fish Bait"]    = { rarity = "Common",    divisor = 1 },
                ["Rare Fish Bait"]      = { rarity = "Rare",      divisor = 2 },
                ["Legendary Fish Bait"] = { rarity = "Legendary", divisor = 1 },
            }
            local craftTasks = {}
            for baitName, info in pairs(craftMap) do
                if isCraftTargetEnabled(baitName) then
                    for fishName, qty in pairs(inv) do
                        if FishRarities[fishName] == info.rarity then
                            local count = math.floor(qty / info.divisor)
                            if count >= 1 then
                                table.insert(craftTasks, {
                                    bait   = baitName,
                                    fish   = fishName,
                                    rarity = info.rarity,
                                    count  = count,
                                })
                            end
                        end
                    end
                end
            end
            if #craftTasks > 0 then
                Util.log("Auto Craft: " .. #craftTasks .. " tasks pending.")
                local saveCF = Util.getHRP() and Util.getHRP().CFrame
                Move.tweenTo(CFrame.new(State.craftNpcPos), C.TWEEN_SPEED_FAST); task.wait(1)
                Util.try(function()
                    local CraftRemote = RepStorage:WaitForChild("CraftingRemote", 3)
                    if CraftRemote then
                        for _, t in ipairs(craftTasks) do
                            local extra = {}
                            if     t.rarity == "Common"    then extra = { ["Common Fish"] = t.fish }
                            elseif t.rarity == "Rare"      then extra = { [t.fish] = "Rare Fish" }
                            elseif t.rarity == "Legendary" then extra = { ["Legendary Fish"] = t.fish }
                            end
                            CraftRemote:InvokeServer({
                                BlueprintItem = t.bait,
                                Method        = "Craft",
                                ExtraData     = extra,
                                Count         = t.count,
                            })
                            Util.log("Crafted " .. t.count .. "x " .. t.bait)
                            task.wait(0.3)
                        end
                    end
                end)
                task.wait(1.5)
                if saveCF then Move.tweenTo(saveCF, C.TWEEN_SPEED_FAST); task.wait(1) end
            end
        end
    end

    -- Cycle: one cast → bite → minigame

    function Fish.cycle()
        -- paused while the merchant cycle runs (it moves the character)
        if State.isBuying then
            Fish.cancel()
            while State.isBuying and Win.Flags["AutoFish"] do task.wait(0.5) end
            return
        end
        upkeep()
        if not Win.Flags["AutoFish"] then return end

        local tool = Fish.equipRod()
        if not tool then task.wait(2); return end
        local c = getClient(tool)
        if not c then
            Util.log("rod client not ready, retrying...")
            task.wait(1); return
        end
        if c.Bobble or not c.Debounce or c.IsCharging then task.wait(0.25); return end

        if State.fishBait then c.SelectedBait = State.fishBait end

        local goal = Fish.findWaterGoal(tool)
        if not goal then
            Util.log("no reachable water nearby")
            task.wait(3); return
        end

        -- Cast: full charge so the cast speed matches the solved arc
        installAimHook()
        aimGoal = goal
        c:_charge()
        if not c.IsCharging then
            aimGoal = nil
            Util.log("cannot cast (no bait selected/left?)")
            task.wait(2); return
        end
        task.wait(CHARGE_TIME)
        c:_throw()
        local cast = waitUntil(function() return c.Bobble ~= nil end, 6)
        aimGoal = nil
        if not cast then
            Util.log("hook not spawned, retrying...")
            task.wait(1); return
        end
        Util.log("cast with " .. tostring(c.SelectedBait))

        -- Bite: the server sets the hook's Caught attribute (10-15s)
        if not waitUntil(function() return c.FishCaught or not c.Bobble end, C.BITE_TIMEOUT) then
            if Win.Flags["AutoFish"] then Util.log("no bite in " .. C.BITE_TIMEOUT .. "s, recasting...") end
            Fish.cancel(); task.wait(0.5); return
        end
        if not c.FishCaught then
            Util.log("hook lost, recasting...")
            task.wait(0.5); return
        end

        Util.log("bite detected, reeling...")
        if playMinigame(tool, c) then
            Util.log("fish caught!")
        elseif Win.Flags["AutoFish"] then
            Util.log("fish escaped")
        end

        waitUntil(function() return not c.Bobble and c.Debounce end, 5)
        task.wait(0.5)
    end

    return Fish
end

return build

end

_MODULES["merchant.lua"] = function()
-- merchant.lua — Traveling Merchant module
-- Receives: ctx { C, State, Util, Move, Webhook, Win, MerchantRemote, LocalPlayer, HttpService, RepStorage }
--
-- Game protocol (TravelingMerchentRemote, a RemoteFunction):
--   "OpenShop"                    -> true | false, errMsg, retryAfterSeconds
--       on success the server puts PlayerGui.MerchentShop with attributes:
--       Prices (JSON {item = {price, priceType, remaining, maxStock, rarity}}),
--       Seed, SessionKey, NextRefresh (server time when the stock refreshes)
--   (itemName, Seed, SessionKey)  -> true, remainingStock | false, ?, errMsg
--   ("Close", Seed, SessionKey)
-- The npc is workspace.NPCs["Traveling Merchant"] (only streamed in when close) and its
-- position is ReplicatedStorage.CompassGuider["Traveling Merchant"] (0,0,0 when absent).

local function build(ctx)
    local C              = ctx.C
    local State          = ctx.State
    local Util           = ctx.Util
    local Move           = ctx.Move
    local Webhook        = ctx.Webhook
    local Win            = ctx.Win
    local MerchantRemote = ctx.MerchantRemote
    local LocalPlayer    = ctx.LocalPlayer
    local HttpService    = ctx.HttpService

    local Merchant = {}

    local NPC_NAME      = "Traveling Merchant"
    local GUI_NAME      = "MerchentShop" -- game typo is intentional
    local OPEN_RANGE    = 5
    local APPROACH_DIST = 40  -- studs: land this short of the npc and WALK the rest in

    -- true for the whole cycle (manual or auto), used to let a walk get cancelled from outside
    local function activeBuying() return State.isBuying == true end

    local function getPeli()
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Stats.Peli.Value
        end)
        return ok and tonumber(v) or 0
    end

    local function getBuyList()
        local cfg = getgenv().gpoConfig
        local list = cfg and cfg.Merchant and cfg.Merchant.itemsToBuy
        return type(list) == "table" and list or {}
    end

    function Merchant.isNew(pos)
        return pos and pos ~= Vector3.zero and pos ~= State.lastMerchantPos
    end

    -- Remove any stale shop gui (left from an earlier session)
    local function closeShop(shop)
        shop = shop or LocalPlayer.PlayerGui:FindFirstChild(GUI_NAME)
        if not shop then return end
        local seed, key = shop:GetAttribute("Seed"), shop:GetAttribute("SessionKey")
        pcall(function() MerchantRemote:InvokeServer("Close", seed, key) end)
        pcall(function() shop:Destroy() end)
    end

    -- same geppo + tween route as "Tween to Island", at 500 studs up (leaves Fishman Island first)
    local MERCHANT_LIFT = 500
    local function travelTo(goal)
        if Util.isAtFishmanIsland() and ctx.Farm and ctx.Farm.exitFishman then
            ctx.Farm.exitFishman()
        end
        Move.tweenIsland(goal, C.TWEEN_SPEED_MERCHANT, activeBuying, MERCHANT_LIFT)
    end

    -- Go next to the npc: tween over structures to APPROACH_DIST studs short of it, then WALK the
    -- rest in (same movement as the Trick or Treat doors — PathfindingService + Humanoid:Move,
    -- normal walk animation, real collisions) instead of landing right on top of it.
    local function reachNPC(pos)
        local groundPos = Move.groundAt(pos)
        local landPos   = groundPos
        local hrp       = Util.getHRP()
        if hrp then
            local dir = (groundPos - hrp.Position) * Vector3.new(1, 0, 1)
            if dir.Magnitude > APPROACH_DIST then
                landPos = Move.groundAt(groundPos - dir.Unit * APPROACH_DIST)
            end
        end
        travelTo(landPos + Vector3.new(0, 3, 0))

        local npcs = workspace:FindFirstChild("NPCs")
        local npc
        local deadline = tick() + 10
        repeat
            npc = npcs and npcs:FindFirstChild(NPC_NAME)
            if not npc then task.wait(0.25) end
        until npc or tick() > deadline
        local torso = npc and (npc:FindFirstChild("LowerTorso") or npc:FindFirstChild("HumanoidRootPart"))
        if not torso then return false end

        Move.walkTo(Move.groundAt(torso.Position), OPEN_RANGE - 1, activeBuying, C.TWEEN_SPEED_NORMAL)
        return true
    end

    -- OpenShop with the game's own retry rules; returns the shop gui or nil
    local function openShop()
        closeShop()
        local errMsg
        for attempt = 1, 3 do
            local ok, res, msg, retryAfter = pcall(function()
                return MerchantRemote:InvokeServer("OpenShop")
            end)
            if ok and res == true then break end
            if ok and type(msg) == "string" then errMsg = msg end
            if not ok or type(retryAfter) ~= "number" or attempt == 3 then
                Util.log("merchant: OpenShop failed — " .. tostring(errMsg or res))
                return nil
            end
            task.wait(math.clamp(retryAfter, 0.5, 5))
        end

        local deadline = tick() + 8
        while tick() < deadline do
            local s = LocalPlayer.PlayerGui:FindFirstChild(GUI_NAME)
            if s and s:GetAttribute("Prices") and s:GetAttribute("SessionKey") then return s end
            task.wait(0.2)
        end
        Util.log("merchant: shop gui did not arrive.")
        return nil
    end

    local function readShop(shop)
        local ok, prices = pcall(function() return HttpService:JSONDecode(shop:GetAttribute("Prices")) end)
        return {
            prices      = ok and prices or {},
            seed        = shop:GetAttribute("Seed"),
            key         = shop:GetAttribute("SessionKey"),
            nextRefresh = shop:GetAttribute("NextRefresh"),
        }
    end

    -- Buy every unit of `name` we can afford. Returns units bought.
    local function buyItem(session, name)
        local info = session.prices[name]
        if not info or (info.remaining or 0) <= 0 then
            Util.log(("merchant: '%s' not in stock."):format(name))
            return 0
        end
        local bought = 0
        while (info.remaining or 0) > 0 and activeBuying() do
            if session.nextRefresh and workspace:GetServerTimeNow() >= session.nextRefresh - 1 then
                Util.log("merchant: shop is refreshing, session expired.")
                break
            end
            if info.priceType == "Peli" and getPeli() < info.price then
                Util.log(("merchant: not enough Peli for '%s' (%d needed)."):format(name, info.price))
                break
            end
            local ok, res, remaining, errMsg = pcall(function()
                return MerchantRemote:InvokeServer(name, session.seed, session.key)
            end)
            if not ok or res ~= true then
                Util.log(("merchant: buying '%s' failed — %s"):format(name, tostring(errMsg or res)))
                break
            end
            bought += 1
            info.remaining = tonumber(remaining) or (info.remaining - 1)
            Win:Notify({
                Title    = "Merchant",
                Message  = ("Bought %s (%d left)"):format(name, info.remaining),
                Type     = "success",
                Duration = 3,
            })
            task.wait(0.5)
        end
        if bought > 0 then
            task.spawn(Webhook.send,
                "Merchant — Purchased",
                ("> Bought **%d x %s** at %d %s each."):format(bought, name, info.price, info.priceType or "Peli"),
                C.WEBHOOK_COLOR_MERCHANT,
                {
                    { name = "Item",       value = "`" .. name .. "`",   inline = true },
                    { name = "Quantity",   value = "`" .. bought .. "x`", inline = true },
                    { name = "Unit Price", value = "`" .. info.price .. "`", inline = true },
                }
            )
        end
        return bought
    end

    local function sendInventory(session)
        local items = {}
        for name, info in pairs(session.prices) do
            if (info.remaining or 0) > 0 then
                table.insert(items, {
                    name   = name,
                    value  = ("`%dx @ %d %s`"):format(info.remaining, info.price, info.priceType or "Peli"),
                    inline = true,
                })
            end
        end
        if #items > 0 then
            task.spawn(Webhook.send, "Merchant — Inventory", "> Items available in this shop:",
                C.WEBHOOK_COLOR_MERCHANT, items)
        end
    end

    -- Re-run when the stock refreshes, if the merchant is still at the same spot
    local function scheduleRefresh(pos, nextRefresh)
        if not nextRefresh then return end
        local waitFor = nextRefresh - workspace:GetServerTimeNow() + 3
        if waitFor <= 0 then return end
        task.delay(waitFor, function()
            if Win.Flags["AutoMerchant"] and State.merchantPos == pos then
                Util.log("merchant: stock refreshed, checking again...")
                Merchant.cycle(pos, true)
            end
        end)
    end

    local function run(pos)
        Util.log("merchant at: " .. tostring(pos))
        Win:Notify({ Title = "Merchant", Message = "traveling...", Type = "success", Duration = 5 })

        if not reachNPC(pos) then
            Util.log("merchant: npc not found at the compass position.")
            return
        end

        local shop = openShop()
        if not shop then
            Win:Notify({ Title = "Merchant", Message = "shop didn't open", Type = "error" })
            return
        end
        local session = readShop(shop)

        local count = 0
        for _ in pairs(session.prices) do count += 1 end
        Util.log("merchant: " .. count .. " items in shop.")

        local total = 0
        for _, name in ipairs(getBuyList()) do
            if not activeBuying() then break end
            if name ~= "" then total += buyItem(session, name) end
        end
        Util.log(("merchant: done, %d bought."):format(total))

        sendInventory(session)
        closeShop(shop)
        scheduleRefresh(pos, session.nextRefresh)
    end

    -- force = true re-runs at a known position (stock refresh)
    function Merchant.cycle(pos, force)
        if State.isBuying then
            Util.log("merchant: cycle already running.")
            return
        end
        if not force and not Merchant.isNew(pos) then return end
        State.isBuying        = true -- Farm/Fish pause while this is set
        State.lastMerchantPos = pos
        State.merchantPos     = pos

        task.wait(0.5) -- let Farm/Fish notice and stop moving the character
        local saveCF = Util.getHRP() and Util.getHRP().CFrame
        local ok, err = pcall(run, pos)
        if not ok then Util.log("merchant error: " .. tostring(err)) end

        -- Fish: go back to the fishing spot. Farm takes its own route back
        -- (the farm loop notices it left Fishman Island and re-travels the full path).
        if saveCF and Win.Flags["AutoFish"] and not Win.Flags["AutoFarm"] then
            pcall(travelTo, saveCF.Position)
        end
        State.isBuying = false
    end

    return Merchant
end

return build

end

_MODULES["move.lua"] = function()
-- move.lua — Movement module
-- Receives: ctx { C, State, Util, RunService, TweenService, LocalPlayer }

local function build(ctx)
    local C            = ctx.C
    local State        = ctx.State
    local Util         = ctx.Util
    local RunService   = ctx.RunService
    local TweenService = ctx.TweenService
    local LocalPlayer  = ctx.LocalPlayer

    local Move = {}

    -- Create a LinearVelocity (+ Attachment) to lock character physics during tweens.
    local function makeMover(hrp)
        local att = Instance.new("Attachment")
        att.Name   = "GPO_MoverAtt"
        att.Parent = hrp
        local lv = Instance.new("LinearVelocity")
        lv.Name           = "GPO_Mover"
        lv.Attachment0    = att
        lv.MaxForce       = math.huge
        lv.VectorVelocity = Vector3.zero
        lv.RelativeTo     = Enum.ActuatorRelativeTo.World
        lv.Parent         = hrp
        return lv, att
    end

    local function destroyMover()
        if State.mover  then Util.try(function() State.mover:Destroy()   end) end
        if State.moverAtt then Util.try(function() State.moverAtt:Destroy() end) end
        State.mover    = nil
        State.moverAtt = nil
        -- sweep leftovers (e.g. from a previous character / race conditions)
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then
            for _, d in ipairs(hrp:GetChildren()) do
                if d.Name == "GPO_Mover" or d.Name == "GPO_MoverAtt" then
                    Util.try(function() d:Destroy() end)
                end
            end
        end
    end

    -- Stop the game's "Fall" animation while we hover (the mover keeps vy = 0,
    -- but the game still plays Freefall/Fall because there is no floor).
    function Move.stopNoFall()
        if State.noFallConn then
            State.noFallConn:Disconnect()
            State.noFallConn = nil
        end
        local hum = State.noFallHum or Util.getHumanoid()
        if hum then
            Util.try(function()
                hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
                hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
            end)
        end
        State.noFallHum = nil
    end

    function Move.startNoFall()
        Move.stopNoFall()
        local hum = Util.getHumanoid()
        if not hum then return end
        State.noFallHum = hum
        Util.try(function()
            hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
            hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        end)
        State.noFallConn = RunService.RenderStepped:Connect(function()
            local h = Util.getHumanoid()
            if not h then return end
            for _, t in ipairs(h:GetPlayingAnimationTracks()) do
                local a = t.Animation
                if a and string.find(a.AnimationId, C.FALL_ANIM_ID, 1, true) then
                    t:Stop(0)
                end
            end
        end)
    end

    function Move.setup()
        destroyMover()
        local hrp = Util.getHRP()
        if hrp then
            State.mover, State.moverAtt = makeMover(hrp)
        end
        Move.startNoFall()
    end

    function Move.clear()
        destroyMover()
        Move.stopNoFall()
    end

    -- Stop EVERYTHING movement-related that the farm turns on.
    function Move.stopAll()
        Move.cancelTween()
        Move.stopAntiDrop()
        Move.clear()
        local hrp = Util.getHRP()
        if hrp then
            Util.try(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
        end
    end

    -- Wait for a tween to finish or be externally cancelled.
    -- Returns true if completed normally, false if cancelled.
    local function waitTween(tween)
        local done = false
        local conn
        conn = tween.Completed:Connect(function()
            done = true
            conn:Disconnect()
        end)
        while not done and State.activeTween == tween do
            task.wait(0.05)
        end
        if not done then
            Util.try(function() tween:Cancel() end)
            conn:Disconnect()
        end
        return done
    end

    -- Cosmetic only: the character's POSITION during a tween is fully owned by TweenService —
    -- this never steers it anywhere. It just repeatedly fires the real Geppo ability (the same
    -- "real M1" trick as Combat.getM1: call the game's own InputCallbacks callback instead of
    -- faking the remote) so its jump animation + VFX + the Sky Walk2 server call play, instead of
    -- the character looking stiff while it's CFrame-tweened. The existing LinearVelocity mover
    -- (0 velocity, infinite force — set up for exactly this reason) cancels the actual velocity
    -- Geppo applies, so it plays the animation without actually moving the character off the
    -- tween's path.
    local function getGeppo()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local mod = bp and bp:FindFirstChild("InputCallbacks")
        if not mod then return nil end
        local ok, ic = pcall(require, mod)
        if ok and type(ic) == "table" and ic.Callbacks and ic.Callbacks.Geppo
            and type(ic.Callbacks.Geppo.PC_Activate) == "function" then
            return ic.Callbacks.Geppo
        end
        return nil
    end

    local heightRay = RaycastParams.new()
    heightRay.FilterType = Enum.RaycastFilterType.Include

    -- distance above the ground under p; groundAt only looks 200 studs down, so it can't see the floor from high up
    function Move.heightAboveGround(p)
        local list = {}
        for _, n in ipairs({ "Islands", "Ships", "Env" }) do
            local f = workspace:FindFirstChild(n)
            if f then table.insert(list, f) end
        end
        heightRay.FilterDescendantsInstances = list
        local hit = workspace:Raycast(p, Vector3.new(0, -6000, 0), heightRay)
        return hit and (p.Y - hit.Position.Y) or math.huge
    end

    local function startGeppoPulse(hrp, interval)
        local geppo = getGeppo()
        local hum   = Util.getHumanoid()
        if not geppo or not hum then return function() end end
        local running = true
        task.spawn(function()
            while running do
                -- re-read the character every cycle: a stale hrp/humanoid stops the pulse for good
                local cur = Util.getHRP()
                local h   = Util.getHumanoid()
                local g   = getGeppo() or geppo
                local aboveGround = cur and Move.heightAboveGround(cur.Position) or 0
                if cur and h and running and aboveGround > 10 then
                    local dir = Vector3.zero -- cosmetic only, no need to aim it anywhere
                    local ok, err = pcall(function()
                        -- the ability's input is edge-triggered (arm on the 1st press, fire on
                        -- the 2nd), and MoveDirection decays between calls, so it is reasserted
                        -- right before each one rather than once before both
                        h:Move(dir, false)
                        g:PC_Activate()
                        task.wait(0.03)
                        if not running then return end
                        h:Move(dir, false)
                        g:PC_Activate()
                    end)
                    if not ok then Util.log("geppo pulse error: " .. tostring(err)) end
                end
                task.wait(interval or 1.5)
            end
        end)
        return function() running = false end
    end

    -- Returns true if the tween ran to completion, false if externally cancelled.
    local function tweenRaw(hrp, targetCFrame, speed)
        if State.activeTween then
            Util.try(function() State.activeTween:Cancel() end)
        end
        local dist     = (hrp.Position - targetCFrame.Position).Magnitude
        local duration = math.max(dist / (speed or C.TWEEN_SPEED_NORMAL), 0.05)
        local tween    = TweenService:Create(hrp,
            TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = targetCFrame })
        State.activeTween = tween
        -- tweenIsland runs its own pulse for the whole flight, so skip the per-tween one
        local stopGeppoPulse = State.geppoHold and function() end or startGeppoPulse(hrp)
        tween:Play()
        local completed = waitTween(tween)
        stopGeppoPulse()
        if State.activeTween == tween then State.activeTween = nil end
        return completed
    end

    function Move.cancelTween()
        if State.activeTween then
            Util.try(function() State.activeTween:Cancel() end)
            State.activeTween = nil
        end
    end

    -- Find the first obstacle between fromPos and targetPos using 3 parallel rays.
    local function findObstacle(fromPos, targetPos)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local char = LocalPlayer.Character
        if char then params.FilterDescendantsInstances = { char } end

        local offsets = { Vector3.new(0, 0, 0), Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0) }
        for _, off in ipairs(offsets) do
            local origin = fromPos + Vector3.new(0, 2, 0) + off
            local dir    = targetPos - origin
            if dir.Magnitude >= 1 then
                local hit = workspace:Raycast(origin, dir.Unit * dir.Magnitude, params)
                if hit then return hit end
            end
        end
        return nil
    end

    -- Tween to target, arcing over obstacles when geppo mode is enabled.
    local function tweenSmart(hrp, targetCFrame, speed)
        local targetPos = targetCFrame.Position
        local maxSteps  = 10

        for _ = 1, maxSteps do
            local hit = findObstacle(hrp.Position, targetPos)
            if not hit then break end

            local topY = hit.Position.Y
            if hit.Instance:IsA("BasePart") then
                topY = hit.Instance.Position.Y + hit.Instance.Size.Y / 2
            end
            local arcHeight = math.max(topY + 15, hrp.Position.Y + 20)
            local arcCFrame = CFrame.new(hit.Position.X, arcHeight, hit.Position.Z)

            local ok = tweenRaw(hrp, arcCFrame, speed)
            if not ok then return end  -- externally cancelled during arc
        end

        tweenRaw(hrp, targetCFrame, speed)
    end

    -- Plain tween: no obstacle arcs (geppo) and it never re-creates the mover,
    -- so a stale caller cannot leave the character frozen in the air after a stop.
    -- Returns true if the tween completed, false if cancelled / no HRP / no mover.
    function Move.tweenDirect(targetCFrame, speed)
        local hrp = Util.getHRP()
        if not hrp or not State.mover then return false end
        return tweenRaw(hrp, targetCFrame, speed)
    end

    function Move.tweenTo(targetCFrame, speed)
        local hrp = Util.getHRP()
        if not hrp then return end
        if not State.mover then Move.setup() end

        if getgenv().gpoConfig and getgenv().gpoConfig.Main.geppo == true then
            tweenSmart(hrp, targetCFrame, speed)
        else
            tweenRaw(hrp, targetCFrame, speed)
        end
    end

    -- Walk like a player: a PathfindingService route followed with Humanoid:Move every frame
    -- (jumps where the path needs it, real collisions — no tween, no noclip). Humanoid:Move is
    -- what the game's own input does, so it sets MoveDirection and GPO's Animate plays its walk
    -- animation (Humanoid:MoveTo leaves MoveDirection at 0, so the character slides).
    -- The LinearVelocity mover must be gone or it pins the character, so it is removed first.
    -- `speed` (optional) is the WalkSpeed used while walking; the game's normal one is put back after.
    -- Returns true when within `reach` studs of the goal.
    local PathfindingService = game:GetService("PathfindingService")

    local function walkPath(goal, reach, active, speed)
        for _ = 1, 3 do -- recompute the path if we get stuck
            local hrp, hum = Util.getHRP(), Util.getHumanoid()
            if not (hrp and hum) or not active() then return false end
            if (hrp.Position - goal).Magnitude <= reach then return true end

            local path = PathfindingService:CreatePath({
                AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6,
            })
            local ok = pcall(function() path:ComputeAsync(hrp.Position, goal) end)
            local waypoints = (ok and path.Status == Enum.PathStatus.Success) and path:GetWaypoints()
                or { { Position = goal, Action = Enum.PathWaypointAction.Walk } } -- no path: straight

            local stuck = false
            for i, wp in ipairs(waypoints) do
                if i > 1 or #waypoints == 1 then
                    if not active() then return false end
                    -- the game resets WalkSpeed (e.g. after a door scene), so set it every leg
                    if speed then hum.WalkSpeed = speed end
                    if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
                    local dist  = (hrp.Position - wp.Position).Magnitude
                    local limit = os.clock() + dist / math.max(speed or hum.WalkSpeed, 1) + 1.5
                    while true do
                        local flat = (wp.Position - hrp.Position) * Vector3.new(1, 0, 1)
                        if flat.Magnitude <= 2 then break end
                        if os.clock() > limit or not active() then stuck = true; break end
                        -- the game resets WalkSpeed (e.g. 0 then 16 around a door scene)
                        if speed and hum.WalkSpeed ~= speed and hum.WalkSpeed > 0 then hum.WalkSpeed = speed end
                        hum:Move(flat.Unit, false) -- world-space direction, like holding a key
                        -- Move only counts when called in RenderStepped (before physics), where the
                        -- game's own controls run; from Heartbeat/Stepped it is ignored
                        RunService.RenderStepped:Wait()
                    end
                    if stuck then break end
                end
            end
            if not stuck then
                hrp = Util.getHRP()
                return hrp ~= nil and (hrp.Position - goal).Magnitude <= reach + 2
            end
            hum.Jump = true -- try to get unstuck, then recompute
            task.wait(0.3)
        end
        return false
    end

    function Move.walkTo(goal, reach, isActive, speed)
        reach = reach or 3
        local function active() return not isActive or isActive() end
        Move.cancelTween()
        Move.clear() -- remove mover + no-fall so the humanoid can walk

        local reached = walkPath(goal, reach, active, speed)
        Move.stopWalking(speed)
        return reached
    end

    -- Stop walking and, if WalkSpeed is still our custom `speed`, put the game's normal one back.
    -- (Remembering the speed from before the walk isn't safe: the game may have it at 0 right
    -- then, during a door scene, which would leave us stuck at the custom speed.)
    function Move.stopWalking(speed)
        local hum = Util.getHumanoid()
        if not hum then return end
        hum:Move(Vector3.zero, false)
        if speed and hum.WalkSpeed == speed then
            hum.WalkSpeed = game:GetService("StarterPlayer").CharacterWalkSpeed
        end
    end

    local TP_STEP = 35
    local TP_LIFT = 100
    local ISLAND_LIFT = 200 -- altitude above the island goal for the tween route

    function Move.geppoFire()
        local geppo = getGeppo()
        local hum   = Util.getHumanoid()
        if not geppo or not hum then return false end
        hum:Move(Vector3.zero, false)
        pcall(function() geppo:PC_Activate() end)
        task.wait(0.03)
        hum:Move(Vector3.zero, false)
        pcall(function() geppo:PC_Activate() end)
        task.wait(0.05)
        return true
    end

    -- BodyForce that cancels gravity on the character, so it hovers instead of falling
    local function holdAir(hrp)
        local bf = Instance.new("BodyForce")
        bf.Name  = "GPO_Hold"
        bf.Force = Vector3.new(0, workspace.Gravity * hrp.AssemblyMass, 0)
        bf.Parent = hrp
        return function() Util.try(function() bf:Destroy() end) end
    end

    -- geppo, TP up `lift` (default ISLAND_LIFT), then a straight tween to `lift` studs above the goal and down onto it
    function Move.tweenIsland(goal, speed, isActive, lift)
        local function active() return not isActive or isActive() end
        local height = lift or ISLAND_LIFT
        Move.setup()
        local hrp = Util.getHRP()
        if not hrp then return end
        local release = holdAir(hrp)
        Move.geppoFire()
        hrp = Util.getHRP()
        if hrp and active() then
            -- Geppo pulses for the whole flight: up, across, and until the final drop
            State.geppoHold = true
            local stopPulse = startGeppoPulse(hrp, 0.5)
            hrp.CFrame = CFrame.new(hrp.Position.X, hrp.Position.Y + height, hrp.Position.Z) * hrp.CFrame.Rotation
            task.wait(0.05)
            if active() then Move.tweenTo(CFrame.new(goal.X, goal.Y + height, goal.Z), speed) end
            stopPulse()
            State.geppoHold = false
            if active() then
                Move.geppoFire()
                hrp = Util.getHRP()
                if hrp then hrp.CFrame = CFrame.new(goal) * hrp.CFrame.Rotation end
            end
        end
        release()
    end

    -- TP-only route: geppo + TP up, then 35-stud horizontal TPs spaced 0.5 s, geppo + TP down
    function Move.tpTravel(goal, isActive)
        local function active() return not isActive or isActive() end
        Move.cancelTween()
        local hrp = Util.getHRP()
        if not hrp then return end
        local release = holdAir(hrp)
        Move.geppoFire()
        hrp = Util.getHRP()
        if hrp then
            local cruiseY = math.max(hrp.Position.Y, goal.Y) + TP_LIFT
            hrp.CFrame = CFrame.new(hrp.Position.X, cruiseY, hrp.Position.Z) * hrp.CFrame.Rotation
            task.wait(0.5)
            while active() do
                hrp = Util.getHRP()
                if not hrp then break end
                local flat = Vector3.new(goal.X - hrp.Position.X, 0, goal.Z - hrp.Position.Z)
                if flat.Magnitude <= TP_STEP then break end
                Move.geppoFire()
                hrp = Util.getHRP()
                if not hrp then break end
                local step = hrp.Position + flat.Unit * TP_STEP
                hrp.CFrame = CFrame.new(step.X, cruiseY, step.Z) * hrp.CFrame.Rotation
                task.wait(0.5)
            end
            if active() then
                Move.geppoFire()
                hrp = Util.getHRP()
                if hrp then hrp.CFrame = CFrame.new(goal) * hrp.CFrame.Rotation end
            end
        end
        release()
    end

    -- Long-distance travel over structures: rise straight up, fly in SEGMENT-long legs, then drop
    -- straight down onto the goal. The map streams in, so far islands are not loaded yet: each
    -- leg first asks the game to stream that area, then measures what is under it.
    local CRUISE_MARGIN = 25   -- studs above the highest thing under the route
    local SAMPLE_STEP   = 20   -- studs between height samples along a leg
    local SEGMENT       = 300  -- studs per leg
    local travelRay = RaycastParams.new()
    travelRay.FilterType = Enum.RaycastFilterType.Include

    -- Highest structure under the straight line from -> to (XZ), plus margin.
    -- baseY = lowest allowed result before the margin (the destination height).
    local function cruiseHeight(from, to, baseY, margin)
        local list = {}
        for _, n in ipairs({ "Islands", "Ships", "Env" }) do
            local f = workspace:FindFirstChild(n)
            if f then table.insert(list, f) end
        end
        travelRay.FilterDescendantsInstances = list

        local flat  = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
        local steps = math.max(1, math.ceil(flat.Magnitude / SAMPLE_STEP))
        local top   = baseY
        for i = 0, steps do
            local p   = from + flat * (i / steps)
            local hit = workspace:Raycast(Vector3.new(p.X, 3000, p.Z), Vector3.new(0, -6000, 0), travelRay)
            if hit then top = math.max(top, hit.Position.Y) end
        end
        return top + (margin or CRUISE_MARGIN)
    end

    -- opts.margin: studs above the highest structure (default CRUISE_MARGIN)
    -- opts.stream: request streaming of each leg first (default true; off for short hops)
    function Move.travelOver(goal, speed, opts)
        opts = opts or {}
        -- leave Fishman Island through its exit path first (it sits deep under the map)
        if Util.isAtFishmanIsland() and ctx.Farm and ctx.Farm.exitFishman then
            Util.log("travel: leaving Fishman Island...")
            ctx.Farm.exitFishman()
        end
        local hrp = Util.getHRP()
        if not hrp then return end
        local pos  = hrp.Position
        local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)

        local legs = 0
        while flat.Magnitude > 1 and legs < 200 do
            legs += 1
            local len  = math.min(SEGMENT, flat.Magnitude)
            local next = pos + flat.Unit * len
            if opts.stream ~= false then
                pcall(function() LocalPlayer:RequestStreamAroundAsync(next) end)
            end
            local y = cruiseHeight(pos, next, goal.Y, opts.margin)
            -- rise first if this leg needs it (never fly into what is ahead); a lower leg is
            -- entered on the diagonal, which stays above y the whole way
            if y > pos.Y then
                Move.tweenTo(CFrame.new(pos.X, y, pos.Z), speed)
            end
            Move.tweenTo(CFrame.new(next.X, y, next.Z), speed)
            hrp = Util.getHRP()
            if not hrp then return end
            pos  = hrp.Position
            flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
        end
        Move.tweenTo(CFrame.new(goal), speed) -- straight down
    end

    -- Ground point under `p` (so walking/landing lands on the floor, not above or inside it).
    -- `filterInstances` defaults to Islands/Ships/Env; pass a narrower list (e.g. one island)
    -- to ignore unrelated geometry below.
    local groundRay = RaycastParams.new()
    groundRay.FilterType = Enum.RaycastFilterType.Include

    function Move.groundAt(p, filterInstances)
        if filterInstances then
            groundRay.FilterDescendantsInstances = filterInstances
        else
            local list = {}
            for _, n in ipairs({ "Islands", "Ships", "Env" }) do
                local f = workspace:FindFirstChild(n)
                if f then table.insert(list, f) end
            end
            groundRay.FilterDescendantsInstances = list
        end
        -- long enough to reach the ground from high up (the pulse checks height with this)
        local hit = workspace:Raycast(p + Vector3.new(0, 50, 0), Vector3.new(0, -500, 0), groundRay)
        return hit and hit.Position or p
    end

    function Move.startNoclip()
        if State.noclipConn then return end
        State.noclipConn = RunService.Stepped:Connect(function()
            local char = LocalPlayer.Character
            if not char then return end
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") then p.CanCollide = false end
            end
        end)
    end

    function Move.stopNoclip()
        if State.noclipConn then
            State.noclipConn:Disconnect()
            State.noclipConn = nil
        end
    end

    function Move.startAntiDrop()
        if State.antiDropConn then State.antiDropConn:Disconnect() end
        State.antiDropConn = RunService.Heartbeat:Connect(function()
            local hrp = Util.getHRP()
            if not hrp then return end
            local cfg = State.currentCfg
            if not cfg then return end
            -- real-M1 mode hovers at cfg.hitHeight; anti-drop would push us up to floatHeight
            -- (every farm config uses hitHeight now, so this only matters for configs without it)
            if cfg.hitHeight then return end

            local npcs       = workspace:FindFirstChild("NPCs")
            local foundNPC   = false
            local currentMin = -99999

            if npcs then
                for _, n in ipairs(npcs:GetChildren()) do
                    if n.Name == cfg.npcName then
                        local nhrp = n:FindFirstChild("HumanoidRootPart")
                        if nhrp then
                            currentMin = math.max(currentMin, nhrp.Position.Y + cfg.floatHeight)
                            foundNPC   = true
                        end
                    end
                end
            end

            State.minHeight = foundNPC and currentMin or (cfg.gatherPos.Y - 20)

            if hrp.Position.Y < State.minHeight then
                hrp.CFrame = CFrame.new(hrp.Position.X, State.minHeight, hrp.Position.Z)
            end
        end)
    end

    function Move.stopAntiDrop()
        if State.antiDropConn then
            State.antiDropConn:Disconnect()
            State.antiDropConn = nil
        end
        State.minHeight = 0
    end

    return Move
end

return build

end

_MODULES["runner.lua"] = function()
-- runner.lua — Background loops and event handlers
-- Loaded last, after all modules and Win are ready.
-- Receives: ctx (full context, including ctx.Win)

local function build(ctx)
    local C               = ctx.C
    local State           = ctx.State
    local Util            = ctx.Util
    local Move            = ctx.Move
    local Combat          = ctx.Combat
    local Farm            = ctx.Farm
    local Fish            = ctx.Fish
    local Merchant        = ctx.Merchant
    local Webhook         = ctx.Webhook
    local FishRarities    = ctx.FishRarities
    local LocalPlayer     = ctx.LocalPlayer
    local VIM             = ctx.VIM
    local RunService      = ctx.RunService
    local Win             = ctx.Win
    local StatsRemote     = ctx.StatsRemote
    local MerchantPosValue= ctx.MerchantPosValue

    Util.startDiagnostics(function()
        if Win.Flags["AutoTrickOrTreat"] and ctx.Trick then
            local ok, s = pcall(ctx.Trick.getStats)
            return "trick:" .. (ok and s.status or "?")
        end
        if State.isBuying then return "merchant" end
        if Win.Flags["AutoFarm"] then return "farm" end
        if Win.Flags["AutoFish"] then return "fish" end
        return "idle"
    end)

    -- Auto-activate toggles from gpoConfig on startup
    do
        local cfg = getgenv().gpoConfig
        if cfg then
            if cfg.Main.Kaitun then
                local t = State.ui.toggles["AutoFarm"]
                if t then t:Set(true) end
            end
            if cfg.Merchant.toggle then
                local t = State.ui.toggles["AutoMerchant"]
                if t then t:Set(true) end
            end
            if cfg.Trick.toggle then
                local t = State.ui.toggles["AutoTrickOrTreat"]
                if t then t:Set(true) end
            end
        end
    end

    -- Anti-AFK: press K on idle events and every AFK_INTERVAL seconds
    task.spawn(function()
        local function pressK()
            if Win.Flags["AntiAFK"] then
                pcall(function() VIM:SendKeyEvent(true,  Enum.KeyCode.K, false, game) end)
                task.wait(0.1)
                pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.K, false, game) end)
            end
        end
        LocalPlayer.Idled:Connect(pressK)
        while true do task.wait(C.AFK_INTERVAL); pressK() end
    end)

    -- Inf M1: reset the M1 combo counter every frame
    task.spawn(function()
        while true do
            if Win.Flags["InfM1"] then
                Util.try(function() getrenv()._G.resetM1() end)
            end
            task.wait(0.05)
        end
    end)

    -- Auto stats, only when gpoConfig.Stats.toggle = true: spend SP following
    -- gpoConfig.Stats.priority, in order (fill the 1st stat to its target, then the 2nd...).
    -- Remote: Events.stats:FireServer(statName, nil, amount) — the same call the stats menu makes.
    local ALLOWED_STATS = { Strength = true, Defense = true, Stamina = true }

    local function statValue(name)
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Stats[name].Value
        end)
        return ok and tonumber(v) or nil
    end

    -- the plan as { {stat, target}, ... } in priority order
    local function statPlan()
        local cfg = getgenv().gpoConfig
        local s = cfg and cfg.Stats
        if s and s.toggle then
            local plan = {}
            for _, entry in ipairs(s.priority or {}) do
                local name = entry.stat or entry[1]
                local target = tonumber(entry.amount or entry[2])
                if ALLOWED_STATS[name] and target and target > 0 then
                    table.insert(plan, { name, target })
                end
            end
            return plan
        end
        return nil -- toggle off: never touch stats
    end

    task.spawn(function()
        while true do
            local plan = statPlan()
            local sp = statValue("SkillPoints")
            local spent = false
            if plan and sp and sp > 0 then
                for _, step in ipairs(plan) do
                    local name, target = step[1], step[2]
                    local current = statValue(name)
                    if current and current < target then
                        local amount = math.min(sp, target - current)
                        Util.log(("auto stats: +%d %s (%d -> %d) | SP: %d"):format(
                            amount, name, current, current + amount, sp))
                        pcall(function() StatsRemote:FireServer(name, nil, amount) end)
                        spent = true
                        break -- one stat per pass, in priority order
                    end
                end
            end
            task.wait(spent and 1 or 3)
        end
    end)

    local function activity()
        if State.isBuying then return "merchant" end
        if Win.Flags["AutoTrickOrTreat"] then return "trick or treat" end
        if Win.Flags["AutoFarm"] then return "kaitun" end
        if Win.Flags["AutoFish"] then return "auto fish" end
        return "idle"
    end

    local function webhookCfg()
        local g = getgenv().gpoConfig
        return (g and g.webhook) or {}
    end

    -- Level webhook: every webhook.levelEvery levels while farming (first one sets the baseline)
    task.spawn(function()
        local lastMilestone
        while true do
            local every = tonumber(webhookCfg().levelEvery) or 0
            local level = Util.getLevel()
            if every > 0 and level and level > 0 then
                local milestone = level // every
                if lastMilestone == nil then
                    lastMilestone = milestone
                elseif milestone > lastMilestone then
                    lastMilestone = milestone
                    if Win.Flags["AutoFarm"] then
                        task.spawn(Webhook.farmLevel, level)
                        Win:Notify({ Title = "Level Up!", Message = "level " .. level .. " reached!", Type = "success", Duration = 5 })
                    end
                end
            end
            task.wait(5)
        end
    end)

    -- Status report: every webhook.reportEvery minutes
    task.spawn(function()
        local last = os.clock()
        while true do
            task.wait(10)
            local every = (tonumber(webhookCfg().reportEvery) or 0) * 60
            if every > 0 and os.clock() - last >= every then
                last = os.clock()
                Webhook.report(activity())
            end
        end
    end)

    -- Fish inventory refresh every 5 seconds
    task.spawn(function()
        while task.wait(5) do
            Util.try(function()
                local inv   = Util.getInventory()
                local lines = { "Inventory:\n" }
                for name, qty in pairs(inv) do
                    local rarity = FishRarities[name]
                    if rarity then
                        table.insert(lines, ("• %s [%s]: %d\n"):format(name, rarity, qty))
                    elseif name:find("Bait") then
                        table.insert(lines, ("♦ %s: %d\n"):format(name, qty))
                    end
                end
                State.ui.fishInvLabel:SetText(
                    #lines > 1 and table.concat(lines) or "No fish or baits yet.")
            end)
        end
    end)

    -- AutoFarm main loop (FASE 1-4 state machine lives in Farm.runLoop)
    task.spawn(Farm.runLoop)

    -- Merchant watcher
    task.spawn(function()
        if not MerchantPosValue then
            Util.log("MerchantPosValue not found.")
            return
        end
        local initialPos = MerchantPosValue.Value
        if Merchant.isNew(initialPos) then
            Util.log("merchant already active: " .. tostring(initialPos))
            if Win.Flags["AutoMerchant"] then task.spawn(Merchant.cycle, initialPos) end
        end
        MerchantPosValue.Changed:Connect(function(newPos)
            State.merchantPos = newPos
            if Merchant.isNew(newPos) then
                Util.log("merchant spawned: " .. tostring(newPos))
                Win:Notify({
                    Title    = "Merchant",
                    Message  = "traveling merchant detected!",
                    Type     = "success",
                    Duration = 6,
                })
                if Win.Flags["AutoMerchant"] then task.spawn(Merchant.cycle, newPos) end
            end
        end)
        Util.log("merchant watcher active.")
    end)

    -- Auto-rejoin: reconnect when the game kicks the player
    do
        local TeleportService = game:GetService("TeleportService")
        local GuiService      = game:GetService("GuiService")
        local PLACE_ID        = 1730877806

        GuiService.ErrorMessageChanged:Connect(function(msg)
            if msg and msg ~= "" then
                task.wait()
                pcall(function()
                    TeleportService:Teleport(PLACE_ID, LocalPlayer)
                end)
            end
        end)
    end

    -- Respawn handler
    LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if Win.Flags["AutoFarm"] then
            -- stop the current kill loop; the farm loop takes the route back from the respawn point
            State.diedInFarm = true
            Move.cancelTween()
            Move.startNoclip()
            Move.setup()
            Move.startAntiDrop()
            task.wait(0.3)
            Combat.ensureMelee()
            Util.log("respawn — resuming farm (" .. State.currentCfg.npcName .. ")")
        end
    end)
end

return build

end

_MODULES["state.lua"] = function()
-- state.lua — Central mutable state
-- Receives: C (config), FarmConfigs

local function build(C, FarmConfigs)
    local State = {
        -- Farm
        currentCfg      = FarmConfigs.bandit,
        fishmanNotified = false,
        travelDone      = false,
        spawnSet        = false,
        sea2Done        = false,
        diedInFarm      = false,  -- set on respawn; the farm loop walks the full route back
        skyWalk2Done    = false,

        -- Merchant
        lastMerchantPos = Vector3.zero,
        merchantPos     = Vector3.zero,
        isBuying        = false,

        -- Movement (LinearVelocity mover)
        mover        = nil,  -- LinearVelocity instance
        moverAtt     = nil,  -- Attachment for mover
        activeTween  = nil,
        antiDropConn = nil,
        minHeight    = 0,
        noclipConn   = nil,

        -- Fishing
        fishBait        = C.BAIT_DEFAULT,
        fishRod         = C.FISH_ROD_DEFAULT,
        craftTargets    = { ["Common Fish Bait"] = true },
        buyBaitPos      = Vector3.new(103, 9, -56),
        craftNpcPos     = Vector3.new(161, 9, -56),
        autoUpgradeBait = false,

        -- Win (assigned when the window is built)
        win = nil,

        -- UI refs
        ui = {
            log            = nil,
            fishInvLabel   = nil,
            buyBaitLabel   = nil,
            craftNpcLabel  = nil,
            webhookInput   = nil,
            toggles        = {},
        },
    }
    return State
end

return build

end

_MODULES["trickortreat.lua"] = function()
-- trickortreat.lua — Halloween "Trick or Treat" event
-- Receives: ctx { C, State, Util, Move, Combat, Win, LocalPlayer, RepStorage }
--
-- How the event works (server side, no client script involved):
--   workspace.Islands.Spooksville.Building has 64 "House" models, each with
--   eventDoor.Frame.ProximityPrompt ("Knock", 10 studs, no hold). Knocking with a candy basket
--   in hand gives a treat (+candy) or a trick (candy stolen / a hit). There are 3 baskets, all
--   ToolDesc Type "CandyBasket": Pumpkin Bag (100), Pumpkin Basket (250), Candy Corn Basket (500).
--   Stats<Name>.Inventory.Halloween26Candy holds the candy (max = the basket's MaxCandy).
--   When a knock is accepted the character gets busyCandy = true (~1s after the knock) and
--   TreatCount / TrickCount are set to the result (1/0 flags of the LAST knock, not totals).
--   busyCandy goes back to nil when the door scene ends (~6s); until then no other door works.
--   Each door has a per-player cooldown: its prompt re-enables after the scene for everyone,
--   but knocking it again too soon is simply ignored (busyCandy never shows up).
-- Inside the island the character WALKS (pathfinding + Humanoid:MoveTo) door to door, with the
-- normal walk animation and real collisions, so it neither floats nor looks like noclip.

local function build(ctx)
    local C           = ctx.C
    local State       = ctx.State
    local Util        = ctx.Util
    local Move        = ctx.Move
    local Combat      = ctx.Combat
    local Win         = ctx.Win
    local LocalPlayer = ctx.LocalPlayer

    local Trick = {}

    local DOOR_CD      = 300  -- seconds we leave a door alone after knocking it
    local STAND_DIST   = 4    -- studs in front of the door (prompt reaches 10)
    local ACCEPT_WAIT  = 2.5  -- seconds for busyCandy to show up (else the door ignored us)
    local SCENE_WAIT   = 15   -- max seconds for busyCandy to clear (scene is ~6s)
    local WALK_SPEED   = 28   -- WalkSpeed while walking between doors (normal is 16)
    local FAR_FROM_ISLAND = 600

    -- Roaming Halloween NPCs: most wander off and never bother us, but when one closes in and
    -- hits us it blocks knocking (busyCandy-less stun, lost steps). Same kill logic as bandits /
    -- fishman: hover above it with the real M1 until it's dead, then go back to the doors.
    local THREAT_NAMES  = { "Candy Skeleton", "Wandering Soul" }
    local THREAT_CFG    = { hitHeight = 7 }
    local THREAT_RADIUS = 20 -- studs: how close a threat must be to blame it for the damage we took

    local underAttack  = false
    local healthConn, watchedHum

    -- Hook the humanoid's HealthChanged once (and again after every respawn)
    local function watchHealth()
        local hum = Util.getHumanoid()
        if not hum or hum == watchedHum then return end
        if healthConn then healthConn:Disconnect() end
        watchedHum = hum
        local last = hum.Health
        healthConn = hum.HealthChanged:Connect(function(hp)
            if hp < last then underAttack = true end
            last = hp
        end)
    end

    local function findThreat(hrp)
        local npcs = workspace:FindFirstChild("NPCs")
        if not npcs then return nil end
        local best, bestDist
        for _, n in ipairs(npcs:GetChildren()) do
            if table.find(THREAT_NAMES, n.Name) then
                local hum = n:FindFirstChildOfClass("Humanoid")
                local nhrp = n:FindFirstChild("HumanoidRootPart")
                if hum and hum.Health > 0 and nhrp then
                    local d = (nhrp.Position - hrp.Position).Magnitude
                    if d <= THREAT_RADIUS and (not bestDist or d < bestDist) then
                        best, bestDist = n, d
                    end
                end
            end
        end
        return best
    end

    local function isBusy()
        local char = LocalPlayer.Character
        return char and char:GetAttribute("busyCandy") == true
    end

    local knockedAt = {}   -- [prompt] = os.clock() of our last knock

    -- Session stats shown in the UI
    local stats
    function Trick.resetStats()
        stats = {
            knocks = 0, treats = 0, tricks = 0, nothing = 0, ignored = 0,
            gained = 0, lost = 0, status = "idle", startedAt = nil,
        }
    end
    Trick.resetStats()
    local function setStatus(s) stats.status = s end

    local function island()
        local islands = workspace:FindFirstChild("Islands")
        return islands and islands:FindFirstChild("Spooksville")
    end

    local function getCandy()
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Inventory.Halloween26Candy.Value
        end)
        return ok and v or 0
    end

    local toolDesc
    local function getToolDesc()
        if not toolDesc then
            local ok, td = pcall(require, ctx.RepStorage.Modules.ToolDesc)
            toolDesc = ok and td or {}
        end
        return toolDesc
    end

    -- The best candy basket we own (highest MaxCandy), equipped or in the backpack.
    -- Returns tool, maxCandy.
    local function findBasket()
        local td = getToolDesc()
        local best, bestMax
        for _, container in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack") }) do
            if container then
                for _, t in ipairs(container:GetChildren()) do
                    local d = t:IsA("Tool") and td[t.Name]
                    if type(d) == "table" and d.Type == "CandyBasket" then
                        local max = tonumber(d.MaxCandy) or 0
                        if not bestMax or max > bestMax then best, bestMax = t, max end
                    end
                end
            end
        end
        return best, bestMax
    end

    local function getMaxCandy()
        local _, max = findBasket()
        return max or math.huge
    end


    local function doorPrompts(isl)
        local list = {}
        local building = isl:FindFirstChild("Building")
        if not building then return list end
        for _, house in ipairs(building:GetChildren()) do
            local door  = house:FindFirstChild("eventDoor")
            local frame = door and door:FindFirstChild("Frame")
            local p     = frame and frame:FindFirstChildOfClass("ProximityPrompt")
            if p then table.insert(list, p) end
        end
        return list
    end

    -- Nearest door that is enabled and not on our own cooldown
    local function nextDoor(isl, from)
        local best, bestDist
        local now = os.clock()
        for _, p in ipairs(doorPrompts(isl)) do
            local last = knockedAt[p]
            if p.Enabled and (not last or now - last >= DOOR_CD) then
                local d = (p.Parent.Position - from).Magnitude
                if not bestDist or d < bestDist then best, bestDist = p, d end
            end
        end
        return best
    end

    -- Basket upgrade ladder: bought in order, each one only when the previous is owned
    local BASKET_LADDER = {
        { name = "Pumpkin Bag",       cap = 100, peli = 5000 },
        { name = "Pumpkin Basket",    cap = 250, candy = 100 },
        { name = "Candy Corn Basket", cap = 500, candy = 250 },
    }

    local function equipByName(name)
        local ok, res = pcall(function()
            return ctx.RepStorage:WaitForChild("Events"):WaitForChild("Tools"):InvokeServer("equip", name)
        end)
        return ok and res
    end

    local function equipBasket()
        local tool = findBasket()
        if not tool then
            for i = #BASKET_LADDER, 1, -1 do
                equipByName(BASKET_LADDER[i].name)
                task.wait(0.3)
                tool = findBasket()
                if tool then break end
            end
            if not tool then return false end
        end
        if tool.Parent == LocalPlayer.Character then return true end
        local hum = Util.getHumanoid()
        if not hum then return false end
        Util.try(function() hum:EquipTool(tool) end)
        task.wait(0.3)
        return tool.Parent == LocalPlayer.Character
    end

    local roofRay = RaycastParams.new()
    roofRay.FilterType = Enum.RaycastFilterType.Include

    -- true if nothing (roof, porch) is above `p`
    local function openSky(isl, p)
        roofRay.FilterDescendantsInstances = { isl }
        local hit = workspace:Raycast(p + Vector3.new(0, 2, 0), Vector3.new(0, 300, 0), roofRay)
        return hit == nil
    end

    -- The door's outward side: the one with open sky in front of it (the street).
    -- Returns the stand point (STAND_DIST in front of the door).
    local function doorStand(isl, frame, from)
        local fp   = frame.Position
        local look = frame.CFrame.LookVector * Vector3.new(1, 0, 1)
        if look.Magnitude < 0.1 then look = (from - fp) * Vector3.new(1, 0, 1) end
        look = look.Unit
        local best
        for _, side in ipairs({ look, -look }) do
            for dist = STAND_DIST, STAND_DIST + 24, 4 do
                local p = fp + side * dist
                if openSky(isl, p) then
                    -- prefer the side that is open closest to the door
                    if not best or dist < best.dist then best = { side = side, dist = dist } end
                    break
                end
            end
        end
        local side = best and best.side or look
        return fp + side * STAND_DIST
    end

    -- Ground point under `p`, restricted to this island (so we land on the floor, not inside it,
    -- and not on some other island's geometry below)
    local function groundAt(isl, p) return Move.groundAt(p, { isl }) end

    local function walking() return Win.Flags["AutoTrickOrTreat"] and not State.isBuying end

    -- Candy prices of the Halloween shop items (Pumpkin Bag is Peli-priced, so it's not here).
    local SHOP_CANDY_PRICES = {
        ["Pumpkin Basket"] = 100, ["Candy Corn Basket"] = 250, ["Lantern"] = 50,
        ["Mummy Wrappings"] = 100, ["Frankenstein Costume"] = 175, ["Tung Sahur Costume"] = 500,
        ["Plague Doctor Costume"] = 100, ["Joker Costume"] = 100, ["Shark Costume"] = 175,
        ["Ghost Face Costume"] = 100, ["Wizard Costume"] = 175, ["Devil Fruit Journal"] = 125,
        ["Spare Fruit Bag"] = 250, ["SP Reset Essence"] = 10, ["Spirit Color Essence"] = 50,
        ["Trading Sign"] = 100, ["Blood Scythe"] = 500, ["Race Reroll x5"] = 25,
        ["Dark Root"] = 25, ["Rare Fruit Chest"] = 250, ["Legendary Fruit Chest Blueprint"] = 100,
    }
    local SHOP_RETRY = 60      -- pause after a visit that bought nothing (avoids walking back in a loop)
    local shopRetryAt = 0
    local MAX_BUYS_PER_ITEM = 100

    local function nextBasket()
        local _, cap = findBasket()
        cap = cap or 0
        for _, b in ipairs(BASKET_LADDER) do
            if b.cap > cap then return b end
        end
    end

    local function getPeli()
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Stats.Peli.Value
        end)
        return ok and tonumber(v) or 0
    end

    local function basketAffordable()
        local nb = nextBasket()
        if not nb then return false end
        if nb.peli then return getPeli() >= nb.peli end
        return getCandy() >= nb.candy
    end

    -- candy kept back for the next basket upgrade, so dropdown items never delay it
    local function basketReserve()
        local nb = nextBasket()
        return nb and nb.candy or 0
    end

    local CHEST_CAP = { ["Rare Fruit Chest"] = 10 }

    local function ownedCount(name)
        local ok, data = pcall(function()
            return ctx.HttpService:JSONDecode(ctx.RepStorage["Stats" .. LocalPlayer.Name].Inventory.Inventory.Value)
        end)
        return ok and tonumber(data[name] or 0) or 0
    end

    -- candy kept back for priority 1 while it's below its cap (never for itself)
    local function priorityReserve(except)
        local cfg = getgenv().gpoConfig.Trick
        local name = cfg.priority1
        if not name or name == except then return 0 end
        local price = SHOP_CANDY_PRICES[name]
        if not price or ownedCount(name) >= (CHEST_CAP[name] or math.huge) then return 0 end
        return price
    end

    local function candyReserve(except)
        return basketReserve() + priorityReserve(except)
    end

    local function priorityAffordable()
        local cfg = getgenv().gpoConfig.Trick
        for _, key in ipairs({ "priority1", "priority2" }) do
            local name = cfg[key]
            local price = name and SHOP_CANDY_PRICES[name]
            if price and ownedCount(name) < (CHEST_CAP[name] or math.huge)
                and getCandy() - candyReserve(name) >= price then
                return true
            end
        end
        return false
    end

    -- Cheapest candy price among the dropdown items, or nil if none selected
    local function cheapestWantedCandy()
        local cheapest
        local cfg = getgenv().gpoConfig
        local list = cfg and cfg.Trick and cfg.Trick.itemsToBuy or {}
        for _, name in ipairs(list) do
            local p = SHOP_CANDY_PRICES[name]
            if p and (not cheapest or p < cheapest) then cheapest = p end
        end
        return cheapest
    end

    -- Snapshot for the UI
    function Trick.getStats()
        local isl = island()
        local total, available, ready = 0, 0, 0
        if isl then
            local now = os.clock()
            for _, p in ipairs(doorPrompts(isl)) do
                total += 1
                local last = knockedAt[p]
                local mine = not last or now - last >= DOOR_CD
                if mine then available += 1 end
                if mine and p.Enabled then ready += 1 end
            end
        end
        local s = table.clone(stats)
        s.candy, s.maxCandy = getCandy(), getMaxCandy()
        s.doorsTotal, s.doorsAvailable, s.doorsReady = total, available, ready
        s.elapsed = stats.startedAt and (os.clock() - stats.startedAt) or 0
        return s
    end

    function Trick.cycle()
        stats.startedAt = stats.startedAt or os.clock()
        if State.isBuying then setStatus("paused (merchant)"); task.wait(0.5); return end

        local isl = island()
        local hrp = Util.getHRP()
        if not isl or not hrp then task.wait(1); return end

        watchHealth()
        if underAttack then
            underAttack = false
            local threat = findThreat(hrp)
            if threat then
                Util.log("Trick or Treat: " .. threat.Name .. " is attacking, killing it...")
                setStatus("fighting " .. threat.Name)
                Combat.killNPC(threat, THREAT_CFG, walking)
            end
            return
        end

        -- get to Spooksville if we are elsewhere
        local center = isl:GetAttribute("islandCFrame")
        center = typeof(center) == "CFrame" and center.Position or isl:GetPivot().Position
        if (hrp.Position - center).Magnitude > FAR_FROM_ISLAND then
            Util.log("Trick or Treat: traveling to Spooksville...")
            setStatus("traveling to Spooksville")
            -- fly there, landing on the ground next to the nearest door so the walk can start
            local doors = doorPrompts(isl)
            local target = doors[1] and doors[1].Parent.Position or center
            Move.travelOver(groundAt(isl, target) + Vector3.new(0, 3, 0), C.TWEEN_SPEED_NORMAL)
            return
        end

        local candy, max = getCandy(), getMaxCandy()

        -- enough candy for something picked in the shop dropdown: go to the pot and buy
        local cheapest = cheapestWantedCandy()
        local wantShop = (cheapest and candy - candyReserve() >= cheapest) or basketAffordable() or priorityAffordable()
        if wantShop and os.clock() >= shopRetryAt then
            Util.log(("Trick or Treat: %d candy, going to the Halloween shop"):format(candy))
            if Trick.buyShop() == 0 then shopRetryAt = os.clock() + SHOP_RETRY end
            return
        end

        if candy >= max then
            Util.log(("Trick or Treat: bag full (%d/%d)"):format(candy, max))
            setStatus("bag full")
            task.wait(5); return
        end

        if not equipBasket() then
            Util.log("Trick or Treat: no candy basket (Pumpkin Bag / Pumpkin Basket / Candy Corn Basket)")
            setStatus("no candy basket")
            task.wait(3); return
        end

        -- still in a door scene (e.g. from a manual knock): wait for it to end
        if isBusy() then setStatus("waiting for door scene"); task.wait(0.2); return end

        local prompt = nextDoor(isl, hrp.Position)
        if not prompt then
            Util.log("Trick or Treat: every door is on cooldown, waiting...")
            setStatus("all doors on cooldown")
            task.wait(2); return
        end

        setStatus("walking to a door")
        local stand = doorStand(isl, prompt.Parent, hrp.Position)
        if not Move.walkTo(groundAt(isl, stand), 3, walking, WALK_SPEED) then
            if walking() then
                Util.log("Trick or Treat: couldn't reach that door, trying another")
                knockedAt[prompt] = os.clock() -- skip it for now
            end
            task.wait(0.5)
            return
        end
        if (Util.getHRP().Position - prompt.Parent.Position).Magnitude > prompt.MaxActivationDistance then
            knockedAt[prompt] = os.clock()
            task.wait(0.5)
            return
        end

        local candyBefore = getCandy()
        knockedAt[prompt] = os.clock()
        setStatus("knocking")
        fireproximityprompt(prompt)

        -- accepted? busyCandy shows up ~1s after the knock
        local deadline = tick() + ACCEPT_WAIT
        while not isBusy() and tick() < deadline do task.wait(0.05) end
        if not isBusy() then
            Util.log("Trick or Treat: door ignored us (cooldown), next one")
            stats.ignored += 1
            return
        end

        -- wait for the door scene to end, then go straight to the next door
        setStatus("door scene")
        deadline = tick() + SCENE_WAIT
        while isBusy() and tick() < deadline and Win.Flags["AutoTrickOrTreat"] do task.wait(0.05) end

        local delta = getCandy() - candyBefore
        stats.knocks += 1
        if delta > 0 then
            stats.treats += 1; stats.gained += delta
        elseif delta < 0 then
            stats.tricks += 1; stats.lost -= delta
        else
            stats.nothing += 1
        end
        Util.log(("Trick or Treat: %s (%+d) candy %d/%d"):format(
            delta > 0 and "TREAT!" or delta < 0 and "trick..." or "nothing", delta, getCandy(), max))
    end

    -- Halloween shop (opens when you walk up to workspace.Islands.Spooksville.Interact.POt).
    -- Buys the items listed in gpoConfig.Trick.itemsToBuy that cost Candy and that we can afford.
    -- Peli items go through a client confirmation prompt, so they're skipped on purpose.
    local SHOP_REMOTE_NAME = "HalloweenShopRemote"
    local POT_NAME = "POt"

    local function getBuyList()
        local cfg = getgenv().gpoConfig
        local list = cfg and cfg.Trick and cfg.Trick.itemsToBuy
        return type(list) == "table" and list or {}
    end

    function Trick.buyShop()
        local isl = island()
        local hrp = Util.getHRP()
        local interact = isl and isl:FindFirstChild("Interact")
        local pot = interact and interact:FindFirstChild(POT_NAME)
        if not hrp or not pot then Util.log("Trick or Treat shop: pot not found"); return 0 end
        setStatus("walking to the shop")
        local potPos = pot:GetPivot().Position
        Move.walkTo(Move.groundAt(potPos, { isl }), 6, walking, WALK_SPEED)
        Move.stopWalking(WALK_SPEED)

        local gui = LocalPlayer.PlayerGui:FindFirstChild("HalloweenShop")
        local deadline = tick() + 3
        while not gui and tick() < deadline do
            task.wait(0.2)
            gui = LocalPlayer.PlayerGui:FindFirstChild("HalloweenShop")
        end
        if not gui then Util.log("Trick or Treat shop: menu did not open"); return 0 end

        local ok, prices = pcall(function() return ctx.HttpService:JSONDecode(gui:GetAttribute("Prices")) end)
        if not ok or type(prices) ~= "table" then return 0 end

        local remote = ctx.RepStorage:FindFirstChild(SHOP_REMOTE_NAME)
        if not remote then Util.log("Trick or Treat shop: remote not found"); return 0 end

        local bought = 0
        local purchases = {} -- for the webhook: { {name, count} }
        local function record(name, count)
            if count > 0 then table.insert(purchases, { name = name, count = count }) end
        end
        local nb = nextBasket()
        local bInfo = nb and prices[nb.name]
        if bInfo then
            local affordable = (bInfo.priceType == "Peli" and getPeli() >= bInfo.price)
                or (bInfo.priceType == "Candy" and getCandy() >= bInfo.price)
            if affordable then
                local okBuy, res = pcall(function() return remote:InvokeServer(nb.name) end)
                if okBuy and res == true then
                    bought += 1
                    record(nb.name, 1)
                    Util.log(("Trick or Treat shop: upgraded to %s"):format(nb.name))
                    equipByName(nb.name)
                    task.wait(0.5)
                else
                    Util.log(("Trick or Treat shop: '%s' not bought"):format(nb.name))
                end
                task.wait(0.5)
            end
        end
        local function buyPriority(key)
            local name = getgenv().gpoConfig.Trick[key]
            local info = name and prices[name]
            if not info or info.priceType ~= "Candy" then return 0 end
            local cap = CHEST_CAP[name] or math.huge
            local n = 0
            while ownedCount(name) + n < cap and n < MAX_BUYS_PER_ITEM and getCandy() - candyReserve(name) >= info.price do
                local okBuy, res = pcall(function() return remote:InvokeServer(name) end)
                if not (okBuy and res == true) then break end
                n += 1
                task.wait(0.5)
            end
            if n > 0 then Util.log(("Trick or Treat shop: %s x%d (priority)"):format(name, n)) end
            record(name, n)
            return n
        end
        bought += buyPriority("priority1") + buyPriority("priority2")

        for _, name in ipairs(getBuyList()) do
            local info = prices[name]
            if info and info.priceType == "Candy" then
                local n = 0
                while n < MAX_BUYS_PER_ITEM and getCandy() - candyReserve() >= info.price do
                    local okBuy, res = pcall(function() return remote:InvokeServer(name) end)
                    if not (okBuy and res == true) then break end
                    n += 1
                    bought += 1
                    task.wait(0.5)
                end
                record(name, n)
                if n > 0 then
                    Util.log(("Trick or Treat shop: bought %dx %s (%d candy each)"):format(n, name, info.price))
                elseif getCandy() - candyReserve() < info.price then
                    Util.log(("Trick or Treat shop: not enough candy for '%s'"):format(name))
                else
                    Util.log(("Trick or Treat shop: '%s' not bought"):format(name))
                end
            elseif info then
                Util.log(("Trick or Treat shop: skipping '%s' (costs %s, not Candy)"):format(name, tostring(info.priceType)))
            end
        end
        if ctx.Webhook and #purchases > 0 then task.spawn(ctx.Webhook.trickShop, purchases) end
        return bought
    end

    function Trick.stop()
        setStatus("stopped")
        Move.cancelTween()
        Move.stopWalking(WALK_SPEED) -- stop and put the normal WalkSpeed back
    end

    return Trick
end

return build

end

_MODULES["ui.lua"] = function()
-- ui.lua — UI construction only
-- Receives: ctx (full context)
-- Returns: Win

local function build(ctx)
    local C            = ctx.C
    local State        = ctx.State
    local Util         = ctx.Util
    local Move         = ctx.Move
    local Fish         = ctx.Fish
    local Merchant     = ctx.Merchant
    local Webhook      = ctx.Webhook
    local FarmConfigs  = ctx.FarmConfigs
    local FishRarities = ctx.FishRarities
    local LocalPlayer  = ctx.LocalPlayer
    local MerchantPosValue = ctx.MerchantPosValue

    local Library = loadstring(game:HttpGet(
        "https://raw.githubusercontent.com/JorgeG489/ousi/refs/heads/main/ui"
    ))()

    local Win = Library:CreateWindow({
        Title         = "Ousi - .gg/yWmNNmffgq",
        Size          = getgenv().WindowSize,
        ToggleKeybind = Enum.KeyCode.RightShift,
    })

    State.win = Win
    ctx.Win   = Win

    local Tabs = {
        farm     = Win:AddTab("Farm"),
        fish     = Win:AddTab("Fish"),
        merchant = Win:AddTab("Merchant"),
        event    = Win:AddTab("Event"),
        config   = Win:AddTab("Config"),
        console  = Win:AddTab("Console"),
    }

    local Boxes = {
        farms     = Tabs.farm:AddLeftGroupbox("Auto Farms"),
        fishMain  = Tabs.fish:AddLeftGroupbox("Auto Fish"),
        fishCraft = Tabs.fish:AddLeftGroupbox("Auto Craft"),
        fishInv   = Tabs.fish:AddRightGroupbox("Inventory"),
        merchant  = Tabs.merchant:AddLeftGroupbox("Merchant"),
        tween     = Tabs.merchant:AddRightGroupbox("Tween to Islands"),
        trick     = Tabs.event:AddLeftGroupbox("Trick or Treat"),
        trickStats = Tabs.event:AddRightGroupbox("Trick or Treat Stats"),
        unu       = Tabs.config:AddLeftGroupbox("Exploits"),
        esp       = Tabs.config:AddRightGroupbox("ESP"),
        webhook   = Tabs.config:AddRightGroupbox("Webhook"),
        log       = Tabs.console:AddLeftGroupbox("Log"),
    }

    Boxes.log:AddButton({ Text = "Clear Log", Func = function() Util.clearLog() end })
    State.ui.log          = Boxes.log:AddLabel("Idle...")
    State.ui.fishInvLabel = Boxes.fishInv:AddLabel("Inventory:\nWaiting for data...")

    -- Enable/disable the toggles that auto-start alongside AutoFarm/AutoMerchant
    local function setRelatedToggles(on)
        for _, name in ipairs({ "InfM1" }) do
            local t = State.ui.toggles[name]
            if t then t:Set(on) end
        end
    end

    -- Stop movement (mover, tween, anti-drop, no-fall) unless another feature still needs it.
    -- A delayed re-check catches stale farm threads that finish after the toggle was turned off.
    local function stopMovementIfIdle()
        local function busy()
            return Win.Flags["AutoFarm"]
                or Win.Flags["AutoMerchant"] or Win.Flags["AutoFish"]
                or Win.Flags["AutoTrickOrTreat"]
        end
        local function stop()
            if busy() then Move.cancelTween() else Move.stopAll() end
        end
        stop()
        task.delay(0.6, function() if not busy() then Move.stopAll() end end)
    end

    -- TAB: FARM
    State.ui.toggles["AutoFarm"] = Boxes.farms:AddToggle("AutoFarm", {
        Text     = "Kaitun",
        Default  = false,
        Callback = function(on)
            if on then
                setRelatedToggles(true)
                Move.setup()
                State.currentCfg      = Util.getFarmConfig(nil, FarmConfigs)
                State.travelDone      = false
                Move.startAntiDrop()
                Util.log("auto farm started (" .. State.currentCfg.npcName .. ")")
                Win:Notify({ Title = "Auto Farm", Message = "started", Type = "success" })
            else
                setRelatedToggles(false)
                Move.stopAntiDrop()
                stopMovementIfIdle()
                Util.log("auto farm stopped")
                Win:Notify({ Title = "Auto Farm", Message = "stopped", Type = "warning" })
            end
        end,
    })
    Boxes.farms:AddLabel("Bandits (lvl 1-24) → Fishman (lvl 25+)\nQuest auto at lvl 190+")

    -- TAB: FISH

    Boxes.fishMain:AddToggle("AutoFish", {
        Text     = "Auto Fish",
        Default  = false,
        Callback = function(on)
            if on then
                Util.log("auto fish started")
                Win:Notify({ Title = "Auto Fish", Message = "started", Type = "success" })
                task.spawn(function()
                    while Win.Flags["AutoFish"] do
                        local ok, err = pcall(Fish.cycle)
                        if not ok then
                            Util.log("fish error: " .. tostring(err))
                            Fish.cancel()
                            task.wait(2)
                        end
                    end
                    Fish.cancel()
                    Util.log("auto fish stopped")
                end)
            else
                Fish.cancel()
                Win:Notify({ Title = "Auto Fish", Message = "stopped", Type = "warning" })
            end
        end,
    })

    Boxes.fishMain:AddDropdown("FishRodSelector", {
        Options  = Util.getRods(),
        Default  = "Fishing Rod",
        Multi    = false,
        Text     = "Select Rod",
        Callback = function(v) State.fishRod = v; Util.log("Rod: " .. v) end,
    })

    Boxes.fishMain:AddDropdown("FishBaitSelect", {
        Options  = { "Common Fish Bait", "Rare Fish Bait", "Legendary Fish Bait" },
        Default  = "Common Fish Bait",
        Multi    = false,
        Text     = "Select Bait",
        Callback = function(v)
            State.fishBait = v ~= "None" and v or nil
            Util.log("Bait: " .. tostring(v))
        end,
    })

    Boxes.fishMain:AddToggle("AutoUpgradeBait", {
        Text     = "Auto Upgrade Bait",
        Default  = false,
        Callback = function(on)
            State.autoUpgradeBait = on
            Util.log("Auto Upgrade Bait: " .. (on and "ON" or "OFF"))
            Win:Notify({
                Title   = "Auto Upgrade Bait",
                Message = on and "enabled" or "disabled",
                Type    = on and "success" or "warning",
            })
        end,
    })

    Boxes.fishMain:AddToggle("AutoBuyCommonBait", {
        Text    = "Auto Buy Common Bait",
        Default = false,
    })

    local buyBaitLabel = Boxes.fishMain:AddLabel(
        ("Buy Pos: (%.1f, %.1f, %.1f)"):format(
            State.buyBaitPos.X, State.buyBaitPos.Y, State.buyBaitPos.Z))
    State.ui.buyBaitLabel = buyBaitLabel

    local function updateBuyBaitLabel()
        local p = State.buyBaitPos
        buyBaitLabel:SetText(("Buy Pos: (%.1f, %.1f, %.1f)"):format(p.X, p.Y, p.Z))
    end

    Boxes.fishMain:AddButton({
        Text = "Capture Buy Bait Position",
        Func = function()
            local hrp = Util.getHRP()
            if hrp then
                State.buyBaitPos = hrp.Position
                updateBuyBaitLabel()
                Win:Notify({ Title = "Buy Bait Pos", Message = "Saved!", Type = "success", Duration = 3 })
            else
                Win:Notify({ Title = "Buy Bait Pos", Message = "Character not found", Type = "error", Duration = 3 })
            end
        end,
    })
    Boxes.fishMain:AddButton({
        Text = "Reset Buy Bait Pos",
        Func = function()
            State.buyBaitPos = Vector3.new(103, 9, -56)
            updateBuyBaitLabel()
            Win:Notify({ Title = "Buy Bait Pos", Message = "Reset to default", Type = "warning", Duration = 3 })
        end,
    })

    Boxes.fishCraft:AddToggle("AutoCraft", { Text = "Auto Craft Baits", Default = false })
    Boxes.fishCraft:AddDropdown("AutoCraftOpts", {
        Options  = { "Common Fish Bait", "Rare Fish Bait", "Legendary Fish Bait" },
        Default  = "Common Fish Bait",
        Multi    = true,
        Text     = "Craft Targets",
        Callback = function(v) State.craftTargets = v end,
    })

    local craftNpcLabel = Boxes.fishCraft:AddLabel(
        ("Craft NPC: (%.1f, %.1f, %.1f)"):format(
            State.craftNpcPos.X, State.craftNpcPos.Y, State.craftNpcPos.Z))
    State.ui.craftNpcLabel = craftNpcLabel

    local function updateCraftNpcLabel()
        local p = State.craftNpcPos
        craftNpcLabel:SetText(("Craft NPC: (%.1f, %.1f, %.1f)"):format(p.X, p.Y, p.Z))
    end

    Boxes.fishCraft:AddButton({
        Text = "Capture Craft NPC Position",
        Func = function()
            local hrp = Util.getHRP()
            if hrp then
                State.craftNpcPos = hrp.Position
                updateCraftNpcLabel()
                Win:Notify({ Title = "Craft NPC Pos", Message = "Saved!", Type = "success", Duration = 3 })
            else
                Win:Notify({ Title = "Craft NPC Pos", Message = "Character not found", Type = "error", Duration = 3 })
            end
        end,
    })
    Boxes.fishCraft:AddButton({
        Text = "Reset Craft NPC Pos",
        Func = function()
            State.craftNpcPos = Vector3.new(161, 9, -56)
            updateCraftNpcLabel()
            Win:Notify({ Title = "Craft NPC Pos", Message = "Reset to default", Type = "warning", Duration = 3 })
        end,
    })

    -- TAB: MERCHANT
    State.ui.toggles["AutoMerchant"] = Boxes.merchant:AddToggle("AutoMerchant", {
        Text     = "Auto Merchant",
        Default  = false,
        Callback = function(on)
            if on then
                setRelatedToggles(true)
                Move.setup()
                -- turning it on always visits a merchant that is already up (even one we saw before)
                local pos = MerchantPosValue and MerchantPosValue.Value
                if pos and pos ~= Vector3.zero then
                    task.spawn(Merchant.cycle, pos, true)
                else
                    Util.log("Auto Merchant: no merchant in this server, waiting for one...")
                end
            else
                stopMovementIfIdle()
            end
            if not on then Util.log("Auto Merchant: OFF") end
            Win:Notify({
                Title   = "Auto Merchant",
                Message = on and "enabled" or "disabled",
                Type    = on and "success" or "warning",
            })
        end,
    })

    -- One-shot visit: walks in (same movement as Trick or Treat) instead of flying onto the npc,
    -- works even with Auto Merchant off, and ignores the "already seen this one" check.
    Boxes.merchant:AddButton({
        Text = "Go to Merchant Now",
        Func = function()
            local pos = MerchantPosValue and MerchantPosValue.Value
            if not pos or pos == Vector3.zero then
                Win:Notify({ Title = "Merchant", Message = "no merchant in this server", Type = "error", Duration = 4 })
                return
            end
            if State.isBuying then
                Win:Notify({ Title = "Merchant", Message = "already on it", Type = "warning", Duration = 3 })
                return
            end
            Move.setup()
            task.spawn(Merchant.cycle, pos, true)
        end,
    })

    -- Items to buy: comma separated, kept in gpoConfig.Merchant.itemsToBuy (also settable by config)
    Boxes.merchant:AddInput("MerchantItems", {
        Text        = "Items to buy",
        Placeholder = "Race Reroll, SP Reset Essence",
        Default     = table.concat(getgenv().gpoConfig.Merchant.itemsToBuy, ", "),
        Callback    = function(text)
            local list = {}
            for item in tostring(text):gmatch("[^,]+") do
                item = item:match("^%s*(.-)%s*$")
                if item ~= "" then table.insert(list, item) end
            end
            getgenv().gpoConfig.Merchant.itemsToBuy = list
        end,
    })
    Boxes.merchant:AddLabel("Exact item names, comma separated.\nBuys all stock you can afford; rechecks when the stock refreshes.")

    -- Tween test: flies (tween only, no teleports) to the chosen island, same route the merchant uses
    local function islandModels()
        local list, folder = {}, workspace:FindFirstChild("Islands")
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") then table.insert(list, m) end
            end
        end
        table.sort(list, function(a, b) return a.Name < b.Name end)
        return list
    end

    local function islandNames()
        local names = {}
        for _, m in ipairs(islandModels()) do table.insert(names, m.Name) end
        return names
    end

    local selectedIsland
    Boxes.tween:AddDropdown("TweenIsland", {
        Options  = islandNames(),
        Text     = "Island",
        Callback = function(name) selectedIsland = name end,
    })

    local function islandGoal()
        for _, m in ipairs(islandModels()) do
            if m.Name == selectedIsland then
                local center = m:GetAttribute("islandCFrame")
                center = typeof(center) == "CFrame" and center.Position or m:GetPivot().Position
                return Move.groundAt(center) + Vector3.new(0, 3, 0)
            end
        end
    end

    -- each toggle run gets a token; turning the toggle off (or starting another run) invalidates it
    local runToken = 0
    local function startRun(route)
        local goal = islandGoal()
        if not goal then
            Win:Notify({ Title = "Tween", Message = "pick an island first", Type = "error", Duration = 3 })
            return
        end
        if State.isBuying then
            Win:Notify({ Title = "Tween", Message = "busy", Type = "warning", Duration = 3 })
            return
        end
        runToken += 1
        local mine = runToken
        local function active() return runToken == mine end
        task.spawn(function()
            route(goal, active)
            if active() then Move.clear() end
        end)
    end

    local function stopRun()
        runToken += 1
        Move.cancelTween()
        Move.clear()
    end

    Boxes.tween:AddToggle("TweenIsland", {
        Text     = "Tween to Island",
        Default  = false,
        Callback = function(on)
            if on then
                startRun(function(goal, active) Move.tweenIsland(goal, C.TWEEN_SPEED_MERCHANT, active) end)
            else
                stopRun()
            end
        end,
    })
    Boxes.tween:AddToggle("TPIsland", {
        Text     = "TP to Island",
        Default  = false,
        Callback = function(on)
            if on then
                startRun(function(goal, active) Move.tpTravel(goal, active) end)
            else
                stopRun()
            end
        end,
    })
    Boxes.tween:AddLabel("Geppo + TP up 100, then tween straight (or TP 35-stud steps) to the island.")

    -- TAB: EVENT — Trick or Treat
    State.ui.toggles["AutoTrickOrTreat"] = Boxes.trick:AddToggle("AutoTrickOrTreat", {
        Text     = "Auto Trick or Treat",
        Default  = getgenv().gpoConfig.Trick.toggle,
        Callback = function(on)
            if on then
                -- no noclip here: inside the island the character walks (noclip gets flagged)
                task.spawn(function()
                    while Win.Flags["AutoTrickOrTreat"] do
                        local ok, err = pcall(ctx.Trick.cycle)
                        if not ok then
                            Util.log("trick or treat error: " .. tostring(err))
                            task.wait(2)
                        end
                    end
                    ctx.Trick.stop()
                end)
            else
                stopMovementIfIdle()
            end
            Win:Notify({
                Title   = "Trick or Treat",
                Message = on and "started" or "stopped",
                Type    = on and "success" or "warning",
            })
        end,
    })
    Boxes.trick:AddLabel("Needs a candy basket (Pumpkin Bag / Pumpkin Basket /\nCandy Corn Basket — uses the biggest one you own).\nGoes to Spooksville and walks door to door,\nskipping the ones on cooldown. Fights off Candy Skeletons\nand Wandering Souls when one hits you.")

    -- Halloween shop: comma separated item names (Candy-priced only), bought from the pot
    getgenv().gpoConfig.Trick = getgenv().gpoConfig.Trick or {}
    getgenv().gpoConfig.Trick.itemsToBuy = getgenv().gpoConfig.Trick.itemsToBuy or {}
    -- Every item of the Halloween shop (the names in its Prices attribute)
    local HALLOWEEN_SHOP_ITEMS = {
        "Pumpkin Basket", "Candy Corn Basket", "Pumpkin Bag", "Lantern", "Mummy Wrappings",
        "Frankenstein Costume", "Tung Sahur Costume", "Plague Doctor Costume", "Joker Costume",
        "Shark Costume", "Ghost Face Costume", "Wizard Costume", "Devil Fruit Journal",
        "Spare Fruit Bag", "SP Reset Essence", "Spirit Color Essence", "Trading Sign",
        "Blood Scythe", "Race Reroll x5", "Dark Root", "Rare Fruit Chest",
        "Legendary Fruit Chest Blueprint",
    }
    Boxes.trick:AddDropdown("TrickShopItems", {
        Options  = HALLOWEEN_SHOP_ITEMS,
        Default  = getgenv().gpoConfig.Trick.itemsToBuy,
        Multi    = true,
        Text     = "Shop items to buy",
        Callback = function(selected)
            -- the library passes the selection either as a list of names or as name -> true
            local list = {}
            for k, v in pairs(selected or {}) do
                if type(v) == "string" then table.insert(list, v)
                elseif v == true and type(k) == "string" then table.insert(list, k) end
            end
            getgenv().gpoConfig.Trick.itemsToBuy = list
        end,
    })

    -- Priority 1 is bought first (Rare Fruit Chest is capped at 10 owned); priority 2 uses the candy left over
    local PRIORITY_OPTIONS = { "None" }
    for _, name in ipairs(HALLOWEEN_SHOP_ITEMS) do table.insert(PRIORITY_OPTIONS, name) end
    for _, key in ipairs({ "priority1", "priority2" }) do
        local label = key == "priority1" and "Priority 1" or "Priority 2"
        Boxes.trick:AddDropdown(label:gsub(" ", ""), {
            Options  = PRIORITY_OPTIONS,
            Default  = getgenv().gpoConfig.Trick[key] or "None",
            Text     = label,
            Callback = function(choice)
                getgenv().gpoConfig.Trick[key] = choice ~= "None" and choice or nil
            end,
        })
    end

    -- Stats panel, refreshed every second
    local trickStatsLabel = Boxes.trickStats:AddLabel("Waiting for data...")
    Boxes.trickStats:AddButton({
        Text = "Reset Stats",
        Func = function()
            ctx.Trick.resetStats()
            Win:Notify({ Title = "Trick or Treat", Message = "stats reset", Type = "warning", Duration = 3 })
        end,
    })

    local function formatTime(sec)
        sec = math.floor(sec)
        return ("%02d:%02d:%02d"):format(sec // 3600, sec % 3600 // 60, sec % 60)
    end

    task.spawn(function()
        while task.wait(1) do
            local ok, s = pcall(function() return ctx.Trick.getStats() end)
            if ok and type(s) == "table" then
                local net    = s.gained - s.lost
                local perHour = s.elapsed > 60 and math.floor(net / s.elapsed * 3600) or 0
                local winRate = s.knocks > 0 and math.floor(s.treats / s.knocks * 100) or 0
                pcall(function()
                    trickStatsLabel:SetText(table.concat({
                        ("Status: %s"):format(s.status),
                        ("Candy: %d / %d"):format(s.candy, s.maxCandy),
                        "",
                        ("Doors ready: %d / %d"):format(s.doorsReady, s.doorsTotal),
                        ("Doors not on your cooldown: %d"):format(s.doorsAvailable),
                        "",
                        ("Knocks: %d   (ignored: %d)"):format(s.knocks, s.ignored),
                        ("Treats: %d   Tricks: %d   Nothing: %d"):format(s.treats, s.tricks, s.nothing),
                        ("Treat rate: %d%%"):format(winRate),
                        "",
                        ("Candy gained: +%d   lost: -%d"):format(s.gained, s.lost),
                        ("Net: %+d   (%+d / hour)"):format(net, perHour),
                        ("Session: %s"):format(formatTime(s.elapsed)),
                    }, "\n"))
                end)
            end
        end
    end)

    -- TAB: UNU — ESP
    Boxes.esp:AddToggle("IslandESP", {
        Text     = "Island ESP",
        Default  = false,
        Callback = function(on) ctx.Esp.setIslands(on) end,
    })

    -- TAB: UNU
    local function addUnu(id, label, onFn, offFn)
        local toggle = Boxes.unu:AddToggle(id, {
            Text     = label,
            Default  = false,
            Callback = function(on)
                if on and onFn then onFn() elseif not on and offFn then offFn() end
                Win:Notify({
                    Title   = label,
                    Message = on and "enabled" or "disabled",
                    Type    = on and "success" or "warning",
                })
            end,
        })
        State.ui.toggles[id] = toggle
        return toggle
    end

    addUnu("InfM1",   "Inf M1",          nil, nil)
    addUnu("AntiAFK", "Anti AFK",        nil, nil)

    -- TAB: CONFIG
    State.ui.webhookInput = Boxes.webhook:AddInput("WebhookURL", {
        Text        = "Webhook URL",
        Placeholder = "https://discord.com/api/webhooks/...",
        Default     = getgenv().gpoConfig.webhook.webhookURL or "",
    })
    Boxes.webhook:AddButton({
        Text = "Test Webhook",
        Func = function()
            if not Webhook.enabled() then
                Win:Notify({ Title = "Webhook", Message = "no URL set (UI box, or config with toggle = true)", Type = "error" })
                return
            end
            Webhook.report("webhook test")
            Win:Notify({ Title = "Webhook", Message = "test sent!", Type = "success" })
        end,
    })
    Boxes.webhook:AddLabel(
        "Sends: level-ups, status reports, geppo,\nHalloween shop buys and the merchant.\nSettings in gpoConfig.webhook.")

    return Win
end

return build

end

_MODULES["util.lua"] = function()
-- util.lua — General utilities
-- Receives: ctx { C, State, Services, LocalPlayer, HttpService }

local function build(ctx)
    local State       = ctx.State
    local HttpService = ctx.HttpService
    local LocalPlayer = ctx.LocalPlayer
    local C           = ctx.C

    local Util = {}

    local LOG_KEEP = 500
    local logHistory = {}
    local logFile

    local function getLogFile()
        if logFile then return logFile end
        local name = game:GetService("Players").LocalPlayer.Name
        logFile = "gpo_log_" .. name .. ".txt"
        -- keep the previous session (the one that crashed) before this one overwrites it
        pcall(function()
            if isfile and readfile and isfile(logFile) then
                writefile("gpo_log_" .. name .. "_prev.txt", readfile(logFile))
            end
        end)
        return logFile
    end

    -- UI log tab: last UI_KEEP messages, newest on top
    local UI_KEEP = 100
    local uiHistory = {}

    local function refreshLogLabel()
        local label = State.ui.log
        if not label then return end
        local lines = {}
        for i = #uiHistory, 1, -1 do lines[#lines + 1] = uiHistory[i] end
        label:SetText(#lines > 0 and table.concat(lines, "\n") or "Idle...")
    end

    function Util.clearLog()
        table.clear(uiHistory)
        refreshLogLabel()
    end

    -- fileOnly: diagnostics that go to the log file but not to the Console tab
    function Util.log(msg, fileOnly)
        local line = ("[%s] %s"):format(os.date("%m-%d %H:%M:%S"), msg)
        if not fileOnly then
            table.insert(uiHistory, ("[%s] %s"):format(os.date("%H:%M:%S"), msg))
            if #uiHistory > UI_KEEP then table.remove(uiHistory, 1) end
            refreshLogLabel()
        end
        if writefile then
            local file = getLogFile()
            table.insert(logHistory, line)
            if #logHistory > LOG_KEEP then table.remove(logHistory, 1) end
            pcall(writefile, file, table.concat(logHistory, "\n"))
        end
    end

    -- Crash diagnostics: session header, 30 s heartbeat (memory / fps / status), frame-hitch
    -- detector and the game's own errors/warnings, all into the log file.
    function Util.startDiagnostics(getStatus)
        if State.diagStarted then return end
        State.diagStarted = true
        local RunService = game:GetService("RunService")
        local Stats      = game:GetService("Stats")
        local LogService = game:GetService("LogService")
        local started    = os.clock()

        local executor = "?"
        pcall(function() executor = table.concat({ identifyexecutor() }, " ") end)
        Util.log(("=== SESSION START place=%s job=%s executor=%s ==="):format(
            tostring(game.PlaceId), tostring(game.JobId), executor))

        local frames, lastBeat = 0, os.clock()
        RunService.RenderStepped:Connect(function() frames += 1 end)

        local lastHitchLog = 0
        RunService.Heartbeat:Connect(function(dt)
            if dt > 1 and os.clock() - lastHitchLog > 5 then
                lastHitchLog = os.clock()
                Util.log(("HITCH: frame took %.1fs (status: %s)"):format(dt, tostring(getStatus and getStatus())))
            end
        end)

        local seen = {}
        LogService.MessageOut:Connect(function(msg, kind)
            if kind ~= Enum.MessageType.MessageError and kind ~= Enum.MessageType.MessageWarning then return end
            local key = msg:sub(1, 120)
            local now = os.clock()
            if seen[key] and now - seen[key] < 30 then return end
            seen[key] = now
            local tag = kind == Enum.MessageType.MessageError and "GAME ERROR" or "GAME WARN"
            Util.log(tag .. ": " .. msg:sub(1, 300))
        end)

        task.spawn(function()
            while true do
                task.wait(30)
                local now = os.clock()
                local fps = frames / math.max(now - lastBeat, 0.001)
                frames, lastBeat = 0, now
                local luaMB = collectgarbage("count") / 1024
                local totalMB = 0
                pcall(function() totalMB = Stats:GetTotalMemoryUsageMb() end)
                local npcs = workspace:FindFirstChild("NPCs")
                Util.log(("BEAT up=%dm lua=%.1fMB total=%.0fMB fps=%.0f npcs=%d players=%d status=%s"):format(
                    (now - started) // 60, luaMB, totalMB, fps,
                    npcs and #npcs:GetChildren() or -1,
                    #game:GetService("Players"):GetPlayers(),
                    tostring(getStatus and getStatus())), true)
                -- what kind of engine memory: top 6 categories
                pcall(function()
                    local tags = {}
                    for _, tag in ipairs(Enum.DeveloperMemoryTag:GetEnumItems()) do
                        local mb = Stats:GetMemoryUsageMbForTag(tag)
                        if mb > 1 then table.insert(tags, { tag.Name, mb }) end
                    end
                    table.sort(tags, function(a, b) return a[2] > b[2] end)
                    local parts = {}
                    for i = 1, math.min(6, #tags) do parts[i] = ("%s=%.0f"):format(tags[i][1], tags[i][2]) end
                    Util.log("  MEM " .. table.concat(parts, " "), true)
                end)
                -- where instances pile up: descendant count per top-level folder, and what grew
                pcall(function()
                    local counts, total, grew = {}, 0, {}
                    local roots = workspace:GetChildren()
                    table.insert(roots, LocalPlayer:FindFirstChild("PlayerGui"))
                    for _, root in ipairs(roots) do
                        if root and not root:IsA("Terrain") then
                            local n = #root:GetDescendants()
                            local key = root == workspace.CurrentCamera and "Camera" or root.Name
                            counts[key] = (counts[key] or 0) + n
                            total += n
                        end
                    end
                    State.diagCounts = State.diagCounts or {}
                    for k, n in pairs(counts) do
                        local before = State.diagCounts[k]
                        if before and n - before >= 200 then table.insert(grew, ("%s +%d (%d)"):format(k, n - before, n)) end
                    end
                    State.diagCounts = counts
                    Util.log(("  INST total=%d%s"):format(total, #grew > 0 and (" GREW: " .. table.concat(grew, ", ")) or ""), true)
                end)
                -- forget old dedupe keys so the table can't grow forever
                for k, t in pairs(seen) do if now - t > 300 then seen[k] = nil end end
            end
        end)
    end

    function Util.try(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then Util.log("Error: " .. tostring(err)) end
        return ok, err
    end

    -- Fire a RemoteEvent server-side; silently skips if remote is nil.
    function Util.fire(remote, ...)
        if not remote then return end
        local args = {...}
        pcall(function() remote:FireServer(unpack(args)) end)
    end

    -- Invoke a RemoteFunction server-side; returns result or nil on error.
    function Util.invoke(remote, ...)
        if not remote then return nil end
        local args = {...}
        local ok, res = pcall(function() return remote:InvokeServer(unpack(args)) end)
        return ok and res or nil
    end

    function Util.getHRP()
        local char = LocalPlayer.Character
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    function Util.getHumanoid()
        local char = LocalPlayer.Character
        return char and char:FindFirstChildOfClass("Humanoid")
    end

    local function readUINumber(fn)
        local ok, v = pcall(fn)
        return ok and tonumber(tostring(v):match("%d+")) or nil
    end

    function Util.getLevel()
        return readUINumber(function()
            return LocalPlayer.PlayerGui.HUD.Main.Bars.Experience.Detail.Level.Text
        end)
    end

    function Util.getPelis()
        local ok, v = pcall(function()
            return LocalPlayer.PlayerGui.HUD.Main.Peli.TextLabel.Text
        end)
        if not ok or not v then return 0 end

        local text   = tostring(v):upper()
        local numStr = text:gsub("[^%d%.]", "")
        local mult   = 1
        if text:find("K") then mult = 1000
        elseif text:find("M") then mult = 1000000 end
        return (tonumber(numStr) or 0) * mult
    end

    function Util.getStrength()
        return readUINumber(function()
            return LocalPlayer.PlayerGui.Statistics.Main.Stats.Strength.Amount.Text
        end)
    end

    function Util.getDefense()
        return readUINumber(function()
            return LocalPlayer.PlayerGui.Statistics.Main.Stats.Defense.Amount.Text
        end)
    end

    function Util.getAvailableSP()
        return readUINumber(function()
            return LocalPlayer.PlayerGui.Statistics.Main.TopOptions.AvailableSP.Text
        end)
    end

    function Util.getQuestProgress()
        local ok, v = pcall(function()
            return LocalPlayer.PlayerGui.Quest.Main.Info.Top.Progress.Text
        end)
        return ok and v or nil
    end

    -- Name of the current quest ("None" when there is none)
    function Util.getCurrentQuest()
        local ok, v = pcall(function()
            return ctx.RepStorage["Stats" .. LocalPlayer.Name].Quest.CurrentQuest.Value
        end)
        return ok and v or nil
    end

    function Util.isQuestActive()
        local ok, v = pcall(function()
            return LocalPlayer.PlayerGui.Quest.Main.Visible
        end)
        return ok and v == true
    end

    function Util.isAtFishmanIsland()
        local hrp = Util.getHRP()
        return hrp and (hrp.Position - C.FISHMAN_SPAWN).Magnitude < C.FISHMAN_RADIUS
    end

    function Util.isNearSurface()
        local hrp = Util.getHRP()
        return hrp and (hrp.Position - C.TRAVEL_SEA_SURFACE).Magnitude < C.SURFACE_RADIUS
    end

    function Util.getInventory()
        local inv = {}
        Util.try(function()
            local RepStorage = ctx.RepStorage
            local stats = RepStorage:FindFirstChild("Stats" .. LocalPlayer.Name)
            local val   = stats and stats:FindFirstChild("Inventory")
                and stats.Inventory:FindFirstChild("Inventory")
            if val and type(val.Value) == "string" then
                inv = HttpService:JSONDecode(val.Value)
            end
        end)
        return inv
    end

    function Util.getBaitCount(name)
        return Util.getInventory()[name] or 0
    end

    function Util.getFarmConfig(level, FarmConfigs)
        level = level or Util.getLevel() or 0
        return level >= C.FISHMAN_MIN_LEVEL and FarmConfigs.fishman or FarmConfigs.bandit
    end

    function Util.getRods()
        local rods   = { "Fishing Rod", "Devil Fruit Rod", "Lovestruck Rod" }
        local rodSet = {}
        for _, r in ipairs(rods) do rodSet[r] = true end
        local containers = { LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character }
        for _, container in ipairs(containers) do
            if container then
                for _, item in ipairs(container:GetChildren()) do
                    if item:IsA("Tool") and string.find(string.lower(item.Name), "rod") then
                        if not rodSet[item.Name] then
                            table.insert(rods, item.Name)
                            rodSet[item.Name] = true
                        end
                    end
                end
            end
        end
        return rods
    end

    return Util
end

return build

end

_MODULES["webhook.lua"] = function()
-- webhook.lua — Discord webhook notifications
-- Receives: ctx { C, State, Util, HttpService, LocalPlayer, RepStorage }
--
-- gpoConfig.webhook:
--   toggle      send from the config URL (the URL typed in the UI always works)
--   webhookURL  Discord webhook URL
--   pingUserId  Discord user id to @mention on important events (geppo, Halloween buys); "" = none
--   levelEvery  send a level-up every N levels (0 = off)
--   reportEvery send an account status report every N minutes (0 = off)

local function build(ctx)
    local C           = ctx.C
    local State       = ctx.State
    local Util        = ctx.Util
    local HttpService = ctx.HttpService
    local LocalPlayer = ctx.LocalPlayer

    local Webhook = {}

    local function cfg()
        local g = getgenv().gpoConfig
        return (g and g.webhook) or {}
    end

    -- The UI box starts with the config URL. Config URL: only with webhook.toggle = true.
    -- A different URL typed in the box always works.
    local function getURL()
        local w = cfg()
        local cfgURL = type(w.webhookURL) == "string" and w.webhookURL or ""
        local input = State.ui.webhookInput
        local typed = input and input.Text or ""
        if typed ~= "" and typed ~= cfgURL then return typed end
        if w.toggle and cfgURL ~= "" then return cfgURL end
        return nil
    end

    function Webhook.enabled() return getURL() ~= nil end

    local httpRequest = request or http_request or (syn and syn.request) or (http and http.request)

    local function avatarURL()
        return ("https://www.roblox.com/headshot-thumbnail/image?userId=%d&width=150&height=150&format=png")
            :format(LocalPlayer.UserId)
    end

    local function stat(path)
        local ok, v = pcall(function()
            local node = ctx.RepStorage["Stats" .. LocalPlayer.Name]
            for part in path:gmatch("[^%.]+") do node = node[part] end
            return node.Value
        end)
        return ok and v or nil
    end

    local function owned(item)
        local ok, data = pcall(function()
            return HttpService:JSONDecode(ctx.RepStorage["Stats" .. LocalPlayer.Name].Inventory.Inventory.Value)
        end)
        return ok and tonumber(data[item]) or 0
    end

    local function fmtNum(n)
        n = tonumber(n)
        if not n then return "?" end
        local s = tostring(math.floor(n))
        return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
    end

    -- the account snapshot attached to most embeds
    function Webhook.statusFields()
        local f = {
            { name = "Level",  value = "`" .. fmtNum(stat("Stats.Level")) .. "`", inline = true },
            { name = "Peli",   value = "`" .. fmtNum(stat("Stats.Peli")) .. "`",  inline = true },
            { name = "SP",     value = "`" .. fmtNum(stat("Stats.SkillPoints")) .. "`", inline = true },
            { name = "Stats",  value = ("`STR %s · DEF %s · STA %s`"):format(
                fmtNum(stat("Stats.Strength")), fmtNum(stat("Stats.Defense")), fmtNum(stat("Stats.Stamina"))), inline = false },
        }
        local candy = stat("Inventory.Halloween26Candy")
        if candy then
            table.insert(f, { name = "Candy", value = "`" .. fmtNum(candy) .. "`", inline = true })
            table.insert(f, { name = "Rare Fruit Chests", value = "`" .. owned("Rare Fruit Chest") .. "/10`", inline = true })
        end
        local rerolls = stat("Stats.RaceRerolls")
        if rerolls then
            table.insert(f, { name = "Race Rerolls", value = "`" .. fmtNum(rerolls) .. "`", inline = true })
        end
        local geppo = stat("Skills.skyWalk")
        if geppo ~= nil then
            table.insert(f, { name = "Geppo", value = geppo and "`yes`" or "`no`", inline = true })
        end
        return f
    end

    local function buildPayload(title, description, color, fields, ping)
        local thumb = avatarURL()
        local w = cfg()
        local content
        if ping and type(w.pingUserId) == "string" and w.pingUserId:match("^%d+$") then
            content = "<@" .. w.pingUserId .. ">"
        end
        return {
            username   = "Ousi",
            avatar_url = thumb,
            content    = content,
            embeds = {{
                title       = title,
                description = description,
                color       = color,
                fields      = fields,
                thumbnail   = { url = thumb },
                footer      = { text = ("Ousi • %s"):format(LocalPlayer.Name), icon_url = thumb },
                timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }},
        }
    end

    -- One sender thread: Discord rate-limits bursts, so messages go out spaced, and a 429 is
    -- retried after the time it asks for.
    local queue, sending = {}, false

    local function post(payload)
        local url = getURL()
        if not url then return false, "No webhook URL configured" end
        if not httpRequest then return false, "executor has no http request function" end
        local ok, res = pcall(httpRequest, {
            Url     = url,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode(payload),
        })
        if not ok then return false, tostring(res) end
        local code = res and res.StatusCode
        if code == 429 then
            local wait = 2
            pcall(function() wait = HttpService:JSONDecode(res.Body).retry_after or wait end)
            return false, "rate limited", wait
        end
        if code and (code < 200 or code >= 300) then return false, "HTTP " .. tostring(code) end
        return true
    end

    local function pump()
        if sending then return end
        sending = true
        task.spawn(function()
            while #queue > 0 do
                local job = table.remove(queue, 1)
                local ok, err, retry = post(job.payload)
                if not ok and retry and job.tries < 3 then
                    job.tries += 1
                    table.insert(queue, 1, job)
                    task.wait(retry + 0.5)
                else
                    if ok then Util.log("Webhook sent: " .. job.title)
                    else Util.log("Webhook failed (" .. job.title .. "): " .. tostring(err)) end
                    task.wait(1.2)
                end
            end
            sending = false
        end)
    end

    function Webhook.send(title, description, color, fields, ping)
        if not Webhook.enabled() then return false end
        table.insert(queue, { title = title, tries = 0,
            payload = buildPayload(title, description, color, fields, ping) })
        pump()
        return true
    end

    -- Events

    function Webhook.farmLevel(level)
        Webhook.send(
            "Level " .. tostring(level) .. " reached",
            "> **" .. LocalPlayer.Name .. "** reached level **" .. tostring(level) .. "**.",
            C.WEBHOOK_COLOR_FARM, Webhook.statusFields())
    end

    function Webhook.fishmanArrival()
        Webhook.send(
            "Arrived at Fishman Island",
            "> **" .. LocalPlayer.Name .. "** traveled to **Fishman Island**.",
            C.WEBHOOK_COLOR_FISHMAN, Webhook.statusFields())
    end

    function Webhook.geppoBought(level)
        Webhook.send(
            "Geppo bought",
            ("> **%s** bought **Sky Walk 2** at level **%s**."):format(LocalPlayer.Name, tostring(level)),
            C.WEBHOOK_COLOR_FARM, Webhook.statusFields(), true)
    end

    -- purchases = { {name = "Rare Fruit Chest", count = 1}, ... }
    function Webhook.trickShop(purchases)
        if #purchases == 0 then return end
        local lines = {}
        for _, p in ipairs(purchases) do
            table.insert(lines, ("• **%dx %s**"):format(p.count, p.name))
        end
        Webhook.send(
            "Halloween shop — bought " .. #purchases .. " item" .. (#purchases > 1 and "s" or ""),
            table.concat(lines, "\n"),
            C.WEBHOOK_COLOR_HALLOWEEN, Webhook.statusFields(), true)
    end

    function Webhook.report(activity)
        Webhook.send(
            "Status report",
            ("> **%s** is running — `%s`"):format(LocalPlayer.Name, tostring(activity or "idle")),
            C.WEBHOOK_COLOR_REPORT, Webhook.statusFields())
    end

    function Webhook.merchant(items)
        local fields = {}
        for _, item in ipairs(items) do
            table.insert(fields, {
                name   = item.name,
                value  = "`" .. item.price .. " Peli`" .. (item.stock and ("\n" .. item.stock) or ""),
                inline = true,
            })
        end
        if #fields == 0 then fields = {{ name = "Items", value = "`Shop is empty`" }} end
        Webhook.send(("Traveling Merchant — %d items"):format(#items),
            "> Items available in the shop.", C.WEBHOOK_COLOR_MERCHANT, fields)
    end

    return Webhook
end

return build

end


-- WAIT FOR GAME
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(2)

-- GLOBAL CONFIG — defaults for any value not set by the user
do
    local cfg = getgenv().gpoConfig or {}
    cfg.Main     = cfg.Main     or {}
    cfg.Merchant = cfg.Merchant or {}
    cfg.webhook  = cfg.webhook  or {}

    cfg.Main.Kaitun    = cfg.Main.Kaitun    ~= nil and cfg.Main.Kaitun    or false
    cfg.Main.geppo     = cfg.Main.geppo     ~= nil and cfg.Main.geppo     or false
    cfg.Main.vipServer = cfg.Main.vipServer ~= nil and cfg.Main.vipServer or ""
    cfg.Main.Sea       = cfg.Main.Sea       ~= nil and cfg.Main.Sea       or "First Sea"
    cfg.Main.rejoinVip = cfg.Main.rejoinVip ~= nil and cfg.Main.rejoinVip or false
    cfg.Main.rejoinAfter = cfg.Main.rejoinAfter or 12
    cfg.Main.geppoLevel  = cfg.Main.geppoLevel or 0

    cfg.Merchant.toggle     = cfg.Merchant.toggle     ~= nil and cfg.Merchant.toggle     or false
    cfg.Merchant.itemsToBuy = cfg.Merchant.itemsToBuy or {}

    cfg.webhook.toggle     = cfg.webhook.toggle     ~= nil and cfg.webhook.toggle     or false
    cfg.webhook.webhookURL  = cfg.webhook.webhookURL or ""
    cfg.webhook.pingUserId  = cfg.webhook.pingUserId or ""
    cfg.webhook.levelEvery  = cfg.webhook.levelEvery or 25
    cfg.webhook.reportEvery = cfg.webhook.reportEvery or 30

    cfg.Stats = cfg.Stats or {}
    cfg.Stats.toggle   = cfg.Stats.toggle ~= nil and cfg.Stats.toggle or false
    cfg.Stats.priority = cfg.Stats.priority or {}

    cfg.Trick = cfg.Trick or {}
    cfg.Trick.toggle      = cfg.Trick.toggle ~= nil and cfg.Trick.toggle or false
    cfg.Trick.itemsToBuy  = cfg.Trick.itemsToBuy or {}

    getgenv().gpoConfig = cfg
end

-- PlaceId 1730877806: solo si Kaitun=true y vipServer configurado
local LOBBY_PLACE_ID = 1730877806
local mainCfg = getgenv().gpoConfig.Main

if game.PlaceId ~= LOBBY_PLACE_ID and mainCfg.rejoinVip and mainCfg.vipServer ~= "" then
    local TeleportService = game:GetService("TeleportService")
    local LocalPlayer     = game:GetService("Players").LocalPlayer

    -- real server age from the game's own HUD, "HH:MM:SS" (also accepts "MM:SS")
    local function serverAgeSeconds()
        local ok, text = pcall(function()
            return LocalPlayer.PlayerGui.Display.ServerAge.ContentText
        end)
        if not ok or type(text) ~= "string" then return nil end
        local nums = {}
        for n in text:gmatch("%d+") do table.insert(nums, tonumber(n)) end
        if #nums == 3 then return nums[1] * 3600 + nums[2] * 60 + nums[3] end
        if #nums == 2 then return nums[1] * 60 + nums[2] end
        return nil
    end

    task.spawn(function()
        local limit = (tonumber(mainCfg.rejoinAfter) or 12) * 60
        while true do
            task.wait(5)
            local age = serverAgeSeconds()
            if age and age >= limit then
                TeleportService:Teleport(LOBBY_PLACE_ID, LocalPlayer)
                return
            end
        end
    end)
end

if game.PlaceId == LOBBY_PLACE_ID and game.PrivateServerId == "" and (mainCfg.Kaitun or mainCfg.rejoinVip or getgenv().gpoConfig.Trick.toggle) and mainCfg.vipServer ~= "" then
    local Players    = game:GetService("Players")
    local RepStorage = game:GetService("ReplicatedStorage")
    local lp         = Players.LocalPlayer
    local gui        = lp.PlayerGui

    local sea = getgenv().gpoConfig.Main.Sea

    task.spawn(function()
        RepStorage:WaitForChild("Events"):WaitForChild("reserved"):InvokeServer(getgenv().gpoConfig.Main.vipServer)
    end)

    local chooseType = gui:WaitForChild("chooseType", 30)
    if not chooseType then
        warn("[VIP] chooseType no apareció")
        return
    end
    local regular
    local deadline = tick() + 20
    repeat
        regular = chooseType:FindFirstChild("Regular", true)
        if not regular then task.wait(0.25) end
    until regular or tick() > deadline
    if not regular then
        warn("[VIP] botón Regular no encontrado")
        return
    end
    if regular:IsA("GuiButton") then
        firesignal(regular.MouseButton1Click)
    else
        firesignal(regular.Activated)
    end

    local prompt   = gui:FindFirstChild("ConfirmationPrompt") or gui:WaitForChild("ConfirmationPrompt", 20)
    local remote   = prompt:WaitForChild("RemoteEvent")
    local isServer = prompt:GetAttribute("isServer")
    local options  = prompt:WaitForChild("Main"):WaitForChild("OptionsFrame")

    repeat task.wait() until #options:GetChildren() > 0

    local targetBtn
    for _, child in ipairs(options:GetChildren()) do
        if child:IsA("ImageButton") then
            local matchName  = child.Name:lower():find(sea:lower())
            local matchValue = tostring(child:GetAttribute("buttonValue")):lower():find(sea:lower())
            if matchName or matchValue then
                targetBtn = child
                break
            end
        end
    end

    if not targetBtn then
        warn("[!] No se encontró botón para '" .. sea .. "', usando el primero disponible")
        for _, child in ipairs(options:GetChildren()) do
            if child:IsA("ImageButton") then targetBtn = child; break end
        end
    end

    if targetBtn then
        local val = targetBtn:GetAttribute("buttonValue")
        if isServer == true then remote:FireServer(val) else prompt.clientEvent:Fire(val) end
        print("[VIP] Confirmado:", targetBtn.Name, "| buttonValue:", tostring(val))
    else
        warn("[VIP] No se encontró ningún ImageButton")
    end
    return
end

-- BASE URL — update to your own GitHub raw URL before deploying
local function load(file)
    if not _MODULES[file] then error("Module not found: " .. tostring(file)) end
    return _MODULES[file]()
end

-- SERVICES
local RunService   = cloneref(game:GetService("RunService"))
local TweenService = cloneref(game:GetService("TweenService"))
local Players      = cloneref(game:GetService("Players"))
local RepStorage   = cloneref(game:GetService("ReplicatedStorage"))
local HttpService  = cloneref(game:GetService("HttpService"))
local VIM          = cloneref(game:GetService("VirtualInputManager"))
local LocalPlayer  = Players.LocalPlayer

-- ANTI-CRAB
repeat task.wait(1.25) until RepStorage and LocalPlayer
pcall(function()
    pcall(function()
        local crabRemote = RepStorage:FindFirstChild("Crab_Strangler")
        if crabRemote then crabRemote:Destroy() end
    end)
    task.wait(1.25)
end)

-- REMOTE REFERENCES
local function waitSafe(parent, name, timeout)
    if not parent then return nil end
    return parent:WaitForChild(name, timeout or 5)
end

local EventsCont       = waitSafe(RepStorage, "Events")
local Events           = waitSafe(EventsCont, "CombatRegister")
local QuestRemote      = waitSafe(EventsCont, "Quest")
local StatsRemote      = waitSafe(EventsCont, "stats")
local SetSpawnRemote   = waitSafe(EventsCont, "SetSpawn")
local MerchantRemote   = waitSafe(EventsCont, "TravelingMerchentRemote")
local LearnStyleRemote = waitSafe(EventsCont, "learnStyle")
local SkillRemote      = waitSafe(EventsCont, "Skill")

local CombatAnimsCont = waitSafe(RepStorage, "CombatAnimations")
local CombatAnims     = waitSafe(CombatAnimsCont, "Melee")
local AnimsByIndex    = {}
if CombatAnims then
    for i, name in ipairs({ "Dash", "Punch2", "Punch3", "GroundPunch4" }) do
        AnimsByIndex[i] = waitSafe(CombatAnims, name)
    end
end

local FishingCont    = waitSafe(RepStorage, "Fishing")
local FishingRemotes = waitSafe(FishingCont, "Remotes")
local FishRemote     = waitSafe(FishingRemotes, "Action")

local CompassGuider    = waitSafe(RepStorage, "CompassGuider")
local MerchantPosValue = waitSafe(CompassGuider, "Traveling Merchant")

-- LOAD MODULES

-- 1. Config
local C, FarmConfigs, FishRarities = load("config.lua")

-- 2. State (depends on C and FarmConfigs)
local buildState = load("state.lua")
local State      = buildState(C, FarmConfigs)

-- Proxy system: modules that reference each other circularly receive a
-- thin proxy that forwards calls once the real module is wired in.
local function createProxy()
    local target = nil
    local proxy  = {}
    setmetatable(proxy, {
        __index = function(_, k)
            if target then return target[k] end
            return function() return nil end
        end
    })
    return proxy, function(real) target = real end
end

local farmProxy,     setFarm     = createProxy()
local fishProxy,     setFish     = createProxy()
local merchantProxy, setMerchant = createProxy()
local trickProxy,    setTrick    = createProxy()

-- Base context (proxies stand in for Farm/Fish/Merchant until wired below)
local ctx = {
    C            = C,
    FarmConfigs  = FarmConfigs,
    FishRarities = FishRarities,
    State        = State,
    RunService   = RunService,
    TweenService = TweenService,
    Players      = Players,
    RepStorage   = RepStorage,
    HttpService  = HttpService,
    VIM          = VIM,
    LocalPlayer  = LocalPlayer,
    Events           = Events,
    QuestRemote      = QuestRemote,
    StatsRemote      = StatsRemote,
    SetSpawnRemote   = SetSpawnRemote,
    MerchantRemote   = MerchantRemote,
    LearnStyleRemote = LearnStyleRemote,
    SkillRemote      = SkillRemote,
    FishRemote       = FishRemote,
    MerchantPosValue = MerchantPosValue,
    AnimsByIndex     = AnimsByIndex,
    Farm             = farmProxy,
    Fish             = fishProxy,
    Merchant         = merchantProxy,
    Trick            = trickProxy,
}

-- Utility modules
ctx.Util    = load("util.lua")(ctx)
ctx.Move    = load("move.lua")(ctx)
ctx.Combat  = load("combat.lua")(ctx)
ctx.Webhook = load("webhook.lua")(ctx)
ctx.Esp     = load("esp.lua")(ctx)

-- UI — returns Win and stores it in ctx.Win + State.win
local Win = load("ui.lua")(ctx)
ctx.Win   = Win

-- Wire real modules into proxies (Win is now available for Farm/Fish/Merchant)
setFarm(load("farm.lua")(ctx))
setFish(load("fish.lua")(ctx))
setMerchant(load("merchant.lua")(ctx))
setTrick(load("trickortreat.lua")(ctx))

-- Start all background loops (must be last — needs all modules ready)
load("runner.lua")(ctx)
