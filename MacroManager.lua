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
local MACRO_BODY_LIMIT     = 255   -- Blizzard hard cap
local MAX_FLUSH_ATTEMPTS   = 3
local DEFAULT_ICON         = "INV_Misc_QuestionMark"

-- One-shot gate per category so a chronic oversize doesn't spam chat on
-- every recompute. Cleared only on /reload — that's a feature: the user
-- reported it once, further noise is waste.
local alreadyWarnedOversized = {}

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
-- pendingUpdates[macroName] = { body, itemID, catKey, attempts }
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
        local numAcct = GetNumMacros()
        if numAcct >= MAX_ACCOUNT_MACROS then
            return "error", "account macro quota full (120)"
        end
        CreateMacro(macroName, DEFAULT_ICON, body, false)
        idx = GetMacroIndexByName(macroName)
        if idx == 0 then return "error", "CreateMacro did not produce an index" end
        return "created"
    end
    -- EditMacro returns the macro index on success; 0 / nil indicates the
    -- edit was rejected (e.g. body failed validation). We use this signal to
    -- drive M-12's bounded retry.
    local editedIdx = EditMacro(idx, nil, nil, body)
    if editedIdx == 0 or editedIdx == nil then
        return "error", "EditMacro returned no index"
    end
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
        -- Silent truncation corrupted the macro (e.g. half a /cast line), so
        -- swap to the category's empty-state body and surface the problem
        -- once per catKey per session. Full oversized body goes to Debug for
        -- troubleshooting.
        local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: %s body exceeds %d bytes: %s",
                tostring(catKey), MACRO_BODY_LIMIT, body)
        end
        if catKey and not alreadyWarnedOversized[catKey] then
            alreadyWarnedOversized[catKey] = true
            print(("|cffff8800[KCM]|r %s macro body exceeds 255 bytes — macro is inert until the picked entry's body fits. Please report this."):format(catKey))
        end
        body = buildEmptyBody(cat)
    end

    KCM.db.profile.macroState = KCM.db.profile.macroState or {}
    local state   = KCM.db.profile.macroState[macroName]
    local pending = pendingUpdates[macroName]

    -- If a pending write is queued but already matches the current on-disk
    -- body, drop it — the queued EditMacro would be redundant.
    if state and state.lastBody == body and pending and pending.body == body then
        pendingUpdates[macroName] = nil
        return "unchanged"
    end
    if state and state.lastBody == body and pending == nil then
        -- Same body and no pending write in flight → nothing to do.
        return "unchanged"
    end

    if InCombatLockdown and InCombatLockdown() then
        -- Preserve `attempts` across re-queues during a single combat window
        -- so a bad EditMacro doesn't reset its retry counter on every new
        -- pipeline run before PLAYER_REGEN_ENABLED fires.
        local attempts = pending and pending.attempts or 0
        pendingUpdates[macroName] = {
            body     = body,
            itemID   = itemID,
            catKey   = catKey,
            attempts = attempts,
        }
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
-- Replays every queued body. Each entry carries `attempts`; after
-- MAX_FLUSH_ATTEMPTS failed writes we give up on that macro and emit a
-- one-time chat error so the user can diagnose. Bounding retries prevents a
-- persistently-failing macro from re-queueing forever on every combat cycle.

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
        local ok, result = pcall(M.SetMacro, name, entry.itemID, entry.catKey)
        if not ok or result == "error" then
            entry.attempts = (entry.attempts or 0) + 1
            if entry.attempts >= MAX_FLUSH_ATTEMPTS then
                print(("|cffff8800[KCM]|r gave up on %s after %d failed writes — check /kcm debug output."):format(name, entry.attempts))
                if KCM.Debug and KCM.Debug.Print then
                    KCM.Debug.Print("FlushPending: dropped %s after %d attempts (last err=%s)",
                        name, entry.attempts, tostring(result))
                end
            else
                still[name] = entry
            end
        elseif result == "deferred" then
            -- Combat re-entered mid-flush; preserve entry as-is.
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
