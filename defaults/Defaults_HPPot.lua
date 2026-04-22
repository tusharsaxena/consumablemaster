-- defaults/Defaults_HPPot.lua — Seed list for KCM_HP_POT.
--
-- Direct-heal potions (subType = "Potions", restores flat HP, no stat buff).
-- Refreshing Serum (241306) restores both HP and mana, so it appears in both
-- KCM.SEED.HP_POT and KCM.SEED.MP_POT; the Classifier matches it for both.
-- Shield / absorb potions (e.g. Light's Preservation) are classified outside
-- HP_POT and are not eligible here.
--
-- Source: Method.gg Midnight consumables list + Wowhead item database,
-- cross-checked via in-game /kcm dump item on a level-90 character.
-- Last refresh: 2026-04-22. See docs/REFRESH_ITEMS.md to re-run.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.HP_POT = {
    241304,  -- Silvermoon Health Potion (Midnight)
    241298,  -- Amani Extract
    241306,  -- Refreshing Serum (also restores mana)
}
