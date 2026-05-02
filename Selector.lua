-- Selector.lua — candidate-set construction, effective priority, and best-owned
-- item picking. Pure over (KCM.SEED, KCM.db.profile.categories, bag state,
-- optional ranking ctx). No Blizzard protected APIs; safe to call in combat.
--
-- Backing data model (see TECHNICAL_DESIGN §4):
--   seed[cat]      : flat array of itemIDs in KCM.SEED[catKey]
--   added[cat]     : set  KCM.db.profile.categories[cat].added[itemID] = true
--   blocked[cat]   : set  KCM.db.profile.categories[cat].blocked[itemID] = true
--   discovered[cat]: map  KCM.db.profile.categories[cat].discovered[itemID] = unixTimestamp
--                    (v1.0.0 stored `true`; reader treats both as "present")
--   pins[cat]      : array of { itemID = X, position = N }
--
-- Spec-aware categories (STAT_FOOD, CMBT_POT, FLASK) swap the four fields for
-- a bySpec[<classID>_<specID>] sub-table holding the same shape.

local KCM = _G.KCM
KCM.Selector = KCM.Selector or {}
local S = KCM.Selector

-- ---------------------------------------------------------------------------
-- Bucket resolution
-- ---------------------------------------------------------------------------
-- Returns the { added, blocked, pins, discovered } table for `catKey`, lazily
-- initializing the spec sub-table for spec-aware categories. `specKey`
-- defaults to the current spec for spec-aware categories; ignored for
-- non-spec-aware categories.
--
-- Returns nil if the category doesn't exist or if a spec-aware category is
-- asked for with no resolvable spec (e.g. low-level character under level 10).

local function emptyBucket()
    return { added = {}, blocked = {}, pins = {}, discovered = {} }
end

function S.GetBucket(catKey, specKey)
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    if not cat then return nil end
    local root = KCM.db and KCM.db.profile and KCM.db.profile.categories
        and KCM.db.profile.categories[catKey]
    if not root then return nil end

    if not cat.specAware then
        -- AceDB defaults guarantee these fields exist, but be defensive.
        root.added      = root.added      or {}
        root.blocked    = root.blocked    or {}
        root.pins       = root.pins       or {}
        root.discovered = root.discovered or {}
        return root
    end

    -- Spec-aware: resolve spec key, lazy-init sub-table.
    if not specKey and KCM.SpecHelper and KCM.SpecHelper.GetCurrent then
        local _, _, key = KCM.SpecHelper.GetCurrent()
        specKey = key
    end
    if not specKey then return nil end

    root.bySpec = root.bySpec or {}
    local bucket = root.bySpec[specKey]
    if not bucket then
        bucket = emptyBucket()
        root.bySpec[specKey] = bucket
    else
        bucket.added      = bucket.added      or {}
        bucket.blocked    = bucket.blocked    or {}
        bucket.pins       = bucket.pins       or {}
        bucket.discovered = bucket.discovered or {}
    end
    return bucket
end

-- ---------------------------------------------------------------------------
-- Candidate set
-- ---------------------------------------------------------------------------
-- Returns an array of itemIDs forming (seed ∪ added ∪ discovered) − blocked.
-- Order inside the returned array is seed-first (stable, by seed order), then
-- added/discovered in numeric order for determinism. Ranking is a separate
-- step — this function's only job is set membership.

function S.BuildCandidateSet(catKey, specKey)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket then return {} end

    local blocked = bucket.blocked or {}
    local seen = {}
    local result = {}

    local function push(id)
        if not id or blocked[id] or seen[id] then return end
        seen[id] = true
        table.insert(result, id)
    end

    local seed = KCM.SEED and KCM.SEED[catKey] or {}
    for _, id in ipairs(seed) do push(id) end

    local extras = {}
    for id in pairs(bucket.added or {}) do table.insert(extras, id) end
    for id in pairs(bucket.discovered or {}) do
        if not bucket.added or not bucket.added[id] then
            table.insert(extras, id)
        end
    end
    table.sort(extras)
    for _, id in ipairs(extras) do push(id) end

    return result
