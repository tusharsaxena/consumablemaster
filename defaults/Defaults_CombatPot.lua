-- defaults/Defaults_CombatPot.lua — Seed list for KCM_CMBT_POT.
--
-- Combat potions: subType = "Potions" + short buff duration (≤60s) + no
-- heal/mana. Spec-specific fit is resolved by Ranker via Defaults_StatPriority
-- and parsed stat buffs. Utility potions (invisibility, slow fall, absorb,
-- water breathing) are intentionally NOT seeded here — they'd confuse
-- rank output even though the Classifier may still match them as CMBT_POT
-- when auto-discovered.
--
-- Stat tags recorded here are what the tooltip describes in natural
-- language; TooltipCache translates "highest secondary stat" phrasing into
-- the synthetic TOP_SECONDARY stat which Ranker scores against the spec's
-- top secondary.
--
-- Source: Method.gg Midnight consumables list, 2026-04-22.
-- See defaults/README.md to re-run the refresh.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.CMBT_POT = {
    241308,  -- Light's Potential           (primary stat, 30s)
    241288,  -- Potion of Recklessness      (top secondary stat, 30s)
    241292,  -- Draught of Rampant Abandon  (primary stat + void zone, 30s)
    241296,  -- Potion of Zealotry          (stacking Holy damage on target)
}
