-- Ranker.lua — Per-category scoring functions.
--
-- All scorers are pure: same (itemID, ctx) → same score, no side effects.
-- Higher = better. Selector (M5) uses SortCandidates to order the
-- effective list; Options UI (M6) shows the same ordering.
--
-- The stat-aware categories (STAT_FOOD / CMBT_POT / FLASK) need a
-- specPriority in ctx: { primary = "AGI"|"STR"|"INT", secondary = {..} }.
-- Non-spec categories ignore ctx entirely.
--
-- Score layering (common to flat-heal / flat-mana categories):
--   conjured bonus (1e6)  -- makes any conjured item beat any crafted one
--   parsed heal / mana    -- raw effect size
--   percent heal * 1e4    -- Midnight %-based food dominates flat tiers
--   ilvl                  -- tiebreak
--   quality * 100         -- epic > rare > uncommon tiebreak
--
-- Healthstones use a hard-coded preference table because the two IDs in
-- the defaults list are strictly ranked (modern > legacy), not tied to
-- any stat or ilvl signal the parser exposes.

local KCM = _G.KCM
KCM.Ranker = KCM.Ranker or {}
local R = KCM.Ranker

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local HEALTHSTONE_PREFERENCE = {
    [224464] = 1000,  -- Modern auto-leveling
    [5512]   = 100,   -- Legacy fallback
}

local CONJURED_BONUS = 1e6
local PCT_WEIGHT     = 1e4  -- makes %-based food outrank flat-value food
local QUALITY_WEIGHT = 100

-- HP_POT / MP_POT: immediate restores always beat heal-over-time, unless the
-- HOT's total restored exceeds IMMEDIATE_PCT_THRESHOLD of the player's max
-- resource. The bonus is large enough to dominate any plausible raw-value
-- difference (amounts cap at ~1e6, bonus is 1e8) so within "immediate-tier"
-- the raw amount still breaks ties naturally. User pins always win over the
-- Ranker score, so this can be manually overridden per category.
local IMMEDIATE_POT_BONUS     = 1e8
local IMMEDIATE_PCT_THRESHOLD = 20

-- Stat-priority weighting. Primary gets a flat floor so any primary-stat
-- consumable beats any secondary-stat one regardless of magnitude; within
-- secondary, earlier position = higher weight.
local PRIMARY_WEIGHT = 1000

-- ---------------------------------------------------------------------------
-- Item-info helpers
-- ---------------------------------------------------------------------------

local function itemFields(itemID)
    local _, _, quality, ilvl, _, _, subType = GetItemInfo(itemID)
    local tt = (KCM.TooltipCache and KCM.TooltipCache.Get(itemID)) or {}
    return quality or 0, ilvl or 0, subType or "", tt
end

-- Weight of a single stat given the active spec's priority.
--   primary         → PRIMARY_WEIGHT
--   secondary[k]    → 100 * (N - k + 1)   -- so position 1 weighs most
--   TOP_SECONDARY   → weight of secondary[1] (wildcard from tooltips like
--                     "N of your highest secondary stat")
--   unranked        → 0
local function statWeight(stat, specPriority)
    if not stat or not specPriority then return 0 end
    if stat == specPriority.primary then return PRIMARY_WEIGHT end
    local sec = specPriority.secondary
    if not sec then return 0 end
    local n = #sec
    if stat == "TOP_SECONDARY" then
        return n > 0 and 100 * n or 0
    end
    for idx, name in ipairs(sec) do
        if name == stat then
            return 100 * (n - idx + 1)
        end
    end
    return 0
end

-- Decide whether an HP/MP pot qualifies for the immediate bonus. `kind` is
-- "HP" or "MP"; the function reads the matching tooltip fields and the
-- player's current max HP / max mana. Returns true when either:
--   * the tooltip has no over-time duration (pure immediate restore), or
--   * the total restored exceeds IMMEDIATE_PCT_THRESHOLD of max resource —
--     so a big HOT still gets the bonus.
-- When the player's max resource can't be resolved (0 / nil), the HOT
-- branch falls through to false so immediate pots keep winning by default.
-- Matches the user-stated preference: immediate wins unless the HOT is big.
local function qualifiesForImmediateBonus(tt, kind)
    if not tt then return false end
    local overSec, pct, flat, maxResource
    if kind == "HP" then
        overSec = tt.healOverSec
        pct     = tt.healPct
        flat    = (tt.healValueAvg or 0) + (tt.healValue or 0)
        maxResource = UnitHealthMax and UnitHealthMax("player") or 0
    else
        overSec = tt.manaOverSec
        pct     = tt.manaPct
        flat    = (tt.manaValueAvg or 0) + (tt.manaValue or 0)
        maxResource = UnitPowerMax and UnitPowerMax("player", 0) or 0
    end
    if not overSec and not (pct and tt.pctOverDurationSec) then
        return true  -- immediate
    end
    -- Over-time: evaluate the 20% threshold. Prefer the explicit pct when
    -- present; derive from flat amount otherwise. "X% every second for Y
    -- sec" multiplies out to total percent restored.
    local totalPct
    if pct then
        totalPct = (tt.isPctPerSecond and tt.pctOverDurationSec)
            and (pct * tt.pctOverDurationSec) or pct
    elseif maxResource > 0 and flat > 0 then
        totalPct = flat / maxResource * 100
    end
    return (totalPct or 0) > IMMEDIATE_PCT_THRESHOLD
