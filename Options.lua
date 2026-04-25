-- Options.lua — AceConfig-driven settings panel.
--
-- Registered in Core:OnInitialize via KCM.Options.Register(). Shows up in
-- Blizzard's ESC → Options → AddOns list as "Consumable Master". The
-- option table is built lazily on each open/refresh by KCM.Options.Build,
-- so any live mutation to KCM.db.profile / Selector state renders
-- immediately the next time NotifyChange fires.
--
-- Layered structure (top-level `args`):
--   1. general      — debug toggle, force resync, reset-all.
--   2. statpriority — shared Viewing-spec selector + primary/secondary
--                     dropdowns + reset. The selector drives
--                     O._viewedSpec, which spec-aware category pages
--                     read when rendering their priority list.
--   3. <categories> — one sub-group per Categories.LIST entry: add-by-id
--                     input, ranked priority list (↑/↓/X per row), per-
--                     category reset.
--
-- Mutation flow: widget -> KCM.Selector.* (or SpecHelper.SetStatPriority)
-- -> KCM.Pipeline.RequestRecompute -> KCM.Options.Refresh. The Refresh
-- call is what makes the UI re-read the underlying state.

local KCM = _G.KCM
KCM.Options = KCM.Options or {}
local O = KCM.Options

-- Shown as the category label in Blizzard's Settings panel and as the
-- root group name in the AceConfig tree. Shortened to "Consumable Master"
-- (the addon itself keeps the "Ka0s Consumable Master" identity in the
-- TOC and in chat output).
local PANEL_TITLE = "Consumable Master"
local REGISTRY_KEY = "ConsumableMaster"

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Every panel mutation funnels through here: request a pipeline recompute so
-- the macro bodies catch up, then redraw the panel so the new state shows
-- immediately.
local function afterMutation(reason)
    if KCM.Pipeline and KCM.Pipeline.RequestRecompute then
        KCM.Pipeline.RequestRecompute(reason or "options_mutation")
    end
    if O.Refresh then O.Refresh() end
end

-- Resolve a spec key for spec-aware categories.
local function currentSpecKey()
    if KCM.SpecHelper and KCM.SpecHelper.GetCurrent then
        local _, _, key = KCM.SpecHelper.GetCurrent()
        return key
    end
    return nil
end

-- Shared "viewed spec" — which spec's bucket the user is editing on the
-- spec-aware pages (Stat Food, Flask) AND on the Stat Priority tab.
-- Module-local (not persisted) so every session opens on the active spec;
-- the user switches via the selector on the Stat Priority tab and the
-- change fans out to every spec-aware category list.
O._viewedSpec = O._viewedSpec or nil

-- Per-category "Add by ID" kind selector state. Not persisted — every
-- session opens on Item for each category, which is the common case.
-- Keys are catKey strings; values are "ITEM" or "SPELL".
O._addKind = O._addKind or {}

local ADD_KIND_OPTIONS = { ITEM = "Item", SPELL = "Spell" }
local ADD_KIND_SORTING = { "ITEM", "SPELL" }

-- Lookup helpers that span the Midnight C_Spell / legacy GetSpellInfo split
-- and the multi-return shape of C_Item.GetItemInfo. Both return nil when the
-- ID isn't resolvable (unknown spell, uncached item on first call), which
-- the validator treats as a hard fail for spells and a soft fallback for
-- items (GetItemInfoInstant still validates the ID even when the name isn't
-- cached yet).
local function spellNameByID(id)
    if not id then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local n = C_Spell.GetSpellName(id)
        if n and n ~= "" then return n end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info and info.name and info.name ~= "" then return info.name end
    end
    if GetSpellInfo then
        local n = GetSpellInfo(id)
        if n and n ~= "" then return n end
    end
    return nil
end

local function itemNameByID(id)
    if not id then return nil end
    if C_Item and C_Item.GetItemInfo then
        local name = C_Item.GetItemInfo(id)
        if name and name ~= "" then return name end
    end
    return nil
end

local function resolveViewedSpec()
    if O._viewedSpec then return O._viewedSpec end
    local cur = currentSpecKey()
    O._viewedSpec = cur
    return cur
end

-- Stat enum constants. Keys match what Ranker.statWeight / SpecHelper
-- consume; display values are human-readable. The empty-string key is
-- the "(none)" sentinel for secondary slots that the user wants to leave
-- blank — compacted out on save so Ranker always sees a dense list.
local PRIMARY_OPTIONS = {
    STR = "Strength",
    AGI = "Agility",
    INT = "Intellect",
}
local PRIMARY_SORTING = { "STR", "AGI", "INT" }

local SECONDARY_OPTIONS = {
    [""]          = "(none)",
    CRIT          = "Critical Strike",
    HASTE         = "Haste",
    MASTERY       = "Mastery",
    VERSATILITY   = "Versatility",
}
local SECONDARY_SORTING = { "", "CRIT", "HASTE", "MASTERY", "VERSATILITY" }

