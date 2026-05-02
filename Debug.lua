-- Debug.lua — conditional logging gated on KCM.db.profile.debug.

local KCM = _G.KCM
KCM.Debug = {}

local PREFIX = "|cff00ffff[CM]|r "

function KCM.Debug.IsOn()
    return KCM.db and KCM.db.profile and KCM.db.profile.debug == true
end

function KCM.Debug.Toggle()
    if not (KCM.db and KCM.db.profile) then
        print(PREFIX .. "DB not ready yet.")
        return
    end
    local next = not KCM.db.profile.debug
    -- Route through Settings.Helpers so the schema row's onChange runs and any
    -- open Options panel re-syncs the checkbox. Falls through to a direct DB
    -- write on the early-boot edge where Helpers hasn't been published yet
    -- (settings/Panel.lua loads after Debug.lua, but slash registration runs
    -- later so this is a defensive guard, not an expected path).
    local H = KCM.Settings and KCM.Settings.Helpers
    if H and H.SetAndRefresh and H.SetAndRefresh("debug", next) then
        KCM.Debug.Print("Debug prints are now enabled.")
        return
    end
    KCM.db.profile.debug = next
    local state = next and "|cff00ff00ON|r" or "|cffff5555OFF|r"
    print(PREFIX .. "Debug mode " .. state)
    KCM.Debug.Print("Debug prints are now enabled.")
    if KCM.Options and KCM.Options.Refresh then
        KCM.Options.Refresh()
    end
end

function KCM.Debug.Print(fmt, ...)
    if not KCM.Debug.IsOn() then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    print(PREFIX .. msg)
end
