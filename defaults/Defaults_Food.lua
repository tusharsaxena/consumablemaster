-- defaults/Defaults_Food.lua — Seed list for KCM_FOOD (basic "Well Fed" food,
-- no stat buff).
--
-- Midnight cooking does not produce basic (non-stat) food — every crafted
-- dish grants a stat buff and is classified as STAT_FOOD. Basic food in
-- Midnight comes from the Silvermoon innkeeper; the IDs below are that
-- vendor's stock so the macro is usable before the first bag scan.
-- Auto-discovery still picks up anything else the player carries.
--
-- Spell entries (KCM.ID.AsSpell) live alongside items in the seed. Ranker
-- assigns them a huge baseline score so they rank above items by default;
-- the user can demote or remove them via the Options panel exactly like
-- any other row.
--
-- Source: in-game Silvermoon innkeeper vendor stock (Midnight 12.0).
-- Last refresh: 2026-04-23. See defaults/README.md to re-run.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.FOOD = {
    KCM.ID.AsSpell(1231411),  -- Recuperate (spell) — always preferred for Food
    113509,  -- Conjured Mana Bun (mage conjured food)
    260264,  -- Quel'Danas Rations
    260263,  -- Silvermoon Soiree Spread
    260262,  -- Fairbreeze Feast
    260257,  -- Ghostlands Pepper
    260256,  -- Luxurious Omelette
    260255,  -- Managi Roll
    260254,  -- Kale'thas Sunsalad
}
