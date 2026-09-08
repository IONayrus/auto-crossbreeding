local gps = require("gps")
local action = require("action")
local database = require("database")
local scanner = require("scanner")
local posUtil = require("posUtil")
local config = require("config")

local function init()
    database.scanStorage()
    action.restockAll()
    action.resetBinder()
end

local function main()
    init()
    for slot = 1, config.farmArea, 1 do
        gps.go(posUtil.farmToGlobal(slot))
        local crop = scanner.scan()
        if crop.name~="air" then
            if crop.isCrop then
                action.transplant(posUtil.farmToGlobal(slot), posUtil.storageToGlobal(database.nextStorageSlot()))
                database.addToStorage(crop)
            end
        end
        if action.needCharge() then
            action.charge()
        end
    end
    action.disarmBinder()
    gps.go({0,0})
end

main()
