local gps = require("gps")
local action = require("action")
local database = require("database")
local scanner = require("scanner")
local posUtil = require("posUtil")
local config = require("config")
local status = require("status")

local args = {...}
local nonstop = false
local docleanup = false
local fill = false
local farm = false
local farmCount = 256

if #args >= 1 then
    if args[1] == "docleanup" then
        docleanup = true
    elseif args[1] == "nonstop" then
        nonstop = true
    elseif args[1] == "fill" then
        fill = true
    elseif args[1] == "farm" then
        farm = true
        if #args == 2 then
            farmCount = args[2]
        end
    end
end

-- stat = growth + gain - resistance; 52 = 21 + 31 - 0 is the maximum
local MAX_STAT = 52
-- breeding and fill stop once every tracked slot reaches config.targetStat,
-- the farm mode always requires perfect parents
local targetStat = config.targetStat or 50
if farm then targetStat = MAX_STAT end
-- stat assigned to a slot that holds no crop (air / bare stick / unknown)
local EMPTY_STAT = -100

local lowestStat;
local lowestStatSlot;
local workingCrop;
local filling = false
local farming = false
local round = 0
-- status area: line 1 progress, line 2 lowest slot, remaining lines histogram
local STATUS_LINES = 4

local function cropStat(crop)
    return crop.gr+crop.ga-crop.re
end

local function isEmptySlot(crop)
    return crop == nil or crop.name == 'crop' or crop.name == 'air' or crop.gr == nil
end

local function modeName()
    if farming then
        return "farming"
    elseif filling then
        return "filling"
    else
        return "breeding"
    end
end

-- status line 1: mode, round and the slot the robot is working on
local function showProgress(slot)
    status.set(1, string.format("autoStat %s  round %d  slot %d/%d",
        modeName(), round, slot or 0, config.farmArea))
end

