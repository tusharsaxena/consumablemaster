-- defaults/Defaults_Drink.lua — Seed list for KCM_DRINK (mana-recovery
-- drink, no stat buff).
--
-- Midnight cooking produces five tea drinks (Argentleaf, Azeroot, Mana
-- Lily, Sanguithorn, Tranquility Bloom). They may grant profession-stat
-- buffs rather than pure mana regen — auto-discovery sorts them out by
-- tooltip content. Conjured Refreshment (mage) auto-discovers from bags
-- at runtime. This seed keeps a classic conjured fallback for first-boot.
--
-- See docs/REFRESH_ITEMS.md for the refresh procedure.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.DRINK = {
    159,     -- Refreshing Spring Water (classic vendor fallback)
}
