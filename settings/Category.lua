-- settings/Category.lua — Per-category panels (single + composite).
--
-- One tab per row in KCM.Categories.LIST, in CLAUDE.md order. The render
-- function dispatches to single or composite layout based on cat.composite.
--
-- Single category layout:
--   1. KCMMacroDragIcon row.
--   2. Spec-aware subheader (FLASK / STAT_FOOD only): "Spec-aware. Viewing: <spec>."
--   3. Section "Add item or spell by ID" — Type dropdown | ID input (paired).
--   4. Section "Priority list" — legend label + one row per item:
--        KCMItemRow | KCMScoreButton | up | down | X
--   5. Inline "Reset category" button (StaticPopup-confirmed).
--
-- Composite layout (HP_AIO / MP_AIO):
--   1. KCMMacroDragIcon row.
--   2. Subheader description.
--   3. Section "In Combat"     — sub-cat rows (KCMItemRow | Enabled | up | down).
--   4. Section "Out of Combat" — same shape.
--   5. Inline "Reset category" button (StaticPopup-confirmed).
--
-- Reads from Selector / Categories / Ranker / BagScanner / SpecHelper; writes
-- via Selector mutators (AddItem / Block / MoveUp / MoveDown). Every mutation
-- calls afterMutation so the macro pipeline and panels stay in sync.

local KCM    = _G.KCM
local H      = KCM.Settings.Helpers
local AceGUI = LibStub("AceGUI-3.0")

KCM.Options = KCM.Options or {}
local O = KCM.Options
O._addKind = O._addKind or {}

-- Row-widget proportions. KCMItemRow takes the bulk of each row and the four
-- 32px square buttons cluster on the right. Tuned for the standard Settings
-- sub-panel content width (~540px); narrower windows still fit because the
-- buttons remain pixel-fixed and the item row is relative.
local ITEM_ROW_RW_SINGLE    = 0.76
local ITEM_ROW_RW_COMPOSITE = 0.72
local ROW_BTN_W             = 32
local CHECK_W               = 78

local OWNED_ICON     = "|TInterface\\RaidFrame\\ReadyCheck-Ready:20|t"
local NOT_OWNED_ICON = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:20|t"
local PICK_ICON      = "|TInterface\\COMMON\\FavoritesIcon:20|t"

local ADD_KIND_OPTIONS = { ITEM = "Item", SPELL = "Spell" }
local ADD_KIND_SORTING = { "ITEM", "SPELL" }

-- ---------------------------------------------------------------------
-- Lookup helpers (Midnight C_Spell + multi-return GetItemInfo split)
-- ---------------------------------------------------------------------

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

local function isOwned(id)
    if not id then return false end
    if KCM.ID and KCM.ID.IsSpell(id) then
        local sid = KCM.ID.SpellID(id)
        return sid and IsPlayerSpell and IsPlayerSpell(sid) or false
    end
    return KCM.BagScanner and KCM.BagScanner.HasItem and KCM.BagScanner.HasItem(id) or false
end

