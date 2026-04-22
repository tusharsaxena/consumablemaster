-- defaults/Defaults_Healthstone.lua — Seed list for KCM_HS.
--
-- Warlock Healthstones. The modern ranked healthstone (224464) auto-upgrades
-- with warlock level; 5512 is the classic evergreen id kept as a safety net.
-- Source: Wowhead, 2026-04.

local KCM = _G.KCM
KCM.SEED = KCM.SEED or {}

KCM.SEED.HS = {
    224464,  -- Healthstone (modern Dragonflight+)
    5512,    -- Healthstone (legacy; compatibility fallback)
}
