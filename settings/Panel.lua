-- settings/Panel.lua — Settings UI framework.
--
-- Mirrors the KickCD pattern: every page (parent + sub-tabs) is registered as
-- a canvas-layout subcategory and shares one header (title + atlas divider)
-- built by Helpers.CreatePanel. Each tab module (settings/General.lua,
-- StatPriority.lua, Category.lua) hands a builder to RegisterTab; this file
-- iterates the builders once Blizzard_Settings is ready.
--
-- Public surface preserved for the rest of the addon:
--   KCM.Options.Register / Refresh / RequestRefresh / Open  (Core, Debug,
--      SlashCommands, Pipeline)
--   KCM.Settings.Helpers + KCM.Settings.Schema  (SlashCommands /cm list/get/set)

local KCM = _G.KCM
local AceGUI = LibStub("AceGUI-3.0")

KCM.Settings         = KCM.Settings         or {}
KCM.Settings.Schema  = KCM.Settings.Schema  or {}
KCM.Settings.builders= KCM.Settings.builders or {}
KCM.Settings.sub     = KCM.Settings.sub     or {}
KCM.Settings._panels = KCM.Settings._panels or {}
KCM.Settings.main    = nil

-- Canonical tab order. General + Stat Priority lead, then the eight single
-- categories, then the two composites — matches the CLAUDE.md panel order.
KCM.Settings.order = KCM.Settings.order or {
    "general", "statpriority",
    "food", "drink", "hp_pot", "mp_pot", "hs", "flask", "cmbt_pot", "stat_food",
    "hp_aio", "mp_aio",
}

local Helpers = KCM.Settings.Helpers or {}
KCM.Settings.Helpers = Helpers

KCM.Options = KCM.Options or {}
local O = KCM.Options

local PANEL_TITLE   = "Ka0s Consumable Master"
local PADDING_X     = 16
local HEADER_TOP    = 20
local HEADER_HEIGHT = 54

local SECTION_TOP_SPACER    = 10
local SECTION_BOTTOM_SPACER = 6
local SECTION_HEADING_H     = 26
local ROW_VSPACER           = 8

local LOGO_TEXTURE = [[Interface\AddOns\ConsumableMaster\media\screenshots\consumemaster.logo.tga]]
local LOGO_PIXELS  = 300

-- ---------------------------------------------------------------------
-- db.profile path helpers
-- ---------------------------------------------------------------------

