-- Options.lua — AceConfig-driven settings panel.
--
-- Registered in Core:OnInitialize via KCM.Options.Register(). Shows up in
-- Blizzard's ESC → Options → AddOns list as "Ka0s Consumable Master". The
-- option table is built lazily on each open/refresh by KCM.Options.Build,
-- so any live mutation to KCM.db.profile / Selector state renders
-- immediately the next time NotifyChange fires.
--
-- Layered structure (top-level `args`):
--   1. general      — debug toggle, force resync, reset-all.
--   2. <categories> — one sub-group per Categories.LIST entry: add-by-id
--                     input, ranked priority list (↑/↓/X per row), per-
--                     category reset. Spec-aware categories additionally
--                     get a spec selector at the top and a stat-priority
--                     editor at the bottom.
--
-- Mutation flow: widget -> KCM.Selector.* (or SpecHelper.SetStatPriority)
-- -> KCM.Pipeline.RequestRecompute -> KCM.Options.Refresh. The Refresh
-- call is what makes the UI re-read the underlying state.

local KCM = _G.KCM
KCM.Options = KCM.Options or {}
local O = KCM.Options

local PANEL_TITLE = "Ka0s Consumable Master"
local REGISTRY_KEY = "ConsumableMaster"

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local function iconMarkup(itemID)
    if not (C_Item and C_Item.GetItemInfoInstant) then return "" end
    local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemID)
    if icon then return ("|T%s:16:16:0:0|t "):format(icon) end
    return ""
end

local function itemName(itemID)
    local tt = KCM.TooltipCache and KCM.TooltipCache.Get and KCM.TooltipCache.Get(itemID)
    if tt and tt.itemName then return tt.itemName end
    if C_Item and C_Item.GetItemNameByID then
        local n = C_Item.GetItemNameByID(itemID)
        if n then return n end
    end
    return "?"
end

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

-- Per-category "viewed spec" — which spec's bucket the user is editing on
-- the spec-aware pages. Module-local (not persisted) so every session
-- opens on the active spec; the user can switch via the selector. Keyed
-- by catKey because different categories may have unrelated spec contexts
-- (e.g. editing Flask for a Warrior spec while viewing Stat Food for a
-- Shaman spec makes no sense, but the state model allows it so we don't
-- cross-pollinate dropdowns).
O._viewedSpec = O._viewedSpec or {}

local function resolveViewedSpec(catKey)
    local viewed = O._viewedSpec[catKey]
    if viewed then return viewed end
    local cur = currentSpecKey()
    O._viewedSpec[catKey] = cur
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

