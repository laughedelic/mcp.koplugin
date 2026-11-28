--[[
    Offline memory: keeping the relay's saved copy up to date

    Optional, and off by default. When the user turns it on, the reader sends
    the relay a snapshot of the open book (see mcp_snapshot.lua), so connected
    AI apps can still answer questions while the reader is asleep or away. The
    relay encrypts the snapshot for the connected apps and deletes it after
    the retention time.

    This module decides when to send:
    - a little after the user turns a page or changes a highlight, at most
      once a minute;
    - when the book is closed, and just before the reader sleeps or the MCP
      server stops;
    - when WiFi comes back, if something changed meanwhile.
    It also runs while the MCP server is off, as long as the device has
    registered with the relay once. It never turns WiFi on.

    One instance is shared by all plugin instances (reader and file browser).
--]]

local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Snapshot = require("mcp_snapshot")

local Memory = {
    -- Timing, in seconds
    SETTLE_DELAY = 20,       -- from the first change to the save (page flipping settles)
    PUSH_INTERVAL = 60,      -- least time between two saves while reading
    QUICK_INTERVAL = 16,     -- least time between two saves at all (the relay asks for 15)
    RETRY_INTERVAL = 300,    -- after a failed save
    NETWORK_RECHECK = 600,   -- while offline, look for a connection at most this often
    BLOCKING_TIMEOUT = 4,    -- for the whole request, when saving just before sleep
    EXTRACT_BUDGET = 0.4,    -- most time spent reading page text for one save

    DEFAULT_RETENTION_DAYS = 30,
    RETENTION_CHOICES = { 1, 7, 30 },

    -- Wiring (see setup)
    relay = nil,
    tools = nil,
    is_remote_mode = nil,
    on_change = nil,

    -- State
    dirty = false,            -- something changed since the last save
    generation = 0,           -- counts changes, to notice ones made during a save
    in_flight = false,
    push_task = nil,
    last_push_at = 0,
    last_fingerprint = nil,
    blocked = nil,            -- message: saving can't work until the device registers again
    waiting_for_network = false,
    network_checked_at = 0,
    page_cache = nil,         -- { key = "<file>|<pages>", pages = { [n] = text or false } }
}

--------------------------------------------------------------------------------
-- Setup and settings
--------------------------------------------------------------------------------

-- @param o table: relay (MCPRelay), tools (MCPTools), is_remote_mode (function),
--        on_change (function, called when the status shown in the menu changes)
function Memory:setup(o)
    self.relay = o.relay
    self.tools = o.tools
    self.is_remote_mode = o.is_remote_mode
    self.on_change = o.on_change
end

-- "position", "pages", or nil when offline memory is off
function Memory:getScope()
    local scope = G_reader_settings:readSetting("mcp_memory_scope")
    if scope == "position" or scope == "pages" then
        return scope
    end
    return nil
end

function Memory:isOn()
    return self:getScope() ~= nil
end

-- What the relay offers ({maxBytes, maxRetentionDays}), as of the last registration
function Memory:getLimits()
    local limits = G_reader_settings:readSetting("mcp_memory_limits")
    if type(limits) == "table" and type(limits.maxBytes) == "number" and limits.maxBytes > 0 then
        return limits
    end
    return nil
end

function Memory:getRetentionDays()
    local days = G_reader_settings:readSetting("mcp_memory_retention_days", self.DEFAULT_RETENTION_DAYS)
    if type(days) ~= "number" or days <= 0 then
        days = self.DEFAULT_RETENTION_DAYS
    end
    local limits = self:getLimits()
    if limits and type(limits.maxRetentionDays) == "number" then
        days = math.min(days, limits.maxRetentionDays)
    end
    return days
end

function Memory:setRetentionDays(days)
    G_reader_settings:saveSetting("mcp_memory_retention_days", days)
    self:markChanged()
end

-- { saved_at, page, scope, result = "stored" | "no_apps" | "error" | "delete_pending", message }
function Memory:getStatus()
    local status = G_reader_settings:readSetting("mcp_memory_status")
    return type(status) == "table" and status or nil
end

function Memory:setStatus(status)
    if status then
        G_reader_settings:saveSetting("mcp_memory_status", status)
    else
        G_reader_settings:delSetting("mcp_memory_status")
    end
    if self.on_change then
        pcall(self.on_change)
    end
end

function Memory:credentials()
    local relay = self.relay
    if not relay or not relay.device_id or not relay.device_secret then
        return nil
    end
    return { relay_url = relay.relay_url, device_id = relay.device_id, device_secret = relay.device_secret }
end

-- On, offered by the relay, and the device has credentials to save with
function Memory:isActive()
    return self:isOn()
        and self:getLimits() ~= nil
        and (not self.is_remote_mode or self.is_remote_mode())
        and self:credentials() ~= nil
