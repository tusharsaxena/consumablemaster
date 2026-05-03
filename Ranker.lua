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

-- HP_POT / MP_POT: immediate restores always beat heal-over-time (HOT),
-- unless the HOT's raw amount exceeds the best immediate pot in the same
-- candidate set by more than HOT_OVER_IMMEDIATE_PCT. The bonus is large
-- enough to dominate any plausible raw-value difference (amounts cap at
-- ~1e6, bonus is 1e8) so within "immediate-tier" the raw amount still
-- breaks ties naturally. The comparison is against the best-immediate
-- amount among the current candidates, not against max HP, so it stays
-- independent of player level/gear. User pins still win over the Ranker
-- score, so this can be manually overridden per category.
local IMMEDIATE_POT_BONUS       = 1e8
local HOT_OVER_IMMEDIATE_PCT    = 20

-- Stat-priority weighting. Primary gets a flat floor so any primary-stat
-- consumable beats any secondary-stat one regardless of magnitude; within
-- secondary, earlier position = higher weight.
local PRIMARY_WEIGHT = 1000

-- ---------------------------------------------------------------------------
-- Item-info helpers
-- ---------------------------------------------------------------------------

-- `scoreCache.fields[id]` memoizes a single GetItemInfo + TooltipCache.Get
-- result across every scorer call that touches the same itemID within one
-- Pipeline.Recompute pass. Callers that pass `scoreCache = nil` get the
-- original uncached path — keeps /cm dump, Explain, and panel renders
-- behaviour-identical.
local function itemFields(itemID, scoreCache)
    if scoreCache and scoreCache.fields and scoreCache.fields[itemID] then
        local f = scoreCache.fields[itemID]
        return f.quality, f.ilvl, f.subType, f.tt
    end
    local _, _, quality, ilvl, _, _, subType = GetItemInfo(itemID)
    quality = quality or 0
    ilvl    = ilvl or 0
    subType = subType or ""
    local tt = (KCM.TooltipCache and KCM.TooltipCache.Get(itemID)) or {}
    if scoreCache and scoreCache.fields then
        scoreCache.fields[itemID] = { quality = quality, ilvl = ilvl, subType = subType, tt = tt }
    end
    return quality, ilvl, subType, tt
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

-- Raw restored amount for an HP/MP pot tooltip. `kind` is "HP" or "MP".
-- Percent-based entries are not included because they'd require max-HP
-- normalization that we're deliberately avoiding; in practice retail HP /
-- MP pots are flat-value, and any pct entries end up in the base score via
-- other signals (pct contributes nothing here, so they stay penalized).
local function potAmount(tt, kind)
    if not tt then return 0 end
    if kind == "HP" then
        return (tt.healValueAvg or 0) + (tt.healValue or 0)
    end
    return (tt.manaValueAvg or 0) + (tt.manaValue or 0)
end

-- Whether a pot restores its resource immediately (no over-time duration).
local function potIsImmediate(tt, kind)
    if not tt then return true end
    if kind == "HP" then
        if tt.healOverSec then return false end
        if tt.healPct and tt.pctOverDurationSec then return false end
    else
        if tt.manaOverSec then return false end
        if tt.manaPct and tt.pctOverDurationSec then return false end
    end
    return true
end

-- Largest raw amount among immediate pots in the candidate set. Used by
-- HP_POT / MP_POT scorers to gate the immediate bonus on HOT entries: a HOT
-- only earns the bonus when its amount exceeds this value by more than
-- HOT_OVER_IMMEDIATE_PCT. When there are no immediate pots in the set the
-- return is 0, which makes every HOT qualify (nothing to lose against).
local function bestImmediateAmount(kind, itemIDs, scoreCache)
    local best = 0
    for _, id in ipairs(itemIDs or {}) do
        if not (KCM.ID and KCM.ID.IsSpell(id)) then
            local tt
            if scoreCache and scoreCache.fields and scoreCache.fields[id] then
                tt = scoreCache.fields[id].tt
            else
                tt = KCM.TooltipCache and KCM.TooltipCache.Get(id) or nil
            end
            if tt and potIsImmediate(tt, kind) then
                local amt = potAmount(tt, kind)
                if amt > best then best = amt end
            end
        end
    end
    return best
end

