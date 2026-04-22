-- defaults/Defaults_MPPot.lua — Seed list for KCM_MP_POT.
--
-- Direct mana-restore potions (subType = "Potions", restores mana, no stat
-- buff). Refreshing Serum (241306) also restores HP and appears in both
-- KCM.SEED.HP_POT and KCM.SEED.MP_POT.
--
-- Source: Method.gg Midnight consumables list + Wowhead item database.
-- Last refresh: 2026-04-22. See docs/REFRESH_ITEMS.md to re-run.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.MP_POT = {
    241300,  -- Lightfused Mana Potion (Midnight)
    241294,  -- Potion of Devoured Dreams
    241306,  -- Refreshing Serum (also restores health)
}
