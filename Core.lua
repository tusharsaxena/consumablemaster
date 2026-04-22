-- Core.lua — AceAddon entry point, DB bootstrap, slash registration.

local ADDON_NAME = "ConsumableMaster"

local KCM = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0", "AceConsole-3.0")
_G.KCM = KCM

KCM.VERSION = "0.1.0"

KCM.dbDefaults = {
    profile = {
        schemaVersion = 1,
        debug = false,
        categories = {
            FOOD      = { added = {}, blocked = {}, pins = {}, discovered = {} },
            DRINK     = { added = {}, blocked = {}, pins = {}, discovered = {} },
            HP_POT    = { added = {}, blocked = {}, pins = {}, discovered = {} },
            MP_POT    = { added = {}, blocked = {}, pins = {}, discovered = {} },
            HS        = { added = {}, blocked = {}, pins = {}, discovered = {} },
            STAT_FOOD = { bySpec = {} },
            CMBT_POT  = { bySpec = {} },
            FLASK     = { bySpec = {} },
        },
        statPriority = {}, -- [specKey] = { primary = "AGI", secondary = {...} }  -- user overrides only
        macroState = {},
    },
}

function KCM:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("ConsumableMasterDB", KCM.dbDefaults, true)
    self:RegisterChatCommand("kcm", "OnSlashCommand")
    if KCM.Options and KCM.Options.Register then
        KCM.Options.Register()
    end
    if KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("Initialized (version %s, debug=%s)", KCM.VERSION, tostring(self.db.profile.debug))
    end
end

-- ---------------------------------------------------------------------------
-- Pipeline — orchestrates Selector → MacroManager for every category.
-- ---------------------------------------------------------------------------
-- All event handlers enqueue a recompute via RequestRecompute; RequestRecompute
-- coalesces calls within the same frame by gating on `_recomputePending` and
-- scheduling a single `C_Timer.After(0, ...)` (see TECHNICAL_DESIGN §6.2).
--
-- Recompute itself walks KCM.Categories.LIST, asks Selector for the best-owned
-- item, and passes the result to MacroManager. MacroManager handles early-out
-- (unchanged body), combat deferral, and the actual Blizzard API calls.

KCM.Pipeline = KCM.Pipeline or {}
local P = KCM.Pipeline

function P.RecomputeOne(catKey, reason)
    if not KCM.Categories or not KCM.Selector or not KCM.MacroManager then
        return
    end
    local cat = KCM.Categories.Get and KCM.Categories.Get(catKey)
    if not cat then return end
    local pick = KCM.Selector.PickBestForCategory(catKey)
    KCM.MacroManager.SetMacro(cat.macroName, pick, catKey)
    -- Verbose per-category recompute log is commented out — it fires N×M
    -- times during login (N categories × M GET_ITEM_INFO_RECEIVED events)
    -- and drowns the chat. Uncomment for debugging pick resolution.
    -- if KCM.Debug and KCM.Debug.Print then
    --     KCM.Debug.Print("Pipeline.RecomputeOne: %s -> %s (reason=%s)",
    --         catKey, tostring(pick), tostring(reason))
    -- end
end

function P.Recompute(reason)
    if not KCM.Categories or not KCM.Categories.LIST then return end
    for _, cat in ipairs(KCM.Categories.LIST) do
        P.RecomputeOne(cat.key, reason)
    end
    -- Event-driven panel updates go through the debounced RequestRefresh so
    -- that a burst of GET_ITEM_INFO_RECEIVED events (dozens during first
    -- panel open while item data hydrates from the server) collapses into
    -- one rebuild. Without this, each event tears down every widget, which
    -- flickers hover tooltips, resets scroll, and can swallow clicks.
    -- User-driven mutations still call O.Refresh directly for snappy UI.
    if KCM.Options and KCM.Options.RequestRefresh then
        KCM.Options.RequestRefresh()
    elseif KCM.Options and KCM.Options.Refresh then
        KCM.Options.Refresh()
    end
end