end

-- Whether the network is up. Never turns WiFi on.
function Memory:online()
    self.network_checked_at = os.time()
    local ok, connected = pcall(function()
        return NetworkMgr:isWifiOn() and NetworkMgr:isConnected()
    end)
    self.waiting_for_network = not (ok and connected)
    return ok and connected and true or false
end

--------------------------------------------------------------------------------
-- When to save
--------------------------------------------------------------------------------

-- Something a snapshot holds has changed (page turned, highlight edited, book opened)
function Memory:markChanged()
    if not self:isOn() then
        return
    end
    self.dirty = true
    self.generation = self.generation + 1
    -- While offline, the "network connected" event brings us back; this is
    -- only a slow fallback for platforms that don't send it
    if self.waiting_for_network and os.time() - self.network_checked_at < self.NETWORK_RECHECK then
        return
    end
    self:schedule(self.SETTLE_DELAY)
end

-- Highlights changed: page text carries them inline, so it must be read again
function Memory:annotationsChanged()
    self.page_cache = nil
    self:markChanged()
end

-- The book was laid out again (font, margins): page numbers mean something else now
function Memory:layoutChanged()
    self.page_cache = nil
    self:markChanged()
end

function Memory:cancelScheduled()
    if self.push_task then
        UIManager:unschedule(self.push_task)
        self.push_task = nil
    end
end

-- Save in `delay` seconds, but no sooner than `gap` seconds after the last save
function Memory:schedule(delay, gap)
    if self.push_task or not self:isActive() or self.blocked then
        return
    end
    local since_last = os.time() - self.last_push_at
    local wait = math.max(delay or 0, (gap or self.PUSH_INTERVAL) - since_last, 1)
    self.push_task = function()
        self.push_task = nil
        if self.dirty then
            self:push()
        end
    end
    UIManager:scheduleIn(wait, self.push_task)
end

--------------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------------

-- Read the text of the pages around `page` into the cache, nearest first,
-- for at most EXTRACT_BUDGET seconds. Scanned books can take a while per
-- page, and this runs on the UI thread; what doesn't fit is read next time.
-- @return true if every page in the window is in the cache
function Memory:warmPageCache(ui, page, page_count)
    local key = tostring(ui.document.file) .. "|" .. tostring(page_count)
    if not self.page_cache or self.page_cache.key ~= key then
        self.page_cache = { key = key, pages = {} }
    end
    local pages = self.page_cache.pages
    local first = math.max(1, page - Snapshot.PAGES_BEFORE)
    local last = math.min(page_count, page + Snapshot.PAGES_AFTER)

    -- Forget pages well outside the window
    for number in pairs(pages) do
        if number < first - 5 or number > last + 5 then
            pages[number] = nil
        end
    end

    -- Nearest first: the current page, then alternating ahead and behind
    local order = { page }
    for distance = 1, math.max(Snapshot.PAGES_BEFORE, Snapshot.PAGES_AFTER) do
        if page + distance <= last then table.insert(order, page + distance) end
        if page - distance >= first then table.insert(order, page - distance) end
    end

    local started = socket.gettime()
    local complete = true
    for _, number in ipairs(order) do
        if pages[number] == nil then
            if socket.gettime() - started > self.EXTRACT_BUDGET then
                complete = false
                break
            end
            local ok, text = pcall(function()
                return self.tools:getPageTextWithHighlights(number)
            end)
            pages[number] = ok and type(text) == "string" and text ~= "" and text or false
        end
    end
    return complete
end