-- Resolve a specKey like "7_264" into a friendly "<icon> Shaman — Enhancement"
-- label, prefixed with the spec's Blizzard icon when the API can surface it.
-- Falls back to the raw key if the classID/specID don't parse (e.g. a stale
-- DB entry from a removed spec) so the UI always renders *something*.
local specLabelCache = {}
local function formatSpec(specKey)
    if not specKey then return "(no active spec)" end
    local cached = specLabelCache[specKey]
    if cached then return cached end

    local classID, specID = specKey:match("^(%d+)_(%d+)$")
    classID, specID = tonumber(classID), tonumber(specID)
    if not (classID and specID) then return specKey end

    local className = tostring(classID)
    if GetClassInfo then
        local n = GetClassInfo(classID)
        if n then className = n end
    end

    local specName, specIcon
    if GetNumSpecializationsForClassID and GetSpecializationInfoForClassID then
        for i = 1, (GetNumSpecializationsForClassID(classID) or 0) do
            local sid, name, _, icon = GetSpecializationInfoForClassID(classID, i)
            if sid == specID then
                specName = name
                specIcon = icon
                break
            end
        end
    end

    local label = ("%s — %s"):format(className, specName or tostring(specID))
    if specIcon then
        label = ("|T%s:16|t %s"):format(specIcon, label)
    end
    specLabelCache[specKey] = label
    return label
end

local function specSelectorValues()
    local values, sorting = {}, {}
    if not (KCM.SpecHelper and KCM.SpecHelper.AllSpecs) then
        return values, sorting
    end
    local rows = KCM.SpecHelper.AllSpecs()
    for _, row in ipairs(rows) do
        values[row.specKey] = formatSpec(row.specKey)
        table.insert(sorting, row.specKey)
    end
    -- Sort by the label with texture markup stripped so "|T...|t Shaman ..."
    -- sorts next to "Shaman", not under "|".
    local stripMarkup = function(s) return (s:gsub("|T.-|t%s*", "")) end
    table.sort(sorting, function(a, b)
        return stripMarkup(values[a] or "") < stripMarkup(values[b] or "")
    end)
    return values, sorting
end

-- Read the effective stat priority for a spec (respects user override if
-- present, else seed, else class fallback — see SpecHelper.GetStatPriority).
-- For the secondary list, we pad to four slots with "" so the UI always
-- shows four dropdowns.
local function readStatPriority(specKey)
    if not (KCM.SpecHelper and KCM.SpecHelper.GetStatPriority) or not specKey then
        return { primary = "STR", secondary = { "", "", "", "" } }
    end
    local p = KCM.SpecHelper.GetStatPriority(specKey)
    local secondary = {}
    for i = 1, 4 do secondary[i] = (p.secondary and p.secondary[i]) or "" end
    return { primary = p.primary or "STR", secondary = secondary }
end

-- Write a stat-priority override to db.profile.statPriority[specKey].
-- `mutate(p)` edits the { primary, secondary } table in place; we then
-- compact secondary (drop "" entries) and persist. Returns true on write.
local function writeStatPriority(specKey, mutate)
    if not specKey or not (KCM.db and KCM.db.profile) then return false end
    local cur = readStatPriority(specKey)
    mutate(cur)
    local compacted = {}
    for _, s in ipairs(cur.secondary) do
        if s and s ~= "" then table.insert(compacted, s) end
    end
    KCM.db.profile.statPriority = KCM.db.profile.statPriority or {}
    KCM.db.profile.statPriority[specKey] = {
        primary   = cur.primary,
        secondary = compacted,
    }
    return true
end

-- ---------------------------------------------------------------------------
-- General page — M6.1b
-- ---------------------------------------------------------------------------
-- Debug toggle reflects KCM.Debug flag; resync/reset fan out to the same
-- helpers the slash commands use so behaviour stays identical regardless
-- of entry point.