local function specSelectorValues()
    local values, sorting = {}, {}
    if not (KCM.SpecHelper and KCM.SpecHelper.AllSpecs) then
        return values, sorting
    end
    local rows = KCM.SpecHelper.AllSpecs()
    -- Group by class to keep the dropdown scannable: "<Class> — <Spec>".
    -- GetClassInfo isn't always available on older clients; fall back to
    -- classID if we can't resolve a friendly name.
    for _, row in ipairs(rows) do
        local className = row.classID
        if GetClassInfo then
            local n = GetClassInfo(row.classID)
            if n then className = n end
        end
        values[row.specKey] = ("%s — %s"):format(tostring(className), row.specName or "?")
        table.insert(sorting, row.specKey)
    end
    table.sort(sorting, function(a, b)
        return (values[a] or "") < (values[b] or "")
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
        debug = {
            type  = "toggle",
            order = 1,
            name  = "Debug mode",
            desc  = "Print per-event diagnostics to chat. Same as /kcm debug.",
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
            desc  = "Invalidate tooltip cache, rescan bags, rewrite every macro. "
                 .. "Same as /kcm resync. Blocked in combat.",
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

        reset = {
            type    = "execute",
            order   = 3,
            name    = "Reset all priorities",
            desc    = "Wipe all added/blocked/pinned items and stat-priority "
                   .. "overrides. Seed defaults are restored. This cannot "
                   .. "be undone.",
            confirm = true,
            confirmText = "Reset ALL ConsumableMaster customization to defaults?",
            func    = function()
                if KCM.ResetAllToDefaults then
                    KCM.ResetAllToDefaults("options_reset")
                end
                O.Refresh()
            end,
        },

        version = {
            type  = "description",
            order = 100,
            name  = function()
                return ("\n|cff888888Version %s|r"):format(tostring(KCM.VERSION or "?"))
            end,
            fontSize = "small",
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

local function formatRow(itemID, pickID, owned)
    local ownedTag = owned and "|cff44ff44[owned]|r" or "|cff888888[ ---  ]|r"
    local pickTag  = (pickID and itemID == pickID) and "  |cffffd100<- pick|r" or ""
    return ("%s %s%s  |cff888888id=%d|r%s"):format(
        ownedTag, iconMarkup(itemID), itemName(itemID), itemID, pickTag)
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

    args.spacer = { type = "description", order = 2, name = " ", width = 1.0 }

    for i = 1, 4 do
        args["secondary" .. i] = {
            type   = "select",
            order  = 10 + i,
            name   = ("Secondary #%d"):format(i),
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

local function buildCategoryArgs(catKey)
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    if not cat then return {} end
    local specKey = cat.specAware and resolveViewedSpec(catKey) or nil

    local args = {}

    args.descHeader = {
        type  = "description",
        order = 1,
        name  = cat.specAware
            and ("|cffffd100%s|r — spec-aware. Viewing: %s.")
                :format(cat.displayName, tostring(specKey or "(no active spec)"))
            or ("|cffffd100%s|r"):format(cat.displayName),
        fontSize = "medium",
    }

    -- Spec selector (spec-aware categories only) ----------------
    if cat.specAware then
        local values, sorting = specSelectorValues()
        args.specSelector = {
            type    = "select",
            order   = 5,
            name    = "Viewing spec",
            desc    = "Select which spec's priority list and stat priority "
                   .. "you want to edit. Defaults to your active spec; all "
                   .. "39 specs are editable even if not your current one.",
            values  = values,
            sorting = sorting,
            width   = "double",
            get     = function() return O._viewedSpec[catKey] end,
            set     = function(_, val)
                O._viewedSpec[catKey] = val
                if O.Refresh then O.Refresh() end
            end,
        }
    end

    -- Add-by-id --------------------------------------------------
    args.addHeader = { type = "header", order = 10, name = "Add item by ID" }
    args.addInput  = {
        type  = "input",
        order = 11,
        name  = "Item ID",
        desc  = "Enter an itemID to add to this category (e.g. 241304). "
             .. "Auto-discovery already handles anything in your bags; use "
             .. "this to seed something you don't currently carry.",
        width = "full",
        get   = function() return "" end,
        validate = function(_, val)
            if val == "" then return true end
            local id = tonumber(val)
            if not id then return "Not a number." end
            if C_Item and C_Item.GetItemInfoInstant then
                local name = C_Item.GetItemInfoInstant(id)
                if not name then return "Unknown itemID." end
            end
            return true
        end,
        set = function(_, val)
            local id = tonumber(val)
            if not id then return end
            if cat.specAware and not specKey then
                print("|cffff8800[KCM]|r spec-aware category: no active spec — can't add.")
                return
            end
            local changed = KCM.Selector and KCM.Selector.AddItem
                and KCM.Selector.AddItem(catKey, id, specKey)
            if changed then afterMutation("options_add_item") end
        end,
    }

    -- Priority list ----------------------------------------------
    args.listHeader = { type = "header", order = 20, name = "Priority list" }

    if cat.specAware and not specKey then
        args.listEmpty = {
            type  = "description",
            order = 21,
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
                order = 21,
                name  = "|cffff8800(empty)|r — no candidates yet. Add an "
                     .. "itemID above or pick up a matching item to trigger "
                     .. "auto-discovery.",
                fontSize = "medium",
            }
        else
            for i, id in ipairs(priority) do
                local base   = 30 + i * 10
                local owned  = hasItem and hasItem(id) or false
                local isFirst = (i == 1)
                local isLast  = (i == #priority)
                local rowID   = id  -- capture for closures

                args["row" .. i .. "_label"] = {
                    type  = "description",
                    order = base + 0,
                    name  = formatRow(rowID, pick, owned),
                    width = 1.5,
                    fontSize = "medium",
                }
                args["row" .. i .. "_up"] = {
                    type  = "execute",
                    order = base + 1,
                    name  = "up",
                    desc  = "Move higher in priority",
                    width = 0.15,
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
                    order = base + 2,
                    name  = "dn",
                    desc  = "Move lower in priority",
                    width = 0.15,
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
                    order = base + 3,
                    name  = "X",
                    desc  = "Remove from this category. Blocks the item so "
                         .. "auto-discovery won't re-add it.",
                    width = 0.2,
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
    args.resetSpacer = { type = "description", order = 200, name = " " }
    args.resetDivider = { type = "header", order = 201, name = "" }
    args.reset = {
        type        = "execute",
        order       = 202,
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

    -- Stat-priority editor (spec-aware only) ---------------------
    -- Appended as an inline group so primary + 4 secondary dropdowns +
    -- reset render in their own visually-distinct panel below the
    -- priority list. Only shown when a spec is resolvable — otherwise
    -- the dropdowns have no target key.
    if cat.specAware and specKey then
        args.statGroup = {
            type   = "group",
            order  = 300,
            name   = "Stat priority (" .. specKey .. ")",
            inline = true,
            args   = buildStatPriorityArgs(specKey),
        }
    end

    return args
end

-- ---------------------------------------------------------------------------
-- Top-level Build
-- ---------------------------------------------------------------------------

function O.Build()
    local args = {
        general = {
            type  = "group",
            order = 1,
            name  = "General",
            args  = buildGeneralArgs(),
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
    return {
        type = "group",
        name = PANEL_TITLE,
        args = args,
    }
end

-- ---------------------------------------------------------------------------
-- Refresh + Register
-- ---------------------------------------------------------------------------
-- Refresh is called after every mutation that the user can see (Selector
-- add/block/move, stat-priority change, force resync). It is a no-op if
-- the panel isn't open.

function O.Refresh()
    local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
    if reg and reg.NotifyChange then
        reg:NotifyChange(REGISTRY_KEY)
    end
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
