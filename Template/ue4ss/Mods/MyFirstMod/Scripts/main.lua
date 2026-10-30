-- MyFirstMod - RuneScape: Dragonwilds
-- Starter template with UE4SS Lua hooks, config.txt loader, and live Mod Menu 2.0 integration.

local TAG = "[MyFirstMod] "
local VERSION = "1.0.0"
local MODMENU_ID = "MyFirstMod"

local function log(msg)
    print(TAG .. tostring(msg) .. "\n")
end

-- Default settings (must match keys in config.txt and modmenu.json)
local cfg = {
    Enabled     = true,
    Multiplier  = 1.0,
    BonusAmount = 5,
    Mode        = "Detailed",
    Hotkey      = "F9",
    Verbose     = true,
}

local function dbg(msg)
    if cfg.Verbose then
        log("[DEBUG] " .. tostring(msg))
    end
end

local function isValid(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

--------------------------------------------------------------------------------
-- 1. Load config.txt from the mod folder
--------------------------------------------------------------------------------
local function getModRoot()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\]Scripts[/\\][^/\\]*$")
end

local function loadConfig()
    local root = getModRoot()
    if not root then
        log("Could not resolve mod root folder; using default settings.")
        return
    end
    local f = io.open(root .. "/config.txt", "r") or io.open(root .. "\\config.txt", "r")
    if not f then
        log("No config.txt found; using default settings.")
        return
    end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and cfg[k] ~= nil then
            v = v:gsub("%s+[#;].*$", "")
            if type(cfg[k]) == "boolean" then
                cfg[k] = (v:lower() == "true" or v == "1")
            elseif type(cfg[k]) == "number" then
                cfg[k] = tonumber(v) or cfg[k]
            else
                cfg[k] = v
            end
        end
    end
    f:close()
end

loadConfig()

--------------------------------------------------------------------------------
-- 2. Core Mod Logic (Called when settings change or hotkey is pressed)
--------------------------------------------------------------------------------
local function applyModSettings()
    if not cfg.Enabled then
        dbg("Mod is currently disabled.")
        return
    end

    dbg(string.format(
        "Applying settings -> Multiplier: %.1fx | BonusAmount: %d | Mode: %s",
        cfg.Multiplier, cfg.BonusAmount, cfg.Mode
    ))

    -- Example: Find the local PlayerController and inspect it safely
    local ok, pc = pcall(FindFirstOf, "PlayerController")
    if ok and isValid(pc) then
        dbg("Active PlayerController: " .. tostring(pc:GetFullName()))
    end
end

--------------------------------------------------------------------------------
-- 3. Mod Menu 2.0 Live Sync (Esc > MODS)
--------------------------------------------------------------------------------
local mmRev = nil
local lastAction = nil

local function getSharedVar(key)
    local ok, val = pcall(function()
        return ModRef:GetSharedVariable("ModMenu." .. MODMENU_ID .. "." .. key)
    end)
    if ok then return val end
    return nil
end

local function syncModMenu()
    -- Check if a setting was changed in Mod Menu
    local rev = getSharedVar("rev")
    if type(rev) == "number" and rev ~= mmRev then
        local isInitialSync = (mmRev == nil)
        mmRev = rev
        for k, oldVal in pairs(cfg) do
            local newVal = getSharedVar(k)
            if newVal ~= nil and type(newVal) == type(oldVal) and k ~= "Hotkey" then
                cfg[k] = newVal
            end
        end
        if not isInitialSync then
            log("Settings updated live from Mod Menu!")
        end
        applyModSettings()
    end

    -- Check if a button was clicked in Mod Menu
    local action = getSharedVar("action")
    if action ~= nil and action ~= lastAction then
        lastAction = action
        if tostring(action):match("^test_button#") then
            log("TEST ACTION button clicked in Mod Menu!")
            applyModSettings()
        end
    end
end

-- Run periodic sync on the game thread so UI / object calls are thread-safe
local okLoop = pcall(LoopInGameThreadWithDelay, 500, function()
    pcall(syncModMenu)
end)
if not okLoop then
    LoopAsync(500, function()
        pcall(ExecuteInGameThread, function() pcall(syncModMenu) end)
        return false
    end)
end

--------------------------------------------------------------------------------
-- 4. UE4SS Object Hooks & Keybinds
--------------------------------------------------------------------------------

-- Run code whenever a PlayerController spawns
NotifyOnNewObject("/Script/Engine.PlayerController", function(Controller)
    if not cfg.Enabled then return end
    dbg("PlayerController spawned: " .. tostring(Controller:GetFullName()))
end)

-- Example function hook (uncomment and replace with a real Dragonwilds Blueprint function path from Live View)
--[[
RegisterHook("/Game/Blueprints/Player/BP_PlayerCharacter.BP_PlayerCharacter_C:SomeFunction", function(Context)
    if not cfg.Enabled then return end
    local player = Context:get()
    if isValid(player) then
        dbg("Hook triggered on: " .. tostring(player:GetFullName()))
    end
end)
--]]

-- Register the hotkey configured in config.txt (default: F9)
local bindKey = Key[(cfg.Hotkey or "F9"):upper()]
if bindKey then
    RegisterKeyBind(bindKey, function()
        log(string.format("Hotkey (%s) pressed! Enabled=%s, Multiplier=%.1fx",
            tostring(cfg.Hotkey), tostring(cfg.Enabled), cfg.Multiplier))
        ExecuteInGameThread(function()
            pcall(applyModSettings)
        end)
    end)
else
    log("Warning: Invalid Hotkey '" .. tostring(cfg.Hotkey) .. "' in config.txt")
end

log("Loaded v" .. VERSION .. " successfully!")
