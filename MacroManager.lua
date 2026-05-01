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
-- Empty-state macros store DEFAULT_ICON (cooking pot) — their bodies have no
-- `#showtooltip`, so this static icon is what renders on the action bar.
-- Active macros store DYNAMIC_ICON (the `?` fileID, 134400). WoW treats that
-- specific fileID as a sentinel meaning "let `#showtooltip` drive the icon";
-- any other stored icon overrides `#showtooltip` on the action bar. This
-- matters on ElvUI/Bartender/etc. but is also the stock Blizzard behavior.
local DEFAULT_ICON         = 7704166
local DYNAMIC_ICON         = 134400

local function iconFor(itemID)
    return itemID and DYNAMIC_ICON or DEFAULT_ICON
end

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
        return ("#showtooltip\n/run print('|cff00ffff[CM]|r spell %d name unavailable')"):format(spellID or 0)
    end
    return ("#showtooltip\n/use item:%d"):format(id)
end

local function buildEmptyBody(cat)
    local text = (cat and cat.emptyText) or "/run print('|cff00ffff[CM]|r no item available')"
    -- No `#showtooltip` here. With `#showtooltip` present and the stored icon
    -- set to `?` (our DYNAMIC_ICON for active macros), WoW tries to resolve
    -- the icon from the first /use or /cast — but the empty body is a plain
    -- /run line, so the action bar would fall back to the `?` icon instead
    -- of our cooking-pot DEFAULT_ICON. Dropping `#showtooltip` pairs with
    -- iconFor(nil) → DEFAULT_ICON so the cooking pot renders for empties.
    return text
end

function M.BuildBody(catKey, itemID)
    if itemID then return buildActiveBody(itemID) end
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    return buildEmptyBody(cat)
end

-- ---------------------------------------------------------------------------
-- Composite body builders
-- ---------------------------------------------------------------------------
-- Composite macros (KCM_HP_AIO, KCM_MP_AIO) compose multiple single-category
-- picks into one macro body driven by [combat]/[nocombat] conditionals:
--
--   #showtooltip
--   /castsequence [combat] reset=combat item:5512, item:171267
--   /use [nocombat] item:113509              (or /cast [nocombat] Recuperate)
--
-- The /castsequence reset=combat line cycles through enabled in-combat sub-
-- categories on each click and rewinds to step 1 when the player leaves
-- combat. Out-of-combat lines are emitted one per enabled sub-category with
-- a current pick — `#showtooltip` resolves to the first usable line, so
-- multiple lines act as a fallback chain.
--
-- Sub-categories with no current pick (item not in bags, spell not learned)
-- are dropped from the body entirely; if no enabled sub-category yields a
-- pick, the body falls through to the empty-state stub.

-- Format one Selector pick (item id or spell sentinel) as a /castsequence
-- token. Items become `item:N`; spells use their localized name. Returns
-- nil for unresolvable picks (caller drops the step).
local function tokenForPick(id)
    if not id then return nil end
    if KCM.ID and KCM.ID.IsSpell(id) then
        local sid = KCM.ID.SpellID(id)
        return spellNameFor(sid)
    end
    return ("item:%d"):format(id)
end

-- Format a single-step `/use` or `/cast` line with the given conditional
-- (e.g. "[nocombat]"). Returns nil if the pick is unresolvable.
local function actionLineForPick(id, conditional)
    if not id then return nil end
    if KCM.ID and KCM.ID.IsSpell(id) then
        local sid = KCM.ID.SpellID(id)
        local name = spellNameFor(sid)
        if not name then return nil end
        return ("/cast %s %s"):format(conditional, name)
    end
    return ("/use %s item:%d"):format(conditional, id)
end