-- Decide whether an HP/MP pot qualifies for the immediate bonus. Immediate
-- pots always qualify. HOT pots qualify only when their raw amount exceeds
-- the best immediate pot in the same set by more than HOT_OVER_IMMEDIATE_PCT
-- (20% by default). `ctx.bestImmediateAmount` is populated by SortCandidates
-- before this runs; callers that invoke Score directly should populate it
-- themselves via R.BuildContext for consistent display.
local function qualifiesForImmediateBonus(tt, kind, ctx)
    if not tt then return false end
    if potIsImmediate(tt, kind) then return true end
    local bestImmediate = (ctx and ctx.bestImmediateAmount) or 0
    if bestImmediate <= 0 then return true end
    local threshold = bestImmediate * (1 + HOT_OVER_IMMEDIATE_PCT / 100)
    return potAmount(tt, kind) > threshold
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
    FOOD = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
        return (tt.healValue or 0)
             + (tt.healValueAvg or 0)
             + (tt.healPct or 0) * PCT_WEIGHT
             + (tt.isConjured and CONJURED_BONUS or 0)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    DRINK = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
        return (tt.manaValue or 0)
             + (tt.manaValueAvg or 0)
             + (tt.manaPct or 0) * PCT_WEIGHT
             + (tt.isConjured and CONJURED_BONUS or 0)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    HP_POT = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
        local bonus = qualifiesForImmediateBonus(tt, "HP", ctx) and IMMEDIATE_POT_BONUS or 0
        return (tt.healValueAvg or 0)
             + (tt.healValue or 0)
             + bonus
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    MP_POT = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
        local bonus = qualifiesForImmediateBonus(tt, "MP", ctx) and IMMEDIATE_POT_BONUS or 0
        return (tt.manaValueAvg or 0)
             + (tt.manaValue or 0)
             + bonus
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    HS = function(itemID, ctx, scoreCache)
        local _, ilvl = itemFields(itemID, scoreCache)
        return (HEALTHSTONE_PREFERENCE[itemID] or 0) + ilvl
    end,
    STAT_FOOD = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
        return scoreByStatPriority(tt, ctx and ctx.specPriority)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    CMBT_POT = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
        return scoreByStatPriority(tt, ctx and ctx.specPriority)
             + ilvl
             + quality * QUALITY_WEIGHT
    end,
    FLASK = function(itemID, ctx, scoreCache)
        local quality, ilvl, _, tt = itemFields(itemID, scoreCache)
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

function R.Score(catKey, itemID, ctx, scoreCache)
    if not catKey or not itemID then return 0 end
    if KCM.ID and KCM.ID.IsSpell(itemID) then return SPELL_SCORE end
    if scoreCache then
        local catCache = scoreCache[catKey]
        if catCache and catCache[itemID] ~= nil then
            return catCache[itemID]
        end
    end
    local fn = scorers[catKey]
    if not fn then return 0 end
    local score = fn(itemID, ctx, scoreCache) or 0
    if scoreCache then
        scoreCache[catKey] = scoreCache[catKey] or {}
        scoreCache[catKey][itemID] = score
    end
    return score
end

-- Build a Ranker ctx for a given candidate set, augmenting `existing` if
-- provided. For HP_POT / MP_POT the scorer's immediate-bonus gate depends
-- on knowing the best-immediate amount in the set; other categories use
-- ctx for specPriority and this helper leaves those fields untouched.
-- Callers that invoke R.Score per item (e.g. the /cm dump pick debug view)
-- should route through here so displayed scores match what SortCandidates
-- produced.
function R.BuildContext(catKey, itemIDs, existing, scoreCache)
    local ctx = existing or {}
    if catKey == "HP_POT" or catKey == "MP_POT" then
        local kind = (catKey == "HP_POT") and "HP" or "MP"
        -- Memoize on the per-pass scoreCache so per-row Explain calls don't
        -- redo the walk during a panel render. SortCandidates and Explain
        -- both flow through here for the same catKey + itemIDs in a single
        -- recompute, and the result is identical across the calls.
        if scoreCache then
            scoreCache.bestImmediate = scoreCache.bestImmediate or {}
            local cached = scoreCache.bestImmediate[catKey]
            if cached == nil then
                cached = bestImmediateAmount(kind, itemIDs, scoreCache)
                scoreCache.bestImmediate[catKey] = cached
            end
            ctx.bestImmediateAmount = cached
        else
            ctx.bestImmediateAmount = bestImmediateAmount(kind, itemIDs, scoreCache)
        end
    end
    return ctx
end

-- Returns two values:
--   1. sorted array of itemIDs (highest score first)
--   2. parallel array of { id, score } rows — handy for debug dumps
function R.SortCandidates(catKey, itemIDs, ctx, scoreCache)
    ctx = R.BuildContext(catKey, itemIDs, ctx, scoreCache)
    local rows = {}
    for _, id in ipairs(itemIDs or {}) do
        table.insert(rows, { id = id, score = R.Score(catKey, id, ctx, scoreCache) })
    end
    table.sort(rows, function(a, b)
        if a.score == b.score then return a.id < b.id end
        return a.score > b.score
    end)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    return ids, rows
end

