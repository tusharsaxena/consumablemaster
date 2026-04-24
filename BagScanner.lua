-- BagScanner.lua — Enumerate bag contents into { [itemID] = count }.
--
-- Retail API: C_Container.GetContainerNumSlots(bag) and
-- C_Container.GetContainerItemInfo(bag, slot). Bags range from 0
-- (backpack) through NUM_TOTAL_EQUIPPED_BAG_SLOTS (reagent bag on Midnight).
-- We defensively fall back to NUM_BAG_SLOTS or 5 if the constant is missing.
--
-- The scanner is intentionally stateless per-call: callers (the Pipeline in
-- M5) run Scan() once per recompute and pass the result to Selector. If we
-- find a perf problem later, memoization with a dirty flag driven by
-- BAG_UPDATE_DELAYED can be bolted on — no API change needed.

local KCM = _G.KCM
KCM.BagScanner = KCM.BagScanner or {}
local BS = KCM.BagScanner

local function maxBagIndex()
    -- Midnight exposes the reagent bag slot via NUM_TOTAL_EQUIPPED_BAG_SLOTS.
    -- Backpack is bag 0, so iterate 0..N inclusive.
    return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 5
end

-- Returns { [itemID] = totalCount } aggregated across all bags.
function BS.Scan()
    local counts = {}
    local getNum = C_Container and C_Container.GetContainerNumSlots
    local getInfo = C_Container and C_Container.GetContainerItemInfo
    if not (getNum and getInfo) then
        return counts
    end

    for bag = 0, maxBagIndex() do
        local slots = getNum(bag) or 0
        for slot = 1, slots do
            local info = getInfo(bag, slot)
            -- Locked items (mailing, splitting, equipping) are still owned;
            -- excluding them causes transient macro flap on stack-lock events.
            if info and info.itemID then
                local id = info.itemID
                local stack = info.stackCount or 1
                counts[id] = (counts[id] or 0) + stack
            end
        end
    end

    return counts
end

-- O(1) single-item lookup via Blizzard's own bag tally. Called hundreds of
-- times during the first-panel-open GET_ITEM_INFO_RECEIVED burst, so the
-- previous full-Scan fallback would have made that burst O(N*bags*slots).
function BS.HasItem(itemID)
    if not itemID then return false, 0 end
    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID, false, false, true) or 0
    return count > 0, count
end

-- Flat array of itemIDs currently in bags. Convenient for iteration; callers
-- needing counts should use Scan() directly.
function BS.GetAllItemIDs()
    local ids = {}
    for id in pairs(BS.Scan()) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end