--[[
    Build and send a snapshot now.
    @param options optional table:
      blocking: wait for the relay (short timeout), for use right before sleep
      leaving: tell the relay the reader is going away after this
    @return true if a snapshot was sent (or is on its way)
--]]
function Memory:push(options)
    options = options or {}
    if not self:isActive() or self.blocked then
        return false
    end
    local ui = self.tools and self.tools.ui
    if not ui or not ui.document then
        -- No book open: what is saved stays as it is
        return false
    end
    if self.in_flight then
        -- The save under way looks at `dirty` when it finishes
        return false
    end
    if not self:online() then
        return false
    end

    local limits = self:getLimits()
    local scope = self:getScope()
    local retention_days = self:getRetentionDays()
    local build_options = { scope = scope, retention_days = retention_days }

    local complete = true
    if scope == "pages" then
        local doc = ui.document
        local ok, result = pcall(function()
            return self:warmPageCache(ui, doc:getCurrentPage(), doc:getPageCount())
        end)
        complete = ok and result or false
        local cached = self.page_cache and self.page_cache.pages or {}
        build_options.page_text = function(number)
            return cached[number] or nil
        end
    end

    local fingerprint = Snapshot.fingerprint(ui, build_options)
    if complete and fingerprint == self.last_fingerprint then
        self.dirty = false
        return false
    end

    local ok_build, snapshot = pcall(Snapshot.build, ui, build_options)
    if not ok_build or not snapshot then
        logger.warn("MCP Memory: Could not build a snapshot:", snapshot)
        return false
    end
    local body = Snapshot.encode(snapshot, limits.maxBytes)
    if not body then
        self:setStatus({ result = "error", message = "The book's details don't fit into the relay's size limit." })
        self.dirty = false
        return false
    end

    local generation = self.generation
    local page = snapshot.position.page
    local credentials = self:credentials()
    self.last_push_at = os.time()
    self.in_flight = not options.blocking
    logger.dbg("MCP Memory: Saving a snapshot,", #body, "bytes, page", page)

    self.relay:detachedDeviceRequest("PUT", "/snapshot", body, function(ok, data, code)
        self.in_flight = false
        self:onPushResult(ok, data, code, {
            generation = generation,
            fingerprint = complete and fingerprint or nil,
            page = page,
            scope = scope,
            final = options.blocking,
            credentials = credentials,
        })
    end, {
        credentials = credentials,
        blocking = options.blocking,
        timeout = options.blocking and self.BLOCKING_TIMEOUT or 30,
        headers = options.leaving and { ["X-Reader-Leaving"] = "1" } or nil,
    })
    return true
end

function Memory:onPushResult(ok, data, code, sent)
    -- Turned off, or the device ID was reset, while this save was under way:
    -- what it stored must go again
    local current = self:credentials()
    local same_device = current and sent.credentials
        and current.device_id == sent.credentials.device_id
        and current.relay_url == sent.credentials.relay_url
    if not self:isOn() or not same_device then
        if ok and sent.credentials then
            G_reader_settings:saveSetting("mcp_memory_pending_delete", sent.credentials)
            self:processPendingDelete()
        end
        return
    end

    if ok then
        local stored = type(data) == "table" and data.stored ~= false
        if stored then
            self.last_fingerprint = sent.fingerprint
            if sent.generation == self.generation and sent.fingerprint then
                self.dirty = false
            end
        else
            -- No connected app could read it yet, so the relay kept nothing.
            -- Sent again once an app connects (or on the next change).
            self.last_fingerprint = nil
            self.dirty = false
        end
        self:setStatus({
            saved_at = os.time(),
            page = sent.page,
            scope = sent.scope,
            result = stored and "stored" or "no_apps",
        })
        if not sent.final and (self.dirty or (stored and not sent.fingerprint)) then
            -- Changed during the save, or some page text is still to be read
            self.dirty = true
            self:schedule(0)
        end
        return
    end

    logger.warn("MCP Memory: Saving failed:", data, code)
    if code == 401 or code == 410 then
        -- The relay doesn't know this device or its secret (any more).
        -- Registering again (starting the MCP server) sorts that out.
        self.blocked = "Start the MCP server once to set up the saved copy."
        self:setStatus({ result = "error", message = self.blocked })
    elseif code == 403 then
        -- The relay has turned offline memory off
        G_reader_settings:delSetting("mcp_memory_limits")
        self:setStatus({ result = "error", message = "This relay no longer offers offline memory." })
    elseif code == 413 or code == 400 then
        self:setStatus({ result = "error", message = tostring(data) })
        self.dirty = false
    elseif not sent.final then
        -- Too soon after the last one (429), or a network problem: try later
        self:schedule(code == 429 and self.QUICK_INTERVAL or self.RETRY_INTERVAL)
    end
end

--[[
    The MCP server is stopping (by hand, on idle, or because the reader is
    going to sleep). Save what changed, and tell the relay the reader is
    going, so that AI apps get the saved copy right away instead of waiting
    for a reader that won't answer. Waits for the relay for a moment
    (BLOCKING_TIMEOUT at worst), which is why it only happens with offline
    memory on and right after the relay connection was in use.
--]]
function Memory:leave()
    self:cancelScheduled()
    if not self:isActive() or self.blocked or not self:online() then
        return
    end
    local sent = false
    if self.dirty then
        sent = self:push({ blocking = true, leaving = true })
    end
    if not sent then
        self.relay:detachedDeviceRequest("POST", "/bye", "{}", nil,
            { blocking = true, timeout = self.BLOCKING_TIMEOUT })
    end
end

--------------------------------------------------------------------------------
-- Deleting
--------------------------------------------------------------------------------

--[[
    Delete the copy saved on the relay.
    @param credentials optional {relay_url, device_id, device_secret} of the
           registration to clean up (default: the current one)
    @param callback optional function(deleted_now)
--]]
function Memory:forget(credentials, callback)
    callback = callback or function() end
    self:cancelScheduled()
    self.dirty = false
    self.last_fingerprint = nil
    self.page_cache = nil

    credentials = credentials or self:credentials()
    local status = self:getStatus()
    local may_exist = self.in_flight or (status ~= nil and status.result ~= "no_apps")
    if not credentials or not may_exist then
        -- Never registered, or nothing was ever saved
        self:setStatus(nil)
        callback(true)
        return
    end

    -- Remember what to delete until the relay has confirmed it
    G_reader_settings:saveSetting("mcp_memory_pending_delete", credentials)
    self:setStatus({ result = "delete_pending" })
    self:processPendingDelete(callback)
end

-- Carry out a deletion that couldn't be confirmed earlier (the reader was offline)
function Memory:processPendingDelete(callback)
    callback = callback or function() end
    local credentials = G_reader_settings:readSetting("mcp_memory_pending_delete")
    if type(credentials) ~= "table" or self.delete_in_flight then
        callback(false)
        return
    end
    if not self:online() then
        callback(false)
        return
    end
    self.delete_in_flight = true
    self.relay:detachedDeviceRequest("DELETE", "/snapshot", nil, function(ok, data, code)
        self.delete_in_flight = false
        -- 401/410: the relay no longer knows that device, so nothing is left.
        -- 404/405: a relay without offline memory never stored anything.
        local gone = ok or code == 401 or code == 410 or code == 404 or code == 405
        if gone then
            G_reader_settings:delSetting("mcp_memory_pending_delete")
            local status = self:getStatus()
            if status and status.result == "delete_pending" then
                self:setStatus(nil)
            end
        else
            logger.warn("MCP Memory: Could not delete the saved copy yet:", data, code)
        end
        callback(gone)
    end, { credentials = credentials })
end

-- Turn offline memory on ("position" or "pages") or off (nil)
function Memory:setScope(scope, callback)
    if scope ~= "position" and scope ~= "pages" then
        G_reader_settings:delSetting("mcp_memory_scope")
        self:forget(nil, callback)
        return
    end
    G_reader_settings:saveSetting("mcp_memory_scope", scope)
    -- Turning it (back) on cancels a deletion that hasn't happened yet:
    -- the next save replaces that copy anyway
    local pending = G_reader_settings:readSetting("mcp_memory_pending_delete")
    local current = self:credentials()
    if type(pending) == "table" and current and pending.device_id == current.device_id
        and pending.relay_url == current.relay_url then
        G_reader_settings:delSetting("mcp_memory_pending_delete")
    end
    local status = self:getStatus()
    if status and (status.result == "delete_pending" or status.result == "error") then
        self:setStatus(nil)
    end
    self.last_fingerprint = nil
    self.dirty = true
    self.generation = self.generation + 1
    self.waiting_for_network = false
    self:schedule(2, self.QUICK_INTERVAL)
    if callback then
        callback(true)
    end
end

--------------------------------------------------------------------------------
-- Events from the plugin
--------------------------------------------------------------------------------

-- The device registered with the relay; `limits` is what it offers (or nil)
function Memory:onRegistered(limits)
    if limits then
        G_reader_settings:saveSetting("mcp_memory_limits", limits)
    else
        G_reader_settings:delSetting("mcp_memory_limits")
    end
    self.blocked = nil
    self.waiting_for_network = false
    local status = self:getStatus()
    if status and status.result == "error" then
        self:setStatus(nil)
    elseif self.on_change then
        pcall(self.on_change)
    end
    self:processPendingDelete()
    if self:isOn() then
        local saved = status and status.result == "stored"
        if self.dirty or not saved then
            self.dirty = true
            self:schedule(3, self.QUICK_INTERVAL)
        end
    end
end

-- An AI app finished connecting: save again so that it can read the copy too
function Memory:onAppConnected()
    if not self:isOn() then
        return
    end
    self.last_fingerprint = nil
    self.dirty = true
    self.generation = self.generation + 1
    self:schedule(3, self.QUICK_INTERVAL)
end

-- WiFi came up (or the device woke up and may be online again)
function Memory:onNetworkAvailable()
    self.waiting_for_network = false
    if G_reader_settings:has("mcp_memory_pending_delete") then
        -- Give the connection a moment to settle
        UIManager:scheduleIn(5, function()
            self:processPendingDelete()
        end)
    end
    if self.dirty then
        self:schedule(5, self.QUICK_INTERVAL)
    end
end

-- A book was opened
function Memory:onBookOpened()
    self.page_cache = nil
    self.waiting_for_network = false
    self:markChanged()
end

-- The open book is closing: save where the user stopped (in the background)
function Memory:onBookClosing()
    self:cancelScheduled()
    if self.dirty then
        self:push()
    end
    self.page_cache = nil
end

return Memory
