-- MacroManager.lua — the only module that calls Blizzard's protected macro
-- APIs (CreateMacro / EditMacro). Everything else stays pure so Selector /
-- Ranker / Classifier can run in combat without taint risk.
--
-- Combat deferral: calls during InCombatLockdown() stash the target body in
-- `pendingUpdates[macroName]`; PLAYER_REGEN_ENABLED triggers FlushPending
-- which replays the queue. We never call macro APIs in combat.
--
-- Macro scope: the third arg to CreateMacro is `perCharacter`. We pass false
-- to get account-wide macros, matching REQUIREMENTS §11.7 (one set of 8
-- macros shared across the account).

local KCM = _G.KCM
KCM.MacroManager = KCM.MacroManager or {}
local M = KCM.MacroManager

local MAX_ACCOUNT_MACROS   = 120
local MAX_CHARACTER_MACROS = 18
local MACRO_BODY_LIMIT     = 255   -- Blizzard hard cap
local DEFAULT_ICON         = "INV_Misc_QuestionMark"

-- ---------------------------------------------------------------------------
-- Body builders
-- ---------------------------------------------------------------------------
-- Active body for an item pick:  `#showtooltip` + `/use item:<id>`. The
-- "item:<id>" form lets /use fire even if the item name is localized
-- differently on the client.
-- Active body for a spell pick:  `#showtooltip` + `/cast <Spell Name>`. WoW
-- does not accept spellID in /cast; it requires the localized name (English
-- here). C_Spell.GetSpellName is the modern API, with a GetSpellInfo
-- fallback for clients that still expose the legacy global.
--
-- Empty-state body: prints the category's emptyText. Using /run instead of
-- /use means clicking the macro still does *something* (a chat message)
-- when the player has no qualifying item, rather than silently failing.

