-- KCMScoreButton.lua — Priority-row "score" button.
--
-- Same visual + hover-swatch behaviour as KCMIconButton, but with a no-op
-- SetLabel so callers can pass an arbitrary string without a label
-- rendering underneath the icon. The label string is repurposed as the
-- tooltip title (yellow header line); the tooltip body is composed from
-- Ranker.Explain output by settings/Category.lua so each row shows its
-- own per-item score breakdown.
--
-- Acquired directly via `AceGUI:Create("KCMScoreButton")` in
-- settings/Category.lua.

local Type, Version = "KCMScoreButton", 1
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
        self:SetImage(nil)
        self:SetImageSize(24, 24)
        self:SetDisabled(false)
    end,

    -- No-op: AceConfigDialog always calls SetLabel(name). Swallowing the
    -- call keeps the button icon-only so the tooltip title (driven by the
    -- same `name` field) doesn't leak into the row layout as a text label.
    ["SetLabel"] = function(self, _) end,

    ["SetImage"] = function(self, path, ...)
        local image = self.image
        if type(path) == "string" and path:sub(1, 6) == "atlas:" then
            image:SetTexture(nil)
            image:SetAtlas(path:sub(7), false)
            image:SetTexCoord(0, 1, 0, 1)
        else
            image:SetTexture(path)
            if image:GetTexture() then
                local n = select("#", ...)
                if n == 4 or n == 8 then
                    image:SetTexCoord(...)
                else
                    image:SetTexCoord(0, 1, 0, 1)
                end
            end
        end
    end,

    ["SetImageSize"] = function(self, width, height)
        self.image:SetWidth(width)
        self.image:SetHeight(height)
        self:SetHeight(height + 2)
    end,

    ["SetDisabled"] = function(self, disabled)
        self.disabled = disabled
        if disabled then
            self.frame:Disable()
            self.image:SetVertexColor(0.5, 0.5, 0.5, 0.5)
        else
            self.frame:Enable()
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

    local hoverBG = frame:CreateTexture(nil, "BACKGROUND")
    hoverBG:SetColorTexture(1, 0.82, 0, 0.25)
    hoverBG:Hide()
    frame.hoverBG = hoverBG

    local image = frame:CreateTexture(nil, "ARTWORK")
    image:SetWidth(24)
    image:SetHeight(24)
    image:SetPoint("CENTER")

    hoverBG:SetAllPoints(image)

    local widget = {
        image   = image,
        hoverBG = hoverBG,
        frame   = frame,
        type    = Type,
    }
    for method, func in pairs(methods) do
        widget[method] = func
    end

    return AceGUI:RegisterAsWidget(widget)
end

AceGUI:RegisterWidgetType(Type, Constructor, Version)
