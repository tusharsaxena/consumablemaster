-- KCMHeading.lua — Custom AceGUI heading widget.
--
-- Forked from AceGUI's Heading widget (libs/AceGUI-3.0/widgets/AceGUIWidget-Heading.lua),
-- swapping the label font to GameFontNormalLarge so section titles ("Add item by ID",
-- "Priority list") read at a comfortable size next to large-font body text.
-- Referenced from Options.lua via `dialogControl = "KCMHeading"` on header entries.

local Type, Version = "KCMHeading", 1
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI or (AceGUI:GetWidgetVersion(Type) or 0) >= Version then return end

local pairs = pairs
local CreateFrame, UIParent = CreateFrame, UIParent

local methods = {
    ["OnAcquire"] = function(self)
        self:SetText()
        self:SetFullWidth()
        self:SetHeight(24)
    end,

    ["SetText"] = function(self, text)
        self.label:SetText(text or "")
        if text and text ~= "" then
            self.left:SetPoint("RIGHT", self.label, "LEFT", -5, 0)
            self.right:Show()
        else
            self.left:SetPoint("RIGHT", -3, 0)
            self.right:Hide()
        end
    end,
}

local function Constructor()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:Hide()

    local label = frame:CreateFontString(nil, "BACKGROUND", "GameFontNormalLarge")
    label:SetPoint("TOP")
    label:SetPoint("BOTTOM")
    label:SetJustifyH("CENTER")

    local left = frame:CreateTexture(nil, "BACKGROUND")
    left:SetHeight(8)
    left:SetPoint("LEFT", 3, 0)
    left:SetPoint("RIGHT", label, "LEFT", -5, 0)
    left:SetTexture(137057) -- Interface\Tooltips\UI-Tooltip-Border
    left:SetTexCoord(0.81, 0.94, 0.5, 1)

    local right = frame:CreateTexture(nil, "BACKGROUND")
    right:SetHeight(8)
    right:SetPoint("RIGHT", -3, 0)
    right:SetPoint("LEFT", label, "RIGHT", 5, 0)
    right:SetTexture(137057)
    right:SetTexCoord(0.81, 0.94, 0.5, 1)

    local widget = {
        label = label,
        left  = left,
        right = right,
        frame = frame,
        type  = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