-- join parts with sep into lines of at most width characters
local function wrapParts(parts, sep, width)
    local lines = {}
    local current = ""
    for _, part in ipairs(parts) do
        if current == "" then
            current = part
        elseif #current + #sep + #part <= width then
            current = current .. sep .. part
        else
            lines[#lines+1] = current
            current = part
        end
    end
    if current ~= "" then
        lines[#lines+1] = current
    end
    return lines
end

-- "50: 10 | 51: 15 | 52 (MAX): 11 | empty: 2", or in compact form
-- "50:10 51:15 52(MAX):11 E:2" when the wide form does not fit
local function histogramParts(values, counts, empty, compact)
    local parts = {}
    for _, stat in ipairs(values) do
        local label = tostring(stat)
        if stat == MAX_STAT then
            if compact then label = label .. "(MAX)" else label = label .. " (MAX)" end
        end
        if compact then
            parts[#parts+1] = label .. ":" .. counts[stat]
        else
            parts[#parts+1] = label .. ": " .. counts[stat]
        end
    end
    if empty > 0 then
        if compact then
            parts[#parts+1] = "E:" .. empty
        else
            parts[#parts+1] = "empty: " .. empty
        end
    end
    return parts
end

-- status line 2: lowest tracked slot; lines 3..STATUS_LINES: histogram of all
-- tracked crops, wrapped over the available lines
local function showStats()
    local lowestText = tostring(lowestStat)
    if lowestStat < 0 then lowestText = "empty" end
    status.set(2, string.format("lowest: %s @ slot %d  target: %d",
        lowestText, lowestStatSlot, targetStat))

    local farm = database.getFarm()
    local counts = {}
    local values = {}
    local empty = 0
    local step = 2
    if filling then step = 1 end
    for slot = 1, config.farmArea, step do
        local crop = farm[slot]
        if isEmptySlot(crop) then
            empty = empty + 1
        else
            local stat = cropStat(crop)
            if counts[stat] == nil then
                counts[stat] = 0
                values[#values+1] = stat
            end
            counts[stat] = counts[stat] + 1
        end
    end
    table.sort(values)

    local width = status.getWidth()
    if width < 10 then width = 50 end
    local histLines = STATUS_LINES - 2
    local lines = wrapParts(histogramParts(values, counts, empty, false), " | ", width)
    if #lines > histLines then
        lines = wrapParts(histogramParts(values, counts, empty, true), "  ", width)
    end
    for i = 1, histLines do
        local text = lines[i] or ""
        if i == histLines and #lines > histLines then
            -- still too much: mark the cut
            text = string.sub(text, 1, width - 3) .. "..."
        end
        status.set(2 + i, text)
    end
end

local function updateLowest()
    lowestStat = 64
    lowestStatSlot = 0
    local farm = database.getFarm()
    local workingCropName = farm[1].name
    local step = 2
    if filling then step = 1 end
    for slot = 1, config.farmArea, step do
        local crop = farm[slot]
        local stat
        if isEmptySlot(crop) then
            -- an empty slot has to be filled first, any crop beats it
            -- (empty parent slots get priority over empty offspring slots)
            stat = EMPTY_STAT
            if slot % 2 == 1 then stat = stat - 1 end
        else
            stat = cropStat(crop)
            if crop.name ~= workingCropName then
                stat = stat - 10
            end
        end
        if stat < lowestStat then
            lowestStat = stat
            lowestStatSlot = slot
        end
    end
    showStats()
end

local function findSuitableFarmSlot(crop)
    if cropStat(crop) > lowestStat then
        return lowestStatSlot
    else
        return 0
    end
end

local function isWeed(crop)

    return crop.name == "weed" or 
        crop.name == "Grass" or
        --(crop.gr > 21 and (not filling or not farming)) or crop.gr > 23 or
        crop.gr > 21 or
        (crop.name == "venomilia" and crop.gr > 7);
end

-- fill mode: keep good offspring where they grew (or move them into an
-- empty parent slot), destroy everything else.
local function fillOffspring(slot, crop)
    if cropStat(crop) < targetStat then
        action.deweed()
        action.placeCropStick()
        return
    end
    if lowestStat < EMPTY_STAT then
        -- a parent slot is empty (e.g. it got weeded), refill it first
        action.transplant(posUtil.farmToGlobal(slot), posUtil.farmToGlobal(lowestStatSlot))
        action.placeCropStick(2)
        database.updateFarm(lowestStatSlot, crop)
    else
        -- keep the crop in place and remember it, so the slot counts as filled
        database.updateFarm(slot, crop)
    end
    updateLowest()
end

local function checkOffspring(slot, crop)
    if crop.name == "air" then
        action.placeCropStick(2)
    elseif (not config.assumeNoBareStick) and crop.name == "crop" then
        action.placeCropStick()
    elseif crop.isCrop then
        if isWeed(crop) then
            action.deweed()
            action.placeCropStick()
        elseif crop.name == workingCrop then
            if farming then
                if crop.size == crop.maxSize or config.focusBreedingAtFarming then
                    action.farmSeed()
                    action.placeCropStick(2)
                end
                return 0
            end
            if filling then
                fillOffspring(slot, crop)
                return 0
            end
            local suitableSlot = findSuitableFarmSlot(crop)
            if suitableSlot == 0 then
                action.deweed()
                action.placeCropStick()
            else
                action.transplant(posUtil.farmToGlobal(slot), posUtil.farmToGlobal(suitableSlot))
                action.placeCropStick(2)
                database.updateFarm(suitableSlot, crop)
                updateLowest()
            end
        elseif config.keepNewCropWhileMinMaxing and (not database.existInStorage(crop)) then
            action.transplant(posUtil.farmToGlobal(slot), posUtil.storageToGlobal(database.nextStorageSlot()))
            action.placeCropStick(2)
            database.addToStorage(crop)
        else
            action.deweed()
            action.placeCropStick()
        end
    end
end

local function checkParent(slot, crop)
    if crop.isCrop and isWeed(crop) then
        action.deweed();
        if farming or filling then
            action.placeCropStick()
            database.updateFarm(slot, {name="crop"})
        else
            action.farmSeed()
            database.updateFarm(slot, {name="crop"})
        end
        updateLowest();
    end
end

local function breedOnce()
    -- return true if all slots reached the target stat
    if not nonstop and lowestStat >= targetStat and not farming then
        return true
    end

    round = round + 1
    for slot=1, config.farmArea, 1 do
        gps.go(posUtil.farmToGlobal(slot))
        showProgress(slot)
        local crop = scanner.scan()

        if (slot % 2 == 0) then
            checkOffspring(slot, crop);
        else
            checkParent(slot, crop);
        end
        
        if action.needCharge() then
            action.charge()
        end

        if farming and (action.getStickCount() >= farmCount) then
            return true
        end
    end
    return false
end

local function init()
    status.init(STATUS_LINES)
    database.scanFarm()
    if config.keepNewCropWhileMinMaxing then
        database.scanStorage()
    end

    workingCrop = database.getFarm()[1].name;

    print("Maxing the stats of " ..workingCrop.. "...")

    updateLowest()
    action.restockAll()
    action.resetBinder()
end

local function main()
    init()
    while not breedOnce() do
        gps.go({0,0})
        action.restockAll()
    end
    gps.go({0,0})
    if docleanup then
        action.destroyAll()
        gps.go({0,0})
    elseif fill then
        print("Parent crops are now 21/31/0.\nFilling the farm...")
        filling = true
        round = 0
        -- offspring slots start out empty, they are tracked from here on
        for slot = 2, config.farmArea, 2 do
            database.updateFarm(slot, nil)
        end
        updateLowest()
        while not breedOnce() do
            gps.go({0,0})
            action.restockAll()
        end
        gps.go({0,0})
    elseif farm then
        print("Parent crops are now 21/31/0.\nFarming seeds with " .. farmCount .. " cropsticks...")
        farmCount = tonumber(farmCount)
        action.resetStickCounter()
        farming = true
        round = 0
        while not breedOnce() do
            gps.go({0,0})
            action.restockAll()
        end
        gps.go({0,0})
        action.destroyAll()
        gps.go({0,0})
    end
    -- leave the binder neutral for the next program start
    action.disarmBinder()
    if config.takeCareOfDrops then
        action.dumpInventory()
    end
    gps.turnTo(1)
    print("Done.\nAll crops are now 21/31/0")
    status.set(1, "autoStat done")
    status.close()
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    status.close()
    err = tostring(err)
    local f = io.open("/home/autoStat.err", "w")
    if f then
        f:write(err, "\n")
        f:close()
    end
    io.stderr:write(err, "\n(saved to /home/autoStat.err)\n")
end
