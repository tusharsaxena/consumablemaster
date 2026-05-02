# Scope

What's in scope, what's out, and the resolved decisions that shaped the contract. The contract itself (macro behavior, slash UX, settings panel) is documented in [README.md](../README.md) — this doc records the *boundary* decisions so a fresh contributor can tell whether a feature request is in or out of scope without re-litigating it.

## In scope

- **Account-wide consumable macros** — eight single-pick categories (FOOD, DRINK, HP_POT, MP_POT, HS, FLASK, CMBT_POT, STAT_FOOD) plus two combat-conditional composites (HP_AIO, MP_AIO). Identified by name, never by slot.
- **Auto-rewriting macro bodies** based on bag contents, spec, and a per-category scorer.
- **Spec-aware ranking** for FLASK / CMBT_POT / STAT_FOOD against per-spec stat priority (primary + ordered secondary).
- **Spell entries** (e.g. Recuperate as a Food entry) via opaque-numeric IDs (positive = item, negative = spell sentinel).
- **Settings panel** integrated into Blizzard's AddOns settings + matching `/cm` slash CLI for every panel-shaped operation.
- **Auto-discovery** from bag scans, bounded by a 30-day stale-discovered sweep.
- **Combat-deferred writes** with bounded retry on flush.

## Out of scope

These have been considered and explicitly declined. A change of heart needs an issue + design discussion, not a stealth PR.

- **Localization.** English only. Classifier compares item subTypes against literal English strings (`"Potions"`, `"Flasks & Phials"`, etc.) and tooltip parsing uses English patterns. Localization plumbing is a deliberate non-goal.
- **Per-character macros.** Everything is account-wide. Per-character profiles aren't needed for the addon's purpose; AceDB is configured with a single account-wide profile by default.
- **Per-encounter / per-boss priorities.** No fight-specific lists.
- **Auto-buying consumables from vendors.** No vendor automation.
- **Cauldrons / phials / weapon oils / augment runes** as separate categories. Phials are absorbed into FLASK by subtype (`"Flasks & Phials"`). Cauldrons / weapon oils / augment runes don't have a managed macro.
- **Bandages.** First aid is a separate workflow; not relevant to current Midnight endgame.
- **Profile import/export.** Settings live in `ConsumableMasterDB` per-account; no serialization layer.
- **LDB / minimap icon.**
- **Drag-and-drop reordering** of priority list rows. The ↑ / ↓ buttons are simpler with AceConfig.
- **Shopping-list / restock reminders.**
- **Feasts** in `STAT_FOOD`. Personal feasts and ground feasts are excluded from the seed; users wanting a feast macro can add the item ID manually.
- **Utility potions** in `CMBT_POT`. Invisibility, slow fall, swiftness, absorb potions are not throughput buffs and don't belong in the combat-pot macro.

## Resolved decisions

Decisions made during requirements review and v1.0.0 launch — these are settled, not open.

- **Spec key shape.** `<classID>_<specID>` numeric pair. UI displays human-readable names (e.g. "Shaman — Enhancement"); persistence uses the numeric form so it's locale-independent.
- **AceDB profile model.** Single account-wide profile. No profile switcher.
- **Macro adoption.** If a `KCM_*`-named macro pre-exists when the addon first runs, the addon adopts it (rewrites the body on next event). The addon never renames user macros and never calls `DeleteMacro` on a `KCM_*` slot.
- **Reset confirmation.** Blizzard `StaticPopupDialogs` yes/no popup, registered with `preferredIndex = 3` to dodge the popup-slot taint cascade that affects slots 1 / 2 when other addons have used them earlier in the session.
- **Conjured / vendor food handling.** The candidate set is built dynamically via the classifier (subType + tooltip) and ordered by the ranker (parsed heal/mana, ilvl, quality, conjured bonus). Defaults ship a known-good seed; auto-discovery handles new items. No static "small seed list" approach.
- **Cyan `[CM]` chat prefix.** All addon chat output goes through the `say()` helper in `SlashCommands.lua` and wears the cyan `|cff00ffff[CM]|r` tag. Raw `print(...)` calls are banned.

## Where the contract lives

- User-facing behavior: [README.md](../README.md) — macro categories, slash commands, FAQ, troubleshooting.
- Engineer working notes: [../CLAUDE.md](../CLAUDE.md) — hard rules, response style, working environment.
- Module map + invariants: [../ARCHITECTURE.md](../ARCHITECTURE.md).
