-- SpecHelper.lua — Spec identity + stat-priority resolution.
--
-- Keys are "<classID>_<specID>", matching Defaults_StatPriority.lua. The
-- Blizzard API id for the player's class does not change, but spec id does
-- when the player respecs; GetCurrent() is the authoritative live reading.

local KCM = _G.KCM
KCM.SpecHelper = KCM.SpecHelper or {}
local SpecHelper = KCM.SpecHelper

-- Class id → primary stat fallback used when a per-spec priority is missing.
-- Matches Blizzard primary stat assignment for each class's DPS / Tank specs.
local CLASS_PRIMARY_FALLBACK = {
    [1]  = "STR", -- Warrior
    [2]  = "STR", -- Paladin (Holy overridden by spec-level entry)
    [3]  = "AGI", -- Hunter
    [4]  = "AGI", -- Rogue
    [5]  = "INT", -- Priest
    [6]  = "STR", -- Death Knight
    [7]  = "INT", -- Shaman (Enhancement overridden)
    [8]  = "INT", -- Mage
    [9]  = "INT", -- Warlock
    [10] = "AGI", -- Monk  (Mistweaver overridden)
    [11] = "INT", -- Druid (Feral/Guardian overridden)
    [12] = "AGI", -- Demon Hunter
    [13] = "INT", -- Evoker
}

function SpecHelper.MakeKey(classID, specID)
    if not classID or not specID then return nil end
    return tostring(classID) .. "_" .. tostring(specID)
end

-- Returns: classID, specID, specKey ("<classID>_<specID>"), specName
-- Nil for all if the player has not chosen a spec yet (low-level characters).
function SpecHelper.GetCurrent()
    local _, _, classID = UnitClass("player")
    if not classID then return nil end

    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex then return classID, nil, nil, nil end

    local specID, specName = GetSpecializationInfo(specIndex)
    if not specID then return classID, nil, nil, nil end

    return classID, specID, SpecHelper.MakeKey(classID, specID), specName
end

-- Iterates every spec of every class. Yields: classID, specID, specKey, specName.
-- Used by the settings UI to show per-spec priority editors even for classes
-- the player has not logged into yet.
function SpecHelper.AllSpecs()
    local results = {}
    for classID = 1, GetNumClasses() do
        local numSpecs = GetNumSpecializationsForClassID(classID)
        for specIndex = 1, (numSpecs or 0) do
            local specID, specName = GetSpecializationInfoForClassID(classID, specIndex)
            if specID then
                table.insert(results, {
                    classID  = classID,
                    specID   = specID,
                    specKey  = SpecHelper.MakeKey(classID, specID),
                    specName = specName,
                })
            end
        end
    end
    return results
end

-- Resolve stat priority for a given specKey. Order of precedence:
--   1. user override in db.profile.statPriority[specKey]
--   2. seed default in KCM.SEED.STAT_PRIORITY[specKey]
--   3. class-primary fallback (secondary list empty; tooltip parsing remains
--      usable but with no secondary-stat tiebreak guidance)
--
-- Returns a table { primary = "STR"|"AGI"|"INT", secondary = { ... } }. Never
-- returns nil so callers don't need to nil-check every field.
function SpecHelper.GetStatPriority(specKey)
    local db = KCM.db and KCM.db.profile
    if db and db.statPriority and db.statPriority[specKey] then
        local user = db.statPriority[specKey]
        if user.primary then
            return {
                primary   = user.primary,
                secondary = user.secondary or {},
            }
        end
    end

    local seed = KCM.SEED and KCM.SEED.STAT_PRIORITY and KCM.SEED.STAT_PRIORITY[specKey]
    if seed then
        return {
            primary   = seed.primary,
            secondary = seed.secondary or {},
        }
    end

    local classID = specKey and tonumber(specKey:match("^(%d+)_"))
    return {
        primary   = (classID and CLASS_PRIMARY_FALLBACK[classID]) or "STR",
        secondary = {},
    }
end