-- Per-item score breakdown for the priority list's "score" tooltip. Returns
-- { score, summary, signals = { {label, value, note?}, ... } } so Options
-- can render a readable explanation without duplicating scorer logic. The
-- individual signals mirror the additive terms inside each scorer; the
-- summary is a short plain-English description of the scoring rule.
--
-- Categories that differ significantly (HP/MP pots with the immediate
-- bonus, healthstones with the preference table, stat-priority categories)
-- get custom breakdowns. Spell entries short-circuit to SPELL_SCORE — the
-- sentinel that keeps them on top unless the user pins otherwise.
function R.Explain(catKey, itemID, ctx)
    local result = { score = 0, summary = "", signals = {} }
    if not catKey or not itemID then return result end

    if KCM.ID and KCM.ID.IsSpell(itemID) then
        result.score   = SPELL_SCORE
        result.summary = "Spell entries rank above every item by default."
        table.insert(result.signals, { label = "spell bonus", value = SPELL_SCORE })
        return result
    end

    local quality, ilvl, _, tt = itemFields(itemID)
    local qualityScore = quality * QUALITY_WEIGHT
    local function pushBase()
        if ilvl and ilvl > 0 then
            table.insert(result.signals, { label = "ilvl", value = ilvl })
        end
        if qualityScore > 0 then
            table.insert(result.signals, { label = "quality x100", value = qualityScore })
        end
    end

    if catKey == "FOOD" or catKey == "DRINK" then
        local isFood = (catKey == "FOOD")
        local flat   = isFood and ((tt.healValueAvg or 0) + (tt.healValue or 0))
                                or ((tt.manaValueAvg or 0) + (tt.manaValue or 0))
        local pct    = isFood and (tt.healPct or 0) or (tt.manaPct or 0)
        local pctContribution = pct * PCT_WEIGHT
        local conjured = tt.isConjured and CONJURED_BONUS or 0
        if flat > 0 then
            table.insert(result.signals, {
                label = isFood and "heal value" or "mana value",
                value = flat,
            })
        end
        if pct > 0 then
            table.insert(result.signals, {
                label = ("pct x%d"):format(PCT_WEIGHT),
                value = pctContribution,
                note  = ("%g%% of max"):format(pct),
            })
        end
        if conjured > 0 then
            table.insert(result.signals, { label = "conjured bonus", value = conjured })
        end
        pushBase()
        result.score   = flat + pctContribution + conjured + ilvl + qualityScore
        result.summary = "Flat + %-based restore, conjured outranks crafted, ilvl + quality break ties."
        return result
    end

    if catKey == "HP_POT" or catKey == "MP_POT" then
        local kind       = (catKey == "HP_POT") and "HP" or "MP"
        local amount     = potAmount(tt, kind)
        local immediate  = potIsImmediate(tt, kind)
        local qualifies  = qualifiesForImmediateBonus(tt, kind, ctx)
        local bonus      = qualifies and IMMEDIATE_POT_BONUS or 0
        if amount > 0 then
            table.insert(result.signals, {
                label = (kind == "HP") and "heal value" or "mana value",
                value = amount,
                note  = immediate and "immediate" or "over time",
            })
        end
        table.insert(result.signals, {
            label = "immediate bonus",
            value = bonus,
            note  = immediate and "immediate"
                or (qualifies
                    and ("HOT > %d%% of best immediate"):format(HOT_OVER_IMMEDIATE_PCT)
                    or  ("HOT <= %d%% of best immediate"):format(HOT_OVER_IMMEDIATE_PCT)),
        })
        pushBase()
        result.score = amount + bonus + ilvl + qualityScore
        result.summary = ("Immediate wins unless a HOT pot's amount beats the best immediate by more than %d%%."):format(HOT_OVER_IMMEDIATE_PCT)
        return result
    end

    if catKey == "HS" then
        local pref = HEALTHSTONE_PREFERENCE[itemID] or 0
        table.insert(result.signals, { label = "preference rank", value = pref })
        pushBase()
        result.score   = pref + ilvl
        result.summary = "Hard-coded preference table (modern > legacy) + ilvl tiebreak."
        return result
    end

    if catKey == "STAT_FOOD" or catKey == "CMBT_POT" or catKey == "FLASK" then
        local specPriority = ctx and ctx.specPriority
        local statTotal    = 0
        for _, sb in ipairs(tt.statBuffs or {}) do
            local w       = statWeight(sb.stat, specPriority)
            local contrib = w * (sb.amount or 1)
            if contrib > 0 then
                table.insert(result.signals, {
                    label = ("%s buff"):format(sb.stat),
                    value = contrib,
                    note  = ("amount %d x weight %d"):format(sb.amount or 0, w),
                })
                statTotal = statTotal + contrib
            end
        end
        if #result.signals == 0 then
            table.insert(result.signals, {
                label = "stat buffs",
                value = 0,
                note  = specPriority and "no buffs match spec priority" or "spec priority unresolved",
            })
        end
        pushBase()
        result.score   = statTotal + ilvl + qualityScore
        result.summary = "Primary-stat buffs outweigh any secondary; secondary ranks by priority position."
        return result
    end

    return result
end

-- Expose helpers for tests / debug code that wants per-signal insight.
R._scorers                    = scorers
R._statWeight                 = statWeight
R._scoreByStatPriority        = scoreByStatPriority
R._qualifiesForImmediateBonus = qualifiesForImmediateBonus
