-- defaults/Defaults_Flask.lua — Seed list for KCM_FLASK.
--
-- Combat flasks only. Midnight merged the legacy "Flask" and "Phial"
-- subtypes into a single "Flasks & Phials" subType string, so Haranir
-- profession phials (241310, 241312, 241316) ALSO classify as FLASK when
-- auto-discovered. They score 0 against combat stat priorities and sort
-- last, so they don't displace a combat flask — but they're intentionally
-- NOT seeded here to keep the default priority list clean.
--
-- Stat-per-spec is resolved by Ranker via Defaults_StatPriority + parsed
-- tooltip stat buffs. Vicious Thalassian Flask of Honor grants +15% honor,
-- not a combat stat, but it remains in the seed as a combat-usable flask
-- for PvP contexts.
--
-- Source: Method.gg Midnight consumables list, 2026-04-22.
-- See defaults/README.md to re-run the refresh.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.FLASK = {
    241326,  -- Flask of the Shattered Sun      (CRIT)
    241324,  -- Flask of the Blood Knights      (HASTE)
    241322,  -- Flask of the Magisters          (MASTERY)
    241321,  -- Flask of Thalassian Resistance  (VERSATILITY)
    241334,  -- Vicious Thalassian Flask of Honor (PvP honor-gain flask)
}
