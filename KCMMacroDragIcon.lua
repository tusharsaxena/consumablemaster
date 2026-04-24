-- KCMMacroDragIcon.lua — Custom AceGUI widget rendering a draggable macro
-- button with an inline "Drag to action bar →" label. Used at the top of each
-- category panel so users can place the auto-managed KCM_* macro on an action
-- bar without opening the macro UI.
--
-- Drag / click behaviour is the standard Blizzard macro-pickup pattern:
-- PickupMacro(index) on OnDragStart + left-click, which puts the macro on the
-- cursor. Dropping on an action slot calls Blizzard's own PlaceAction flow —
-- no protected-API call from us, so this stays taint-free even mid-combat.
--
-- The widget receives { macroName = "KCM_FOO" } via AceConfig's `arg` field
-- (forwarded through SetCustomData). Icon and tooltip are pulled fresh on
-- each refresh so they track the current macro body (which auto-rewrites as
-- bags change).

local Type, Version = "KCMMacroDragIcon", 1
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

local pairs = pairs
local CreateFrame, UIParent = CreateFrame, UIParent
local GameTooltip = GameTooltip

local ICON_SIZE      = 36
local ROW_HEIGHT     = 40
local LABEL_GAP      = 8
local FALLBACK_ICON  = 7704166 -- matches MacroManager.DEFAULT_ICON

local function macroIndex(name)
    if not name or not GetMacroIndexByName then return 0 end
    return GetMacroIndexByName(name) or 0
end

-- Active KCM macros store the `?` sentinel as their icon (so `#showtooltip`
-- can drive the action bar button). That sentinel is meaningless on our
-- static widget, so render the picked item's / spell's texture directly
-- from macroState. Falls back to the stored icon (empty-state → cooking
-- pot) and then to FALLBACK_ICON if none is available.
local function macroIcon(macroName, index)
    local KCM = _G.KCM
    local state = KCM and KCM.db and KCM.db.profile and KCM.db.profile.macroState
    local entry = state and state[macroName]
    local lastID = entry and entry.lastItemID
    local ID = KCM and KCM.ID
    if lastID and ID then
        if ID.IsSpell(lastID) and C_Spell and C_Spell.GetSpellTexture then
            local tex = C_Spell.GetSpellTexture(ID.SpellID(lastID))
            if tex then return tex end
        elseif ID.IsItem(lastID) then
            local getIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
            if getIcon then
                local tex = getIcon(lastID)
                if tex then return tex end
            end
        end
    end
    if index == 0 or not GetMacroInfo then return FALLBACK_ICON end
    local _, icon = GetMacroInfo(index)
    return icon or FALLBACK_ICON
end

-- Prefer the real in-game tooltip if MacroManager has recorded an ID for this
-- slot. `lastItemID` holds an opaque KCM ID — positive itemIDs route to
-- SetItemByID, negative spell sentinels route to SetSpellByID. Anything else
-- (empty-state macros, unresolved picks) falls back to the macro name + body.
local function showMacroTooltip(owner, macroName, index)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local KCM = _G.KCM
    local state = KCM and KCM.db and KCM.db.profile and KCM.db.profile.macroState
    local entry = state and state[macroName]
    local lastID = entry and entry.lastItemID
    local ID = KCM and KCM.ID

    if ID and lastID and ID.IsSpell(lastID) and GameTooltip.SetSpellByID then
        GameTooltip:SetSpellByID(ID.SpellID(lastID))
    elseif ID and lastID and ID.IsItem(lastID) and GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(lastID)
    else
        GameTooltip:SetText(macroName, 1, 0.82, 0)
        if GetMacroInfo and index ~= 0 then
            local _, _, body = GetMacroInfo(index)
            if body and body ~= "" then
                GameTooltip:AddLine(body, 1, 1, 1, true)
            end
        end
    end
    GameTooltip:Show()
end

local methods = {
    ["OnAcquire"] = function(self)
        self.macroName = nil
        self.frame.height = ROW_HEIGHT
        self:SetHeight(ROW_HEIGHT)
        self:SetWidth(220)
        self:RefreshDisplay()
    end,

    -- AceConfigDialog calls SetText/SetFontObject on every description-type
    -- entry. Ignore both — widget builds its own label.
    ["SetText"]       = function(self, _) end,
    ["SetFontObject"] = function(self, _) end,

    ["SetCustomData"] = function(self, data)
        if type(data) ~= "table" then return end
        self.macroName = data.macroName
        self:RefreshDisplay()
    end,

    ["RefreshDisplay"] = function(self)
        local idx = macroIndex(self.macroName)
        self.icon:SetTexture(macroIcon(self.macroName, idx))
        if idx == 0 then
            self.label:SetText("|cff999999Macro not created yet|r")
            self.frame:Disable()
        else
            self.label:SetText("|cffffd100Drag to action bar|r")
            self.frame:Enable()
        end
    end,
}

local function Constructor()
    local frame = CreateFrame("Button", nil, UIParent)
    frame:Hide()
    frame:SetHeight(ROW_HEIGHT)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame:RegisterForDrag("LeftButton")

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", 0, 0)

    -- Subtle button-press highlight so the icon reads as interactive.
    local highlight = frame:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(icon)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", icon, "RIGHT", LABEL_GAP, 0)
    label:SetJustifyH("LEFT")
    label:SetJustifyV("MIDDLE")

    local widget = {
        frame = frame,
        icon  = icon,
        label = label,
        type  = Type,
    }

    local function pickup()
        if not widget.macroName then return end
        local idx = macroIndex(widget.macroName)
        if idx == 0 then return end
        if PickupMacro then PickupMacro(idx) end
    end

    frame:SetScript("OnClick", pickup)
    frame:SetScript("OnDragStart", pickup)

    frame:SetScript("OnEnter", function(self)
        if not widget.macroName then return end
        local idx = macroIndex(widget.macroName)
        showMacroTooltip(self, widget.macroName, idx)
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    for method, func in pairs(methods) do
        widget[method] = func
    end

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