function Helpers.Resolve(path)
    if not (KCM.db and KCM.db.profile) then return nil, nil end
    local segments = {}
    for part in string.gmatch(path or "", "[^.]+") do
        segments[#segments + 1] = part
    end
    if #segments == 0 then return nil, nil end
    local parent = KCM.db.profile
    for i = 1, #segments - 1 do
        parent = parent[segments[i]]
        if type(parent) ~= "table" then return nil, nil end
    end
    return parent, segments[#segments]
end

function Helpers.Get(path)
    local parent, key = Helpers.Resolve(path)
    if not parent then return nil end
    return parent[key]
end

function Helpers.FireConfigChanged(_section)
    -- Stub. CM's central refresh is Pipeline.RequestRecompute (called via
    -- panel afterMutation closures); kept so the API matches KickCD's and
    -- live subscribers can be added later without changing call sites.
end

function Helpers.Set(path, section, value)
    local parent, key = Helpers.Resolve(path)
    if not parent then return false end
    parent[key] = value
    Helpers.FireConfigChanged(section)
    return true
end

function Helpers.SchemaForPanel(panelKey)
    local out = {}
    for _, def in ipairs(KCM.Settings.Schema) do
        if def.panel == panelKey then out[#out + 1] = def end
    end
    return out
end

function Helpers.FindSchema(path)
    for _, def in ipairs(KCM.Settings.Schema) do
        if def.path == path then return def end
    end
    return nil
end

local _validPanels = {
    general = true, statpriority = true,
    food = true, drink = true, hp_pot = true, mp_pot = true, hs = true,
    flask = true, cmbt_pot = true, stat_food = true,
    hp_aio = true, mp_aio = true,
}
local _validSections = { general = true }
local _validTypes    = { bool = true, number = true, string = true, color = true }

local function _printSchemaError(prefix, msg)
    print("|cff00ffff[CM]|r |cffff0000schema error|r: " .. prefix .. ": " .. msg)
end

function Helpers.ValidateSchema()
    local errors = 0
    for i, def in ipairs(KCM.Settings.Schema) do
        local where = "row #" .. i .. " (" .. tostring(def.path or "<no path>") .. ")"
        if type(def) ~= "table" then
            _printSchemaError(where, "row is not a table"); errors = errors + 1
        else
            if type(def.path) ~= "string" or def.path == "" then
                _printSchemaError(where, "missing or empty `path`"); errors = errors + 1
            end
            if not _validPanels[def.panel] then
                _printSchemaError(where, "invalid `panel` = " .. tostring(def.panel)); errors = errors + 1
            end
            if not _validSections[def.section] then
                _printSchemaError(where, "invalid `section` = " .. tostring(def.section)); errors = errors + 1
            end
            if not _validTypes[def.type] then
                _printSchemaError(where, "invalid `type` = " .. tostring(def.type)); errors = errors + 1
            end
        end
    end
    return errors
end

-- ---------------------------------------------------------------------
-- Tooltip helper
-- ---------------------------------------------------------------------

local function attachTooltip(widget, label, tooltip)
    if not widget then return end
    local anchor = widget.frame or widget
    if not anchor then return end

    local function show()
        if not GameTooltip then return end
        GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
        if label and label ~= "" then GameTooltip:SetText(label, 1, 1, 1) end
        if tooltip and tooltip ~= "" then
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        end
        GameTooltip:Show()
    end
    local function hide() if GameTooltip then GameTooltip:Hide() end end

    if widget.SetCallback then
        widget:SetCallback("OnEnter", show)
        widget:SetCallback("OnLeave", hide)
    elseif widget.HookScript then
        widget:HookScript("OnEnter", show)
        widget:HookScript("OnLeave", hide)
    end
end
Helpers.AttachTooltip = attachTooltip

-- ---------------------------------------------------------------------
-- Header (title + atlas divider). No Defaults button — every panel keeps
-- its reset action inline at the bottom of its body content.
-- ---------------------------------------------------------------------

local function buildHeader(panel, title, opts)
    -- Sub-pages render with an addon-name breadcrumb prefix so the header
    -- reads as "Ka0s Consumable Master  |  <Page>". The parent (About)
    -- opts in to the unprefixed form via opts.isMain.
    local displayTitle = title
    if not opts.isMain then
        displayTitle = PANEL_TITLE .. "  |  " .. title
    end

    local titleFS = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    titleFS:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING_X, -HEADER_TOP)
    titleFS:SetText(displayTitle)

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetAtlas("Options_HorizontalDivider", true)
    divider:SetPoint("TOPLEFT",  panel, "TOPLEFT",   PADDING_X, -HEADER_HEIGHT)
    divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PADDING_X, -HEADER_HEIGHT)
    divider:SetVertexColor(titleFS:GetTextColor())

    return titleFS, divider
end

-- ---------------------------------------------------------------------
-- CreatePanel — Frame compatible with RegisterCanvasLayoutSubcategory
-- with the unified header stamped on top. Returns a `ctx` table the
-- caller threads through Section / RenderField / Button / SetRenderer.
-- ---------------------------------------------------------------------