-- Build the active body for a composite category. Returns nil when no
-- enabled sub-category produces a usable pick (caller falls back to
-- buildEmptyBody). `pickFor` is a function `(refKey) -> pickID|nil` injected
-- by the caller so this stays unit-testable; production callers pass
-- `Selector.PickBestForCategory`.
local function buildCompositeBody(cat, pickFor)
    if not (cat and cat.composite and cat.components) then return nil end
    if not pickFor then return nil end

    local cfg = KCM.db and KCM.db.profile and KCM.db.profile.categories
        and KCM.db.profile.categories[cat.key]
    if not cfg then return nil end

    local enabled  = cfg.enabled or {}
    local orderIn  = cfg.orderInCombat    or cat.components.inCombat    or {}
    local orderOut = cfg.orderOutOfCombat or cat.components.outOfCombat or {}

    local lines = {}

    -- In-combat: collect every enabled sub-cat's pick, emit one /castsequence
    -- line. `enabled[ref] ~= false` defaults to true when the field is unset
    -- (e.g. for refs added later via Categories metadata that aren't yet in
    -- the saved bucket).
    local seqTokens = {}
    for _, ref in ipairs(orderIn) do
        if enabled[ref] ~= false then
            local pick = pickFor(ref)
            local tok = tokenForPick(pick)
            if tok then table.insert(seqTokens, tok) end
        end
    end
    local hasInCombat = #seqTokens > 0
    if hasInCombat then
        table.insert(lines,
            ("/castsequence [combat] reset=combat %s"):format(table.concat(seqTokens, ", ")))
    end

    -- Out-of-combat: emit one /use|/cast line per enabled sub-cat with a
    -- pick. Multiple lines act as a fallback chain through the WoW macro
    -- engine — `#showtooltip` resolves to the first line whose target is
    -- currently usable, and the others no-op against the GCD.
    local hasOutOfCombat = false
    for _, ref in ipairs(orderOut) do
        if enabled[ref] ~= false then
            local pick = pickFor(ref)
            local line = actionLineForPick(pick, "[nocombat]")
            if line then
                table.insert(lines, line)
                hasOutOfCombat = true
            end
        end
    end

    if not (hasInCombat or hasOutOfCombat) then return nil end

    -- Per-section empty-state fallback. When one combat-state side produced
    -- usable lines but the other didn't, clicking the macro from the empty
    -- side would otherwise be silent. Mirror the single-cat empty-state
    -- behaviour (a chat print) but gated on combat state via Lua, since
    -- /run doesn't accept `[combat]` / `[nocombat]` macro conditionals —
    -- those are evaluated by the secure-macro parser, which only attaches
    -- them to /use, /cast, /castsequence, /click, /target, etc.
    if hasInCombat and not hasOutOfCombat then
        table.insert(lines,
            ('/run if not InCombatLockdown() then print("|cff00ffff[CM]|r no %s option out of combat") end')
                :format(cat.displayName))
    elseif hasOutOfCombat and not hasInCombat then
        -- Insert before any /use [nocombat] lines so the print path runs
        -- when in combat (the /use line still owns the [nocombat] state).
        table.insert(lines, 1,
            ('/run if InCombatLockdown() then print("|cff00ffff[CM]|r no %s option in combat") end')
                :format(cat.displayName))
    end

    table.insert(lines, 1, "#showtooltip")
    return table.concat(lines, "\n")
end

M.BuildCompositeBody = buildCompositeBody  -- exposed for /cm dump pick

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

local function doEdit(macroName, icon, body, catKey)
    if not (GetMacroIndexByName and EditMacro and CreateMacro) then
        return "error", "macro API unavailable"
    end
    local idx = GetMacroIndexByName(macroName)
    if idx == 0 then
        -- CreateMacro signature: (name, icon, body, perCharacter). Icon
        -- accepts fileID or texture path. Active → DYNAMIC_ICON (lets
        -- `#showtooltip` resolve the item/spell icon). Empty → DEFAULT_ICON
        -- (the stored cooking pot renders because empty bodies omit
        -- `#showtooltip` entirely).
        local numAcct = GetNumMacros()
        if numAcct >= MAX_ACCOUNT_MACROS then
            return "error", "account macro quota full (120)"
        end
        CreateMacro(macroName, icon, body, false)
        idx = GetMacroIndexByName(macroName)
        if idx == 0 then return "error", "CreateMacro did not produce an index" end
        return "created"
    end
    -- EditMacro returns the macro index on success; 0 / nil indicates the
    -- edit was rejected (e.g. body failed validation). We use this signal to
    -- drive M-12's bounded retry. Re-asserting the stored icon on every edit
    -- migrates macros from prior addon versions (which always stored
    -- DEFAULT_ICON, causing action bars to show the cooking pot instead of
    -- the picked item's icon).
    local editedIdx = EditMacro(idx, nil, icon, body)
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
    local effectiveItemID = itemID
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
            print(("|cff00ffff[CM]|r %s macro body exceeds 255 bytes — macro is inert until the picked entry's body fits. Please report this."):format(catKey))
        end
        body = buildEmptyBody(cat)
        effectiveItemID = nil  -- body is now empty-state; stored icon must follow
    end
    local icon = iconFor(effectiveItemID)

    KCM.db.profile.macroState = KCM.db.profile.macroState or {}
    local state   = KCM.db.profile.macroState[macroName]
    local pending = pendingUpdates[macroName]

    -- If a pending write is queued but already matches the current on-disk
    -- body+icon, drop it — the queued EditMacro would be redundant.
    if state and state.lastBody == body and state.lastIcon == icon
            and pending and pending.body == body then
        pendingUpdates[macroName] = nil
        return "unchanged"
    end
    if state and state.lastBody == body and state.lastIcon == icon and pending == nil then
        -- Same body+icon and no pending write in flight → nothing to do.
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

    local result, err = doEdit(macroName, icon, body, catKey)
    if result == "error" then
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: %s failed — %s", macroName, tostring(err))
        end
        return "error", err
    end

    KCM.db.profile.macroState[macroName] = {
        lastItemID = itemID,
        lastBody   = body,
        lastIcon   = icon,
        lastCat    = catKey,
    }
    pendingUpdates[macroName] = nil
    if KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("MacroManager: %s %s (item=%s icon=%s)",
            macroName, result, tostring(itemID), tostring(icon))
    end
    return result
end

-- ---------------------------------------------------------------------------
-- SetCompositeMacro — write the body for a composite category (KCM_HP_AIO,
-- KCM_MP_AIO). Mirrors SetMacro's guard ladder (size limit, fingerprint cache,
-- combat deferral, doEdit) but reads picks from the underlying single
-- categories via Selector. Returns the same result codes as SetMacro.
-- ---------------------------------------------------------------------------

