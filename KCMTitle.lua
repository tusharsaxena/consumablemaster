-- KCMTitle.lua — Custom AceGUI widget for the page-title banner.
--
-- Used for the per-category header at the top of each options page ("Food",
-- "Flask", etc.). AceConfig's `fontSize` option tops out at "large" (→
-- GameFontHighlightLarge, ~14pt), which is too small for a page title. This
-- widget renders the text at 22pt gold so the header reads as a page title,
-- not just another line of body text. Referenced via
-- `dialogControl = "KCMTitle"` on a description entry.

local Type, Version = "KCMTitle", 1
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

local pairs = pairs
local CreateFrame, UIParent = CreateFrame, UIParent

local methods = {
    ["OnAcquire"] = function(self)
        self:SetText("")
        self:SetFullWidth(true)
        self:SetHeight(34)
    end,

    ["SetText"] = function(self, text)
        self.label:SetText(text or "")
    end,

    -- AceConfigDialog calls SetFontObject on every description-type widget
    -- (AceConfigDialog-3.0.lua:1406-1410). We ignore it — the widget uses a
    -- fixed font set in Constructor.
    ["SetFontObject"] = function(self, _) end,
}

local function Constructor()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local label = frame:CreateFontString(nil, "OVERLAY")
    label:SetFont(STANDARD_TEXT_FONT, 22, "")
    label:SetTextColor(1, 0.82, 0) -- gold, matches section-header tint
    label:SetAllPoints()
    label:SetJustifyH("LEFT")
    label:SetJustifyV("MIDDLE")

    local widget = {
        label = label,
        frame = frame,
        type  = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