function P.RequestRecompute(reason)
    KCM._recomputePending = true
    KCM._recomputeReason  = reason or KCM._recomputeReason or "unknown"
    if KCM._recomputeScheduled then return end
    KCM._recomputeScheduled = true
    -- C_Timer.After(0, ...) defers to the end of the current frame, which
    -- collapses a flurry of events (e.g. multiple BAG_UPDATE_DELAYED during
    -- loot) into a single pipeline run.
    C_Timer.After(0, function()
        KCM._recomputeScheduled = false
        if KCM._recomputePending then
            local r = KCM._recomputeReason
            KCM._recomputePending = false
            KCM._recomputeReason  = nil
            P.Recompute(r)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------
-- All handlers route through Pipeline.RequestRecompute; none of them touch
-- macro APIs directly. This keeps Selector/Ranker/Classifier on the
-- unprotected path and leaves MacroManager as the sole caller of
-- CreateMacro/EditMacro.

-- Classify one bag item into any matching categories and, for each match
-- that isn't already in the shipped seed, record it in the bucket's
-- `discovered` set. Shared between the bulk bag pass (PEW,
-- BAG_UPDATE_DELAYED) and the per-item retry triggered by
-- GET_ITEM_INFO_RECEIVED — which exists because `Classifier.Match` returns
-- false for items whose tooltip isn't loaded yet. Without the retry, an
-- item present in bags from /reload silently gets skipped on first
-- discovery pass and never re-enters the candidate set until bags change.
local function discoverOne(itemID, reason)
    if not (itemID and KCM.Classifier and KCM.Classifier.MatchAny
            and KCM.Selector and KCM.Selector.MarkDiscovered) then
        return 0
    end
    local added = 0
    local hits = KCM.Classifier.MatchAny(itemID)
    if KCM.Debug and KCM.Debug.Print and #hits == 0 then
        -- Per-bag-item trace. We only log the zero-hit case because a
        -- successful discovery already prints "Discovered:" below.
        KCM.Debug.Print("discoverOne: id=%d no category match (reason=%s)",
            itemID, tostring(reason))
    end
    for _, catKey in ipairs(hits) do
        local cat = KCM.Categories.Get(catKey)
        local inSeed = false
        local seed = KCM.SEED and KCM.SEED[catKey] or {}
        for _, sid in ipairs(seed) do
            if sid == itemID then inSeed = true; break end
        end
        if not inSeed then
            local specKey
            if cat and cat.specAware and KCM.SpecHelper then
                local _, _, key = KCM.SpecHelper.GetCurrent()
                specKey = key
            end
            if KCM.Selector.MarkDiscovered(catKey, itemID, specKey) then
                added = added + 1
                if KCM.Debug and KCM.Debug.Print then
                    KCM.Debug.Print("Discovered: %s id=%d (reason=%s)",
                        catKey, itemID, tostring(reason))
                end
            end
        end
    end
    return added
end

local function runAutoDiscovery(reason)
    if not (KCM.BagScanner and KCM.Classifier) then return 0 end
    local counts = KCM.BagScanner.Scan()
    local discovered = 0
    for id in pairs(counts) do
        discovered = discovered + discoverOne(id, reason)
    end
    return discovered
end

-- Expose for manual invocation from /kcm resync and tests.
KCM.Pipeline.RunAutoDiscovery = runAutoDiscovery
KCM.Pipeline.DiscoverOne      = discoverOne

-- Wipe every user customization and restore from dbDefaults. Preserves
-- macroState so live macros aren't orphaned. Shared by the Options panel's
-- "Reset all priorities" execute and the /kcm reset StaticPopup — both
-- paths land here to keep semantics identical regardless of entry point.
--
-- After the DB wipe we drive a full resync (not just a RequestRecompute):
-- tooltip cache invalidation, auto-discovery pass, then an immediate
-- Recompute. The cache invalidation clears any stale `pending` entries
-- from the prior session, auto-discovery re-fills the `discovered` set
-- which we just wiped, and Recompute rewrites every macro body. Macro
-- writes that land in combat defer via MacroManager's pending queue, so
-- this is safe to run without a combat guard.
--
-- Returns true if the DB was mutated; callers that want user feedback
-- should print their own confirmation message.
function KCM.ResetAllToDefaults(reason)
    if not (KCM.db and KCM.db.profile) then return false end
    local defaults = KCM.dbDefaults and KCM.dbDefaults.profile or {}
    KCM.db.profile.categories   = CopyTable(defaults.categories or {})
    KCM.db.profile.statPriority = CopyTable(defaults.statPriority or {})
    reason = reason or "reset_all"
    if KCM.TooltipCache and KCM.TooltipCache.InvalidateAll then
        KCM.TooltipCache.InvalidateAll()
    end
    if KCM.Pipeline and KCM.Pipeline.RunAutoDiscovery then
        KCM.Pipeline.RunAutoDiscovery(reason)
    end
    if KCM.Pipeline and KCM.Pipeline.Recompute then
        KCM.Pipeline.Recompute(reason)
    end
    return true
end

function KCM:OnPlayerEnteringWorld()
    -- Fires on login and /reload. Discover + recompute everything.
    runAutoDiscovery("player_entering_world")
    KCM.Pipeline.RequestRecompute("player_entering_world")
end

function KCM:OnBagUpdateDelayed()
    runAutoDiscovery("bag_update_delayed")
    KCM.Pipeline.RequestRecompute("bag_update_delayed")
end

function KCM:OnSpecChanged()
    KCM.Pipeline.RequestRecompute("spec_changed")
end

function KCM:OnRegenDisabled()
    KCM._inCombat = true
end

function KCM:OnRegenEnabled()
    KCM._inCombat = false
    if KCM.MacroManager and KCM.MacroManager.FlushPending then
        local n = KCM.MacroManager.FlushPending()
        if n > 0 and KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("FlushPending applied %d macro(s)", n)
        end
    end
end

function KCM:OnItemInfoReceived(event, itemID, success)
    if not success or not itemID then return end
    if KCM.TooltipCache and KCM.TooltipCache.Invalidate then
        KCM.TooltipCache.Invalidate(itemID)
    end
    -- Split bag vs non-bag events. First opening the options panel accesses
    -- ~150 priority-list items that aren't in bags, each firing an event as
    -- its data hydrates from the server. A full Pipeline.Recompute on each
    -- (160 TC.Get calls × many events/sec) tanks FPS for 5-10 seconds; but
    -- those items can't affect macro picks (macros only select from bag
    -- items), so the recompute is pure waste. Only bag items need the full
    -- pipeline; everything else just triggers a debounced panel refresh so
    -- rows can swap "?" for the real name once data arrives.
    if KCM.BagScanner and KCM.BagScanner.HasItem and KCM.BagScanner.HasItem(itemID) then
        discoverOne(itemID, "item_info_received")
        KCM.Pipeline.RequestRecompute("item_info_received")
    elseif KCM.Options and KCM.Options.RequestRefresh then
        KCM.Options.RequestRefresh()
    end
end

function KCM:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD",         "OnPlayerEnteringWorld")
    self:RegisterEvent("BAG_UPDATE_DELAYED",            "OnBagUpdateDelayed")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "OnSpecChanged")
    self:RegisterEvent("PLAYER_REGEN_DISABLED",         "OnRegenDisabled")
    self:RegisterEvent("PLAYER_REGEN_ENABLED",          "OnRegenEnabled")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED",        "OnItemInfoReceived")
end
