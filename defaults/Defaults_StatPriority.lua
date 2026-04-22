-- defaults/Defaults_StatPriority.lua — Seed stat priority per class/spec.
--
-- Keyed by "<classID>_<specID>" (see SpecHelper.MakeKey). `specID` is the
-- Blizzard-global spec identifier returned by GetSpecializationInfo, NOT a
-- 1..N index — e.g. Shaman Restoration is spec id 264, not 3. Using the
-- global id keeps the key stable across UI reorderings and matches what
-- SpecHelper.GetCurrent() produces at runtime.
--
-- Values:
--   primary    : "STR" | "AGI" | "INT"            -- dominant stat
--   secondary  : ordered list of secondary stats the spec favors
--                ("HASTE" | "CRIT" | "MASTERY" | "VERSATILITY")
--
-- Used by the Ranker to pick the best-fit stat food / flask / combat potion
-- when no user override is present.
--
-- Class IDs (Blizzard API): 1 Warrior, 2 Paladin, 3 Hunter, 4 Rogue, 5 Priest,
-- 6 Death Knight, 7 Shaman, 8 Mage, 9 Warlock, 10 Monk, 11 Druid, 12 Demon
-- Hunter, 13 Evoker.
--
-- ---------------------------------------------------------------------------
-- HOW TO REFRESH THIS TABLE
-- ---------------------------------------------------------------------------
-- Source: https://www.archon.gg/wow — per-spec Mythic+ overview pages.
-- URL pattern (replace <spec> and <class> with the slug, keep the rest):
--
--   https://www.archon.gg/wow/builds/<spec>/<class>/mythic-plus/overview/10/all-dungeons/this-week
--
-- Examples:
--   .../builds/blood/death-knight/mythic-plus/overview/10/all-dungeons/this-week
--   .../builds/restoration/shaman/mythic-plus/overview/10/all-dungeons/this-week
--   .../builds/beast-mastery/hunter/mythic-plus/overview/10/all-dungeons/this-week
--
-- Each page has a "Stat Priority" block near the top — primary stat, then an
-- ordered list of secondary stats (Crit / Haste / Mastery / Versatility).
-- Copy that order into the `secondary` array below. The `primary` field is
-- fixed per spec (armor class determines it) and almost never changes
-- between patches.
--
-- Spec slugs archon.gg uses (for copy-paste when refreshing):
--   Warrior       : arms, fury, protection
--   Paladin       : holy, protection, retribution
--   Hunter        : beast-mastery, marksmanship, survival
--   Rogue         : assassination, outlaw, subtlety
--   Priest        : discipline, holy, shadow
--   Death-Knight  : blood, frost, unholy                (class slug: death-knight)
--   Shaman        : elemental, enhancement, restoration
--   Mage          : arcane, fire, frost
--   Warlock       : affliction, demonology, destruction
--   Monk          : brewmaster, windwalker, mistweaver
--   Druid         : balance, feral, guardian, restoration
--   Demon-Hunter  : havoc, vengeance                     (class slug: demon-hunter)
--   Evoker        : devastation, preservation, augmentation
--
-- Refresh cadence: once per major patch (0.1, 0.2, 1.0, ...) is enough —
-- archon.gg re-ranks weekly but the top-to-bottom order only shuffles
-- significantly around balance patches. When refreshing:
--   1. Walk the 39 specs above.
--   2. Paste the new ordering into the relevant row.
--   3. Update the "Last refreshed" line directly below.
--   4. Bump defaults/README.md's snapshot date to match.
--
-- Last refreshed: 2026-04-21 from archon.gg (WoW Midnight 12.0).

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.STAT_PRIORITY = {
    -- Warrior
    ["1_71"] = { primary = "STR", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },        -- Arms
    ["1_72"] = { primary = "STR", secondary = { "HASTE", "MASTERY", "CRIT", "VERSATILITY" } },        -- Fury
    ["1_73"] = { primary = "STR", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },        -- Protection

    -- Paladin
    ["2_65"] = { primary = "INT", secondary = { "HASTE", "MASTERY", "CRIT", "VERSATILITY" } },        -- Holy
    ["2_66"] = { primary = "STR", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },        -- Protection
    ["2_70"] = { primary = "STR", secondary = { "MASTERY", "CRIT", "HASTE", "VERSATILITY" } },        -- Retribution

    -- Hunter
    ["3_253"] = { primary = "AGI", secondary = { "CRIT", "MASTERY", "HASTE", "VERSATILITY" } },       -- Beast Mastery
    ["3_254"] = { primary = "AGI", secondary = { "CRIT", "MASTERY", "HASTE", "VERSATILITY" } },       -- Marksmanship
    ["3_255"] = { primary = "AGI", secondary = { "MASTERY", "CRIT", "HASTE", "VERSATILITY" } },       -- Survival

    -- Rogue
    ["4_259"] = { primary = "AGI", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },       -- Assassination
    ["4_260"] = { primary = "AGI", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },       -- Outlaw
    ["4_261"] = { primary = "AGI", secondary = { "MASTERY", "CRIT", "HASTE", "VERSATILITY" } },       -- Subtlety

    -- Priest
    ["5_256"] = { primary = "INT", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },       -- Discipline
    ["5_257"] = { primary = "INT", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },       -- Holy
    ["5_258"] = { primary = "INT", secondary = { "HASTE", "MASTERY", "CRIT", "VERSATILITY" } },       -- Shadow

    -- Death Knight
    ["6_250"] = { primary = "STR", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },       -- Blood
    ["6_251"] = { primary = "STR", secondary = { "CRIT", "MASTERY", "HASTE", "VERSATILITY" } },       -- Frost
    ["6_252"] = { primary = "STR", secondary = { "MASTERY", "CRIT", "HASTE", "VERSATILITY" } },       -- Unholy

    -- Shaman
    ["7_262"] = { primary = "INT", secondary = { "MASTERY", "CRIT", "HASTE", "VERSATILITY" } },       -- Elemental
    ["7_263"] = { primary = "AGI", secondary = { "MASTERY", "HASTE", "CRIT", "VERSATILITY" } },       -- Enhancement
    ["7_264"] = { primary = "INT", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },       -- Restoration

    -- Mage
    ["8_62"] = { primary = "INT", secondary = { "MASTERY", "HASTE", "CRIT", "VERSATILITY" } },        -- Arcane
    ["8_63"] = { primary = "INT", secondary = { "HASTE", "MASTERY", "CRIT", "VERSATILITY" } },        -- Fire
    ["8_64"] = { primary = "INT", secondary = { "CRIT", "MASTERY", "HASTE", "VERSATILITY" } },        -- Frost

    -- Warlock
    ["9_265"] = { primary = "INT", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },       -- Affliction
    ["9_266"] = { primary = "INT", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },       -- Demonology
    ["9_267"] = { primary = "INT", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },       -- Destruction

    -- Monk
    ["10_268"] = { primary = "AGI", secondary = { "CRIT", "VERSATILITY", "MASTERY", "HASTE" } },      -- Brewmaster
    ["10_269"] = { primary = "AGI", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },      -- Windwalker
    ["10_270"] = { primary = "INT", secondary = { "HASTE", "CRIT", "VERSATILITY", "MASTERY" } },      -- Mistweaver

    -- Druid
    ["11_102"] = { primary = "INT", secondary = { "MASTERY", "HASTE", "CRIT", "VERSATILITY" } },      -- Balance
    ["11_103"] = { primary = "AGI", secondary = { "MASTERY", "HASTE", "CRIT", "VERSATILITY" } },      -- Feral
    ["11_104"] = { primary = "AGI", secondary = { "HASTE", "MASTERY", "VERSATILITY", "CRIT" } },      -- Guardian
    ["11_105"] = { primary = "INT", secondary = { "HASTE", "MASTERY", "CRIT", "VERSATILITY" } },      -- Restoration

    -- Demon Hunter
    ["12_577"] = { primary = "AGI", secondary = { "CRIT", "MASTERY", "HASTE", "VERSATILITY" } },      -- Havoc
    ["12_581"] = { primary = "AGI", secondary = { "HASTE", "CRIT", "MASTERY", "VERSATILITY" } },      -- Vengeance

    -- Evoker
    ["13_1467"] = { primary = "INT", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },     -- Devastation
    ["13_1468"] = { primary = "INT", secondary = { "MASTERY", "HASTE", "CRIT", "VERSATILITY" } },     -- Preservation
    ["13_1473"] = { primary = "INT", secondary = { "CRIT", "HASTE", "MASTERY", "VERSATILITY" } },     -- Augmentation
}
