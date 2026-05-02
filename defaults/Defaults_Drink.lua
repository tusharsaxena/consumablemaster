-- defaults/Defaults_Drink.lua — Seed list for KCM_DRINK (mana-recovery
-- drink, no stat buff).
--
-- Midnight cooking produces five tea drinks (Argentleaf, Azeroot, Mana
-- Lily, Sanguithorn, Tranquility Bloom). They may grant profession-stat
-- buffs rather than pure mana regen — auto-discovery sorts them out by
-- tooltip content. Conjured Refreshment (mage) auto-discovers from bags
-- at runtime. The seed below is the Silvermoon innkeeper's drink stock so
-- the macro is usable before the first bag scan.
--
-- Source: in-game Silvermoon innkeeper vendor stock (Midnight 12.0).
-- Last refresh: 2026-04-23. See defaults/README.md to re-run.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.DRINK = {
    113509,  -- Conjured Mana Bun (mage conjured food) — top by default via the
             -- Ranker's conjured-bonus layer; user can demote / remove.
    260261,  -- Bloom Nectar
    260260,  -- Springrunner Sparkling
    260259,  -- Everspring Water
    260258,  -- Purified Cordial
}
