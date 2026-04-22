-- KCMIconButton.lua — Custom AceGUI icon-button widget.
--
-- Based on AceGUI's Icon widget (libs/AceGUI-3.0/widgets/AceGUIWidget-Icon.lua),
-- but with a solid gold BACKGROUND swatch behind the icon on mouseover so the
-- priority-row action buttons (up / down / delete) have an obvious hover state.
-- The icon lives on the ARTWORK draw layer so the swatch renders cleanly behind
-- it. Referenced from Options.lua via `dialogControl = "KCMIconButton"`.

local Type, Version = "KCMIconButton", 1
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

local pairs, select = pairs, select
local CreateFrame, UIParent = CreateFrame, UIParent

local function Control_OnEnter(frame)
    if frame.hoverBG then frame.hoverBG:Show() end
    frame.obj:Fire("OnEnter")
end
local function Control_OnLeave(frame)
    if frame.hoverBG then frame.hoverBG:Hide() end
    frame.obj:Fire("OnLeave")
end
local function Button_OnClick(frame, button)
    frame.obj:Fire("OnClick", button)
    AceGUI:ClearFocus()
end

local methods = {
    ["OnAcquire"] = function(self)
        self:SetHeight(110)
        self:SetWidth(110)
        self:SetLabel()
        self:SetImage(nil)
        self:SetImageSize(64, 64)
        self:SetDisabled(false)
    end,

    ["SetLabel"] = function(self, text)
        if text and text ~= "" then
            self.label:Show()
            self.label:SetText(text)
            self:SetHeight(self.image:GetHeight() + 25)
        else
            self.label:Hide()
            self:SetHeight(self.image:GetHeight() + 10)
        end
    end,

    ["SetImage"] = function(self, path, ...)
        local image = self.image
        image:SetTexture(path)
        if image:GetTexture() then
            local n = select("#", ...)
            if n == 4 or n == 8 then
                image:SetTexCoord(...)
            else
                image:SetTexCoord(0, 1, 0, 1)
            end
        end
    end,

    ["SetImageSize"] = function(self, width, height)
        self.image:SetWidth(width)
        self.image:SetHeight(height)
        if self.label:IsShown() then
            self:SetHeight(height + 25)
        else
            -- Tight vertical padding (1px above/below image) — the priority
            -- list rows render flush against each other, which is the point.
            self:SetHeight(height + 2)
        end
    end,

    ["SetDisabled"] = function(self, disabled)
        self.disabled = disabled
        if disabled then
            self.frame:Disable()
            self.label:SetTextColor(0.5, 0.5, 0.5)
            self.image:SetVertexColor(0.5, 0.5, 0.5, 0.5)
        else
            self.frame:Enable()
            self.label:SetTextColor(1, 1, 1)
            self.image:SetVertexColor(1, 1, 1, 1)
        end
    end,
}

local function Constructor()
    local frame = CreateFrame("Button", nil, UIParent)
    frame:Hide()
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", Control_OnEnter)
    frame:SetScript("OnLeave", Control_OnLeave)
    frame:SetScript("OnClick", Button_OnClick)

    local label = frame:CreateFontString(nil, "BACKGROUND", "GameFontHighlight")
    label:SetPoint("BOTTOMLEFT")
    label:SetPoint("BOTTOMRIGHT")
    label:SetJustifyH("CENTER")
    label:SetJustifyV("TOP")
    label:SetHeight(18)

    -- Solid gold hover swatch sits on BACKGROUND (below the icon on ARTWORK) and
    -- pins flush to the image's bounds — no gap, icon unobscured. Shown/hidden
    -- manually from Control_OnEnter/OnLeave. Colour matches GameFontNormal gold
    -- (1, 0.82, 0) used by section headers, at 25% alpha.
    local hoverBG = frame:CreateTexture(nil, "BACKGROUND")
    hoverBG:SetColorTexture(1, 0.82, 0, 0.25)
    hoverBG:Hide()
    frame.hoverBG = hoverBG

    local image = frame:CreateTexture(nil, "ARTWORK")
    image:SetWidth(64)
    image:SetHeight(64)
    image:SetPoint("CENTER")

    hoverBG:SetAllPoints(image)

    local widget = {
        label     = label,
        image     = image,
        hoverBG   = hoverBG,
        frame     = frame,
        type      = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