end

-- ---------------------------------------------------------------------------
-- Pin merge
-- ---------------------------------------------------------------------------
-- See TECHNICAL_DESIGN §5.3. Given an auto-ranked list and a pins array of
-- { itemID, position } entries, produce a final list where each pin lands at
-- its requested 1-based position and non-pinned items fill the remaining
-- slots in auto-rank order.
--
-- Rules:
--   - Pins for items not in the candidate set are ignored (set by autoSet).
--   - If two pins collide on the same position, ties are broken by the order
--     they appear in the pins array (stable).
--   - Positions past the end clamp to the last available slot.

local function mergePins(autoRanked, pins)
    if not pins or #pins == 0 then return autoRanked end

    local autoSet = {}
    for _, id in ipairs(autoRanked) do autoSet[id] = true end

    -- Copy + sort pins by position ascending, dropping any pin whose item
    -- isn't a candidate anymore.
    local active = {}
    for i, p in ipairs(pins) do
        if p.itemID and autoSet[p.itemID] and p.position then
            table.insert(active, { itemID = p.itemID, position = p.position, _order = i })
        end
    end
    if #active == 0 then return autoRanked end
    table.sort(active, function(a, b)
        if a.position == b.position then return a._order < b._order end
        return a.position < b.position
    end)

    -- Strip pinned IDs from autoRanked, preserving order.
    local pinnedSet = {}
    for _, p in ipairs(active) do pinnedSet[p.itemID] = true end
    local rest = {}
    for _, id in ipairs(autoRanked) do
        if not pinnedSet[id] then table.insert(rest, id) end
    end

    -- Interleave: fill slot 1..N, inserting a pin when its position matches,
    -- otherwise the next item from `rest`. Pins whose position overshoots are
    -- appended at the end.
    local result = {}
    local pinIdx, restIdx = 1, 1
    local slot = 1
    while slot <= #autoRanked do
        if pinIdx <= #active and active[pinIdx].position == slot then
            table.insert(result, active[pinIdx].itemID)
            pinIdx = pinIdx + 1
        else
            if restIdx <= #rest then
                table.insert(result, rest[restIdx])
                restIdx = restIdx + 1
            else
                -- ran out of non-pinned items; remaining pins go here.
                break
            end
        end
        slot = slot + 1
    end
    -- Overshoot / leftover pins.
    while pinIdx <= #active do
        table.insert(result, active[pinIdx].itemID)
        pinIdx = pinIdx + 1
    end
    -- Leftover rest (shouldn't happen if autoRanked was the union, but guard).
    while restIdx <= #rest do
        table.insert(result, rest[restIdx])
        restIdx = restIdx + 1
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Effective priority
-- ---------------------------------------------------------------------------
-- Full pipeline: candidate set → Ranker.SortCandidates (spec-aware ctx for
-- STAT_FOOD / CMBT_POT / FLASK) → pin merge. Returns an array of itemIDs
-- ordered by effective rank (best first).

function S.GetEffectivePriority(catKey, specKey, scoreCache)
    local cat = KCM.Categories and KCM.Categories.Get and KCM.Categories.Get(catKey)
    if not cat then return {} end

    local bucket = S.GetBucket(catKey, specKey)
    if not bucket then return {} end

    local candidates = S.BuildCandidateSet(catKey, specKey)
    if #candidates == 0 then return {} end

    local ctx
    if cat.specAware and KCM.SpecHelper then
        local key = specKey
        if not key then
            local _, _, cur = KCM.SpecHelper.GetCurrent()
            key = cur
        end
        if key then
            ctx = { specPriority = KCM.SpecHelper.GetStatPriority(key) }
        end
    end

    local sorted = candidates
    if KCM.Ranker and KCM.Ranker.SortCandidates then
        sorted = KCM.Ranker.SortCandidates(catKey, candidates, ctx, scoreCache) or candidates
    end

    return mergePins(sorted, bucket.pins)
end

-- ---------------------------------------------------------------------------
-- Pick best owned
-- ---------------------------------------------------------------------------
-- Walks the effective priority list and returns the first itemID the player
-- has in bags, or nil if none are owned. Bag lookup goes through BagScanner
-- if available, otherwise falls back to C_Item.GetItemCount so the function
-- remains usable in unit tests with a stubbed environment.

function S.PickBestForCategory(catKey, specKey, scoreCache)
    local priority = S.GetEffectivePriority(catKey, specKey, scoreCache)
    if #priority == 0 then return nil end

    local hasItem = KCM.BagScanner and KCM.BagScanner.HasItem
    for _, id in ipairs(priority) do
        if KCM.ID and KCM.ID.IsSpell(id) then
            local spellID = KCM.ID.SpellID(id)
            -- IsPlayerSpell covers class / spec / talent-granted spells; it
            -- is the "do I actually have this" API rather than IsSpellKnown,
            -- which can miss talent-gated abilities.
            if spellID and IsPlayerSpell and IsPlayerSpell(spellID) then
                return id
            end
        elseif hasItem and hasItem(id) then
            return id
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- DB-mutating operations
-- ---------------------------------------------------------------------------
-- All mutations go through GetBucket so spec-aware categories land in the
-- correct bySpec[specKey] sub-table. After any mutation we return true on
-- success so callers (Options UI, slash commands) can chain a recompute.
-- Callers are responsible for invoking KCM.Pipeline.RequestRecompute — these
-- functions stay pure with respect to events to keep them unit-testable.

local function findPinIndex(pins, itemID)
    for i, p in ipairs(pins) do
        if p.itemID == itemID then return i end
    end
    return nil
end

-- Normalize pins to 1..N contiguous positions after a move. Input/output
-- order is the display order; positions are rewritten to 1,2,3,... so that
-- subsequent swaps are unambiguous.
local function renumberPins(pins)
    table.sort(pins, function(a, b) return (a.position or 0) < (b.position or 0) end)
    for i, p in ipairs(pins) do p.position = i end
end

-- Add a user-supplied itemID (or spell sentinel via KCM.ID.AsSpell) to the
-- candidate set. Also clears a blocklist entry if present so the add is
-- always visible. Returns true if either the unblock or the add changed
-- state — callers gate recompute on this, so unblocking a previously-blocked
-- item must return true even when `added[itemID]` was already set.
function S.AddItem(catKey, itemID, specKey)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket or not itemID then return false end
    local changed = false
    if bucket.blocked[itemID] then
        bucket.blocked[itemID] = nil
        changed = true
    end
    if not bucket.added[itemID] then
        bucket.added[itemID] = true
        changed = true
    end
    return changed
end

-- Mark an item as blocked so it's excluded from the candidate set. Also drops
-- any matching pin (a blocked item can't be pinned). Returns true if the
-- block flag was newly set.
function S.Block(catKey, itemID, specKey)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket or not itemID then return false end
    local pinIdx = findPinIndex(bucket.pins, itemID)
    if pinIdx then
        table.remove(bucket.pins, pinIdx)
        renumberPins(bucket.pins)
    end
    if bucket.blocked[itemID] then return false end
    bucket.blocked[itemID] = true
    return true
end

-- Record that an item was seen in bags (auto-discovery). Spells can't be
-- bag-discovered; guard anyway. Blocked items are never promoted to
-- discovered (user intent overrides). The stored value is a unix timestamp
-- used by SweepStaleDiscovered's 30-day TTL; legacy `true` values from v1.0.0
-- are overwritten on next sighting. Returns true only when the entry is
-- newly created — timestamp bumps return false so callers don't trigger a
-- spurious UI refresh on every bag scan.
function S.MarkDiscovered(catKey, itemID, specKey, nowUnix)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket or not itemID then return false end
    if KCM.ID and KCM.ID.IsSpell(itemID) then return false end
    if bucket.blocked[itemID] then return false end
    nowUnix = nowUnix or time()
    local current = bucket.discovered[itemID]
    if current == nil then
        bucket.discovered[itemID] = nowUnix
        return true
    end
    -- Legacy `true` or an older timestamp → bump to now. Idempotent for
    -- already-current entries so we don't dirty SavedVariables every scan.
    if current == true or (type(current) == "number" and current < nowUnix) then
        bucket.discovered[itemID] = nowUnix
    end
    return false
end

-- TTL garbage collection for `discovered` entries. Called from PEW after
-- auto-discovery and before the first recompute (see Core.lua). Items still
-- in bags have their timestamp bumped to now; otherwise entries older than
-- DISCOVERED_TTL_SEC are deleted. `added` and `blocked` are user-intentional
-- and never touched here.
local DISCOVERED_TTL_SEC = 30 * 86400

local function sweepBucket(bucket, bagCounts, nowUnix, cutoff)
    if not (bucket and bucket.discovered) then return 0 end
    local swept = 0
    for id, value in pairs(bucket.discovered) do
        if bagCounts[id] and bagCounts[id] > 0 then
            bucket.discovered[id] = nowUnix
        else
            local staleTs = (value == true) and 0 or (type(value) == "number" and value or 0)
            if staleTs < cutoff then
                bucket.discovered[id] = nil
                swept = swept + 1
            end
        end
    end
    return swept
end

function S.SweepStaleDiscovered(nowUnix)
    if not (KCM.db and KCM.db.profile and KCM.db.profile.categories) then
        return 0, 0
    end
    nowUnix = nowUnix or time()
    local cutoff = nowUnix - DISCOVERED_TTL_SEC
    local bagCounts = (KCM.BagScanner and KCM.BagScanner.Scan and KCM.BagScanner.Scan()) or {}
    local totalSwept, touchedCats = 0, 0
    for _, root in pairs(KCM.db.profile.categories) do
        local catSwept = 0
        if root.bySpec then
            for _, specBucket in pairs(root.bySpec) do
                catSwept = catSwept + sweepBucket(specBucket, bagCounts, nowUnix, cutoff)
            end
        else
            catSwept = catSwept + sweepBucket(root, bagCounts, nowUnix, cutoff)
        end
        if catSwept > 0 then
            totalSwept = totalSwept + catSwept
            touchedCats = touchedCats + 1
        end
    end
    if KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("GC: swept %d entries across %d categories", totalSwept, touchedCats)
    end
    return totalSwept, touchedCats
end

-- Internal helper: given the current effective priority and a direction (-1
-- for up, +1 for down), swap `itemID` with its neighbor by emitting pins at
-- the new positions. If the item isn't in the priority list, no-op.
local function movePinned(catKey, itemID, delta, specKey)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket or not itemID then return false end

    local priority = S.GetEffectivePriority(catKey, specKey)
    local curIdx
    for i, id in ipairs(priority) do
        if id == itemID then curIdx = i; break end
    end
    if not curIdx then return false end

    local newIdx = curIdx + delta
    if newIdx < 1 or newIdx > #priority then return false end

    -- Strategy: rebuild the pins array as the full re-ordered priority list
    -- with the two affected slots swapped. This is O(N) but N <= ~30 per
    -- category and only runs on explicit user reorder clicks. It guarantees
    -- deterministic behaviour regardless of how ranker scores break ties.
    priority[curIdx], priority[newIdx] = priority[newIdx], priority[curIdx]
    local newPins = {}
    for i, id in ipairs(priority) do
        table.insert(newPins, { itemID = id, position = i })
    end
    bucket.pins = newPins
    return true
end

function S.MoveUp(catKey, itemID, specKey)
    return movePinned(catKey, itemID, -1, specKey)
end

function S.MoveDown(catKey, itemID, specKey)
    return movePinned(catKey, itemID, 1, specKey)
end
