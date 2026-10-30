-- Lua Heap Cleaner & Crash Optimizer (LuaHeapCleaner) - RuneScape: Dragonwilds (UE4SS)
-- Version 1.1.0
--
-- How this mod reduces stutters & UE4SS Lua crashes:
--   1) Frame-Budgeted GC Step Pacer ("StepPacer"):
--      By default, Lua waits until its heap doubles and then triggers an un-splittable mark-and-sweep cycle
--      right in the middle of whatever hook/callback allocated memory (causing 20-40ms frame spikes and racing
--      with UE5's UObject destruction). StepPacer calls collectgarbage("stop") and runs tiny, time-budgeted
--      incremental steps exclusively on the Game Thread.
--   2) Lua 5.4 Generational & Tuned Incremental Modes:
--      Allows switching live in Mod Menu between StepPacer, Lua 5.4's Generational GC ("generational", 20, 100),
--      or Tuned Incremental GC ("incremental", 110, 400).
--   3) World / Map Transition Heap Flush:
--      Detects PlayerController / World changes and executes a debounced double-pass collectgarbage("collect")
--      so stale UObject userdata wrappers pointing to destroyed actors/widgets are finalized safely on the
--      Game Thread before UE5 recycles their memory addresses.
--   4) Soft-Cap Emergency Sweep & Optional UE5 Engine GC Assist:
--      Forces a clean sweep if the Lua heap exceeds SoftCapKB, and optionally invokes Unreal Engine's
--      KismetSystemLibrary:CollectGarbage() on a safe interval after flushing Lua userdata.
--   5) Cross-Mod Shared Signal & Shared Library:
--      Publishes "LuaHeapCleaner.*" state via ModRef:SetSharedVariable so any cooperative mod can flush
--      and pace its own VM in sync, and provides Scripts/heap_shield.lua for one-line integration.

local TAG = "[LuaHeapCleaner] "
local VERSION = "1.1.0"
local MODMENU_ID = "LuaHeapCleaner"

local function log(msg)
print(TAG .. tostring(msg) .. "\n")
end

local cfg = {
    Enabled             = true,
    GCMode              = "StepPacer",      -- "StepPacer", "Generational", "TunedIncremental"
    StepIntervalMs      = 250,
    StepSizeKB          = 8,
    RestThresholdKB     = 256,
    MaxStepBudgetMs     = 2.0,
    SoftCapKB           = 4096,
    CleanOnWorldChange  = true,
    EngineGCAssist      = false,
    EngineGCIntervalSec = 180,
    TelemetryLog        = true,
    Verbose             = false,
    FlushHotkey         = "F10",
}