local function buildGeneralArgs()
    return {
        title = {
            type  = "description",
            order = 0,
            name  = "General",
            dialogControl = "KCMTitle",
        },
        titleSpacer = {
            type  = "description",
            order = 0.5,
            name  = " ",
            fontSize = "medium",
        },

        debug = {
            type  = "toggle",
            order = 1,
            name  = "Debug mode",
            desc  = "Print per-event diagnostics to chat. Same as /kcm debug.",
            width = "full",
            get   = function()
                return KCM.Debug and KCM.Debug.IsOn and KCM.Debug.IsOn() or false
            end,
            set   = function(_, val)
                if not (KCM.Debug and KCM.Debug.Toggle) then return end
                -- Toggle only if the requested value differs from current,
                -- so clicking the checkbox has deterministic semantics
                -- regardless of what Toggle's default behaviour is.
                local cur = KCM.Debug.IsOn and KCM.Debug.IsOn()
                if cur ~= val then KCM.Debug.Toggle() end
            end,
        },

        resync = {
            type  = "execute",
            order = 2,
            name  = "Force resync",
            desc  = "Invalidate the tooltip cache, re-run auto-discovery against "
                 .. "your bags, and recompute every category's pick. Macros are "
                 .. "re-issued only if the picked item or body actually changes "
                 .. "— use Force rewrite macros below to re-issue them "
                 .. "unconditionally. Same as /kcm resync. Blocked in combat.",
            width = "full",
            func  = function()
                if InCombatLockdown and InCombatLockdown() then
                    print("|cffff8800[KCM]|r in combat — resync deferred until regen.")
                    return
                end
                if KCM.TooltipCache and KCM.TooltipCache.InvalidateAll then
                    KCM.TooltipCache.InvalidateAll()
                end
                if KCM.Pipeline and KCM.Pipeline.RunAutoDiscovery then
                    KCM.Pipeline.RunAutoDiscovery("options_resync")
                end
                if KCM.Pipeline and KCM.Pipeline.Recompute then
                    KCM.Pipeline.Recompute("options_resync")
                end
                O.Refresh()
            end,
        },

        rewritemacros = {
            type  = "execute",
            order = 2.5,
            name  = "Force rewrite macros",
            desc  = "Clear cached macro fingerprints and re-issue every KCM macro "
                 .. "(body + stored icon). Use this if a macro's action-bar icon "
                 .. "looks stale. Same as /kcm rewritemacros. Blocked in combat.",
            width = "full",
            func  = function()
                if InCombatLockdown and InCombatLockdown() then
                    print("|cffff8800[KCM]|r in combat — macro writes deferred until regen.")
                    return
                end
                if KCM.MacroManager and KCM.MacroManager.InvalidateState then
                    KCM.MacroManager.InvalidateState()
                end
                if KCM.Pipeline and KCM.Pipeline.Recompute then
                    KCM.Pipeline.Recompute("options_rewrite")
                end
                print("|cffff8800[KCM]|r rewrote all macros. If action bar icons still look stale, /reload to force the bars to refresh.")
                O.Refresh()
            end,
        },

        reset = {
            type    = "execute",
            order   = 3,
            name    = "Reset all priorities",
            desc    = "Wipe all added/blocked/pinned items and stat-priority "
                   .. "overrides. Seed defaults are restored. This cannot "
                   .. "be undone.",
            width   = "full",
            confirm = true,
            confirmText = "Reset ALL ConsumableMaster customization to defaults?",
            func    = function()
                if KCM.ResetAllToDefaults then
                    KCM.ResetAllToDefaults("options_reset")
                end
                O.Refresh()
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Per-category page — M6.1c/d
-- ---------------------------------------------------------------------------
-- Layout of one category sub-group:
--   1. description header
--   2. "Add item by ID" input (validates with GetItemInfoInstant)
--   3. priority list — one row per item, widths chosen so four widgets
--      (label 1.5 + ↑ 0.15 + ↓ 0.15 + X 0.2 = 2.0) fit on one row in
--      AceConfigDialog's default 2-unit layout.
--   4. "Reset category" execute — wipes added/blocked/pins for this
--      category (or this spec's sub-bucket for spec-aware categories).
--
-- Reads from Selector; writes via Selector.AddItem / .Block / .MoveUp /
-- .MoveDown / .GetBucket. Every mutation calls afterMutation so the macro
-- pipeline and panel stay in sync.

-- Shared status glyphs for the listLegend description (KCMItemRow handles its
-- own status rendering directly from textures, so these only feed the legend
-- inline markup).
local OWNED_ICON     = "|TInterface\\RaidFrame\\ReadyCheck-Ready:20|t"
local NOT_OWNED_ICON = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:20|t"
local PICK_ICON      = "|TInterface\\COMMON\\FavoritesIcon:20|t"

-- Format a number with thousands separators so the score tooltip reads
-- cleanly (the heal-value + immediate-bonus sums run to nine digits).
-- Non-numbers pass through as tostring; fractional values keep one decimal.
local function formatNumber(n)
    if type(n) ~= "number" then return tostring(n) end
    local isWhole = (n == math.floor(n))
    local abs = math.abs(n)
    local body = isWhole and tostring(math.floor(abs)) or ("%.1f"):format(abs)
    -- Reverse, group every 3 digits, reverse back. Works for both the
    -- integer form and the "123456.7" form (the decimal part never exceeds
    -- 3 digits so the post-decimal doesn't pick up stray commas once
    -- reversed).
    local sepd = body:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0) and ("-" .. sepd) or sepd
end

-- Build the multi-line tooltip body that the score button shows on hover
-- from a Ranker.Explain() result. Each signal line is the contributing
-- factor's label, value, and optional note; the summary appended at the
-- end describes the overall scoring rule for the category.
local function formatScoreTooltipDesc(explain)
    if not explain then return "" end
    local lines = {}
    for _, s in ipairs(explain.signals or {}) do
        local note = s.note and ("  |cff888888(" .. s.note .. ")|r") or ""
        table.insert(lines, ("  %s: |cffffffff%s|r%s")
            :format(s.label or "?", formatNumber(s.value or 0), note))
    end
    if explain.summary and explain.summary ~= "" then
        table.insert(lines, "")
        table.insert(lines, "|cffaaaaaa" .. explain.summary .. "|r")
    end
    return table.concat(lines, "\n")
end

local function buildStatPriorityArgs(specKey)
    local args = {}

    args.primary = {
        type   = "select",
        order  = 1,
        name   = "Primary stat",
        desc   = "Dominant stat for this spec. Primary-stat consumables "
              .. "always beat secondary-stat ones regardless of magnitude.",
        values = PRIMARY_OPTIONS,
        sorting = PRIMARY_SORTING,
        width  = 1.0,
        get    = function()
            return readStatPriority(specKey).primary
        end,
        set    = function(_, val)
            if writeStatPriority(specKey, function(p) p.primary = val end) then
                afterMutation("options_stat_primary")
            end
        end,
    }

    args.primarySpacer = { type = "description", order = 2, name = " ", width = 1.0 }

    for i = 1, 4 do
        args["secondary" .. i] = {
            type   = "select",
            order  = 10 + i,
            name   = ("Secondary stat #%d"):format(i),
            desc   = "Secondary stat ranked at position " .. i
                  .. ". Position 1 weighs the most; leave as (none) to "
                  .. "truncate the list.",
            values = SECONDARY_OPTIONS,
            sorting = SECONDARY_SORTING,
            width  = 1.0,
            get    = function()
                return readStatPriority(specKey).secondary[i]
            end,
            set    = function(_, val)
                local changed = writeStatPriority(specKey, function(p)
                    p.secondary[i] = val or ""
                end)
                if changed then afterMutation("options_stat_secondary") end
            end,
        }
    end

    args.resetSpacer = { type = "description", order = 50, name = " " }
    args.reset = {
        type  = "execute",
        order = 51,
        name  = "Reset stat priority",
        desc  = "Drop user override for this spec. The Ranker falls back "
             .. "to the seed default (Defaults_StatPriority.lua) or the "
             .. "class-primary fallback if no seed exists.",
        width = 1.0,
        func  = function()
            if not (KCM.db and KCM.db.profile and specKey) then return end
            KCM.db.profile.statPriority = KCM.db.profile.statPriority or {}
            if KCM.db.profile.statPriority[specKey] then
                KCM.db.profile.statPriority[specKey] = nil
                afterMutation("options_stat_reset")
            end
        end,
    }

    return args
end

-- Builds the top-level "Stat Priority" tab (one shared panel replacing the
-- per-category inline groups). The spec selector here is the single source of
-- truth for O._viewedSpec — changing it also re-renders spec-aware category
-- pages (Stat Food, Flask) with the new spec's priority list.
local function buildStatPriorityTabArgs()
    local specKey = resolveViewedSpec()
    local args = {}

    args.title = {
        type  = "description",
        order = 1,
        name  = "Stat Priority",
        dialogControl = "KCMTitle",
    }

    local values, sorting = specSelectorValues()
    args.specSelector = {
        type    = "select",
        order   = 2,
        name    = "Viewing spec",
        desc    = "Select which spec's stat priority you want to edit. This "
               .. "also determines which spec's priority list is shown on "
               .. "the Stat Food and Flask tabs.",
        values  = values,
        sorting = sorting,
        width   = "double",
        get     = function() return O._viewedSpec end,
        set     = function(_, val)
            O._viewedSpec = val
            if O.Refresh then O.Refresh() end
        end,
    }

    args.selectorSpacer = {
        type  = "description",
        order = 3,
        name  = " ",
        fontSize = "medium",
    }

    if not specKey then
        args.empty = {
            type  = "description",
            order = 10,
            name  = "|cffff8800No spec selected.|r Pick one above to edit its stat priority.",
            fontSize = "medium",
        }
        return args
    end

    -- Splice the primary/secondary/reset editor in. Keys don't collide with
    -- title/specSelector/selectorSpacer/empty, and each call to
    -- buildStatPriorityArgs creates fresh tables, so order shifts here don't
    -- leak across calls.
    local editor = buildStatPriorityArgs(specKey)
    for k, v in pairs(editor) do
        if type(v) == "table" and type(v.order) == "number" then
            v.order = v.order + 10
        end
        args[k] = v
    end

    return args
end

-- ---------------------------------------------------------------------------
-- Composite category panel (HP_AIO, MP_AIO)
-- ---------------------------------------------------------------------------
-- Composite categories don't have an item priority list of their own — the
-- macro body is composed at recompute time from the picks of the underlying
-- single categories (e.g. HP_AIO reads HS, HP_POT, FOOD picks). This panel
-- exposes only what the user can configure: which sub-categories are
-- enabled, their order within each combat-state section, and a read-only
-- preview of what each sub-category is currently picking. Sub-categories
-- are locked to their section.
local function buildCompositeArgs(catKey)
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    if not cat or not cat.composite then return {} end
    local cfg = KCM.db and KCM.db.profile and KCM.db.profile.categories
        and KCM.db.profile.categories[cat.key]
    if not cfg then return {} end

    local args = {}

    args.descHeader = {
        type  = "description",
        order = 1,
        name  = cat.displayName,
        dialogControl = "KCMTitle",
    }
    args.descSubheader = {
        type  = "description",
        order = 2,
        name  = "Composite macro. Toggle and order the contributing categories below — "
             .. "each category's own ranking and pick logic is edited on its individual panel.",
        fontSize = "medium",
    }
    args.subheaderSpacer = {
        type  = "description",
        order = 3,
        name  = " ",
        fontSize = "medium",
    }
    args.dragIcon = {
        type  = "description",
        order = 4,
        name  = "",
        dialogControl = "KCMMacroDragIcon",
        descStyle = "hide",
        arg   = { macroName = cat.macroName },
        width = "full",
    }

    -- Resolve the "currently owned" status the same way the single-cat panel
    -- does so the KCMItemRow status glyph stays consistent across pages.
    local hasItem = KCM.BagScanner and KCM.BagScanner.HasItem
    local function isOwned(id)
        if not id then return false end
        if KCM.ID and KCM.ID.IsSpell(id) then
            local sid = KCM.ID.SpellID(id)
            return sid and IsPlayerSpell and IsPlayerSpell(sid) or false
        end
        return hasItem and hasItem(id) or false
    end

    local sections = {
        { key = "inCombat",    orderField = "orderInCombat",    label = "In Combat",     headingOrder = 10  },
        { key = "outOfCombat", orderField = "orderOutOfCombat", label = "Out of Combat", headingOrder = 100 },
    }

    for _, section in ipairs(sections) do
        local orderArr = cfg[section.orderField] or {}

        args[section.key .. "_heading"] = {
            type  = "header",
            order = section.headingOrder,
            name  = section.label,
            dialogControl = "KCMHeading",
        }

        if #orderArr == 0 then
            args[section.key .. "_empty"] = {
                type  = "description",
                order = section.headingOrder + 1,
                name  = "|cffff8800(no sub-categories)|r",
                fontSize = "medium",
            }
        else
            local rowSize = #orderArr
            for i, ref in ipairs(orderArr) do
                local refCat = KCM.Categories.Get(ref)
                local pick   = (KCM.Selector and KCM.Selector.PickBestForCategory)
                    and KCM.Selector.PickBestForCategory(ref) or nil

                -- Capture closure values: rowIndex and orderField are stable
                -- across the AceConfig render cycle (panel cache invalidates
                -- on every mutation), so reading by index is safe.
                local rowIndex = i
                local rowRef   = ref
                local sectionOrderField = section.orderField

                local base = section.headingOrder + i * 10
                local rowKey = section.key .. "_" .. i
                local refLabel = refCat and refCat.displayName or rowRef

                -- Single-row layout: KCMItemRow (preview, also identifies the
                -- sub-cat via fallbackName when there's no pick) on the left,
                -- Enabled toggle and ↑/↓ on the right. KCMItemRow at 1.8
                -- mirrors the single-cat layout so item names line up
                -- vertically between AIO and individual category pages; the
                -- toggle is held at 0.4 so its "Enabled" label doesn't
                -- truncate to "Ena…".
                args[rowKey .. "_preview"] = {
                    type  = "description",
                    order = base + 0,
                    name  = "",
                    dialogControl = "KCMItemRow",
                    descStyle = "hide",
                    arg   = {
                        itemID       = pick,
                        owned        = isOwned(pick),
                        isPick       = false,
                        fallbackName = refLabel,
                    },
                    width = 1.8,
                }
                args[rowKey .. "_toggle"] = {
                    type  = "toggle",
                    order = base + 1,
                    name  = "Enabled",
                    desc  = ("Include %s in the macro body."):format(refLabel),
                    width = 0.4,
                    get   = function()
                        local en = cfg.enabled
                        return en == nil or en[rowRef] ~= false
                    end,
                    set   = function(_, val)
                        cfg.enabled = cfg.enabled or {}
                        cfg.enabled[rowRef] = val and true or false
                        afterMutation("options_aio_toggle")
                    end,
                }
                args[rowKey .. "_up"] = {
                    type  = "execute",
                    order = base + 2,
                    name  = "",
                    desc  = "Move higher in section order",
                    descStyle = "hide",
                    image = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up",
                    imageWidth  = 24,
                    imageHeight = 24,
                    dialogControl = "KCMIconButton",
                    width = 0.155,
                    disabled = (rowIndex == 1) or (rowSize <= 1),
                    func  = function()
                        local arr = cfg[sectionOrderField]
                        if not arr or rowIndex <= 1 then return end
                        arr[rowIndex], arr[rowIndex - 1] = arr[rowIndex - 1], arr[rowIndex]
                        afterMutation("options_aio_move_up")
                    end,
                }
                args[rowKey .. "_down"] = {
                    type  = "execute",
                    order = base + 3,
                    name  = "",
                    desc  = "Move lower in section order",
                    descStyle = "hide",
                    image = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
                    imageWidth  = 24,
                    imageHeight = 24,
                    dialogControl = "KCMIconButton",
                    width = 0.155,
                    disabled = (rowIndex == rowSize) or (rowSize <= 1),
                    func  = function()
                        local arr = cfg[sectionOrderField]
                        if not arr or rowIndex >= #arr then return end
                        arr[rowIndex], arr[rowIndex + 1] = arr[rowIndex + 1], arr[rowIndex]
                        afterMutation("options_aio_move_down")
                    end,
                }
            end
        end
    end

    args.resetDivider = { type = "header", order = 10000, name = "" }
    args.reset = {
        type        = "execute",
        order       = 10001,
        name        = "Reset category",
        desc        = "Restore enabled flags and section order to defaults.",
        confirm     = true,
        confirmText = ("Reset %s to defaults?"):format(cat.displayName),
        func        = function()
            local defaults = KCM.dbDefaults and KCM.dbDefaults.profile
                and KCM.dbDefaults.profile.categories
                and KCM.dbDefaults.profile.categories[cat.key]
            if not defaults then return end
            cfg.enabled          = CopyTable(defaults.enabled or {})
            cfg.orderInCombat    = CopyTable(defaults.orderInCombat or {})
            cfg.orderOutOfCombat = CopyTable(defaults.orderOutOfCombat or {})
            afterMutation("options_aio_reset_cat")
        end,
    }

    return args
end

local function buildCategoryArgs(catKey)
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    if not cat then return {} end
    if cat.composite then return buildCompositeArgs(catKey) end
    local specKey = cat.specAware and resolveViewedSpec() or nil

    local args = {}

    args.descHeader = {
        type  = "description",
        order = 1,
        name  = cat.displayName,
        dialogControl = "KCMTitle",
    }
    if cat.specAware then
        args.descSubheader = {
            type  = "description",
            order = 2,
            name  = ("Spec-aware. Viewing: %s."):format(formatSpec(specKey)),
            fontSize = "medium",
        }
        args.subheaderSpacer = {
            type  = "description",
            order = 3,
            name  = " ",
            fontSize = "medium",
        }
    end
    args.dragIcon = {
        type  = "description",
        order = 4,
        name  = "",
        dialogControl = "KCMMacroDragIcon",
        descStyle = "hide",
        arg   = { macroName = cat.macroName },
        width = "full",
    }

    -- Add-by-id --------------------------------------------------
    -- Two widgets on one row: a kind selector (Item / Spell, width 0.5) and
    -- the ID input (width 1.5). The kind drives validation (itemID via
    -- GetItemInfoInstant, spellID via spellNameByID), the confirm message
    -- shown before commit, and whether `set` converts the number into a
    -- spell sentinel via KCM.ID.AsSpell before handing it to Selector.
    args.addHeader = {
        type = "header",
        order = 10,
        name = "Add item or spell by ID",
        dialogControl = "KCMHeading",
    }
    args.addKind = {
        type    = "select",
        order   = 11,
        name    = "Type",
        desc    = "Choose whether the ID you're entering belongs to an item "
               .. "(default — anything in bags) or a spell (class abilities "
               .. "like Recuperate).",
        values  = ADD_KIND_OPTIONS,
        sorting = ADD_KIND_SORTING,
        width   = 0.5,
        get     = function() return O._addKind[catKey] or "ITEM" end,
        set     = function(_, val)
            O._addKind[catKey] = val
            if O.Refresh then O.Refresh() end
        end,
    }
    args.addInput = {
        type  = "input",
        order = 12,
        name  = "ID",
        desc  = "Enter an itemID or spellID to add to this category. Pick "
             .. "the matching type on the left. Auto-discovery already "
             .. "handles items in your bags; use this to seed something "
             .. "you don't currently carry, or any castable spell.",
        width = 1.5,
        get   = function() return "" end,
        validate = function(_, val)
            if val == "" then return true end
            local id = tonumber(val)
            if not id then return "Not a number." end
            if id <= 0 then return "Must be a positive ID." end
            local kind = O._addKind[catKey] or "ITEM"
            if kind == "SPELL" then
                if not spellNameByID(id) then return "Unknown spellID." end
            else
                if C_Item and C_Item.GetItemInfoInstant then
                    local name = C_Item.GetItemInfoInstant(id)
                    if not name then return "Unknown itemID." end
                end
            end
            return true
        end,
        confirm = function(_, val)
            local id = tonumber(val)
            if not id then return false end
            local kind = O._addKind[catKey] or "ITEM"
            if kind == "SPELL" then
                local name = spellNameByID(id) or ("Spell #" .. id)
                return ("Add spell \"%s\" (ID %d) to %s?"):format(name, id, cat.displayName)
            end
            local name = itemNameByID(id) or ("Item #" .. id)
            return ("Add item \"%s\" (ID %d) to %s?"):format(name, id, cat.displayName)
        end,
        set = function(_, val)
            local id = tonumber(val)
            if not id then return end
            if cat.specAware and not specKey then
                print("|cffff8800[KCM]|r spec-aware category: no active spec — can't add.")
                return
            end
            local kind = O._addKind[catKey] or "ITEM"
            local storedID = (kind == "SPELL") and KCM.ID.AsSpell(id) or id
            local changed = KCM.Selector and KCM.Selector.AddItem
                and KCM.Selector.AddItem(catKey, storedID, specKey)
            if changed then afterMutation("options_add_item") end
        end,
    }

    -- Priority list ----------------------------------------------
    args.listHeader = {
        type = "header",
        order = 20,
        name = "Priority list",
        dialogControl = "KCMHeading",
    }
    args.listLegend = {
        type  = "description",
        order = 21,
        name  = ("%s in bags    %s not in bags    %s picked in macro"):format(OWNED_ICON, NOT_OWNED_ICON, PICK_ICON),
        fontSize = "medium",
    }
    args.listLegendSpacer = {
        type  = "description",
        order = 22,
        name  = " ",
        fontSize = "medium",
    }

    if cat.specAware and not specKey then
        args.listEmpty = {
            type  = "description",
            order = 23,
            name  = "|cffff8800No active spec.|r Spec-aware categories need a "
                 .. "resolvable spec to display a priority list.",
            fontSize = "medium",
        }
    else
        local priority = (KCM.Selector and KCM.Selector.GetEffectivePriority
            and KCM.Selector.GetEffectivePriority(catKey, specKey)) or {}
        local pick     = KCM.Selector and KCM.Selector.PickBestForCategory
            and KCM.Selector.PickBestForCategory(catKey, specKey) or nil
        local hasItem  = KCM.BagScanner and KCM.BagScanner.HasItem

        if #priority == 0 then
            args.listEmpty = {
                type  = "description",
                order = 23,
                name  = "|cffff8800(empty)|r — no candidates yet. Add an "
                     .. "itemID above or pick up a matching item to trigger "
                     .. "auto-discovery.",
                fontSize = "medium",
            }
        else
            -- Spell entries (negative sentinel) are "owned" iff IsPlayerSpell
            -- returns true; BagScanner only knows about items.
            local function isOwned(id)
                if KCM.ID and KCM.ID.IsSpell(id) then
                    local sid = KCM.ID.SpellID(id)
                    return sid and IsPlayerSpell and IsPlayerSpell(sid) or false
                end
                return hasItem and hasItem(id) or false
            end

            -- Ranker ctx is built once per category per render: specPriority
            -- for stat-aware cats, bestImmediateAmount for HP_POT / MP_POT.
            -- Every row's score tooltip uses the same ctx so the numbers
            -- match the effective sort exactly.
            local rankerCtx
            if cat.specAware and specKey and KCM.SpecHelper and KCM.SpecHelper.GetStatPriority then
                rankerCtx = { specPriority = KCM.SpecHelper.GetStatPriority(specKey) }
            end
            if KCM.Ranker and KCM.Ranker.BuildContext then
                rankerCtx = KCM.Ranker.BuildContext(catKey, priority, rankerCtx)
            end

            for i, id in ipairs(priority) do
                local base   = 30 + i * 10
                local owned  = isOwned(id)
                local isFirst = (i == 1)
                local isLast  = (i == #priority)
                local rowID   = id  -- capture for closures

                local explain = KCM.Ranker and KCM.Ranker.Explain
                    and KCM.Ranker.Explain(catKey, rowID, rankerCtx) or nil
                local scoreTitle = explain
                    and ("Rank score: %s"):format(formatNumber(explain.score))
                    or "Rank score"
                local scoreDesc  = formatScoreTooltipDesc(explain)

                args["row" .. i .. "_label"] = {
                    type  = "description",
                    order = base + 0,
                    name  = "",
                    dialogControl = "KCMItemRow",
                    descStyle = "hide",
                    arg   = {
                        itemID = rowID,
                        owned  = owned,
                        isPick = (pick and rowID == pick) and true or false,
                    },
                    width = 1.8,
                }
                -- FriendsFrame\InformationIcon is the classic blue "i" info
                -- glyph — reads as "hover for info", matches the button's
                -- role as a tooltip anchor. Clicking is a no-op; this button
                -- exists only to display the per-item score breakdown.
                args["row" .. i .. "_score"] = {
                    type  = "execute",
                    order = base + 1,
                    name  = scoreTitle,
                    desc  = scoreDesc,
                    image = "Interface\\FriendsFrame\\InformationIcon",
                    imageWidth  = 22,
                    imageHeight = 22,
                    dialogControl = "KCMScoreButton",
                    width = 0.155,
                    func  = function() end,
                }
                args["row" .. i .. "_up"] = {
                    type  = "execute",
                    order = base + 2,
                    name  = "",
                    desc  = "Move higher in priority",
                    descStyle = "hide",
                    image = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up",
                    imageWidth  = 24,
                    imageHeight = 24,
                    dialogControl = "KCMIconButton",
                    width = 0.155,
                    disabled = isFirst,
                    func  = function()
                        if KCM.Selector and KCM.Selector.MoveUp
                            and KCM.Selector.MoveUp(catKey, rowID, specKey) then
                            afterMutation("options_move_up")
                        end
                    end,
                }
                args["row" .. i .. "_down"] = {
                    type  = "execute",
                    order = base + 3,
                    name  = "",
                    desc  = "Move lower in priority",
                    descStyle = "hide",
                    image = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
                    imageWidth  = 24,
                    imageHeight = 24,
                    dialogControl = "KCMIconButton",
                    width = 0.155,
                    disabled = isLast,
                    func  = function()
                        if KCM.Selector and KCM.Selector.MoveDown
                            and KCM.Selector.MoveDown(catKey, rowID, specKey) then
                            afterMutation("options_move_down")
                        end
                    end,
                }
                args["row" .. i .. "_x"] = {
                    type  = "execute",
                    order = base + 4,
                    name  = "",
                    desc  = "Remove from this category. Blocks the item so "
                         .. "auto-discovery won't re-add it.",
                    descStyle = "hide",
                    -- atlas:transmog-icon-remove is Blizzard's "remove item"
                    -- glyph (red circle-slash / no-entry sign) — visually
                    -- distinct from ReadyCheck-NotReady, which KCMItemRow uses
                    -- for the "not in bags" status indicator on the left.
                    image = "atlas:transmog-icon-remove",
                    imageWidth  = 22,
                    imageHeight = 22,
                    dialogControl = "KCMIconButton",
                    width = 0.155,
                    func  = function()
                        if KCM.Selector and KCM.Selector.Block
                            and KCM.Selector.Block(catKey, rowID, specKey) then
                            afterMutation("options_remove")
                        end
                    end,
                }
            end
        end
    end

    -- Per-category reset -----------------------------------------
    -- Order numbers must sit above the highest possible row order. Rows use
    -- (30 + i * 10), so a list of N items reaches 30 + N*10 + 4. A constant
    -- well above any plausible category size keeps the divider/reset pinned
    -- at the bottom regardless of list length (Stat Food in particular can
    -- exceed 17 entries, which is where the old order=201 began appearing
    -- mid-list).
    args.resetDivider = { type = "header", order = 10000, name = "" }
    args.reset = {
        type        = "execute",
        order       = 10001,
        name        = "Reset category",
        desc        = "Clear added/blocked items and pin overrides for this "
                   .. "category" .. (cat.specAware and " (viewed spec only)" or "")
                   .. ". Discovered items (from bag scans) are preserved.",
        confirm     = true,
        confirmText = ("Reset %s%s to defaults?"):format(
                          cat.displayName,
                          cat.specAware and " (viewed spec)" or ""),
        func        = function()
            local bucket = KCM.Selector and KCM.Selector.GetBucket
                and KCM.Selector.GetBucket(catKey, specKey)
            if not bucket then return end
            bucket.added   = {}
            bucket.blocked = {}
            bucket.pins    = {}
            afterMutation("options_reset_cat")
        end,
    }

    return args
end

-- ---------------------------------------------------------------------------
-- Top-level Build
-- ---------------------------------------------------------------------------

-- Memoized options tree. AceConfigDialog calls the registered builder on
-- every access (tab navigation included) via AceConfigRegistry:GetOptionsTable,
-- and buildCategoryArgs is expensive (Selector.GetEffectivePriority runs the
-- full candidate/rank pipeline with tooltip lookups for each of the 8
-- categories). Rebuilding on every click produced perceptible lag where
-- rapid tab clicks appeared to ignore the first press while the previous
-- rebuild was still in flight. We cache the full tree and invalidate in
-- O.Refresh, which already fires after every mutation that changes what
-- the panel should show (Selector.*, SpecHelper.SetStatPriority, resync,
-- reset-all, Pipeline.Recompute).
O._cache = nil

function O.Build()
    if O._cache then return O._cache end
    local args = {
        general = {
            type  = "group",
            order = 1,
            name  = "General",
            args  = buildGeneralArgs(),
        },
        statpriority = {
            type  = "group",
            order = 2,
            name  = "Stat Priority",
            args  = buildStatPriorityTabArgs(),
        },
    }
    if KCM.Categories and KCM.Categories.LIST then
        for i, cat in ipairs(KCM.Categories.LIST) do
            args[cat.key:lower()] = {
                type  = "group",
                order = 10 + i,
                name  = cat.displayName,
                args  = buildCategoryArgs(cat.key),
            }
        end
    end
    O._cache = {
        type = "group",
        name = PANEL_TITLE,
        args = args,
    }
    return O._cache
end

-- ---------------------------------------------------------------------------
-- Refresh + Register
-- ---------------------------------------------------------------------------
-- Refresh is called after every mutation that the user can see (Selector
-- add/block/move, stat-priority change, force resync). It is a no-op if
-- the panel isn't open.

function O.Refresh()
    -- A direct refresh satisfies any pending debounced refresh — clear the
    -- flag so the scheduled timer (if any) becomes a no-op when it fires.
    O._refreshPending = false
    O._cache = nil
    local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if reg and reg.NotifyChange then
        reg:NotifyChange(REGISTRY_KEY)
    end
end

-- Trailing-edge debounced refresh. Used by Pipeline.Recompute so a burst of
-- GET_ITEM_INFO_RECEIVED events (dozens during first panel open while item
-- data streams in from the server) collapses into ONE rebuild after the
-- storm ends. Each new call resets the timer — the refresh only fires once
-- the caller has been quiet for REFRESH_DEBOUNCE_SEC. A max-wait cap
-- guarantees the user sees updated data even if events never fully stop.
--
-- Panel rebuilds destroy every widget — which resets hover tooltips, scroll
-- position, and can swallow mid-rebuild clicks — so this MUST not fire
-- during a burst. User-driven mutations (add/remove/move buttons) still
-- call O.Refresh directly via afterMutation for snappy click response.
local REFRESH_DEBOUNCE_SEC = 1.0
local REFRESH_MAX_WAIT_SEC = 3.0
function O.RequestRefresh()
    local now = GetTime()
    if not O._refreshFirstAt then O._refreshFirstAt = now end
    O._refreshPending = true
    -- Invalidate any previously-scheduled fire via a token check.
    O._refreshToken = (O._refreshToken or 0) + 1
    local myToken = O._refreshToken

    local waited = now - O._refreshFirstAt
    local delay = REFRESH_DEBOUNCE_SEC
    if waited + delay > REFRESH_MAX_WAIT_SEC then
        delay = math.max(0.05, REFRESH_MAX_WAIT_SEC - waited)
    end

    C_Timer.After(delay, function()
        if O._refreshToken ~= myToken then return end
        if O._refreshPending then
            O._refreshFirstAt = nil
            O.Refresh()
        end
    end)
end

function O.Register()
    local AceConfig       = LibStub and LibStub("AceConfig-3.0", true)
    local AceConfigDialog = LibStub and LibStub("AceConfigDialog-3.0", true)
    if not (AceConfig and AceConfigDialog) then
        if KCM.Debug and KCM.Debug.Print then
            KCM.Debug.Print("Options.Register: AceConfig not loaded; skipping.")
        end
        return false
    end
    AceConfig:RegisterOptionsTable(REGISTRY_KEY, O.Build)
    -- On modern (10.x+) clients, AddToBlizOptions returns (frame, categoryID);
    -- on legacy clients it returns just (frame). Settings.OpenToCategory
    -- requires the numeric ID, so capture both forms and fall back to the
    -- AceGUI container's `name` field (which the Settings registration sets
    -- to the category ID) if the second return isn't provided.
    local frame, categoryID = AceConfigDialog:AddToBlizOptions(REGISTRY_KEY, PANEL_TITLE)
    KCM._settingsCategoryFrame = frame
    KCM._settingsCategoryID    = categoryID or (frame and frame.name) or nil

    -- BlizOptionsGroup renders the panel title ("Consumable Master") in
    -- GameFontNormalLarge (~14pt), which is smaller than our per-page KCMTitle
    -- headers (22pt). Bump it to 24pt gold so the addon title is the dominant
    -- top-level heading and clearly outranks the page headers below it. We
    -- also push the content area down to make room for the taller label.
    local widget = frame and frame.obj
    if widget and widget.label then
        widget.label:SetFont(STANDARD_TEXT_FONT, 24, "")
        widget.label:SetTextColor(1, 0.82, 0)
        widget.label:ClearAllPoints()
        widget.label:SetPoint("TOPLEFT", 10, -12)
        widget.label:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 10, -50)
        if widget.content then
            widget.content:ClearAllPoints()
            widget.content:SetPoint("TOPLEFT", 10, -55)
            widget.content:SetPoint("BOTTOMRIGHT", -10, 10)
        end
    end

    return true
end

-- Opens the Blizzard settings panel directly to our page. Used by /kcm config.
function O.Open()
    local id = KCM._settingsCategoryID
    if type(id) ~= "number" then id = tonumber(id) end
    if Settings and Settings.OpenToCategory and id then
        Settings.OpenToCategory(id)
        return true
    end
    -- Legacy fallback for clients where Settings.OpenToCategory isn't
    -- available. InterfaceOptionsFrame_OpenToCategory was removed in 10.x,
    -- so if Settings is missing we just print a hint.
    print("|cffff8800[KCM]|r settings panel unavailable on this client; use /kcm.")
    return false
end
