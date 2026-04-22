-- defaults/Defaults_Food.lua — Seed list for KCM_FOOD (basic "Well Fed" food,
-- no stat buff).
--
-- Midnight cooking does not produce basic (non-stat) food — every crafted
-- dish grants a stat buff and is classified as STAT_FOOD. Basic food
-- comes from vendors, quests, conjured refreshments (mage), or legacy
-- stockpiles. Auto-discovery catches whatever the player actually carries;
-- this seed only keeps a classic conjured fallback so the macro is usable
-- before the first bag scan.
--
-- See docs/REFRESH_ITEMS.md for the refresh procedure.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.FOOD = {
    4540,    -- Tough Hunk of Bread (classic vendor fallback)
}