local function spellNameFor(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local n = C_Spell.GetSpellName(spellID)
        if n and n ~= "" then return n end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name and info.name ~= "" then return info.name end
    end
    if GetSpellInfo then
        local n = GetSpellInfo(spellID)
        if n and n ~= "" then return n end
    end
    return nil
end

local function buildActiveBody(id)
    if KCM.ID and KCM.ID.IsSpell(id) then
        local spellID = KCM.ID.SpellID(id)
        local name = spellNameFor(spellID)
        if name then return ("#showtooltip\n/cast %s"):format(name) end
        -- Spell name not yet resolvable (very rare — would imply the spell
        -- book hasn't hydrated). Emit a user-visible stub so the macro
        -- exists and the failure is observable rather than silent.
        return ("#showtooltip\n/run print('KCM: spell %d name unavailable')"):format(spellID or 0)
    end
    return ("#showtooltip\n/use item:%d"):format(id)
end

local function buildEmptyBody(cat)
    local text = (cat and cat.emptyText) or "/run print('KCM: no item available')"
    -- emptyText in Categories.lua already starts with `/run` so we don't
    -- double it up.
    return "#showtooltip\n" .. text
end

function M.BuildBody(catKey, itemID)
    if itemID then return buildActiveBody(itemID) end
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    return buildEmptyBody(cat)
end

-- ---------------------------------------------------------------------------
-- Combat-deferral queue
-- ---------------------------------------------------------------------------
-- pendingUpdates[macroName] = { body = "...", itemID = N | nil, catKey = "..." }
-- Last write wins — if the body changes again before PLAYER_REGEN_ENABLED, we
-- only apply the final version, which matches the documented goal of
-- coalescing bag flurries into a single macro write.

local pendingUpdates = {}

function M.HasPending()
    return next(pendingUpdates) ~= nil
end

function M.PendingCount()
    local n = 0
    for _ in pairs(pendingUpdates) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Macro write (the only place touching protected APIs)
-- ---------------------------------------------------------------------------
-- Returns one of:
--   "unchanged" — body matched lastBody; no API call made.
--   "deferred"  — in combat; body queued for flush.
--   "created"   — macro didn't exist, we called CreateMacro.
--   "edited"    — macro existed, we called EditMacro.
--   "error"     — a guard failed (no db, no slots, etc.); macroState untouched.

local function doEdit(macroName, itemID, body, catKey)
    if not (GetMacroIndexByName and EditMacro and CreateMacro) then
        return "error", "macro API unavailable"
    end
    local idx = GetMacroIndexByName(macroName)
    if idx == 0 then
        -- CreateMacro signature: (name, icon, body, perCharacter)
        -- Icon accepts fileID or texture path. Questionmark keeps the icon
        -- slot empty-looking for unset macros; active macros adopt the
        -- item's icon automatically because the body begins with
        -- #showtooltip.
        local numAcct, numChar = GetNumMacros()
        if numAcct >= MAX_ACCOUNT_MACROS then
            return "error", "account macro quota full (120)"
        end
        CreateMacro(macroName, DEFAULT_ICON, body, false)
        idx = GetMacroIndexByName(macroName)
        if idx == 0 then return "error", "CreateMacro did not produce an index" end
        return "created"
    end
    EditMacro(idx, nil, nil, body)
    return "edited"
end

function M.SetMacro(macroName, itemID, catKey)
    if not macroName or macroName == "" then return "error", "empty macroName" end
    if not KCM.db or not KCM.db.profile then return "error", "db not ready" end

    -- Resolve catKey if the caller didn't pass one: used by BuildBody for
    -- the empty-state fallback. If we can't find the category we still
    -- produce a generic empty body so the macro at least exists.
    if not catKey and KCM.Categories and KCM.Categories.LIST then
        for _, c in ipairs(KCM.Categories.LIST) do
            if c.macroName == macroName then catKey = c.key; break end
        end
    end

    local body = M.BuildBody(catKey, itemID)
    if #body > MACRO_BODY_LIMIT then
        body = body:sub(1, MACRO_BODY_LIMIT)
    end

    KCM.db.profile.macroState = KCM.db.profile.macroState or {}
    local state = KCM.db.profile.macroState[macroName]
    if state and state.lastBody == body and (pendingUpdates[macroName] == nil) then
        -- Same body and no pending write in flight → nothing to do.
        return "unchanged"
    end

    if InCombatLockdown and InCombatLockdown() then
        pendingUpdates[macroName] = { body = body, itemID = itemID, catKey = catKey }
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: deferred %s (combat)", macroName)
        end
        return "deferred"
    end

    local result, err = doEdit(macroName, itemID, body, catKey)
    if result == "error" then
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: %s failed — %s", macroName, tostring(err))
        end
        return "error", err
    end

    KCM.db.profile.macroState[macroName] = {
        lastItemID = itemID,
        lastBody   = body,
        lastCat    = catKey,
    }
    pendingUpdates[macroName] = nil
    if KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("MacroManager: %s %s (item=%s)",
            macroName, result, tostring(itemID))
    end
    return result
end

-- ---------------------------------------------------------------------------
-- FlushPending — called from PLAYER_REGEN_ENABLED handler.
-- ---------------------------------------------------------------------------
-- Replays every queued body. Because doEdit only calls EditMacro /
-- CreateMacro, both of which are safe after regen, a taint-free macro update
-- lands here. Clears the queue atomically (after each successful edit) so a
-- mid-flush error leaves the remaining items queued for the next regen.

function M.FlushPending()
    if InCombatLockdown and InCombatLockdown() then
        -- Shouldn't happen — PLAYER_REGEN_ENABLED fires out of combat — but
        -- guard anyway so a caller invoking us at the wrong time doesn't
        -- taint.
        return 0
    end
    local applied = 0
    local still = {}
    for name, entry in pairs(pendingUpdates) do
        local result = M.SetMacro(name, entry.itemID, entry.catKey)
        if result == "deferred" or result == "error" then
            still[name] = entry
        else
            applied = applied + 1
        end
    end
    pendingUpdates = still
    return applied
end

-- ---------------------------------------------------------------------------
-- IsAdopted — has the macro been written by us yet?
-- ---------------------------------------------------------------------------
-- Used by Options UI and slash commands to show whether a slot is live.

function M.IsAdopted(macroName)
    if not GetMacroIndexByName then return false end
    return GetMacroIndexByName(macroName) ~= 0
end
