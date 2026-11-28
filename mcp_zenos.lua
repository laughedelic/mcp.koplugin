--[[
    Optional integration with ZenOS (https://github.com/xZenLabs/zen-os),
    a KOReader UI plugin.

    ZenOS publishes a small API for other plugins as globals. This module only
    uses that API when it is there: on plain KOReader every function here is a
    no-op, so the plugin behaves exactly as before.

    What it adds under ZenOS:
    - An "MCP server" item for the Library status bar
      (Zen Settings > Interface > Status bar). It shows while the server runs.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

local STATUS_ITEM_KEY = "mcp"

local status_fetch = nil
local status_registered = false

-- Current and legacy (Zen UI) names of the same ZenOS functions
local function zenos_function(...)
    for i = 1, select("#", ...) do
        local fn = rawget(_G, (select(i, ...)))
        if type(fn) == "function" then
            return fn
        end
    end
end

local function register_status_item()
    local register = zenos_function("__ZENOS_REGISTER_STATUS_ITEM", "__ZEN_UI_REGISTER_STATUS_ITEM")
    if not register or not status_fetch then
        return false
    end
    local ok, result = pcall(register, STATUS_ITEM_KEY, status_fetch, {
        label = _("MCP server"),
        side = "right",
    })
    if not ok then
        logger.warn("MCP: ZenOS status item registration failed:", result)
        return false
    end
    return result ~= false
end

-- Offer a status bar item to ZenOS.
-- @param fetch function returning the text to show, or nil to hide the item
function M.registerStatusItem(fetch)
    status_fetch = fetch
    if status_registered then
        return true
    end
    status_registered = register_status_item()
    if status_registered then
        logger.info("MCP: Registered ZenOS status bar item")
    end
    return status_registered
end

-- Redraw the ZenOS status bar after the server state changed.
-- ZenOS refreshes its bar whenever an item is registered, so registering the
-- same item again is the public way to ask for a redraw.
function M.refresh()
    if status_registered then
        register_status_item()
    end
end

return M
