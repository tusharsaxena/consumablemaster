-- Classifier.lua — Per-category match predicates.
--
-- Given an itemID, decide which of the 8 managed categories (if any) it
-- belongs to. Used by:
--   * Selector (M5) — auto-discover bag items and slot them into categories.
--   * SlashCommands (/kcm dump / /kcm rank) — debug introspection.
--
-- Every predicate reads from TooltipCache (parsed tooltip) and GetItemInfo
-- (subType / quality / ilvl). Project scope is English-only, so subType is
-- compared against literal English strings ("Potions", "Food & Drink",
-- "Flasks & Phials"). Healthstones are identified by hard-coded itemIDs
-- because they share the "Potions" subType with everything else.
--
-- Midnight renamed several consumable subtypes: "Potion" → "Potions", and
-- "Flask" / "Phial" merged into "Flasks & Phials". The underlying
-- classID/subClassID are unchanged (Consumable=0, Potion=1, Flask=3), but
-- GetItemInfoInstant returns the display string. If Blizzard renames
-- these again, update ST_POTION / ST_FLASK_PHIAL here.

local KCM = _G.KCM
KCM.Classifier = KCM.Classifier or {}
local C = KCM.Classifier

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local ST_POTION      = "Potions"
local ST_FOOD        = "Food & Drink"
local ST_FLASK_PHIAL = "Flasks & Phials"

-- Healthstones look like potions subtype-wise but are always warlock-only.
-- Kept as a whitelist rather than a rule so classification stays O(1).
local HEALTHSTONE_IDS = {
    [5512]   = true,  -- Classic healthstone (legacy fallback)
    [224464] = true,  -- Modern healthstone (auto-scales with warlock level)
}

-- Combat potions have a short buff (≤60s). Flasks/elixirs run for minutes
-- to hours. This threshold separates "use-in-fight" from "pre-buff".
local CMBT_POT_MAX_DURATION = 60

-- ---------------------------------------------------------------------------
-- Tooltip helpers
-- ---------------------------------------------------------------------------

local function hasHeal(tt)
    return (tt.healValue and tt.healValue > 0)
        or (tt.healValueAvg and tt.healValueAvg > 0)
        or (tt.healPct and tt.healPct > 0)
end

local function hasMana(tt)
    return (tt.manaValue and tt.manaValue > 0)
        or (tt.manaValueAvg and tt.manaValueAvg > 0)
        or (tt.manaPct and tt.manaPct > 0)
end

-- ---------------------------------------------------------------------------
-- Matchers — keyed by category key (uppercase, matches Categories.LIST).
-- Signature: (itemID, tt, subType) -> boolean
-- ---------------------------------------------------------------------------

local matchers = {
    FOOD = function(_, tt, subType)
        return subType == ST_FOOD and hasHeal(tt) and not tt.hasStatBuff
    end,
    DRINK = function(_, tt, subType)
        return subType == ST_FOOD and hasMana(tt) and not tt.hasStatBuff
    end,
    STAT_FOOD = function(_, tt, subType)
        return subType == ST_FOOD and tt.hasStatBuff and not tt.isFeast
    end,
    HP_POT = function(_, tt, subType)
        return subType == ST_POTION and hasHeal(tt) and not tt.hasStatBuff
    end,
    MP_POT = function(_, tt, subType)
        return subType == ST_POTION and hasMana(tt) and not tt.hasStatBuff
    end,
    HS = function(itemID)
        return HEALTHSTONE_IDS[itemID] == true
    end,
    -- Combat potion = Potion subtype + short buff + not healing/mana. We
    -- deliberately do NOT require `hasStatBuff`: Midnight potions like
    -- "Potion of Recklessness" describe their effect as "increases damage
    -- dealt" rather than a stat rating, so the tooltip stat parser finds
    -- nothing. Any short-duration Potion that doesn't restore HP/mana is a
    -- combat potion by elimination.
    CMBT_POT = function(_, tt, subType)
        return subType == ST_POTION
           and not hasHeal(tt)
           and not hasMana(tt)
           and (tt.buffDurationSec or 0) > 0
           and tt.buffDurationSec <= CMBT_POT_MAX_DURATION
    end,
    FLASK = function(_, _, subType)
        return subType == ST_FLASK_PHIAL
    end,
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- HS matches by itemID alone — returns true even before tooltip data loads.
-- Useful because the auto-discovery pass wants to pick up healthstones the
-- moment they land in bags.
local function isHealthstone(itemID)
    return HEALTHSTONE_IDS[itemID] == true
end

function C.Match(catKey, itemID)
    if not catKey or not itemID then return false end
    local fn = matchers[catKey]
    if not fn then return false end

    if catKey == "HS" then
        return isHealthstone(itemID)
    end

    -- GetItemInfoInstant is synchronous and returns subType from the
    -- client's item DB without waiting on a server round-trip. GetItemInfo
    -- would work too, but can briefly return nil for items whose full
    -- metadata hasn't arrived yet — and discovery runs on
    -- PLAYER_ENTERING_WORLD when that race is live.
    local subType
    if C_Item and C_Item.GetItemInfoInstant then
        local _
        _, _, subType = C_Item.GetItemInfoInstant(itemID)
    else
        local _
        _, _, _, _, _, _, subType = GetItemInfo(itemID)
    end
    if not subType then return false end

    -- FLASK classification reads subType only, so skip the tooltip gate.
    -- On /reload, C_TooltipInfo.GetItemByID can return empty lines for
    -- seconds even after GetItemInfoInstant already resolves subType, and
    -- GET_ITEM_INFO_RECEIVED does not fire for items the client already
    -- had cached — so the bulk PEW / BAG_UPDATE_DELAYED passes would both
    -- skip the item and never retry. Classifying on subType alone makes
    -- FLASK discovery deterministic on the first bag scan.
    if catKey == "FLASK" then
        return fn(itemID, nil, subType) == true
    end

    local tt = KCM.TooltipCache and KCM.TooltipCache.Get(itemID)
    if not tt or tt.pending then return false end

    return fn(itemID, tt, subType) == true
end

function C.MatchAny(itemID)
    local hits = {}
    if not itemID or not KCM.Categories or not KCM.Categories.LIST then
        return hits
    end
    for _, cat in ipairs(KCM.Categories.LIST) do
        if C.Match(cat.key, itemID) then
            table.insert(hits, cat.key)
        end
    end
    return hits
end
