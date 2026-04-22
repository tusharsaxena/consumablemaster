-- defaults/Categories.lua — Category metadata. Each row describes one managed macro.
--
-- Fields:
--   key         : internal identifier, matches AceDB profile.categories[key]
--   macroName   : global macro name (<=16 chars, GetMacroIndexByName lookup)
--   displayName : human-readable label for settings UI
--   specAware   : if true, priority list is per-spec (uses bySpec sub-table)
--   rankerKey   : hint for Ranker module (Milestone 4)
--   classifier  : hint for Classifier module (Milestone 4)
--   emptyText   : fallback macro body when category has no resolvable items

local KCM = _G.KCM
KCM.Categories = KCM.Categories or {}

KCM.Categories.LIST = {
    {
        key         = "FOOD",
        macroName   = "KCM_FOOD",
        displayName = "Food (Well Fed)",
        specAware   = false,
        rankerKey   = "FOOD_BASIC",
        classifier  = "FOOD_BASIC",
        emptyText   = "/run print('KCM: no food in bags')",
    },
    {
        key         = "DRINK",
        macroName   = "KCM_DRINK",
        displayName = "Drink (Mana Recovery)",
        specAware   = false,
        rankerKey   = "DRINK",
        classifier  = "DRINK",
        emptyText   = "/run print('KCM: no drink in bags')",
    },
    {
        key         = "STAT_FOOD",
        macroName   = "KCM_STAT_FOOD",
        displayName = "Stat Food (Spec-aware)",
        specAware   = true,
        rankerKey   = "STAT_FOOD",
        classifier  = "STAT_FOOD",
        emptyText   = "/run print('KCM: no stat food for this spec')",
    },
    {
        key         = "HP_POT",
        macroName   = "KCM_HP_POT",
        displayName = "Healing Potion",
        specAware   = false,
        rankerKey   = "HP_POT",
        classifier  = "HP_POT",
        emptyText   = "/run print('KCM: no healing potion in bags')",
    },
    {
        key         = "MP_POT",
        macroName   = "KCM_MP_POT",
        displayName = "Mana Potion",
        specAware   = false,
        rankerKey   = "MP_POT",
        classifier  = "MP_POT",
        emptyText   = "/run print('KCM: no mana potion in bags')",
    },
    {
        key         = "HS",
        macroName   = "KCM_HS",
        displayName = "Healthstone",
        specAware   = false,
        rankerKey   = "HS",
        classifier  = "HS",
        emptyText   = "/run print('KCM: no healthstone in bags')",
    },
    {
        key         = "CMBT_POT",
        macroName   = "KCM_CMBT_POT",
        displayName = "Combat Potion (Spec-aware)",
        specAware   = true,
        rankerKey   = "CMBT_POT",
        classifier  = "CMBT_POT",
        emptyText   = "/run print('KCM: no combat potion for this spec')",
    },
    {
        key         = "FLASK",
        macroName   = "KCM_FLASK",
        displayName = "Flask (Spec-aware)",
        specAware   = true,
        rankerKey   = "FLASK",
        classifier  = "FLASK",
        emptyText   = "/run print('KCM: no flask for this spec')",
    },
}

KCM.Categories.BY_KEY = {}
for _, row in ipairs(KCM.Categories.LIST) do
    KCM.Categories.BY_KEY[row.key] = row
end

function KCM.Categories.Get(key)
    return KCM.Categories.BY_KEY[key]
end

function KCM.Categories.All()
    return KCM.Categories.LIST
end
