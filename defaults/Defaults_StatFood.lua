-- defaults/Defaults_StatFood.lua — Seed list for KCM_STAT_FOOD.
--
-- Midnight cooked stat meals. Stat-per-spec is resolved by Ranker via
-- Defaults_StatPriority + parsed tooltip stat buffs. Feasts (single-serve
-- and raid-wide) are deliberately NOT seeded here — they're classified
-- out of STAT_FOOD via TooltipCache `isFeast` detection.
--
-- "Hearty" variants (tier 35+ of the same recipe) share the subType and
-- stat profile; they're auto-discovered from bags and sorted by the
-- Ranker. We only seed the base-tier IDs for a clean default priority.
--
-- Source: Method.gg Midnight consumables list + Warcraft Wiki cooking
-- recipes, 2026-04-22. See docs/REFRESH_ITEMS.md to re-run.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.STAT_FOOD = {
    -- Master tier (primary stat, highest amount)
    242275,  -- Royal Roast                    (primary stat)
    255847,  -- Impossibly Royal Roast         (primary stat, top tier)

    -- Intermediate / Advanced single-stat
    242283,  -- Sun-Seared Lumifin             (CRIT)
    242286,  -- Arcano Cutlets                 (CRIT)
    242278,  -- Tasty Smoked Tetra             (CRIT)
    242277,  -- Crimson Calamari               (HASTE)
    242282,  -- Null and Void Plate            (HASTE)
    242281,  -- Glitter Skewers                (MASTERY)
    242285,  -- Warped Wise Wings              (MASTERY)
    242284,  -- Void-Kissed Fish Rolls         (VERSATILITY)
    242280,  -- Buttered Root Crab             (VERSATILITY)
    242276,  -- Braised Blood Hunter           (VERSATILITY)
    242294,  -- Felberry Figs                  (VERSATILITY)

    -- Primary-stat starter/intermediate
    242288,  -- Twilight Angler's Medley       (primary stat)
    242289,  -- Spellfire Filet                (primary stat)
    242302,  -- Bloom Skewers                  (primary stat)
    242303,  -- Mana-Infused Stew              (primary stat)

    -- Dual-stat combined (Intermediate tier)
    242290,  -- Wise Tails                     (CRIT + VERS)
    242291,  -- Fried Bloomtail                (MASTERY + VERS)
    242292,  -- Eversong Pudding               (MASTERY + CRIT)
    242293,  -- Sunwell Delight                (VERS + HASTE)
    242295,  -- Hearthflame Supper             (CRIT + HASTE)
    242296,  -- Bloodthistle-Wrapped Cutlets   (MASTERY + HASTE)

    -- Dual-stat Starter tier (smaller amount)
    242304,  -- Spiced Biscuits                (CRIT + VERS)
    242305,  -- Silvermoon Standard            (MASTERY + VERS)
    242306,  -- Forager's Medley               (MASTERY + CRIT)
    242307,  -- Quick Sandwich                 (VERS + HASTE)
    242308,  -- Portable Snack                 (CRIT + HASTE)
    242309,  -- Farstrider Rations             (MASTERY + HASTE)
}
