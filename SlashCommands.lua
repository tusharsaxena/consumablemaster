-- SlashCommands.lua — /cm (and /consumablemaster) dispatcher. Registered via AceConsole in Core:OnInitialize.

local KCM = _G.KCM
KCM.SlashCommands = {}

local PREFIX = "|cff00ffff[CM]|r "

-- Every chat line we emit goes through this so the [CM] tag is unconditional —
-- including dump body rows and help-table rows that don't manually prepend it.
local function say(s)
    print(PREFIX .. s)
end

-- Shared confirmation popup for /cm reset. preferredIndex = 3 dodges the
-- taint cascade that affects popup slots 1/2 when other addons have used
-- them earlier in the session (a well-known Ace3 footgun around any
-- StaticPopup that mutates SavedVariables).
--
-- Do NOT write `StaticPopupDialogs = StaticPopupDialogs or {}` here —
-- reassigning a Blizzard-managed global from insecure load-time code taints
-- it, and ToggleGameMenu's first-show path reads StaticPopupDialogs, which
-- propagates the taint to protected calls like ClearTarget() and throws
-- ADDON_ACTION_FORBIDDEN on the first ESC after /reload. Blizzard always
-- pre-defines StaticPopupDialogs before addons load, so the guard is
-- unnecessary. Just write the subkey.
StaticPopupDialogs["KCM_CONFIRM_RESET"] = {
    text = "Reset ALL ConsumableMaster customization to defaults?\n\n"
        .. "Wipes every category's added/blocked/pinned items and all "
        .. "stat-priority overrides. Macros in your macro pool stay in "
        .. "place. This cannot be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        if KCM.ResetAllToDefaults and KCM.ResetAllToDefaults("slash_reset") then
            say("Reset complete — defaults restored.")
        else
            say("Reset failed (DB not ready).")
        end
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Dump targets: single source of truth. Each entry has a one-line summary
-- (shown in help) and a handler. Add new dump targets here and they appear
-- in both `/cm` and `/cm dump` help output automatically.
-- ---------------------------------------------------------------------------

local DUMP_TARGETS = {}

DUMP_TARGETS.categories = {
    summary = "category metadata table",
    run = function()
        if not (KCM.Categories and KCM.Categories.LIST) then
            say("KCM.Categories.LIST not loaded.")
            return
        end
        if DevTools_Dump then
            DevTools_Dump(KCM.Categories.LIST)
        else
            for i, row in ipairs(KCM.Categories.LIST) do
                say(("  [%d] %s  macro=%s  display=%q  specAware=%s")
                    :format(i, row.key, row.macroName, row.displayName, tostring(row.specAware)))
            end
        end
    end,
}

DUMP_TARGETS.statpriority = {
    summary = "stat priority for current spec",
    run = function()
        if not (KCM.SpecHelper and KCM.SpecHelper.GetCurrent) then
            say("KCM.SpecHelper not loaded.")
            return
        end
        local classID, specID, specKey, specName = KCM.SpecHelper.GetCurrent()
        if not specKey then
            say("No active spec (low-level character?).")
            return
        end
        local priority = KCM.SpecHelper.GetStatPriority(specKey)
        say(("spec: %s  (classID=%s  specID=%s  key=%s)")
            :format(specName or "?", tostring(classID), tostring(specID), specKey))
        if DevTools_Dump then
            DevTools_Dump(priority)
        else
            say(("  primary: %s"):format(tostring(priority.primary)))
            say(("  secondary: %s"):format(table.concat(priority.secondary or {}, ", ")))
        end
    end,
}

DUMP_TARGETS.bags = {
    summary = "bag contents as itemID -> count",
    run = function()
        if not (KCM.BagScanner and KCM.BagScanner.Scan) then
            say("KCM.BagScanner not loaded.")
            return
        end
        local counts = KCM.BagScanner.Scan()
        if DevTools_Dump then
            DevTools_Dump(counts)
        else
            for id, n in pairs(counts) do
                say(("  %d x %d"):format(id, n))
            end
        end
    end,
}

DUMP_TARGETS.item = {
    summary = "parsed tooltip + raw lines for <itemID> (e.g. /cm dump item 241304)",
    usage   = "item <itemID>",
    run = function(arg)
        local id = tonumber(arg or "")
        if not id then
            say("usage: /cm dump item <itemID>")
            return
        end
        if not (KCM.TooltipCache and KCM.TooltipCache.Get) then
            say("KCM.TooltipCache not loaded.")
            return
        end
        local entry = KCM.TooltipCache.Get(id)
        local name = (entry and entry.itemName)
            or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
            or "?"
        say(("item %d  (%s)"):format(id, tostring(name)))

        -- Dump GetItemInfoInstant — what Classifier uses for subType. This
        -- is the fastest way to tell why an item does/doesn't match a
        -- category (wrong subType string, mis-typed consumable, etc.).
        if C_Item and C_Item.GetItemInfoInstant then
            local iName, iType, iSubType, iEquip, iIcon, iClass, iSub =
                C_Item.GetItemInfoInstant(id)
            say(("  instant: type=%q  subType=%q  classID=%s  subClassID=%s")
                :format(tostring(iType), tostring(iSubType),
                        tostring(iClass), tostring(iSub)))
            local hits = KCM.Classifier and KCM.Classifier.MatchAny
                and KCM.Classifier.MatchAny(id) or {}
            if #hits > 0 then
                say(("  classified: %s"):format(table.concat(hits, ", ")))
            else
                say("  classified: |cffff4444(none)|r")
            end
        end

        if entry and entry.pending then
            say("  pending: tooltip data not yet loaded — try again in a moment.")
        elseif entry then
            local ok, reason = KCM.TooltipCache.IsUsableByPlayer(id)
            local playerLvl = UnitLevel("player") or 0
            if ok then
                say(("  usable: yes  (minLevel=%d, you=%d)")
                    :format(entry.minLevel or 0, playerLvl))
            else
                say(("  usable: no   (%s)"):format(tostring(reason)))
            end
        end
        if DevTools_Dump then
            DevTools_Dump(entry)
        end

        -- Raw tooltip lines appended after parsed output — the pattern-
        -- debugging view. Skipped silently when C_TooltipInfo or the
        -- tooltip data isn't available (tooltip will usually be available
        -- since TooltipCache.Get above already fetched it).
        if C_TooltipInfo and C_TooltipInfo.GetItemByID then
            local data = C_TooltipInfo.GetItemByID(id)
            if data and data.lines and #data.lines > 0 then
                say(("  raw tooltip lines (%d):"):format(#data.lines))
                for i, line in ipairs(data.lines) do
                    local left = line.leftText or ""
                    local right = line.rightText or ""
                    if right ~= "" then
                        say(("    [%2d] L=%q  R=%q"):format(i, left, right))
                    else
                        say(("    [%2d] %q"):format(i, left))
                    end
                end
            end
        end
    end,
}

-- ---------------------------------------------------------------------------
-- /cm dump pick <catKey>
-- Runs the full selector pipeline (candidates → rank → pin merge → first
-- owned) and prints the effective priority list with ranker scores, owned
-- flags, and the pick highlight. Folds in what used to be /cm dump rank —
-- since the ranker score is now shown inline, there's no need for a
-- separate seed-only ranking command.
-- ---------------------------------------------------------------------------

DUMP_TARGETS.pick = {
    summary = "effective priority (with scores) + best-owned pick for a category",
    usage   = "pick <catKey>",
    run = function(arg)
        arg = (arg or ""):match("^(%S*)") or ""
        if arg == "" then
            say("usage: /cm dump pick <catKey>  (e.g. flask, hp_pot, stat_food)")
            if KCM.Categories and KCM.Categories.LIST then
                local keys = {}
                for _, cat in ipairs(KCM.Categories.LIST) do
                    table.insert(keys, cat.key:lower())
                end
                say("  known: " .. table.concat(keys, ", "))
            end
            return
        end
        local catKey = arg:upper()
        local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
        if not cat then
            say("unknown category: |cffffff00" .. arg .. "|r")
            return
        end
        if not (KCM.Selector and KCM.Selector.GetEffectivePriority) then
            say("KCM.Selector not loaded.")
            return
        end

        -- Composite category: print the configured sub-cat order, the pick
        -- each sub-cat resolves to right now, and the macro body that
        -- SetCompositeMacro would write. No effective-priority list because
        -- composites don't have items of their own.
        if cat.composite then
            say(("%s (composite)"):format(catKey))
            local cfg = KCM.db and KCM.db.profile and KCM.db.profile.categories
                and KCM.db.profile.categories[cat.key]
            if not cfg then
                say("no DB bucket for composite category.")
                return
            end
            local function describePick(refKey)
                local pick = KCM.Selector.PickBestForCategory(refKey)
                if not pick then return "(no pick)" end
                if KCM.ID and KCM.ID.IsSpell(pick) then
                    local sid = KCM.ID.SpellID(pick)
                    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or "?"
                    return ("spell:%d %s"):format(sid or 0, name)
                end
                local tt = KCM.TooltipCache and KCM.TooltipCache.Get(pick)
                local name = (tt and tt.itemName)
                    or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(pick))
                    or "?"
                return ("%d %s"):format(pick, name)
            end
            local sections = {
                { label = "In Combat",     orderField = "orderInCombat"    },
                { label = "Out of Combat", orderField = "orderOutOfCombat" },
            }
            for _, section in ipairs(sections) do
                say(("  %s:"):format(section.label))
                local arr = cfg[section.orderField] or {}
                if #arr == 0 then
                    say("    (none)")
                else
                    for i, ref in ipairs(arr) do
                        local enabled = not (cfg.enabled and cfg.enabled[ref] == false)
                        local tag = enabled and "|cff44ff44[on]|r " or "|cff888888[off]|r"
                        say(("    %d. %s %s -> %s"):format(i, tag, ref, describePick(ref)))
                    end
                end
            end
            if KCM.MacroManager and KCM.MacroManager.BuildCompositeBody then
                local body = KCM.MacroManager.BuildCompositeBody(cat,
                    function(refKey) return KCM.Selector.PickBestForCategory(refKey) end)
                if body then
                    say("  macro body:")
                    for line in body:gmatch("[^\n]+") do
                        say("    " .. line)
                    end
                else
                    say("no usable picks — macro would show empty-state stub.")
                end
            end
            return
        end

        -- Build the ranker ctx once; the list is pre-sorted via pins+rank
        -- inside Selector, but we still want per-row raw scores so the user
        -- can see WHY an entry landed where it did (useful when a pin has
        -- overridden the natural ranker order).
        local ctx
        if cat.specAware and KCM.SpecHelper then
            local _, _, specKey, specName = KCM.SpecHelper.GetCurrent()
            if specKey then
                ctx = { specPriority = KCM.SpecHelper.GetStatPriority(specKey) }
                say(("%s for spec %s (%s)"):format(
                    catKey, specName or "?", specKey))
                say(("  primary=%s  secondary=%s"):format(
                    tostring(ctx.specPriority.primary),
                    table.concat(ctx.specPriority.secondary or {}, ">")))
            else
                say(("%s (no active spec)"):format(catKey))
            end
        else
            say(("%s"):format(catKey))
        end

        local priority = KCM.Selector.GetEffectivePriority(catKey)
        local pick = KCM.Selector.PickBestForCategory(catKey)

        -- Augment ctx with set-dependent fields (HP_POT / MP_POT need the
        -- best-immediate amount in the candidate set so per-item scores
        -- shown here line up with what the effective sort produced).
        if KCM.Ranker and KCM.Ranker.BuildContext then
            ctx = KCM.Ranker.BuildContext(catKey, priority, ctx)
        end

        say(("  effective priority (%d entries):"):format(#priority))
        for i, id in ipairs(priority) do
            local name, displayID, have
            if KCM.ID and KCM.ID.IsSpell(id) then
                local sid = KCM.ID.SpellID(id)
                displayID = ("spell:%d"):format(sid or 0)
                if C_Spell and C_Spell.GetSpellName then
                    name = C_Spell.GetSpellName(sid)
                end
                name = name or "?"
                have = sid and IsPlayerSpell and IsPlayerSpell(sid) or false
            else
                displayID = tostring(id)
                local tt = KCM.TooltipCache and KCM.TooltipCache.Get(id)
                name = (tt and tt.itemName)
                    or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
                    or "?"
                have = KCM.BagScanner and KCM.BagScanner.HasItem and KCM.BagScanner.HasItem(id) or false
            end
            local score = (KCM.Ranker and KCM.Ranker.Score and KCM.Ranker.Score(catKey, id, ctx)) or 0
            local haveTag = have and "|cff44ff44[owned]|r" or "|cff888888[---]|r"
            local pickTag = (id == pick) and "  |cffffd100<-- pick|r" or ""
            say(("  %2d. %s %8.1f  %s  %s%s"):format(i, haveTag, score, displayID, name, pickTag))
        end
        if not pick then
            say("no owned item — macro would show empty-state stub.")
        end
    end,
}

-- Ordered keys so help output is stable. Add new dump names here in the
-- order you want them shown.
local DUMP_ORDER = { "categories", "statpriority", "bags", "item", "pick" }

-- ---------------------------------------------------------------------------
-- Help printers
-- ---------------------------------------------------------------------------

local function printDumpLines(prefix)
    for _, name in ipairs(DUMP_ORDER) do
        local target = DUMP_TARGETS[name]
        if target then
            local label = target.usage or name
            say(("  |cffffff00%s%s|r%s |cffffffff%s|r")
                :format(prefix, label, string.rep(" ", math.max(1, 18 - #label)), target.summary))
        end
    end
end

local function printHelp()
    say("|cffffd100Ka0s Consumable Master|r — commands:")
    say("  |cffffff00/cm|r              |cffffffffshow this help (alias: |r|cffffff00/consumablemaster|r|cffffffff)|r")
    say("  |cffffff00/cm config|r       |cffffffffopen settings panel|r")
    say("  |cffffff00/cm debug|r        |cfffffffftoggle debug mode|r")
    say("  |cffffff00/cm resync|r       |cffffffffforce macros to resync from bags|r")
    say("  |cffffff00/cm rewritemacros|r  |cffffffffforce a full rewrite of every KCM macro (icon + body)|r")
    say("  |cffffff00/cm reset|r        |cffffffffreset all priority lists to defaults|r")
    say("  |cffffff00/cm version|r      |cffffffffprint addon version|r")
    say("  |cffffff00/cm dump|r         |cffffffffdump internal state. subcommands:|r")
    printDumpLines("/cm dump ")
end

local function dumpHelp()
    say("dump targets:")
    printDumpLines("/cm dump ")
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function dumpDispatch(rest)
    rest = rest or ""
    local head, tail = rest:match("^(%S*)%s*(.-)$")
    head = (head or ""):lower()
    if head == "" then
        dumpHelp()
        return
    end

    -- Shortcut: `/cm dump <itemID>` routes to the `item` target.
    if tonumber(head) then
        DUMP_TARGETS.item.run(head)
        return
    end

    local target = DUMP_TARGETS[head]
    if target then
        target.run(tail)
        return
    end

    say("Unknown dump target: |cffffff00" .. head .. "|r")
    dumpHelp()
end

function KCM.SlashCommands.PrintHelp()
    printHelp()
end

function KCM:OnSlashCommand(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "help" then
        printHelp()
    elseif cmd == "debug" then
        KCM.Debug.Toggle()
    elseif cmd == "config" then
        if not (KCM.Options and KCM.Options.Open and KCM.Options.Open()) then
            say("Settings panel unavailable.")
        end
    elseif cmd == "resync" then
        if InCombatLockdown and InCombatLockdown() then
            say("in combat — macro writes deferred until regen.")
        end
        if KCM.TooltipCache and KCM.TooltipCache.InvalidateAll then
            KCM.TooltipCache.InvalidateAll()
        end
        if KCM.Pipeline and KCM.Pipeline.RunAutoDiscovery then
            local n = KCM.Pipeline.RunAutoDiscovery("manual_resync")
            say(("auto-discovery found %d new item(s)"):format(n))
        end
        if KCM.Pipeline and KCM.Pipeline.Recompute then
            KCM.Pipeline.Recompute("manual_resync")
            say("recomputed all categories.")
        end
    elseif cmd == "rewritemacros" or cmd == "rewrite" then
        if InCombatLockdown and InCombatLockdown() then
            say("in combat — macro writes deferred until regen.")
        end
        if KCM.MacroManager and KCM.MacroManager.InvalidateState then
            KCM.MacroManager.InvalidateState()
        end
        if KCM.Pipeline and KCM.Pipeline.Recompute then
            KCM.Pipeline.Recompute("manual_rewrite")
            say("rewrote all macros (body + icon). If action bar icons still look stale, /reload to force the bars to refresh.")
        end
    elseif cmd == "reset" then
        if StaticPopup_Show then
            StaticPopup_Show("KCM_CONFIRM_RESET")
        else
            say("StaticPopup unavailable.")
        end
    elseif cmd == "version" then
        say(("version %s"):format(tostring(KCM.VERSION or "?")))
    elseif cmd == "dump" then
        dumpDispatch(rest)
    else
        say("Unknown command: |cffffff00" .. cmd .. "|r")
        printHelp()
    end
end
