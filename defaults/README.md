# defaults/ — seed item IDs and stat priorities

Everything in this folder is **seed data**, not persistent user state. Files
here are evaluated at addon load and written into `KCM.SEED.*` constants. The
runtime candidate set for each category is computed as:

```
candidates = SEED ∪ db.added ∪ db.discovered − db.blocked
```

That means **updating a defaults file is a free upgrade for every user** —
when they next log in, the new seed IDs are picked up without any migration
step. User-local changes (added, blocked, pins) live in SavedVariables and
are preserved independently.

## Files

| File                          | Populates            | Purpose                                                      |
| ----------------------------- | -------------------- | ------------------------------------------------------------ |
| `Categories.lua`              | `KCM.Categories`     | Metadata (macro name, spec-awareness, ranker/classifier key) |
| `Defaults_StatPriority.lua`   | `KCM.SEED.STAT_PRIORITY` | Primary + ordered secondary stats per `<classID>_<specID>` |
| `Defaults_Food.lua`           | `KCM.SEED.FOOD`      | Basic Well Fed food (non-stat)                               |
| `Defaults_Drink.lua`          | `KCM.SEED.DRINK`     | Mana-recovery drinks                                         |
| `Defaults_StatFood.lua`       | `KCM.SEED.STAT_FOOD` | Cooked stat meals (feasts excluded)                          |
| `Defaults_HPPot.lua`          | `KCM.SEED.HP_POT`    | Direct-heal potions (no absorb/shield)                       |
| `Defaults_MPPot.lua`          | `KCM.SEED.MP_POT`    | Mana-restoration potions                                     |
| `Defaults_Healthstone.lua`    | `KCM.SEED.HS`        | Warlock Healthstones                                         |
| `Defaults_CombatPot.lua`      | `KCM.SEED.CMBT_POT`  | Offensive combat potions (utility potions excluded)          |
| `Defaults_Flask.lua`          | `KCM.SEED.FLASK`     | Flasks / Alchemist's Concoctions                             |

## Category scope decisions

- **No feasts.** Personal feasts and raid feasts are deliberately excluded from
  `STAT_FOOD`. Users wanting a feast macro can add the item ID manually.
- **No bandages.** Bandage category was considered and cut; first aid is a
  separate workflow.
- **No utility potions** in `CMBT_POT` (invisibility, slow fall, swiftness,
  absorb potions are not throughput).
- **Healthstones** are always listed; on non-warlock characters the bag scan
  simply returns zero count and the macro falls back to its `emptyText`.

## Sources

- **archon.gg** — `Defaults_StatPriority.lua` (Mythic+ "this week" ranking, last
  refreshed 2026-04-21). See the comment header inside that file for the exact
  URL pattern and refresh procedure.
- **Method.gg / Icy Veins** — cross-checks for `Defaults_StatPriority.lua` and
  source for the consumable item-ID seed lists (Midnight 12.0, April 2026).
- **Wowhead** — item database entries for name / quality / tooltip verification.

All IDs should be treated as data, not code — corrections welcome.