function M.SetCompositeMacro(cat, scoreCache)
    if not (cat and cat.macroName and cat.composite) then
        return "error", "not a composite category"
    end
    if not KCM.db or not KCM.db.profile then return "error", "db not ready" end
    if not (KCM.Selector and KCM.Selector.PickBestForCategory) then
        return "error", "Selector unavailable"
    end

    local macroName = cat.macroName
    local catKey    = cat.key

    local pickFor = function(refKey)
        return KCM.Selector.PickBestForCategory(refKey, nil, scoreCache)
    end

    local activeBody = buildCompositeBody(cat, pickFor)
    local body = activeBody or buildEmptyBody(cat)
    local effectiveActive = activeBody ~= nil

    if #body > MACRO_BODY_LIMIT then
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: %s composite body exceeds %d bytes: %s",
                tostring(catKey), MACRO_BODY_LIMIT, body)
        end
        if catKey and not alreadyWarnedOversized[catKey] then
            alreadyWarnedOversized[catKey] = true
            print(("|cff00ffff[CM]|r %s macro body exceeds 255 bytes — macro is inert until the composite body fits. Please report this."):format(catKey))
        end
        body = buildEmptyBody(cat)
        effectiveActive = false
    end
    -- Active body has #showtooltip → DYNAMIC_ICON sentinel so the action bar
    -- adopts the icon of whichever step the current combat conditional
    -- selects. Empty body has no #showtooltip → DEFAULT_ICON renders the
    -- cooking pot directly.
    local icon = effectiveActive and DYNAMIC_ICON or DEFAULT_ICON

    KCM.db.profile.macroState = KCM.db.profile.macroState or {}
    local state   = KCM.db.profile.macroState[macroName]
    local pending = pendingUpdates[macroName]

    if state and state.lastBody == body and state.lastIcon == icon
            and pending and pending.body == body then
        pendingUpdates[macroName] = nil
        return "unchanged"
    end
    if state and state.lastBody == body and state.lastIcon == icon and pending == nil then
        return "unchanged"
    end

    if InCombatLockdown and InCombatLockdown() then
        local attempts = pending and pending.attempts or 0
        pendingUpdates[macroName] = {
            body     = body,
            itemID   = nil,
            catKey   = catKey,
            cat      = cat,           -- drives composite dispatch in FlushPending
            attempts = attempts,
        }
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: deferred %s composite (combat)", macroName)
        end
        return "deferred"
    end

    local result, err = doEdit(macroName, icon, body, catKey)
    if result == "error" then
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("MacroManager: %s failed — %s", macroName, tostring(err))
        end
        return "error", err
    end

    KCM.db.profile.macroState[macroName] = {
        lastItemID = nil,
        lastBody   = body,
        lastIcon   = icon,
        lastCat    = catKey,
    }
    pendingUpdates[macroName] = nil
    if KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("MacroManager: %s %s (composite icon=%s)",
            macroName, result, tostring(icon))
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
        local ok, result
        if entry.cat and entry.cat.composite then
            ok, result = pcall(M.SetCompositeMacro, entry.cat, nil)
        else
            ok, result = pcall(M.SetMacro, name, entry.itemID, entry.catKey)
        end
        if not ok or result == "error" then
            entry.attempts = (entry.attempts or 0) + 1
            if entry.attempts >= MAX_FLUSH_ATTEMPTS then
                print(("|cff00ffff[CM]|r gave up on %s after %d failed writes — check /cm debug output."):format(name, entry.attempts))
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

-- ---------------------------------------------------------------------------
-- InvalidateState — clear cached body/icon fingerprints so the next pipeline
-- run writes every macro from scratch. Used by `/cm rewritemacros` when a
-- user needs to force-refresh icons without deleting the macros themselves
-- (stored icon corrupted, action-bar framework cached the old texture, etc.).
-- Also drops the combat-deferral queue since those entries reference stale
-- state expectations.
-- ---------------------------------------------------------------------------

function M.InvalidateState()
    if KCM.db and KCM.db.profile then
        KCM.db.profile.macroState = {}
    end
    pendingUpdates = {}
    alreadyWarnedOversized = {}
end
