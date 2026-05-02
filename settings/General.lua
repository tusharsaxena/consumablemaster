-- settings/General.lua — General page.
--
-- Two sections:
--   * General      — paired [Enable] | [Debug] checkboxes (both schema-driven;
--                    same rows /cm get/set enabled and /cm get/set debug use).
--   * Maintenance  — Row 1: Force resync | Force rewrite macros (paired 50/50).
--                    Row 2: Reset all priorities (full-width, StaticPopup-confirmed).
--
-- Every execute path is shared with the slash commands so behaviour stays
-- identical regardless of entry point.

local KCM    = _G.KCM
local H      = KCM.Settings.Helpers
local AceGUI = LibStub("AceGUI-3.0")

local function inCombatNotice(label)
    print(("|cff00ffff[CM]|r in combat — %s deferred until regen."):format(label))
end

local function doForceResync()
    if InCombatLockdown and InCombatLockdown() then
        return inCombatNotice("resync")
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
    H.RefreshAllPanels()
end

local function doForceRewriteMacros()
    if InCombatLockdown and InCombatLockdown() then
        return inCombatNotice("macro writes")
    end
    if KCM.MacroManager and KCM.MacroManager.InvalidateState then
        KCM.MacroManager.InvalidateState()
    end
    if KCM.Pipeline and KCM.Pipeline.Recompute then
        KCM.Pipeline.Recompute("options_rewrite")
    end
    print("|cff00ffff[CM]|r rewrote all macros. If action bar icons still look stale, /reload to force the bars to refresh.")
    H.RefreshAllPanels()
end

local function doResetAll()
    if KCM.ResetAllToDefaults then
        KCM.ResetAllToDefaults("options_reset")
    end
    H.RefreshAllPanels()
end

StaticPopupDialogs["KCM_RESET_ALL"] = {
    text         = "Reset ALL ConsumableMaster customization to defaults? This wipes added/blocked/pinned items and stat-priority overrides. Discovered items from bag scans are preserved.",
    button1      = "Yes",
    button2      = "No",
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnAccept     = function() doResetAll() end,
}

local function render(ctx)
    H.ResetScroll(ctx)
    local scroll = H.EnsureScroll(ctx)

    -- General: paired [Enable] | [Debug] schema-driven row so the slash
    -- command path uses the same write+refresh wiring as the toggles.
    H.Section(ctx, "General")
    local enabledDef = H.FindSchema("enabled")
    local debugDef   = H.FindSchema("debug")
    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    if enabledDef then H.RenderField(ctx, enabledDef, row, 0.5) end
    if debugDef   then H.RenderField(ctx, debugDef,   row, 0.5) end
    scroll:AddChild(row)

    H.Section(ctx, "Maintenance")
    H.ButtonPair(ctx,
        {
            text    = "Force resync",
            tooltip = "Invalidate the tooltip cache, re-run auto-discovery against your bags, and recompute every category's pick. Same as /cm resync. Blocked in combat.",
            onClick = doForceResync,
        },
        {
            text    = "Force rewrite macros",
            tooltip = "Clear cached macro fingerprints and re-issue every KCM macro (body + stored icon). Use this if a macro's action-bar icon looks stale. Same as /cm rewritemacros. Blocked in combat.",
            onClick = doForceRewriteMacros,
        })
    H.Button(ctx, {
        text    = "Reset all priorities",
        tooltip = "Wipe all added/blocked/pinned items and stat-priority overrides. Seed defaults are restored. This cannot be undone.",
        onClick = function() StaticPopup_Show("KCM_RESET_ALL") end,
    })

    if scroll.DoLayout then scroll:DoLayout() end
end

local function Build(mainCategory)
    if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then
        return nil
    end

    local ctx = H.CreatePanel("KCMGeneralPanel", "General", { panelKey = "general" })
    H.SetRenderer(ctx, render)
    return Settings.RegisterCanvasLayoutSubcategory(mainCategory, ctx.panel, "General")
end

if KCM.Settings and KCM.Settings.RegisterTab then
    KCM.Settings.RegisterTab("general", Build)
end
