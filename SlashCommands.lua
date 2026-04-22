-- SlashCommands.lua — /kcm dispatcher. Registered via AceConsole in Core:OnInitialize.

local KCM = _G.KCM
KCM.SlashCommands = {}

local PREFIX = "|cffff8800[KCM]|r "

-- Shared confirmation popup for /kcm reset. preferredIndex = 3 dodges the
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
            print(PREFIX .. "Reset complete — defaults restored.")
        else
            print(PREFIX .. "Reset failed (DB not ready).")
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
-- in both `/kcm` and `/kcm dump` help output automatically.
-- ---------------------------------------------------------------------------

local DUMP_TARGETS = {}

DUMP_TARGETS.categories = {
    summary = "category metadata table",
    run = function()
        if not (KCM.Categories and KCM.Categories.LIST) then
            print(PREFIX .. "KCM.Categories.LIST not loaded.")
            return
        end
        if DevTools_Dump then
            DevTools_Dump(KCM.Categories.LIST)
        else
            for i, row in ipairs(KCM.Categories.LIST) do
                print(("  [%d] %s  macro=%s  display=%q  specAware=%s")
                    :format(i, row.key, row.macroName, row.displayName, tostring(row.specAware)))
            end
        end
    end,
}

DUMP_TARGETS.statpriority = {
    summary = "stat priority for current spec",
    run = function()
        if not (KCM.SpecHelper and KCM.SpecHelper.GetCurrent) then
            print(PREFIX .. "KCM.SpecHelper not loaded.")
            return
        end
        local classID, specID, specKey, specName = KCM.SpecHelper.GetCurrent()
        if not specKey then
            print(PREFIX .. "No active spec (low-level character?).")
            return
        end
        local priority = KCM.SpecHelper.GetStatPriority(specKey)
        print(PREFIX .. ("spec: %s  (classID=%s  specID=%s  key=%s)")
            :format(specName or "?", tostring(classID), tostring(specID), specKey))
        if DevTools_Dump then
            DevTools_Dump(priority)
        else
            print(("  primary: %s"):format(tostring(priority.primary)))
            print(("  secondary: %s"):format(table.concat(priority.secondary or {}, ", ")))
        end
    end,
}

DUMP_TARGETS.bags = {
    summary = "bag contents as itemID -> count",
    run = function()
        if not (KCM.BagScanner and KCM.BagScanner.Scan) then
            print(PREFIX .. "KCM.BagScanner not loaded.")
            return
        end
        local counts = KCM.BagScanner.Scan()
        if DevTools_Dump then
            DevTools_Dump(counts)
        else
            for id, n in pairs(counts) do
                print(("  %d x %d"):format(id, n))
            end
        end
    end,
}

DUMP_TARGETS.item = {
    summary = "parsed tooltip for <itemID> (e.g. /kcm dump item 241304)",
    usage   = "item <itemID>",
    run = function(arg)
        local id = tonumber(arg or "")
        if not id then
            print(PREFIX .. "usage: /kcm dump item <itemID>")
            return
        end
        if not (KCM.TooltipCache and KCM.TooltipCache.Get) then
            print(PREFIX .. "KCM.TooltipCache not loaded.")
            return
        end
        local entry = KCM.TooltipCache.Get(id)
        local name = (entry and entry.itemName)
            or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
            or "?"
        print(PREFIX .. ("item %d  (%s)"):format(id, tostring(name)))

        -- Dump GetItemInfoInstant — what Classifier uses for subType. This
        -- is the fastest way to tell why an item does/doesn't match a
        -- category (wrong subType string, mis-typed consumable, etc.).
        if C_Item and C_Item.GetItemInfoInstant then
            local iName, iType, iSubType, iEquip, iIcon, iClass, iSub =
                C_Item.GetItemInfoInstant(id)
            print(("  instant: type=%q  subType=%q  classID=%s  subClassID=%s")
                :format(tostring(iType), tostring(iSubType),
                        tostring(iClass), tostring(iSub)))
            local hits = KCM.Classifier and KCM.Classifier.MatchAny
                and KCM.Classifier.MatchAny(id) or {}
            if #hits > 0 then
                print(("  classified: %s"):format(table.concat(hits, ", ")))
            else
                print("  classified: |cffff4444(none)|r")
            end
        end

        if entry and entry.pending then
            print("  pending: tooltip data not yet loaded — try again in a moment.")
        elseif entry then
            local ok, reason = KCM.TooltipCache.IsUsableByPlayer(id)
            local playerLvl = UnitLevel("player") or 0
            if ok then
                print(("  usable: yes  (minLevel=%d, you=%d)")
                    :format(entry.minLevel or 0, playerLvl))
            else
                print(("  usable: no   (%s)"):format(tostring(reason)))
            end
        end
        if DevTools_Dump then
            DevTools_Dump(entry)
        end
    end,
}