end

-- Shared scoring for stat-aware categories. Sum of (weight × amount)
-- across every stat buff found in the tooltip. If the item confers
-- multiple stats (rare), each one contributes separately.
local function scoreByStatPriority(tt, specPriority)
    if not tt or not tt.statBuffs then return 0 end
    local total = 0
    for _, sb in ipairs(tt.statBuffs) do
        total = total + statWeight(sb.stat, specPriority) * (sb.amount or 1)
    end
    return total
end

-- ---------------------------------------------------------------------------
-- Per-category scorers
-- ---------------------------------------------------------------------------

local scorers = {
    FOOD = function(itemID)
        local quality, ilvl, _, tt = itemFields(itemID)
        return (tt.healValue or 0)
             + (tt.healValueAvg or 0)
             + (tt.healPct or 0) * PCT_WEIGHT
             + (tt.isConjured and CONJURED_BONUS or 0)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    DRINK = function(itemID)
        local quality, ilvl, _, tt = itemFields(itemID)
        return (tt.manaValue or 0)
             + (tt.manaValueAvg or 0)
             + (tt.manaPct or 0) * PCT_WEIGHT
             + (tt.isConjured and CONJURED_BONUS or 0)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    HP_POT = function(itemID)
        local quality, ilvl, _, tt = itemFields(itemID)
        local bonus = qualifiesForImmediateBonus(tt, "HP") and IMMEDIATE_POT_BONUS or 0
        return (tt.healValueAvg or 0)
             + (tt.healValue or 0)
             + bonus
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    MP_POT = function(itemID)
        local quality, ilvl, _, tt = itemFields(itemID)
        local bonus = qualifiesForImmediateBonus(tt, "MP") and IMMEDIATE_POT_BONUS or 0
        return (tt.manaValueAvg or 0)
             + (tt.manaValue or 0)
             + bonus
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    HS = function(itemID)
        local _, ilvl = itemFields(itemID)
        return (HEALTHSTONE_PREFERENCE[itemID] or 0) + ilvl
    end,
    STAT_FOOD = function(itemID, ctx)
        local quality, ilvl, _, tt = itemFields(itemID)
        return scoreByStatPriority(tt, ctx and ctx.specPriority)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    CMBT_POT = function(itemID, ctx)
        local quality, ilvl, _, tt = itemFields(itemID)
        return scoreByStatPriority(tt, ctx and ctx.specPriority)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    FLASK = function(itemID, ctx)
        local quality, ilvl, _, tt = itemFields(itemID)
        return scoreByStatPriority(tt, ctx and ctx.specPriority)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Spell entries (negative sentinel) outrank every item by default. Pins win
-- over score, so a user who reorders a spell down in the priority list still
-- sees their ordering respected — the huge score only controls the
-- unpinned Ranker baseline.
local SPELL_SCORE = 1e9

function R.Score(catKey, itemID, ctx)
    if not catKey or not itemID then return 0 end
    if KCM.ID and KCM.ID.IsSpell(itemID) then return SPELL_SCORE end
    local fn = scorers[catKey]
    if not fn then return 0 end
    return fn(itemID, ctx) or 0
end

-- Returns two values:
--   1. sorted array of itemIDs (highest score first)
--   2. parallel array of { id, score } rows — handy for debug dumps
function R.SortCandidates(catKey, itemIDs, ctx)
    local rows = {}
    for _, id in ipairs(itemIDs or {}) do
        table.insert(rows, { id = id, score = R.Score(catKey, id, ctx) })
    end
    table.sort(rows, function(a, b)
        if a.score == b.score then return a.id < b.id end
        return a.score > b.score
    end)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    return ids, rows
end

-- Expose helpers for tests / debug code that wants per-signal insight.
R._statWeight                = statWeight
R._scoreByStatPriority       = scoreByStatPriority
R._qualifiesForImmediateBonus = qualifiesForImmediateBonus
