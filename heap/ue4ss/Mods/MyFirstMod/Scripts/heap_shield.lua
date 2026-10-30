-- LuaHeapCleaner Shared Helper (heap_shield.lua)
-- Version 1.1.0
--
-- Any UE4SS Lua mod can include this helper in its Scripts/ folder (or resolve it via
-- ModRef:GetSharedVariable("LuaHeapCleaner.ScriptsPath")) and call `heap_shield.step()` on the Game Thread to:
--   1) Automatically sync with LuaHeapCleaner's GCMode, Mod Menu settings, and FlushEpoch signals.
--   2) Pace its own Lua VM's garbage collector within MaxStepBudgetMs so it never causes 20-40ms GC hitches.

local M = {}

local function getShared(key)
if not ModRef or not ModRef.GetSharedVariable then return nil end
    local ok, val = pcall(ModRef.GetSharedVariable, ModRef, key)
    if ok then return val end
        return nil
        end

        -- Cached state synced via ConfigRev so M.step() allocates zero closures on hot ticks
        local state = {
            configRev       = -1,
            enabled         = true,
            gcMode          = "StepPacer",
            appliedMode     = nil,
            stepIntervalSec = 0.25,
            stepSizeKB      = 8,
            restThresholdKB = 256,
            maxBudgetSec    = 0.002,
            softCapKB       = 4096,
            lastEpoch       = tonumber(getShared("LuaHeapCleaner.FlushEpoch")) or 0,
            lastStepAt      = 0,
            lastSyncAt      = 0,
            restUntilKB     = nil,
        }

        local function applyVMCollectorMode(force)
        local target = state.enabled and state.gcMode or "Disabled"
        if state.appliedMode == target and not force then return end
            state.appliedMode = target
            state.restUntilKB = nil

            if target == "Disabled" then
                pcall(collectgarbage, "restart")
                pcall(collectgarbage, "incremental", 200, 200)
                pcall(collectgarbage, "setpause", 200)
                pcall(collectgarbage, "setstepmul", 200)
                elseif target == "StepPacer" then
                    pcall(collectgarbage, "incremental", 110, 200, 13)
                    pcall(collectgarbage, "setpause", 110)
                    pcall(collectgarbage, "setstepmul", 200)
                    pcall(collectgarbage, "stop")
                    elseif target == "Generational" then
                        pcall(collectgarbage, "generational", 20, 100)
                        pcall(collectgarbage, "restart")
                        elseif target == "TunedIncremental" then
                            pcall(collectgarbage, "incremental", 110, 400, 12)
                            pcall(collectgarbage, "setpause", 110)
                            pcall(collectgarbage, "setstepmul", 400)
                            pcall(collectgarbage, "restart")
                            end
                            end

                            local function syncSharedConfig()
                            local rev = getShared("LuaHeapCleaner.ConfigRev")
                            if type(rev) ~= "number" or rev == state.configRev then
                                return
                                end
                                state.configRev = rev

                                local en = getShared("LuaHeapCleaner.Enabled")
                                if type(en) == "boolean" then state.enabled = en end

                                    local mode = getShared("LuaHeapCleaner.GCMode")
                                    if type(mode) == "string" then state.gcMode = mode end

                                        local intervalMs = getShared("LuaHeapCleaner.StepIntervalMs")
                                        if type(intervalMs) == "number" and intervalMs >= 50 then
                                            state.stepIntervalSec = intervalMs / 1000.0
                                            end

                                            local stepKB = getShared("LuaHeapCleaner.StepSizeKB")
                                            if type(stepKB) == "number" and stepKB > 0 then
                                                state.stepSizeKB = stepKB
                                                end

                                                local restKB = getShared("LuaHeapCleaner.RestThresholdKB")
                                                if type(restKB) == "number" and restKB > 0 then
                                                    state.restThresholdKB = restKB
                                                    end

                                                    local budgetMs = getShared("LuaHeapCleaner.MaxStepBudgetMs")
                                                    if type(budgetMs) == "number" and budgetMs > 0 then
                                                        state.maxBudgetSec = budgetMs / 1000.0
                                                        end

                                                        local softCap = getShared("LuaHeapCleaner.SoftCapKB")
                                                        if type(softCap) == "number" and softCap >= 512 then
                                                            state.softCapKB = softCap
                                                            end

                                                            applyVMCollectorMode(false)
                                                            end

                                                            local function flushLocalVM()
                                                            pcall(collectgarbage, "collect")
                                                            pcall(collectgarbage, "collect")
                                                            if state.enabled and state.gcMode == "StepPacer" then
                                                                pcall(collectgarbage, "stop")
                                                                end
                                                                state.restUntilKB = collectgarbage("count") + state.restThresholdKB
                                                                end

                                                                function M.step()
                                                                local now = os.clock()

                                                                -- 1. Sync shared config & cross-mod FlushEpoch at most every 200ms
                                                                if (now - state.lastSyncAt) >= 0.20 then
                                                                    state.lastSyncAt = now
                                                                    syncSharedConfig()

                                                                    local epoch = getShared("LuaHeapCleaner.FlushEpoch")
                                                                    if type(epoch) == "number" and epoch > state.lastEpoch then
                                                                        state.lastEpoch = epoch
                                                                        if state.enabled then
                                                                            flushLocalVM()
                                                                            state.lastStepAt = now
                                                                            return
                                                                            end
                                                                            end
                                                                            end

                                                                            if not state.enabled then return end

                                                                                -- 2. Respect StepIntervalMs even if the caller invokes M.step() every frame
                                                                                if (now - state.lastStepAt) < state.stepIntervalSec then return end
                                                                                    state.lastStepAt = now

                                                                                    local curKB = collectgarbage("count")

                                                                                    -- 3. Soft-cap safety flush for this VM
                                                                                    if curKB >= state.softCapKB then
                                                                                        flushLocalVM()
                                                                                        return
                                                                                        end

                                                                                        -- 4. Time-budgeted micro-step in StepPacer mode
                                                                                        if state.gcMode == "StepPacer" then
                                                                                            if state.restUntilKB and curKB < state.restUntilKB then return end

                                                                                                local t0 = os.clock()
                                                                                                local remainingKB = state.stepSizeKB
                                                                                                local sliceKB = math.max(1, math.ceil(state.stepSizeKB / 4))
                                                                                                local cycleDone = false

                                                                                                while remainingKB > 0 do
                                                                                                    local chunk = math.min(sliceKB, remainingKB)
                                                                                                    local ok, done = pcall(collectgarbage, "step", chunk)
                                                                                                    remainingKB = remainingKB - chunk
                                                                                                    if ok and done then
                                                                                                        cycleDone = true
                                                                                                        break
                                                                                                        end
                                                                                                        if (os.clock() - t0) >= state.maxBudgetSec then
                                                                                                            break
                                                                                                            end
                                                                                                            end

                                                                                                            if cycleDone then
                                                                                                                state.restUntilKB = collectgarbage("count") + state.restThresholdKB
                                                                                                                end
                                                                                                                end
                                                                                                                end

                                                                                                                M.flush = flushLocalVM

                                                                                                                return M