local function formatNumber(n)
    if type(n) ~= "number" then return tostring(n) end
    local isWhole = (n == math.floor(n))
    local abs = math.abs(n)
    local body = isWhole and tostring(math.floor(abs)) or ("%.1f"):format(abs)
    local int, rest = body:match("^(%d+)(.*)$")
    if not int then return tostring(n) end
    -- Walk the integer part forward in 3-digit groups so we don't need to
    -- reverse the string. The first group is shorter when len % 3 ~= 0.
    local len = #int
    local first = ((len - 1) % 3) + 1
    local pieces = { int:sub(1, first) }
    for i = first + 1, len, 3 do
        pieces[#pieces + 1] = int:sub(i, i + 2)
    end
    local sepd = table.concat(pieces, ",") .. (rest or "")
    return (n < 0) and ("-" .. sepd) or sepd
end

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

local function afterMutation(reason)
    if KCM.Pipeline and KCM.Pipeline.RequestRecompute then
        KCM.Pipeline.RequestRecompute(reason or "options_mutation")
    end
    H.RefreshAllPanels()
end

-- ---------------------------------------------------------------------
-- StaticPopup for per-category reset. One popup, shared across all
-- category panels — the active catKey is parked in popup.data on show.
-- ---------------------------------------------------------------------

-- Shared between single + composite reset paths. Caller passes the prompt
-- as the second arg to StaticPopup_Show, which substitutes into %s, and
-- the catKey/specKey/composite payload as the fourth arg (popup.data).
StaticPopupDialogs["KCM_RESET_CATEGORY"] = {
    text         = "%s",
    button1      = "Yes",
    button2      = "No",
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept = function(self, data)
        if not data then return end
        if data.composite then
            local defaults = KCM.dbDefaults and KCM.dbDefaults.profile
                and KCM.dbDefaults.profile.categories
                and KCM.dbDefaults.profile.categories[data.catKey]
            local cfg = KCM.db and KCM.db.profile and KCM.db.profile.categories
                and KCM.db.profile.categories[data.catKey]
            if not (defaults and cfg) then return end
            cfg.enabled          = CopyTable(defaults.enabled or {})
            cfg.orderInCombat    = CopyTable(defaults.orderInCombat or {})
            cfg.orderOutOfCombat = CopyTable(defaults.orderOutOfCombat or {})
            afterMutation("options_aio_reset_cat")
        else
            local bucket = KCM.Selector and KCM.Selector.GetBucket
                and KCM.Selector.GetBucket(data.catKey, data.specKey)
            if not bucket then return end
            bucket.added   = {}
            bucket.blocked = {}
            bucket.pins    = {}
            afterMutation("options_reset_cat")
        end
    end,
}

-- ---------------------------------------------------------------------
-- Small AceGUI builders shared by single + composite renderers
-- ---------------------------------------------------------------------

local function newRow(scroll, height)
    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    if height then row:SetHeight(height) end
    scroll:AddChild(row)
    return row
end

local function makeIconBtn(parent, opts)
    local btn = AceGUI:Create("KCMIconButton")
    btn:SetImageSize(opts.size or 24, opts.size or 24)
    btn:SetImage(opts.image)
    btn:SetWidth(opts.width or ROW_BTN_W)
    if opts.disabled then btn:SetDisabled(true) end
    if opts.onClick then
        btn:SetCallback("OnClick", function()
            local ok, err = pcall(opts.onClick)
            if not ok then
                print("|cff00ffff[CM]|r icon-button onClick failed: " .. tostring(err))
            end
        end)
    end
    if opts.tooltip then H.AttachTooltip(btn, opts.label, opts.tooltip) end
    parent:AddChild(btn)
    return btn
end

local function makeScoreBtn(parent, opts)
    local btn = AceGUI:Create("KCMScoreButton")
    btn:SetImageSize(22, 22)
    btn:SetImage(opts.image)
    btn:SetWidth(ROW_BTN_W)
    if opts.tooltip or opts.label then
        H.AttachTooltip(btn, opts.label, opts.tooltip)
    end
    parent:AddChild(btn)
    return btn
end

local function makeItemRow(parent, data, rw)
    local row = AceGUI:Create("KCMItemRow")
    row:SetRelativeWidth(rw or ITEM_ROW_RW_SINGLE)
    row:SetCustomData(data)
    parent:AddChild(row)
    return row
end

local function makeMacroDragIcon(scroll, macroName)
    local w = AceGUI:Create("KCMMacroDragIcon")
    w:SetFullWidth(true)
    w:SetCustomData({ macroName = macroName })
    scroll:AddChild(w)
    return w
end

local function makeDropdown(parent, opts)
    local dd = AceGUI:Create("Dropdown")
    if opts.label then dd:SetLabel(opts.label) end
    dd:SetList(opts.values or {}, opts.sorting)
    if opts.relativeWidth then dd:SetRelativeWidth(opts.relativeWidth)
    elseif opts.width    then dd:SetWidth(opts.width)
    else                       dd:SetFullWidth(true) end
    dd:SetValue(opts.value)
    if opts.onChange then
        dd:SetCallback("OnValueChanged", function(_, _, v) opts.onChange(v) end)
    end
    if opts.tooltip then H.AttachTooltip(dd, opts.label, opts.tooltip) end
    parent:AddChild(dd)
    return dd
end

local function makeEditBox(parent, opts)
    local eb = AceGUI:Create("EditBox")
    if opts.label then eb:SetLabel(opts.label) end
    if opts.relativeWidth then eb:SetRelativeWidth(opts.relativeWidth)
    elseif opts.width    then eb:SetWidth(opts.width)
    else                       eb:SetFullWidth(true) end
    if opts.maxLetters and eb.editbox and eb.editbox.SetMaxLetters then
        eb.editbox:SetMaxLetters(opts.maxLetters)
    end
    if opts.onSubmit then
        -- A successful submit triggers afterMutation → RefreshAllPanels →
        -- ResetScroll, which releases this very widget. SetText after the
        -- handler would be a use-after-release. Skip it: the rebuilt
        -- panel's fresh EditBox starts empty, which is what we want.
        -- On validation failure (no rebuild), the typed text deliberately
        -- persists so the user can fix the typo without re-typing.
        eb:SetCallback("OnEnterPressed", function(_, _, v)
            opts.onSubmit(v)
        end)
    end
    if opts.tooltip then H.AttachTooltip(eb, opts.label, opts.tooltip) end
    parent:AddChild(eb)
    return eb
end

local function makeCheckbox(parent, opts)
    local cb = AceGUI:Create("CheckBox")
    cb:SetLabel(opts.label or "")
    if opts.width then cb:SetWidth(opts.width)
    elseif opts.relativeWidth then cb:SetRelativeWidth(opts.relativeWidth)
    else cb:SetFullWidth(true) end
    cb:SetValue(opts.value and true or false)
    if opts.onChange then
        cb:SetCallback("OnValueChanged", function(_, _, v) opts.onChange(v and true or false) end)
    end
    if opts.tooltip then H.AttachTooltip(cb, opts.label, opts.tooltip) end
    parent:AddChild(cb)
    return cb
end

-- ---------------------------------------------------------------------
-- Single-category render
-- ---------------------------------------------------------------------

local function renderSingle(ctx, cat)
    H.ResetScroll(ctx)
    local scroll = H.EnsureScroll(ctx)

    local specKey = cat.specAware and (O.ResolveViewedSpec and O.ResolveViewedSpec()) or nil

    -- Drag icon
    makeMacroDragIcon(scroll, cat.macroName)
    H.AddSpacer(scroll, 6)

    if cat.specAware then
        H.Label(ctx,
            ("Spec-aware. Viewing: %s."):format(O.FormatSpec and O.FormatSpec(specKey) or tostring(specKey)),
            "medium")
    end

    -- Add by ID (kind selector | ID input, paired 50/50)
    H.Section(ctx, "Add item or spell by ID")
    local addRow = newRow(scroll)
    makeDropdown(addRow, {
        label         = "Type",
        tooltip       = "Choose whether the ID belongs to an item (default — anything in bags) or a spell (class abilities like Recuperate). Auto-discovery already handles items in your bags; use this to seed something you don't currently carry, or any castable spell.",
        values        = ADD_KIND_OPTIONS,
        sorting       = ADD_KIND_SORTING,
        value         = O._addKind[cat.key] or "ITEM",
        relativeWidth = 0.4,
        onChange      = function(v)
            O._addKind[cat.key] = v
        end,
    })
    makeEditBox(addRow, {
        label         = "ID",
        tooltip       = "Enter an itemID or spellID to add to this category. Press Enter to add.",
        relativeWidth = 0.6,
        maxLetters    = 12,
        onSubmit = function(text)
            local id = tonumber(text)
            if not id or id <= 0 then
                print("|cff00ffff[CM]|r expected a positive numeric ID; got: " .. tostring(text))
                return
            end
            local kind = O._addKind[cat.key] or "ITEM"
            if kind == "SPELL" then
                if not spellNameByID(id) then
                    print("|cff00ffff[CM]|r unknown spellID: " .. id)
                    return
                end
            else
                if C_Item and C_Item.GetItemInfoInstant
                   and not C_Item.GetItemInfoInstant(id) then
                    print("|cff00ffff[CM]|r unknown itemID: " .. id)
                    return
                end
            end
            if cat.specAware and not specKey then
                print("|cff00ffff[CM]|r spec-aware category: no active spec — can't add.")
                return
            end
            local storedID = (kind == "SPELL") and KCM.ID.AsSpell(id) or id
            local changed = KCM.Selector and KCM.Selector.AddItem
                and KCM.Selector.AddItem(cat.key, storedID, specKey)
            if changed then afterMutation("options_add_item") end
        end,
    })

    -- Priority list
    H.Section(ctx, "Priority list")
    H.Label(ctx,
        ("%s in bags    %s not in bags    %s picked in macro"):format(OWNED_ICON, NOT_OWNED_ICON, PICK_ICON),
        "medium")
    H.AddSpacer(scroll, 4)

    if cat.specAware and not specKey then
        H.Label(ctx,
            "|cffff8800No active spec.|r Spec-aware categories need a resolvable spec to display a priority list.",
            "medium")
    else
        local priority = (KCM.Selector and KCM.Selector.GetEffectivePriority
            and KCM.Selector.GetEffectivePriority(cat.key, specKey)) or {}
        local pick     = KCM.Selector and KCM.Selector.PickBestForCategory
            and KCM.Selector.PickBestForCategory(cat.key, specKey) or nil

        if #priority == 0 then
            H.Label(ctx,
                "|cffff8800(empty)|r — no candidates yet. Add an itemID above or pick up a matching item to trigger auto-discovery.",
                "medium")
        else
            -- Ranker context shared across rows so every score tooltip uses
            -- the same numbers as the effective sort.
            local rankerCtx
            if cat.specAware and specKey and KCM.SpecHelper and KCM.SpecHelper.GetStatPriority then
                rankerCtx = { specPriority = KCM.SpecHelper.GetStatPriority(specKey) }
            end
            if KCM.Ranker and KCM.Ranker.BuildContext then
                rankerCtx = KCM.Ranker.BuildContext(cat.key, priority, rankerCtx)
            end

            for i, id in ipairs(priority) do
                local isFirst = (i == 1)
                local isLast  = (i == #priority)
                local rowID   = id

                local explain = KCM.Ranker and KCM.Ranker.Explain
                    and KCM.Ranker.Explain(cat.key, rowID, rankerCtx) or nil
                local scoreTitle = explain
                    and ("Rank score: %s"):format(formatNumber(explain.score))
                    or "Rank score"

                local row = newRow(scroll, 28)
                makeItemRow(row, {
                    itemID = rowID,
                    owned  = isOwned(rowID),
                    isPick = (pick and rowID == pick) and true or false,
                }, ITEM_ROW_RW_SINGLE)
                makeScoreBtn(row, {
                    image   = "Interface\\FriendsFrame\\InformationIcon",
                    label   = scoreTitle,
                    tooltip = formatScoreTooltipDesc(explain),
                })
                makeIconBtn(row, {
                    image    = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up",
                    label    = "Move up",
                    tooltip  = "Move higher in priority",
                    disabled = isFirst,
                    onClick  = function()
                        if KCM.Selector and KCM.Selector.MoveUp
                            and KCM.Selector.MoveUp(cat.key, rowID, specKey) then
                            afterMutation("options_move_up")
                        end
                    end,
                })
                makeIconBtn(row, {
                    image    = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
                    label    = "Move down",
                    tooltip  = "Move lower in priority",
                    disabled = isLast,
                    onClick  = function()
                        if KCM.Selector and KCM.Selector.MoveDown
                            and KCM.Selector.MoveDown(cat.key, rowID, specKey) then
                            afterMutation("options_move_down")
                        end
                    end,
                })
                makeIconBtn(row, {
                    image    = "atlas:transmog-icon-remove",
                    size     = 22,
                    label    = "Remove",
                    tooltip  = "Remove from this category. Blocks the item so auto-discovery won't re-add it.",
                    onClick  = function()
                        if KCM.Selector and KCM.Selector.Block
                            and KCM.Selector.Block(cat.key, rowID, specKey) then
                            afterMutation("options_remove")
                        end
                    end,
                })
            end
        end
    end

    -- Inline reset
    H.AddSpacer(scroll, 12)
    H.Button(ctx, {
        text    = "Reset category",
        tooltip = "Clear added/blocked items and pin overrides for this category"
                  .. (cat.specAware and " (viewed spec only)" or "")
                  .. ". Discovered items (from bag scans) are preserved.",
        onClick = function()
            local prompt = ("Reset %s%s to defaults?"):format(
                cat.displayName,
                cat.specAware and " (viewed spec)" or "")
            StaticPopup_Show("KCM_RESET_CATEGORY", prompt, nil, {
                catKey    = cat.key,
                specKey   = specKey,
                composite = false,
            })
        end,
    })

    if scroll.DoLayout then scroll:DoLayout() end
end

-- ---------------------------------------------------------------------
-- Composite render (HP_AIO / MP_AIO)
-- ---------------------------------------------------------------------

local function renderComposite(ctx, cat)
    H.ResetScroll(ctx)
    local scroll = H.EnsureScroll(ctx)

    local cfg = KCM.db and KCM.db.profile and KCM.db.profile.categories
        and KCM.db.profile.categories[cat.key]
    if not cfg then return end

    -- Drag icon
    makeMacroDragIcon(scroll, cat.macroName)
    H.AddSpacer(scroll, 6)

    H.Label(ctx,
        "Composite macro. Toggle and order the contributing categories below — each category's own ranking and pick logic is edited on its individual panel.",
        "medium")

    local sections = {
        { key = "inCombat",    orderField = "orderInCombat",    label = "In Combat"     },
        { key = "outOfCombat", orderField = "orderOutOfCombat", label = "Out of Combat" },
    }

    for _, section in ipairs(sections) do
        H.Section(ctx, section.label)
        local orderArr = cfg[section.orderField] or {}

        if #orderArr == 0 then
            H.Label(ctx, "|cffff8800(no sub-categories)|r", "medium")
        else
            for i, ref in ipairs(orderArr) do
                local refCat = KCM.Categories.Get(ref)
                local pick   = (KCM.Selector and KCM.Selector.PickBestForCategory)
                    and KCM.Selector.PickBestForCategory(ref) or nil
                local rowIndex = i
                local rowSize  = #orderArr
                local rowRef   = ref
                local sectionOrderField = section.orderField
                local refLabel = refCat and refCat.displayName or rowRef

                local row = newRow(scroll, 28)
                makeItemRow(row, {
                    itemID       = pick,
                    owned        = isOwned(pick),
                    isPick       = false,
                    fallbackName = refLabel,
                }, ITEM_ROW_RW_COMPOSITE)
                makeCheckbox(row, {
                    label    = "Enabled",
                    tooltip  = ("Include %s in the macro body."):format(refLabel),
                    value    = (cfg.enabled == nil) or (cfg.enabled[rowRef] ~= false),
                    width    = CHECK_W,
                    onChange = function(v)
                        cfg.enabled = cfg.enabled or {}
                        cfg.enabled[rowRef] = v
                        afterMutation("options_aio_toggle")
                    end,
                })
                makeIconBtn(row, {
                    image    = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up",
                    label    = "Move up",
                    tooltip  = "Move higher in section order",
                    disabled = (rowIndex == 1) or (rowSize <= 1),
                    onClick  = function()
                        local arr = cfg[sectionOrderField]
                        if not arr or rowIndex <= 1 then return end
                        arr[rowIndex], arr[rowIndex - 1] = arr[rowIndex - 1], arr[rowIndex]
                        afterMutation("options_aio_move_up")
                    end,
                })
                makeIconBtn(row, {
                    image    = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
                    label    = "Move down",
                    tooltip  = "Move lower in section order",
                    disabled = (rowIndex == rowSize) or (rowSize <= 1),
                    onClick  = function()
                        local arr = cfg[sectionOrderField]
                        if not arr or rowIndex >= #arr then return end
                        arr[rowIndex], arr[rowIndex + 1] = arr[rowIndex + 1], arr[rowIndex]
                        afterMutation("options_aio_move_down")
                    end,
                })
            end
        end
    end

    -- Inline reset
    H.AddSpacer(scroll, 12)
    H.Button(ctx, {
        text    = "Reset category",
        tooltip = "Restore enabled flags and section order to defaults.",
        onClick = function()
            local prompt = ("Reset %s to defaults?"):format(cat.displayName)
            StaticPopup_Show("KCM_RESET_CATEGORY", prompt, nil, {
                catKey    = cat.key,
                composite = true,
            })
        end,
    })

    if scroll.DoLayout then scroll:DoLayout() end
end

-- ---------------------------------------------------------------------
-- Tab registration — one builder per category, in CLAUDE.md order.
-- ---------------------------------------------------------------------

local function buildCategory(cat)
    return function(mainCategory)
        if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then
            return nil
        end
        local panelName = "KCMCatPanel_" .. cat.key
        local ctx = H.CreatePanel(panelName, cat.displayName, {
            panelKey = cat.key:lower(),
        })
        H.SetRenderer(ctx, function(c)
            if cat.composite then renderComposite(c, cat)
            else                  renderSingle(c, cat) end
        end)
        return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, cat.displayName)
    end
end

if KCM.Settings and KCM.Settings.RegisterTab and KCM.Categories and KCM.Categories.LIST then
    for _, cat in ipairs(KCM.Categories.LIST) do
        KCM.Settings.RegisterTab(cat.key:lower(), buildCategory(cat))
    end
end
