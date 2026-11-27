--[[--
The plugin version, read from _meta.lua so there is one place to bump it.
]]

local function readVersion()
    -- This file's folder is the plugin folder, wherever it is installed
    local source = debug.getinfo(1, "S").source or ""
    local dir = source:match("^@(.*)[/\\]") or "."
    local ok, meta = pcall(dofile, dir .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string" then
        return meta.version
    end
    return "unknown"
end

return readVersion()
