local component = require("component")

local gpu
local term
local width, height = 0, 0
local lines = 0
local enabled = false

local function init(lineCount)
    lines = lineCount or 3
    enabled = false
    if not component.isAvailable("gpu") then
        return false
    end
    local ok = pcall(function()
        gpu = component.gpu
        term = require("term")
        width, height = gpu.getResolution()
        if height <= lines then
            error("screen too small")
        end
        if term.setViewport then
            -- print() scrolls inside this viewport only
            term.setViewport(width, height - lines, 0, 0)
            -- move the cursor into the viewport if it is already below
            local _, cy = term.getCursor()
            if cy > height - lines then
                term.setCursor(1, height - lines)
            end
        end
        gpu.fill(1, height - lines + 1, width, lines, " ")
    end)
    enabled = ok
    return enabled
end

-- overwrite status line i (1 = top status line) with text
local function set(i, text)
    if not enabled or i < 1 or i > lines then
        return
    end
    pcall(function()
        local y = height - lines + i
        gpu.fill(1, y, width, 1, " ")
        gpu.set(1, y, string.sub(tostring(text), 1, width))
    end)
end

-- give the full screen back to the terminal; the last status lines stay visible
local function close()
    if not enabled then
        return
    end
    pcall(function()
        if term.setViewport then
            term.setViewport(width, height, 0, 0)
        end
    end)
    enabled = false
end

local function getWidth()
    return width
end

return {
    init = init,
    set = set,
    close = close,
    getWidth = getWidth
}