DUMP_TARGETS.raw = {
    summary = "raw tooltip lines for <itemID> (for pattern debugging)",
    usage   = "raw <itemID>",
    run = function(arg)
        local id = tonumber(arg or "")
        if not id then
            print(PREFIX .. "usage: /kcm dump raw <itemID>")
            return
        end
        if not (C_TooltipInfo and C_TooltipInfo.GetItemByID) then
            print(PREFIX .. "C_TooltipInfo.GetItemByID unavailable.")
            return
        end
        local data = C_TooltipInfo.GetItemByID(id)
        if not data or not data.lines then
            print(PREFIX .. ("item %d: no tooltip data yet (try again shortly)."):format(id))
            return
        end
        print(PREFIX .. ("raw tooltip lines for item %d (%d lines):"):format(id, #data.lines))
        for i, line in ipairs(data.lines) do
            local left = line.leftText or ""
            local right = line.rightText or ""
            if right ~= "" then
                print(("  [%2d] L=%q  R=%q"):format(i, left, right))
            else
                print(("  [%2d] %q"):format(i, left))
            end
        end
    end,
}

-- ---------------------------------------------------------------------------
-- /kcm dump rank <catKey> — M4 debug helper.
-- Scores every seed item for the given category against the current spec's
-- stat priority (for spec-aware categories) and prints the sorted list.
-- ---------------------------------------------------------------------------

DUMP_TARGETS.rank = {
    summary = "rank seed items for a category (e.g. /kcm dump rank flask)",
    usage   = "rank <catKey>",
    run = function(arg)
        arg = (arg or ""):match("^(%S*)") or ""
        if arg == "" then
            print(PREFIX .. "usage: /kcm dump rank <catKey>  (e.g. flask, hp_pot, stat_food)")
            if KCM.Categories and KCM.Categories.LIST then
                local keys = {}
                for _, cat in ipairs(KCM.Categories.LIST) do
                    table.insert(keys, cat.key:lower())
                end
                print("  known: " .. table.concat(keys, ", "))
            end
            return
        end

        local catKey = arg:upper()
        local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
        if not cat then
            print(PREFIX .. "unknown category: |cffffff00" .. arg .. "|r")
            return
        end

        if not (KCM.Ranker and KCM.Ranker.SortCandidates) then
            print(PREFIX .. "KCM.Ranker not loaded.")
            return
        end

        local seed = KCM.SEED and KCM.SEED[catKey] or {}
        if #seed == 0 then
            print(PREFIX .. ("no seed items for %s"):format(catKey))
            return
        end

        local ctx
        if cat.specAware and KCM.SpecHelper then
            local _, _, specKey, specName = KCM.SpecHelper.GetCurrent()
            if specKey then
                ctx = { specPriority = KCM.SpecHelper.GetStatPriority(specKey) }
                print(PREFIX .. ("ranking %s for spec %s (%s)"):format(
                    catKey, specName or "?", specKey))
                print(("  primary=%s  secondary=%s"):format(
                    tostring(ctx.specPriority.primary),
                    table.concat(ctx.specPriority.secondary or {}, ">")))
            else
                print(PREFIX .. ("ranking %s (no active spec — priority will be empty)"):format(catKey))
            end
        else
            print(PREFIX .. ("ranking %s"):format(catKey))
        end

        local _, rows = KCM.Ranker.SortCandidates(catKey, seed, ctx)
        for i, row in ipairs(rows) do
            local tt = KCM.TooltipCache and KCM.TooltipCache.Get(row.id)
            local name = (tt and tt.itemName)
                or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(row.id))
                or "?"
            local tag = (tt and tt.pending) and "  |cffff8800(pending)|r" or ""
            print(("  %2d. %8.1f  %d  %s%s"):format(i, row.score, row.id, name, tag))
        end
    end,
}

-- ---------------------------------------------------------------------------
-- /kcm dump pick <catKey> — M5 debug helper.
-- Runs the full selector pipeline (candidates → rank → pin merge → first
-- owned) and prints the resulting priority list plus the pick.
-- ---------------------------------------------------------------------------

DUMP_TARGETS.pick = {
    summary = "effective priority + best-owned pick for a category",
    usage   = "pick <catKey>",
    run = function(arg)
        arg = (arg or ""):match("^(%S*)") or ""
        if arg == "" then
            print(PREFIX .. "usage: /kcm dump pick <catKey>")
            return
        end
        local catKey = arg:upper()
        local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
        if not cat then
            print(PREFIX .. "unknown category: |cffffff00" .. arg .. "|r")
            return
        end
        if not (KCM.Selector and KCM.Selector.GetEffectivePriority) then
            print(PREFIX .. "KCM.Selector not loaded.")
            return
        end

        local priority = KCM.Selector.GetEffectivePriority(catKey)
        local pick = KCM.Selector.PickBestForCategory(catKey)

        print(PREFIX .. ("effective priority for %s (%d items):"):format(catKey, #priority))
        for i, id in ipairs(priority) do
            local tt = KCM.TooltipCache and KCM.TooltipCache.Get(id)
            local name = (tt and tt.itemName)
                or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
                or "?"
            local have = KCM.BagScanner and KCM.BagScanner.HasItem and KCM.BagScanner.HasItem(id)
            local haveTag = have and "|cff44ff44[owned]|r" or "|cff888888[---]|r"
            local pickTag = (id == pick) and "  |cffffd100<-- pick|r" or ""
            print(("  %2d. %s  %d  %s%s"):format(i, haveTag, id, name, pickTag))
        end
        if not pick then
            print(PREFIX .. "no owned item — macro would show empty-state stub.")
        end
    end,
}

-- Ordered keys so help output is stable. Add new dump names here in the
-- order you want them shown.
local DUMP_ORDER = { "categories", "statpriority", "bags", "item", "raw", "rank", "pick" }

-- ---------------------------------------------------------------------------
-- Help printers
-- ---------------------------------------------------------------------------

local function printDumpLines(prefix)
    for _, name in ipairs(DUMP_ORDER) do
        local target = DUMP_TARGETS[name]
        if target then
            local label = target.usage or name
            print(("  |cffffff00%s%s|r%s %s")
                :format(prefix, label, string.rep(" ", math.max(1, 18 - #label)), target.summary))
        end
    end
end

local function printHelp()
    print(PREFIX .. "|cffffd100Ka0s Consumable Master|r — commands:")
    print("  |cffffff00/kcm|r             show this help")
    print("  |cffffff00/kcm config|r      open settings panel")
    print("  |cffffff00/kcm debug|r       toggle debug mode")
    print("  |cffffff00/kcm resync|r      force macros to resync from bags")
    print("  |cffffff00/kcm reset|r       reset all priority lists to defaults")
    print("  |cffffff00/kcm dump|r        dump internal state. subcommands:")
    printDumpLines("/kcm dump ")
end

local function dumpHelp()
    print(PREFIX .. "dump targets:")
    printDumpLines("/kcm dump ")
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

    -- Shortcut: `/kcm dump <itemID>` routes to the `item` target.
    if tonumber(head) then
        DUMP_TARGETS.item.run(head)
        return
    end

    local target = DUMP_TARGETS[head]
    if target then
        target.run(tail)
        return
    end

    print(PREFIX .. "Unknown dump target: |cffffff00" .. head .. "|r")
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
            print(PREFIX .. "Settings panel unavailable.")
        end
    elseif cmd == "resync" then
        if InCombatLockdown and InCombatLockdown() then
            print(PREFIX .. "in combat — macro writes deferred until regen.")
        end
        if KCM.TooltipCache and KCM.TooltipCache.InvalidateAll then
            KCM.TooltipCache.InvalidateAll()
        end
        if KCM.Pipeline and KCM.Pipeline.RunAutoDiscovery then
            local n = KCM.Pipeline.RunAutoDiscovery("manual_resync")
            print(PREFIX .. ("auto-discovery found %d new item(s)"):format(n))
        end
        if KCM.Pipeline and KCM.Pipeline.Recompute then
            KCM.Pipeline.Recompute("manual_resync")
            print(PREFIX .. "recomputed all categories.")
        end
    elseif cmd == "reset" then
        if StaticPopup_Show then
            StaticPopup_Show("KCM_CONFIRM_RESET")
        else
            print(PREFIX .. "StaticPopup unavailable.")
        end
    elseif cmd == "dump" then
        dumpDispatch(rest)
    else
        print(PREFIX .. "Unknown command: |cffffff00" .. cmd .. "|r")
        printHelp()
    end
end