function Helpers.CreatePanel(name, title, opts)
    opts = opts or {}

    local panel = CreateFrame("Frame", name)
    panel.name = title
    panel:Hide()

    local titleFS, divider = buildHeader(panel, title, opts)
    panel.title   = titleFS
    panel.divider = divider

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -(HEADER_HEIGHT + 8))
    body:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    panel.body = body

    local ctx = {
        panel       = panel,
        body        = body,
        scroll      = nil,           -- lazy AceGUI ScrollFrame
        refreshers  = {},
        lastGroup   = nil,
        panelKey    = opts.panelKey,
        _rendered   = false,
        _renderFn   = nil,
    }
    KCM.Settings._panels[#KCM.Settings._panels + 1] = ctx
    return ctx
end

-- A panel module calls SetRenderer(ctx, fn) to declare how to render its
-- body. The framework calls fn(ctx) on first show and after every Refresh.
-- The renderer is responsible for releasing existing children before
-- adding new ones (Helpers.ResetScroll handles that).
function Helpers.SetRenderer(ctx, fn)
    ctx._renderFn = fn
    ctx.panel:SetScript("OnShow", function()
        if ctx._rendered then return end
        ctx._rendered = true
        if ctx._renderFn then ctx._renderFn(ctx) end
    end)
end

-- Release scroll children + reset bookkeeping so a fresh render starts on
-- a clean slate. Panels with dynamic content (priority list rows that
-- change as items are added/removed) call this at the top of their
-- renderer; panels rendered once on first OnShow don't need it.
function Helpers.ResetScroll(ctx)
    if ctx.scroll then ctx.scroll:ReleaseChildren() end
    ctx.refreshers = {}
    ctx.lastGroup  = nil
end

-- ---------------------------------------------------------------------
-- Always-visible scrollbar patch (lifted verbatim from KickCD's
-- Helpers.PatchAlwaysShowScrollbar). Gives every panel a symmetric
-- right-edge gutter regardless of content length.
-- ---------------------------------------------------------------------

function Helpers.PatchAlwaysShowScrollbar(scroll)
    if not scroll or scroll._kcmAlwaysScrollbar then return end
    scroll._kcmAlwaysScrollbar = true

    local origFixScroll  = scroll.FixScroll
    local origMoveScroll = scroll.MoveScroll
    local origOnRelease  = scroll.OnRelease

    local scrollbar = scroll.scrollbar
    local thumb     = scrollbar and scrollbar.GetThumbTexture and scrollbar:GetThumbTexture() or nil
    local sbName    = scrollbar and scrollbar.GetName and scrollbar:GetName() or nil
    local upBtn     = sbName and _G[sbName .. "ScrollUpButton"]   or nil
    local downBtn   = sbName and _G[sbName .. "ScrollDownButton"] or nil

    local currentEnabled

    local function setEnabled(want)
        if currentEnabled == want then return end
        currentEnabled = want
        if not scrollbar then return end
        if want then
            if scrollbar.Enable then scrollbar:Enable() end
            if thumb and thumb.SetVertexColor then thumb:SetVertexColor(1, 1, 1, 1) end
            if upBtn   and upBtn.Enable   then upBtn:Enable()   end
            if downBtn and downBtn.Enable then downBtn:Enable() end
        else
            scrollbar:SetValue(0)
            if scrollbar.Disable then scrollbar:Disable() end
            if thumb and thumb.SetVertexColor then thumb:SetVertexColor(0.5, 0.5, 0.5, 0.6) end
            if upBtn   and upBtn.Disable   then upBtn:Disable()   end
            if downBtn and downBtn.Disable then downBtn:Disable() end
        end
    end

    scroll.scrollBarShown = true
    if scrollbar then scrollbar:Show() end
    if scroll.scrollframe then
        scroll.scrollframe:SetPoint("BOTTOMRIGHT", -20, 0)
    end
    if scroll.content and scroll.content.original_width then
        scroll.content.width = scroll.content.original_width - 20
    end

    scroll.FixScroll = function(self)
        if self.updateLock then return end
        self.updateLock = true
        if not self.scrollBarShown then
            self.scrollBarShown = true
            self.scrollbar:Show()
            self.scrollframe:SetPoint("BOTTOMRIGHT", -20, 0)
            if self.content.original_width then
                self.content.width = self.content.original_width - 20
            end
        end
        local status = self.status or self.localstatus
        local height, viewheight =
            self.scrollframe:GetHeight(), self.content:GetHeight()
        local offset = status.offset or 0
        if viewheight < height + 2 then
            setEnabled(false)
            self.scrollbar:SetValue(0)
            self.scrollframe:SetVerticalScroll(0)
            status.offset = 0
        else
            setEnabled(true)
            local value = (offset / (viewheight - height) * 1000)
            if value > 1000 then value = 1000 end
            self.scrollbar:SetValue(value)
            self:SetScroll(value)
            if value < 1000 then
                self.content:ClearAllPoints()
                self.content:SetPoint("TOPLEFT",  0, offset)
                self.content:SetPoint("TOPRIGHT", 0, offset)
                status.offset = offset
            end
        end
        self.updateLock = nil
    end

    scroll.MoveScroll = function(self, value)
        if currentEnabled == false then return end
        if origMoveScroll then return origMoveScroll(self, value) end
    end

    scroll.OnRelease = function(self)
        self.FixScroll  = origFixScroll
        self.MoveScroll = origMoveScroll
        self.OnRelease  = origOnRelease
        self._kcmAlwaysScrollbar = nil
        currentEnabled  = nil
        if thumb and thumb.SetVertexColor then thumb:SetVertexColor(1, 1, 1, 1) end
        if scrollbar and scrollbar.Enable then scrollbar:Enable() end
        if upBtn   and upBtn.Enable   then upBtn:Enable()   end
        if downBtn and downBtn.Enable then downBtn:Enable() end
        if origOnRelease then origOnRelease(self) end
    end
end

-- ---------------------------------------------------------------------
-- Lazy AceGUI scroll container.
-- ---------------------------------------------------------------------

local function ensureScroll(ctx)
    if ctx.scroll then return ctx.scroll end
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll.frame:SetParent(ctx.body)
    scroll.frame:ClearAllPoints()
    scroll.frame:SetPoint("TOPLEFT",     ctx.body, "TOPLEFT",      PADDING_X - 4, -8)
    scroll.frame:SetPoint("BOTTOMRIGHT", ctx.body, "BOTTOMRIGHT", -(PADDING_X + 12), 8)
    scroll.frame:Show()

    -- AceGUI's ScrollFrame normally has its size set by a parent AceGUI
    -- container during DoLayout. We parent it to a Blizzard frame instead,
    -- so OnSizeChanged forwards the actual size into AceGUI and re-runs
    -- DoLayout + FixScroll so the scrollbar appears whenever the body
    -- resizes (panel open / Settings window resize).
    scroll.frame:SetScript("OnSizeChanged", function(_, w, h)
        if scroll.OnWidthSet  then scroll:OnWidthSet(w)  end
        if scroll.OnHeightSet then scroll:OnHeightSet(h) end
        if scroll.DoLayout    then scroll:DoLayout()     end
        if scroll.FixScroll   then scroll:FixScroll()    end
    end)

    Helpers.PatchAlwaysShowScrollbar(scroll)
    ctx.scroll = scroll
    return scroll
end
Helpers.EnsureScroll = ensureScroll

local function fireOnChange(def, value)
    if def.onChange then
        local ok, err = pcall(def.onChange, value)
        if not ok then
            print("|cff00ffff[CM]|r onChange for " .. tostring(def.path)
                  .. " failed: " .. tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------
-- Section heading (AceGUI Heading with side dividers) + spacers.
-- ---------------------------------------------------------------------

local function addSpacer(scroll, height)
    local sp = AceGUI:Create("SimpleGroup")
    sp:SetLayout(nil)
    sp:SetFullWidth(true)
    sp:SetHeight(height)
    scroll:AddChild(sp)
end
Helpers.AddSpacer = addSpacer

function Helpers.Section(ctx, label)
    local scroll = ensureScroll(ctx)
    if ctx.lastGroup ~= nil then
        addSpacer(scroll, SECTION_TOP_SPACER)
    end

    local h = AceGUI:Create("Heading")
    h:SetText(label)
    h:SetFullWidth(true)
    h:SetHeight(SECTION_HEADING_H)
    if h.label and h.label.SetFontObject and _G.GameFontNormalLarge then
        h.label:SetFontObject(_G.GameFontNormalLarge)
    end
    scroll:AddChild(h)

    addSpacer(scroll, SECTION_BOTTOM_SPACER)
    ctx.lastGroup = label
    return h
end

-- ---------------------------------------------------------------------
-- Schema-driven widget creators. Today CM's schema only defines bool
-- rows; non-bool types fall through to nil. Add makers when a row of
-- that type lands in the schema.
-- ---------------------------------------------------------------------

local function applyWidth(widget, relativeWidth)
    if relativeWidth then widget:SetRelativeWidth(relativeWidth)
    else widget:SetFullWidth(true) end
end

local function makeCheckbox(ctx, def, parent, relativeWidth)
    parent = parent or ensureScroll(ctx)
    local cb = AceGUI:Create("CheckBox")
    cb:SetLabel(def.label or def.path)
    applyWidth(cb, relativeWidth)
    cb:SetValue(Helpers.Get(def.path) and true or false)

    local function refresh()
        cb:SetValue(Helpers.Get(def.path) and true or false)
    end

    cb:SetCallback("OnValueChanged", function(_, _, value)
        local v = value and true or false
        Helpers.Set(def.path, def.section, v)
        fireOnChange(def, v)
    end)

    attachTooltip(cb, def.label, def.tooltip)
    parent:AddChild(cb)
    ctx.refreshers[#ctx.refreshers + 1] = refresh
    return cb
end
Helpers.MakeCheckbox = makeCheckbox

function Helpers.RenderField(ctx, def, parent, relativeWidth)
    if def.type == "bool" then return makeCheckbox(ctx, def, parent, relativeWidth) end
    -- Other types intentionally omitted; add when the first row needs them.
    return nil
end

-- ---------------------------------------------------------------------
-- Inline action button helpers. `Button` produces a single full-width
-- button on its own row; `ButtonPair` puts two buttons side-by-side at
-- 50/50 width — used by the General page's Maintenance section.
-- ---------------------------------------------------------------------

local function makeButton(parent, spec, relativeWidth)
    local btn = AceGUI:Create("Button")
    btn:SetText(spec.text or "")
    if relativeWidth then btn:SetRelativeWidth(relativeWidth)
    elseif spec.width then btn:SetWidth(spec.width)
    else btn:SetFullWidth(true) end
    btn:SetCallback("OnClick", function()
        if not spec.onClick then return end
        local ok, err = pcall(spec.onClick)
        if not ok then
            print("|cff00ffff[CM]|r button onClick failed: " .. tostring(err))
        end
    end)
    if spec.disabled then btn:SetDisabled(true) end
    attachTooltip(btn, spec.text, spec.tooltip)
    parent:AddChild(btn)
    return btn
end

function Helpers.Button(ctx, spec)
    local scroll = ensureScroll(ctx)
    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    row:SetHeight(28)
    local btn = makeButton(row, spec)
    scroll:AddChild(row)
    return btn
end

function Helpers.ButtonPair(ctx, leftSpec, rightSpec)
    local scroll = ensureScroll(ctx)
    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    row:SetHeight(28)
    if leftSpec  then makeButton(row, leftSpec,  0.5) end
    if rightSpec then makeButton(row, rightSpec, 0.5) end
    scroll:AddChild(row)
end

-- AceGUI Label with optional fontSize hint ("medium" maps to GameFontHighlight,
-- otherwise GameFontNormalSmall). Used for inline descriptions / legends.
function Helpers.Label(ctx, text, fontSize)
    local scroll = ensureScroll(ctx)
    local lbl = AceGUI:Create("Label")
    lbl:SetText(text or "")
    lbl:SetFullWidth(true)
    if lbl.label and lbl.label.SetFontObject then
        if fontSize == "medium" and _G.GameFontHighlight then
            lbl.label:SetFontObject(_G.GameFontHighlight)
        end
    end
    if lbl.label and lbl.label.SetJustifyH then
        lbl.label:SetJustifyH("LEFT")
    end
    scroll:AddChild(lbl)
    return lbl
end

-- ---------------------------------------------------------------------
-- Per-panel + global refresh. Each panel module sets ctx._renderFn via
-- Helpers.SetRenderer; Refresh re-runs every renderer that has been shown
-- at least once. Panels that have never been opened stay unrendered to
-- avoid wasted AceGUI widget allocation.
-- ---------------------------------------------------------------------

function Helpers.RefreshAllPanels()
    for _, ctx in ipairs(KCM.Settings._panels) do
        if ctx._rendered and ctx._renderFn then
            local ok, err = pcall(ctx._renderFn, ctx)
            if not ok then
                print("|cff00ffff[CM]|r panel render failed: " .. tostring(err))
            end
        end
    end
end

function Helpers.SetAndRefresh(path, value)
    local def = Helpers.FindSchema(path)
    if not def then return false end
    if not Helpers.Set(def.path, def.section, value) then return false end
    fireOnChange(def, value)
    Helpers.RefreshAllPanels()
    return true
end

function Helpers.RestoreDefaults(panelKey)
    for _, def in ipairs(Helpers.SchemaForPanel(panelKey)) do
        if def.default ~= nil then
            Helpers.Set(def.path, def.section, def.default)
            fireOnChange(def, def.default)
        end
    end
    Helpers.RefreshAllPanels()
end

-- ---------------------------------------------------------------------
-- Schema rows. Each row defines a scalar setting that the General panel
-- renders as a widget AND that /cm list / get / set sees on the CLI.
-- Adding a new scalar = one row.
-- ---------------------------------------------------------------------

KCM.Settings.Schema[#KCM.Settings.Schema + 1] = {
    panel    = "general", section = "general", group = "Diagnostics",
    path     = "debug",   type    = "bool",
    label    = "Debug mode",
    tooltip  = "Print per-event diagnostics to chat. Same as /cm debug.",
    default  = false,
    onChange = function(v)
        local state = v and "|cff00ff00ON|r" or "|cffff5555OFF|r"
        print("|cff00ffff[CM]|r Debug mode " .. state)
    end,
}

-- ---------------------------------------------------------------------
-- About content (parent canvas). Logo + addon notes + slash command list.
-- ---------------------------------------------------------------------

local function readAddOnNotes()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata("ConsumableMaster", "Notes") or ""
    end
    if GetAddOnMetadata then
        return GetAddOnMetadata("ConsumableMaster", "Notes") or ""
    end
    return ""
end

function Helpers.BuildAboutContent(ctx)
    local scroll = ensureScroll(ctx)

    -- Logo: SimpleGroup is full-width so AceGUI's List layout gives it a
    -- known cell to live in; the texture inside is anchored TOPLEFT at
    -- native pixel size so it renders left-aligned regardless of panel
    -- width.
    local logoGroup = AceGUI:Create("SimpleGroup")
    logoGroup:SetLayout(nil)
    logoGroup:SetFullWidth(true)
    logoGroup:SetHeight(LOGO_PIXELS)

    local logoTex = logoGroup.frame:CreateTexture(nil, "ARTWORK")
    logoTex:SetTexture(LOGO_TEXTURE)
    logoTex:SetSize(LOGO_PIXELS, LOGO_PIXELS)
    logoTex:SetPoint("TOPLEFT", logoGroup.frame, "TOPLEFT", 0, 0)
    scroll:AddChild(logoGroup)

    addSpacer(scroll, 8)

    local desc = AceGUI:Create("Label")
    desc:SetFullWidth(true)
    desc:SetText(readAddOnNotes())
    if desc.label and desc.label.SetFontObject and _G.GameFontHighlight then
        desc.label:SetFontObject(_G.GameFontHighlight)
    end
    if desc.label and desc.label.SetJustifyH then
        desc.label:SetJustifyH("LEFT")
    end
    scroll:AddChild(desc)

    addSpacer(scroll, 12)

    local heading = AceGUI:Create("Heading")
    heading:SetFullWidth(true)
    heading:SetHeight(SECTION_HEADING_H)
    heading:SetText("Slash Commands")
    if heading.label and heading.label.SetFontObject and _G.GameFontNormalLarge then
        heading.label:SetFontObject(_G.GameFontNormalLarge)
    end
    scroll:AddChild(heading)

    addSpacer(scroll, 6)

    local rows = (KCM.SlashCommands and KCM.SlashCommands.GetCommandSummary)
        and KCM.SlashCommands.GetCommandSummary() or {}
    for _, entry in ipairs(rows) do
        local row = AceGUI:Create("Label")
        row:SetFullWidth(true)
        row:SetText(("|cffffff00/cm %s|r  |cffffffff—|r  %s")
            :format(entry.name or entry[1] or "", entry.desc or entry[2] or ""))
        if row.label and row.label.SetJustifyH then
            row.label:SetJustifyH("LEFT")
        end
        scroll:AddChild(row)
    end
end

-- ---------------------------------------------------------------------
-- Tab + main-category registration
-- ---------------------------------------------------------------------

function KCM.Settings.RegisterTab(key, builder)
    if type(key) ~= "string" or type(builder) ~= "function" then return end
    KCM.Settings.builders[key] = builder
    if KCM.Settings.main and not KCM.Settings.sub[key] then
        local ok, sub = pcall(builder, KCM.Settings.main)
        if ok and sub then
            KCM.Settings.sub[key] = sub
        end
    end
end

local function registerPanel()
    if KCM.Settings.main then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory
            and Settings.RegisterAddOnCategory) then
        return
    end

    Helpers.ValidateSchema()

    local mainCtx = Helpers.CreatePanel("KCMMainPanel", PANEL_TITLE, { isMain = true })
    Helpers.SetRenderer(mainCtx, Helpers.BuildAboutContent)

    local main = Settings.RegisterCanvasLayoutCategory(mainCtx.panel, PANEL_TITLE)
    Settings.RegisterAddOnCategory(main)
    KCM.Settings.main = main

    -- Default landing target is the parent (About). General overrides this
    -- once it registers so /cm config (and KCM.Options.Open) drop the user
    -- on a configurable surface, not the splash page.
    KCM._settingsCategoryID = main:GetID()

    for _, key in ipairs(KCM.Settings.order) do
        local fn = KCM.Settings.builders[key]
        if type(fn) == "function" and not KCM.Settings.sub[key] then
            local ok, sub = pcall(fn, main)
            if ok and sub then
                KCM.Settings.sub[key] = sub
            elseif not ok then
                print("|cff00ffff[CM]|r settings tab '" .. key .. "' failed: " .. tostring(sub))
            end
        end
    end
end
KCM.Settings.Register = registerPanel

-- ---------------------------------------------------------------------
-- KCM.Options shim — preserves the public API used by Core / Debug /
-- SlashCommands / Pipeline. Internals route through the new framework.
-- ---------------------------------------------------------------------

function O.Register()
    registerPanel()
    return KCM.Settings.main ~= nil
end

function O.Refresh()
    O._refreshPending = false
    Helpers.RefreshAllPanels()
end

-- Trailing-edge debounced refresh. Pipeline.Recompute fires this on every
-- recompute, which during a GET_ITEM_INFO_RECEIVED storm at first panel
-- open lands dozens of calls in quick succession. Debounce so the panel
-- rebuilds once at the tail of the burst, with a cap so the user always
-- sees the latest state within REFRESH_MAX_WAIT_SEC even if events never
-- fully stop.
local REFRESH_DEBOUNCE_SEC = 1.0
local REFRESH_MAX_WAIT_SEC = 3.0
function O.RequestRefresh()
    local now = GetTime()
    if not O._refreshFirstAt then O._refreshFirstAt = now end
    O._refreshPending = true
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

function O.Open()
    local id = KCM._settingsCategoryID
    if type(id) ~= "number" then id = tonumber(id) end
    if Settings and Settings.OpenToCategory and id then
        Settings.OpenToCategory(id)
        return true
    end
    print("|cff00ffff[CM]|r settings panel unavailable on this client; use /cm.")
    return false
end

-- Bootstrap: defer until Blizzard_Settings is ready.
local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("PLAYER_LOGIN")
bootstrap:RegisterEvent("ADDON_LOADED")
bootstrap:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= "Blizzard_Settings" then return end
    registerPanel()
    if KCM.Settings.main then
        self:UnregisterAllEvents()
    end
end)