local function dbg(msg)
if cfg.Verbose then
    log("[DEBUG] " .. tostring(msg))
    end
    end

    -- Zero-Allocation Helpers --------------------------------------------------------------------------
    local function callIsValid(o)
    return o:IsValid()
    end

    local function valid(o)
    if not o or type(o) ~= "userdata" then return false end
        local ok, v = pcall(callIsValid, o)
        return ok and v == true
        end

        local function callGetAddress(o)
        return o:GetAddress()
        end

        local function getAddress(o)
        if not valid(o) then return nil end
            local ok, addr = pcall(callGetAddress, o)
            return ok and addr or nil
            end

            local function setShared(key, val)
            if not ModRef or not ModRef.SetSharedVariable then return false end
                return pcall(ModRef.SetSharedVariable, ModRef, key, val)
                end

                local function getShared(key)
                if not ModRef or not ModRef.GetSharedVariable then return nil end
                    local ok, val = pcall(ModRef.GetSharedVariable, ModRef, key)
                    if ok then return val end
                        return nil
                        end

                        local function clamp(v, lo, hi)
                        return math.max(lo, math.min(hi, v))
                        end

                        local cachedModRoot = nil
                        local function modRoot()
                        if cachedModRoot then return cachedModRoot end
                            local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
                            cachedModRoot = src:match("^(.*)[/\\]Scripts[/\\][^/\\]*$")
                            return cachedModRoot
                            end

                            local function clampConfig()
                            if cfg.GCMode ~= "StepPacer" and cfg.GCMode ~= "Generational" and cfg.GCMode ~= "TunedIncremental" then
                                cfg.GCMode = "StepPacer"
                                end
                                cfg.StepIntervalMs      = math.floor(clamp(tonumber(cfg.StepIntervalMs) or 250, 50, 1000) + 0.5)
                                cfg.StepSizeKB          = math.floor(clamp(tonumber(cfg.StepSizeKB) or 8, 1, 64) + 0.5)
                                cfg.RestThresholdKB     = math.floor(clamp(tonumber(cfg.RestThresholdKB) or 256, 64, 2048) + 0.5)
                                cfg.MaxStepBudgetMs     = clamp(tonumber(cfg.MaxStepBudgetMs) or 2.0, 0.5, 8.0)
                                cfg.SoftCapKB           = math.floor(clamp(tonumber(cfg.SoftCapKB) or 4096, 1024, 16384) + 0.5)
                                cfg.EngineGCIntervalSec = math.floor(clamp(tonumber(cfg.EngineGCIntervalSec) or 180, 60, 600) + 0.5)
                                cfg.FlushHotkey         = tostring(cfg.FlushHotkey or "F10"):upper():gsub("^%s+", ""):gsub("%s+$", "")
                                if cfg.FlushHotkey == "" then cfg.FlushHotkey = "F10" end
                                    end

                                    local function loadConfig()
                                    local root = modRoot()
                                    if not root then
                                        log("Could not resolve mod folder; using defaults.")
                                        return
                                        end
                                        local f = io.open(root .. "/config.txt", "r") or io.open(root .. "\\config.txt", "r")
                                        if not f then
                                            log("No config.txt found; using defaults.")
                                            return
                                            end
                                            for line in f:lines() do
                                                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                                                if line ~= "" and line:sub(1, 1) ~= "#" then
                                                    local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
                                                    v = (v or ""):gsub("%s*[#;].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                                                    if k and cfg[k] ~= nil then
                                                        if type(cfg[k]) == "boolean" then
                                                            local w = v:lower()
                                                            cfg[k] = (w == "true" or w == "1" or w == "yes" or w == "on")
                                                            elseif type(cfg[k]) == "number" then
                                                                cfg[k] = tonumber(v) or cfg[k]
                                                                else
                                                                    cfg[k] = v:gsub('^"(.*)"$', "%1")
                                                                    end
                                                                    end
                                                                    end
                                                                    end
                                                                    f:close()
                                                                    clampConfig()
                                                                    end

                                                                    local CONFIG_KEYS_ORDER = {
                                                                        "Enabled", "GCMode", "StepIntervalMs", "StepSizeKB", "RestThresholdKB",
                                                                        "MaxStepBudgetMs", "SoftCapKB", "CleanOnWorldChange", "EngineGCAssist",
                                                                        "EngineGCIntervalSec", "TelemetryLog", "Verbose", "FlushHotkey"
                                                                    }

                                                                    local function saveConfig()
                                                                    local root = modRoot()
                                                                    if not root then return end
                                                                        local f = io.open(root .. "/config.txt", "w") or io.open(root .. "\\config.txt", "w")
                                                                        if not f then return end
                                                                            f:write("# LuaHeapCleaner Configuration (Auto-synced with Mod Menu)\n")
                                                                            for _, k in ipairs(CONFIG_KEYS_ORDER) do
                                                                                local v = cfg[k]
                                                                                if type(v) == "string" then
                                                                                    f:write(string.format('%s = "%s"\n', k, v))
                                                                                    elseif type(v) == "number" and k == "MaxStepBudgetMs" then
                                                                                        f:write(string.format("%s = %.1f\n", k, v))
                                                                                        else
                                                                                            f:write(string.format("%s = %s\n", k, tostring(v)))
                                                                                            end
                                                                                            end
                                                                                            f:close()
                                                                                            end

                                                                                            loadConfig()

                                                                                            -- Telemetry & Pacer State --------------------------------------------------------------------------
                                                                                            local prevEpoch = tonumber(getShared("LuaHeapCleaner.FlushEpoch")) or 0
                                                                                            local prevCfgRev = tonumber(getShared("LuaHeapCleaner.ConfigRev")) or 0

                                                                                            local stats = {
                                                                                                windowStart   = os.clock(),
                                                                                                stepsRun      = 0,
                                                                                                cyclesDone    = 0,
                                                                                                fullFlushes   = 0,
                                                                                                totalStepMs   = 0,
                                                                                                maxStepMs     = 0,
                                                                                                totalFreedKB  = 0,
                                                                                                peakHeapKB    = collectgarbage("count"),
                                                                                                restUntilKB   = nil,
                                                                                                lastStepAt    = 0,
                                                                                                lastAuxTickAt = 0,
                                                                                                lastFlushAt   = -10,
                                                                                                lastEngineGC  = os.clock(),
                                                                                                flushEpoch    = prevEpoch,
                                                                                                configRev     = prevCfgRev,
                                                                                            }

                                                                                            local appliedMode = nil

                                                                                            local function publishSharedState(bumpConfigRev)
                                                                                            if bumpConfigRev then
                                                                                                stats.configRev = stats.configRev + 1
                                                                                                end
                                                                                                local root = modRoot()
                                                                                                if root then
                                                                                                    setShared("LuaHeapCleaner.ScriptsPath", root .. "/Scripts/?.lua")
                                                                                                    end
                                                                                                    setShared("LuaHeapCleaner.Enabled", cfg.Enabled)
                                                                                                    setShared("LuaHeapCleaner.GCMode", cfg.GCMode)
                                                                                                    setShared("LuaHeapCleaner.StepIntervalMs", cfg.StepIntervalMs)
                                                                                                    setShared("LuaHeapCleaner.StepSizeKB", cfg.StepSizeKB)
                                                                                                    setShared("LuaHeapCleaner.RestThresholdKB", cfg.RestThresholdKB)
                                                                                                    setShared("LuaHeapCleaner.MaxStepBudgetMs", cfg.MaxStepBudgetMs)
                                                                                                    setShared("LuaHeapCleaner.SoftCapKB", cfg.SoftCapKB)
                                                                                                    setShared("LuaHeapCleaner.FlushEpoch", stats.flushEpoch)
                                                                                                    setShared("LuaHeapCleaner.ConfigRev", stats.configRev)
                                                                                                    end

                                                                                                    -- Applies the chosen GC strategy to Lua's garbage collector
                                                                                                    local function configureCollector(force)
                                                                                                    if not cfg.Enabled then
                                                                                                        if appliedMode ~= "Disabled" or force then
                                                                                                            pcall(collectgarbage, "restart")
                                                                                                            pcall(collectgarbage, "incremental", 200, 200)
                                                                                                            pcall(collectgarbage, "setpause", 200)
                                                                                                            pcall(collectgarbage, "setstepmul", 200)
                                                                                                            appliedMode = "Disabled"
                                                                                                            stats.restUntilKB = nil
                                                                                                            publishSharedState(true)
                                                                                                            log("Collector restored to standard Lua defaults (mod disabled).")
                                                                                                            end
                                                                                                            return
                                                                                                            end

                                                                                                            if appliedMode == cfg.GCMode and not force then
                                                                                                                publishSharedState(true)
                                                                                                                return
                                                                                                                end
                                                                                                                appliedMode = cfg.GCMode
                                                                                                                stats.restUntilKB = nil

                                                                                                                if cfg.GCMode == "StepPacer" then
                                                                                                                    -- Stop automatic GC so it never interrupts random hooks mid-frame; mainTick drives it on GameThread
                                                                                                                    pcall(collectgarbage, "incremental", 110, 200, 13)
                                                                                                                    pcall(collectgarbage, "setpause", 110)
                                                                                                                    pcall(collectgarbage, "setstepmul", 200)
                                                                                                                    pcall(collectgarbage, "stop")
                                                                                                                    log(string.format("GC Mode: StepPacer active (Step=%d KB every %d ms, Rest=%d KB, Budget=%.1f ms, SoftCap=%d KB)",
                                                                                                                                      cfg.StepSizeKB, cfg.StepIntervalMs, cfg.RestThresholdKB, cfg.MaxStepBudgetMs, cfg.SoftCapKB))
                                                                                                                    elseif cfg.GCMode == "Generational" then
                                                                                                                        local ok = pcall(collectgarbage, "generational", 20, 100)
                                                                                                                        pcall(collectgarbage, "restart")
                                                                                                                        log("GC Mode: Lua 5.4 Generational collector active (" .. (ok and "20/100" or "fallback") .. ").")
                                                                                                                        elseif cfg.GCMode == "TunedIncremental" then
                                                                                                                            pcall(collectgarbage, "incremental", 110, 400, 12)
                                                                                                                            pcall(collectgarbage, "setpause", 110)
                                                                                                                            pcall(collectgarbage, "setstepmul", 400)
                                                                                                                            pcall(collectgarbage, "restart")
                                                                                                                            log("GC Mode: Tuned Incremental collector active (pause=110%, stepmul=400%).")
                                                                                                                            end

                                                                                                                            publishSharedState(true)
                                                                                                                            end

                                                                                                                            -- Full Heap Flush (Double-pass to finalize __gc userdata & reclaim tables in one go) ---------------
                                                                                                                            local kslCache = nil
                                                                                                                            local function callEngineCollectGarbage()
                                                                                                                            if not valid(kslCache) then
                                                                                                                                kslCache = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
                                                                                                                                end
                                                                                                                                if valid(kslCache) then
                                                                                                                                    kslCache:CollectGarbage()
                                                                                                                                    return true
                                                                                                                                    end
                                                                                                                                    return false
                                                                                                                                    end

                                                                                                                                    local function triggerEngineGC()
                                                                                                                                    local ok, ran = pcall(callEngineCollectGarbage)
                                                                                                                                    if ok and ran then
                                                                                                                                        dbg("Triggered Unreal Engine KismetSystemLibrary:CollectGarbage() on GameThread.")
                                                                                                                                        elseif not ok then
                                                                                                                                            dbg("Engine CollectGarbage skipped: " .. tostring(ran))
                                                                                                                                            end
                                                                                                                                            end

                                                                                                                                            local function performFullFlush(reason, includeEngineGC, isManual)
                                                                                                                                            local now = os.clock()
                                                                                                                                            if not isManual and (now - stats.lastFlushAt) < 1.0 then
                                                                                                                                                return
                                                                                                                                                end
                                                                                                                                                stats.lastFlushAt = now

                                                                                                                                                local beforeKB = collectgarbage("count")
                                                                                                                                                if beforeKB > stats.peakHeapKB then stats.peakHeapKB = beforeKB end

                                                                                                                                                    -- Pass 1 runs __gc metamethods on unreachable UObject userdata; Pass 2 frees the finalized userdata
                                                                                                                                                    pcall(collectgarbage, "collect")
                                                                                                                                                    pcall(collectgarbage, "collect")

                                                                                                                                                    if cfg.Enabled and cfg.GCMode == "StepPacer" then
                                                                                                                                                        pcall(collectgarbage, "stop")
                                                                                                                                                        end

                                                                                                                                                        local afterKB = collectgarbage("count")
                                                                                                                                                        local freedKB = math.max(0, beforeKB - afterKB)
                                                                                                                                                        local elapsedMs = (os.clock() - now) * 1000

                                                                                                                                                        stats.fullFlushes  = stats.fullFlushes + 1
                                                                                                                                                        stats.cyclesDone   = stats.cyclesDone + 1
                                                                                                                                                        stats.totalFreedKB = stats.totalFreedKB + freedKB
                                                                                                                                                        stats.restUntilKB  = afterKB + cfg.RestThresholdKB
                                                                                                                                                        stats.flushEpoch   = stats.flushEpoch + 1
                                                                                                                                                        setShared("LuaHeapCleaner.FlushEpoch", stats.flushEpoch)

                                                                                                                                                        if includeEngineGC then
                                                                                                                                                            triggerEngineGC()
                                                                                                                                                            stats.lastEngineGC = os.clock()
                                                                                                                                                            end

                                                                                                                                                            log(string.format("Full Heap Flush (%s): %.1f KB -> %.1f KB (freed %.1f KB in %.2f ms)",
                                                                                                                                                                              reason or "manual", beforeKB, afterKB, freedKB, elapsedMs))
                                                                                                                                                            end

                                                                                                                                                            -- Frame-Budgeted Incremental Step ------------------------------------------------------------------
                                                                                                                                                            local function performPacedStep(now)
                                                                                                                                                            if not cfg.Enabled then return end

                                                                                                                                                                local curKB = collectgarbage("count")
                                                                                                                                                                if curKB > stats.peakHeapKB then stats.peakHeapKB = curKB end

                                                                                                                                                                    -- 1. Emergency soft-cap check (applies in all active modes)
                                                                                                                                                                    if curKB >= cfg.SoftCapKB then
                                                                                                                                                                        performFullFlush(string.format("SoftCap %.0f >= %d KB", curKB, cfg.SoftCapKB), false, false)
                                                                                                                                                                        return
                                                                                                                                                                        end

                                                                                                                                                                        -- 2. In StepPacer mode, slice StepSizeKB into budgeted micro-steps on the Game Thread
                                                                                                                                                                        if cfg.GCMode == "StepPacer" then
                                                                                                                                                                            if stats.restUntilKB and curKB < stats.restUntilKB then
                                                                                                                                                                                return
                                                                                                                                                                                end

                                                                                                                                                                                local t0 = os.clock()
                                                                                                                                                                                local budgetSec = cfg.MaxStepBudgetMs / 1000.0
                                                                                                                                                                                local cycleFinished = false
                                                                                                                                                                                local remainingKB = cfg.StepSizeKB
                                                                                                                                                                                local sliceKB = math.max(1, math.ceil(cfg.StepSizeKB / 4))

                                                                                                                                                                                while remainingKB > 0 do
                                                                                                                                                                                    local chunk = math.min(sliceKB, remainingKB)
                                                                                                                                                                                    local ok, done = pcall(collectgarbage, "step", chunk)
                                                                                                                                                                                    remainingKB = remainingKB - chunk
                                                                                                                                                                                    if ok and done then
                                                                                                                                                                                        cycleFinished = true
                                                                                                                                                                                        break
                                                                                                                                                                                        end
                                                                                                                                                                                        if (os.clock() - t0) >= budgetSec then
                                                                                                                                                                                            break
                                                                                                                                                                                            end
                                                                                                                                                                                            end

                                                                                                                                                                                            local tookMs = (os.clock() - t0) * 1000
                                                                                                                                                                                            local afterKB = collectgarbage("count")
                                                                                                                                                                                            local freed = math.max(0, curKB - afterKB)

                                                                                                                                                                                            stats.stepsRun     = stats.stepsRun + 1
                                                                                                                                                                                            stats.totalStepMs  = stats.totalStepMs + tookMs
                                                                                                                                                                                            stats.maxStepMs    = math.max(stats.maxStepMs, tookMs)
                                                                                                                                                                                            stats.totalFreedKB = stats.totalFreedKB + freed

                                                                                                                                                                                            if cycleFinished then
                                                                                                                                                                                                stats.cyclesDone  = stats.cyclesDone + 1
                                                                                                                                                                                                stats.restUntilKB = afterKB + cfg.RestThresholdKB
                                                                                                                                                                                                dbg(string.format("Completed incremental GC cycle (heap: %.1f KB, resting until %.1f KB, step: %.2f ms)",
                                                                                                                                                                                                                  afterKB, stats.restUntilKB, tookMs))
                                                                                                                                                                                                end
                                                                                                                                                                                                end

                                                                                                                                                                                                -- 3. Optional periodic UE5 Engine GC assist
                                                                                                                                                                                                if cfg.EngineGCAssist and (now - stats.lastEngineGC) >= cfg.EngineGCIntervalSec then
                                                                                                                                                                                                    performFullFlush("Periodic EngineGCAssist", true, false)
                                                                                                                                                                                                    end
                                                                                                                                                                                                    end

                                                                                                                                                                                                    -- World / Map Transition Watchdog (Cached & Debounced) ---------------------------------------------
                                                                                                                                                                                                    local cachedPC = nil
                                                                                                                                                                                                    local lastPCAddr = nil
                                                                                                                                                                                                    local pendingWorldFlushAt = nil

                                                                                                                                                                                                    local function checkWorldTransition(now)
                                                                                                                                                                                                    if not cfg.Enabled or not cfg.CleanOnWorldChange then
                                                                                                                                                                                                        pendingWorldFlushAt = nil
                                                                                                                                                                                                        return
                                                                                                                                                                                                        end

                                                                                                                                                                                                        if pendingWorldFlushAt and now >= pendingWorldFlushAt then
                                                                                                                                                                                                            pendingWorldFlushAt = nil
                                                                                                                                                                                                            cachedPC = nil
                                                                                                                                                                                                            performFullFlush("World / Controller Transition", cfg.EngineGCAssist, false)
                                                                                                                                                                                                            return
                                                                                                                                                                                                            end

                                                                                                                                                                                                            local addr = getAddress(cachedPC)
                                                                                                                                                                                                            if not addr then
                                                                                                                                                                                                                cachedPC = nil
                                                                                                                                                                                                                local ok, pc = pcall(FindFirstOf, "PlayerController")
                                                                                                                                                                                                                if ok and valid(pc) then
                                                                                                                                                                                                                    cachedPC = pc
                                                                                                                                                                                                                    addr = getAddress(pc)
                                                                                                                                                                                                                    end
                                                                                                                                                                                                                    end

                                                                                                                                                                                                                    if addr ~= lastPCAddr then
                                                                                                                                                                                                                        local hadPrevious = (lastPCAddr ~= nil)
                                                                                                                                                                                                                        lastPCAddr = addr
                                                                                                                                                                                                                        if hadPrevious then
                                                                                                                                                                                                                            -- Release cached references immediately and allow 250ms for old world UObjects to finish teardown
                                                                                                                                                                                                                            cachedPC = nil
                                                                                                                                                                                                                            pendingWorldFlushAt = now + 0.25
                                                                                                                                                                                                                            end
                                                                                                                                                                                                                            end
                                                                                                                                                                                                                            end

                                                                                                                                                                                                                            pcall(NotifyOnNewObject, "/Script/Engine.PlayerController", function(newPC)
                                                                                                                                                                                                                            if cfg.Enabled and cfg.CleanOnWorldChange then
                                                                                                                                                                                                                                pcall(ExecuteInGameThread, function()
                                                                                                                                                                                                                                cachedPC = newPC
                                                                                                                                                                                                                                checkWorldTransition(os.clock())
                                                                                                                                                                                                                                end)
                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                end)

                                                                                                                                                                                                                            -- Telemetry Reporting ------------------------------------------------------------------------------
                                                                                                                                                                                                                            local function logTelemetrySnapshot(prefix)
                                                                                                                                                                                                                            local now = os.clock()
                                                                                                                                                                                                                            local elapsed = math.max(1, now - stats.windowStart)
                                                                                                                                                                                                                            local curKB = collectgarbage("count")
                                                                                                                                                                                                                            if curKB > stats.peakHeapKB then stats.peakHeapKB = curKB end
                                                                                                                                                                                                                                local avgMs = stats.stepsRun > 0 and (stats.totalStepMs / stats.stepsRun) or 0

                                                                                                                                                                                                                                log(string.format(
                                                                                                                                                                                                                                    "%s [%.0fs] Mode=%s | Heap: %.1f KB (Peak %.1f KB) | Steps: %d (avg %.2f ms, max %.2f ms) | Cycles: %d (Full: %d) | Reclaimed: %.1f KB",
                                                                                                                                                                                                                                                  prefix or "Telemetry", elapsed, tostring(appliedMode or cfg.GCMode),
                                                                                                                                                                                                                                                  curKB, stats.peakHeapKB,
                                                                                                                                                                                                                                                  stats.stepsRun, avgMs, stats.maxStepMs,
                                                                                                                                                                                                                                                  stats.cyclesDone, stats.fullFlushes, stats.totalFreedKB
                                                                                                                                                                                                                                ))

                                                                                                                                                                                                                                stats.windowStart  = now
                                                                                                                                                                                                                                stats.stepsRun     = 0
                                                                                                                                                                                                                                stats.cyclesDone   = 0
                                                                                                                                                                                                                                stats.fullFlushes  = 0
                                                                                                                                                                                                                                stats.totalStepMs  = 0
                                                                                                                                                                                                                                stats.maxStepMs    = 0
                                                                                                                                                                                                                                stats.totalFreedKB = 0
                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                -- Dynamic Hotkey Registration ----------------------------------------------------------------------
                                                                                                                                                                                                                                local registeredKeys = {}

                                                                                                                                                                                                                                local function registerFlushHotkey(keyName)
                                                                                                                                                                                                                                local norm = tostring(keyName or "F10"):upper():gsub("^%s+", ""):gsub("%s+$", "")
                                                                                                                                                                                                                                if norm == "" then norm = "F10" end
                                                                                                                                                                                                                                    cfg.FlushHotkey = norm
                                                                                                                                                                                                                                    if registeredKeys[norm] then return end

                                                                                                                                                                                                                                        local bindKey = Key and Key[norm]
                                                                                                                                                                                                                                        if bindKey then
                                                                                                                                                                                                                                            local ok = pcall(RegisterKeyBind, bindKey, function()
                                                                                                                                                                                                                                            if cfg.FlushHotkey ~= norm then return end
                                                                                                                                                                                                                                                ExecuteInGameThread(function()
                                                                                                                                                                                                                                                pcall(performFullFlush, "Hotkey " .. norm, cfg.EngineGCAssist, true)
                                                                                                                                                                                                                                                end)
                                                                                                                                                                                                                                                end)
                                                                                                                                                                                                                                            if ok then
                                                                                                                                                                                                                                                registeredKeys[norm] = true
                                                                                                                                                                                                                                                dbg("Registered flush hotkey: " .. norm)
                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                -- Mod Menu 2.0 Live Sync ---------------------------------------------------------------------------
                                                                                                                                                                                                                                                local mmRev = nil
                                                                                                                                                                                                                                                local lastAction = nil

                                                                                                                                                                                                                                                local function getModMenuVar(k)
                                                                                                                                                                                                                                                return getShared("ModMenu." .. MODMENU_ID .. "." .. k)
                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                local function syncModMenu()
                                                                                                                                                                                                                                                local rev = getModMenuVar("rev")
                                                                                                                                                                                                                                                if type(rev) == "number" and rev ~= mmRev then
                                                                                                                                                                                                                                                    mmRev = rev
                                                                                                                                                                                                                                                    local changed = false
                                                                                                                                                                                                                                                    local hotkeyChanged = false
                                                                                                                                                                                                                                                    for k, oldVal in pairs(cfg) do
                                                                                                                                                                                                                                                        local newVal = getModMenuVar(k)
                                                                                                                                                                                                                                                        if newVal ~= nil and type(newVal) == type(oldVal) then
                                                                                                                                                                                                                                                            if cfg[k] ~= newVal then
                                                                                                                                                                                                                                                                changed = true
                                                                                                                                                                                                                                                                if k == "FlushHotkey" then hotkeyChanged = true end
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                cfg[k] = newVal
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                clampConfig()
                                                                                                                                                                                                                                                                if hotkeyChanged then
                                                                                                                                                                                                                                                                registerFlushHotkey(cfg.FlushHotkey)
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                if changed then
                                                                                                                                                                                                                                                                configureCollector(true)
                                                                                                                                                                                                                                                                pcall(saveConfig)
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                                local action = getModMenuVar("action")
                                                                                                                                                                                                                                                                if action ~= nil and action ~= lastAction then
                                                                                                                                                                                                                                                                lastAction = action
                                                                                                                                                                                                                                                                local actStr = tostring(action)
                                                                                                                                                                                                                                                                if actStr:match("^flush_now#") then
                                                                                                                                                                                                                                                                performFullFlush("Mod Menu Button", cfg.EngineGCAssist, true)
                                                                                                                                                                                                                                                                elseif actStr:match("^log_stats#") then
                                                                                                                                                                                                                                                                logTelemetrySnapshot("Manual Snapshot")
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                                -- Main GameThread Loop -----------------------------------------------------------------------------
                                                                                                                                                                                                                                                                pcall(syncModMenu)
                                                                                                                                                                                                                                                                configureCollector(true)
                                                                                                                                                                                                                                                                registerFlushHotkey(cfg.FlushHotkey)

                                                                                                                                                                                                                                                                local function mainTick()
                                                                                                                                                                                                                                                                local now = os.clock()

                                                                                                                                                                                                                                                                -- Throttle ModMenu and World Transition checks to 250ms (4Hz instead of 20Hz)
                                                                                                                                                                                                                                                                if (now - stats.lastAuxTickAt) >= 0.25 then
                                                                                                                                                                                                                                                                stats.lastAuxTickAt = now
                                                                                                                                                                                                                                                                pcall(syncModMenu)
                                                                                                                                                                                                                                                                pcall(checkWorldTransition, now)
                                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                                if (now - stats.lastStepAt) * 1000 >= cfg.StepIntervalMs then
                                                                                                                                                                                                                                                                stats.lastStepAt = now
                                                                                                                                                                                                                                                                pcall(performPacedStep, now)
                                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                                if cfg.Enabled and cfg.TelemetryLog and (now - stats.windowStart) >= 60 then
                                                                                                                                                                                                                                                                pcall(logTelemetrySnapshot, "Telemetry")
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                                -- Run at 50ms resolution on the Game Thread so StepIntervalMs (50..1000ms) is respected accurately
                                                                                                                                                                                                                                                                local okLoop = pcall(LoopInGameThreadWithDelay, 50, mainTick)
                                                                                                                                                                                                                                                                if not okLoop then
                                                                                                                                                                                                                                                                local queued, queuedAt = false, 0
                                                                                                                                                                                                                                                                local function runQueuedMainTick()
                                                                                                                                                                                                                                                                queued = false
                                                                                                                                                                                                                                                                mainTick()
                                                                                                                                                                                                                                                                end
                                                                                                                                                                                                                                                                LoopAsync(100, function()
                                                                                                                                                                                                                                                                if queued and os.clock() - queuedAt > 5 then queued = false end
                                                                                                                                                                                                                                                                if queued then return false end
                                                                                                                                                                                                                                                                queued, queuedAt = true, os.clock()
                                                                                                                                                                                                                                                                local sent = pcall(ExecuteInGameThread, runQueuedMainTick)
                                                                                                                                                                                                                                                                if not sent then queued = false end
                                                                                                                                                                                                                                                                return false
                                                                                                                                                                                                                                                                end)
                                                                                                                                                                                                                                                                end

                                                                                                                                                                                                                                                                log(string.format("Loaded v%s! Mode=%s, Step=%dKB/%dms, Budget=%.1fms, SoftCap=%dKB (Hotkey: %s)",
                                                                                                                                                                                                                                                                VERSION, cfg.GCMode, cfg.StepSizeKB, cfg.StepIntervalMs, cfg.MaxStepBudgetMs, cfg.SoftCapKB, tostring(cfg.FlushHotkey)))
