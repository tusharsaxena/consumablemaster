-- Debug.lua — conditional logging gated on KCM.db.profile.debug.

local KCM = _G.KCM
KCM.Debug = {}

local PREFIX = "|cffff8800[KCM]|r "

function KCM.Debug.IsOn()
    return KCM.db and KCM.db.profile and KCM.db.profile.debug == true
end

function KCM.Debug.Toggle()
    if not (KCM.db and KCM.db.profile) then
        print(PREFIX .. "DB not ready yet.")
        return
    end
    KCM.db.profile.debug = not KCM.db.profile.debug
    local state = KCM.db.profile.debug and "|cff00ff00ON|r" or "|cffff5555OFF|r"
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
