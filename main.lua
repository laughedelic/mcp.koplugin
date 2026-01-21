--[[
    MCP Server Plugin for KOReader
    Provides a Model Context Protocol (MCP) server that allows AI assistants
    to interact with book content on the e-reader device
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local SpinWidget = require("ui/widget/spinwidget")
local _ = require("gettext")
local T = require("ffi/util").template

local MCPServer = require("mcp_server")
local MCPProtocol = require("mcp_protocol")
local MCPResources = require("mcp_resources")
local MCPTools = require("mcp_tools")

-- Module-level state to persist across plugin instance recreation
-- (when switching between file browser and reader)
local shared_state = {
    server = nil,       -- shared server instance
    protocol = nil,     -- shared protocol instance
    resources = nil,    -- shared resources instance
    tools = nil,        -- shared tools instance
    server_running = false,
    poll_task = nil,
    last_interaction_time = nil,  -- timestamp of last MCP interaction
    idle_check_task = nil,        -- scheduled idle check function
    idle_warning_widget = nil,    -- reference to the warning notification widget
}

local MCP = WidgetContainer:extend{
    name = "mcp",
    is_doc_only = false,
}

-- Default settings
local DEFAULT_IDLE_TIMEOUT_MINUTES = 0  -- 0 = disabled
local IDLE_WARNING_SECONDS = 5  -- Show warning 5 seconds before stopping

function MCP:init()
    logger.info("Initializing MCP Plugin instance")

    -- Initialize shared MCP components if not already created
    if not shared_state.server then
        logger.info("Creating new shared MCP components")
        shared_state.server = MCPServer:new()
        shared_state.protocol = MCPProtocol:new()
        shared_state.resources = MCPResources:new()
        shared_state.tools = MCPTools:new()

        -- Wire up components
        shared_state.protocol:setResources(shared_state.resources)
        shared_state.protocol:setTools(shared_state.tools)
    end

    -- Always update UI reference when plugin instance is created
    -- This ensures the tools/resources have access to the current UI
    shared_state.resources:setUI(self.ui)
    shared_state.tools:setUI(self.ui)

    -- If server is running, ensure polling continues with new instance
    if shared_state.server_running and not shared_state.poll_task then
        self:schedulePoll()
    end

    -- Add menu item
    self.ui.menu:registerToMainMenu(self)
end

function MCP:addToMainMenu(menu_items)
    -- Simple start/stop toggle in Tools menu for easy access
    menu_items.mcp = {
        text_func = function()
            if shared_state.server_running then
                local ip = shared_state.server:getLocalIP()
                local port = shared_state.server.port
                return _("MCP server: ") .. ip .. ":" .. port
            else
                return _("MCP server")
            end
        end,
        sorting_hint = "tools",
        checked_func = function()
            return shared_state.server_running
        end,
        callback = function(touchmenu_instance)
            if shared_state.server_running then
                self:stopServer()
            else
                self:startServer()
                -- Close menu when server starts successfully
                if shared_state.server_running and touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
            end
        end,
        hold_callback = function()
            self:showStatus()
        end,
    }

    -- Settings sub-menu in Network section
    menu_items.mcp_settings = {
        text = _("MCP server"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Start server automatically"),
                help_text = _("Start the MCP server automatically when KOReader starts (requires network)."),
                checked_func = function()
                    return G_reader_settings:isTrue("mcp_server_autostart")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("mcp_server_autostart")
                end,
            },
            {
                text_func = function()
                    local timeout = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes", DEFAULT_IDLE_TIMEOUT_MINUTES)
                    if timeout > 0 then
                        return T(_("Idle timeout: %1 min"), timeout)
                    else
                        return _("Idle timeout: disabled")
                    end
                end,
                help_text = _("Automatically stop the server after a period of inactivity. A warning notification will appear before stopping, which can be tapped to keep the server alive."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local timeout = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes", DEFAULT_IDLE_TIMEOUT_MINUTES)
                    local idle_dialog = SpinWidget:new{
                        title_text = _("MCP server idle timeout"),
                        info_text = _("Stop the server after this period of inactivity. Set to 0 to disable."),
                        value = timeout,
                        default_value = DEFAULT_IDLE_TIMEOUT_MINUTES,
                        value_min = 0,
                        value_max = 120,
                        value_step = 1,
                        value_hold_step = 5,
                        unit = _("min"),
                        ok_text = _("Set"),
                        callback = function(spin)
                            G_reader_settings:saveSetting("mcp_server_idle_timeout_minutes", spin.value)
                            -- Reschedule idle check if server is running
                            if shared_state.server_running then
                                self:scheduleIdleCheck()
                            end
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    }
                    UIManager:show(idle_dialog)
                end,
            },
            {
                text = _("Turn off WiFi on idle timeout"),
                help_text = _("When the server is stopped due to idle timeout, also turn off WiFi to save battery."),
                enabled_func = function()
                    return G_reader_settings:readSetting("mcp_server_idle_timeout_minutes", DEFAULT_IDLE_TIMEOUT_MINUTES) > 0
                end,
                checked_func = function()
                    return G_reader_settings:isTrue("mcp_server_idle_timeout_wifi_off")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("mcp_server_idle_timeout_wifi_off")
                end,
                separator = true,
            },
            {
                text = _("About MCP server"),
                keep_menu_open = true,
                callback = function()
                    self:showAbout()
                end,
            },
        },
    }
end

function MCP:startServer()
    if shared_state.server_running then
        -- Already running, nothing to do
        return
    end

    -- Check network connectivity
    if not NetworkMgr:isNetworkInfoAvailable() then
        UIManager:show(InfoMessage:new{
            text = _("Network is not available. Please enable WiFi first."),
            timeout = 3,
        })
        return
    end

    -- Update UI reference for resources and tools
    shared_state.resources:setUI(self.ui)
    shared_state.tools:setUI(self.ui)

    -- Start HTTP server
    local port = 8788

    -- On Kindle devices, open firewall port
    if Device:isKindle() then
        logger.info("MCP: Opening firewall port on Kindle")
        os.execute(string.format("%s %s %s",
            "iptables -A INPUT -p tcp --dport", port,
            "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        os.execute(string.format("%s %s %s",
            "iptables -A OUTPUT -p tcp --sport", port,
            "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
    end

    local success = shared_state.server:start(port, function(request)
        -- Update last interaction time on each request
        shared_state.last_interaction_time = os.time()
        -- Cancel any pending warning
        self:cancelIdleWarning()
        return shared_state.protocol:handleRequest(request)
    end)

    if not success then
        UIManager:show(InfoMessage:new{
            text = _("Failed to start MCP Server. Port may be in use."),
            timeout = 3,
        })
        return
    end

    shared_state.server_running = true
    shared_state.last_interaction_time = os.time()

    -- Start polling for requests
    self:schedulePoll()

    -- Start idle timeout checking
    self:scheduleIdleCheck()

    -- Show success message with connection info
    local ip = shared_state.server:getLocalIP()
    UIManager:show(Notification:new{
        text = _("MCP Server started: ") .. ip .. ":" .. port,
        timeout = 5,
    })

    logger.info("MCP Server started on", ip .. ":" .. port)
end

function MCP:stopServer()
    if not shared_state.server_running then
        return
    end

    -- Stop polling
    if shared_state.poll_task then
        UIManager:unschedule(shared_state.poll_task)
        shared_state.poll_task = nil
    end

    -- Stop idle checking
    self:cancelIdleCheck()
    self:cancelIdleWarning()

    -- Stop server
    shared_state.server:stop()
    shared_state.server_running = false
    shared_state.last_interaction_time = nil

    -- On Kindle devices, close firewall port
    local port = shared_state.server.port
    if Device:isKindle() then
        logger.info("MCP: Closing firewall port on Kindle")
        os.execute(string.format("%s %s %s",
            "iptables -D INPUT -p tcp --dport", port,
            "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        os.execute(string.format("%s %s %s",
            "iptables -D OUTPUT -p tcp --sport", port,
            "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
    end

    UIManager:show(Notification:new{
        text = _("MCP Server stopped"),
        timeout = 2,
    })

    logger.info("MCP Server stopped")
end

function MCP:schedulePoll()
    if not shared_state.server_running then
        return
    end

    shared_state.poll_task = function()
        -- Poll for incoming requests
        shared_state.server:pollOnce()

        -- Schedule next poll (poll more frequently for better responsiveness)
        if shared_state.server_running then
            UIManager:scheduleIn(0.05, shared_state.poll_task)
        end
    end

    UIManager:scheduleIn(0.05, shared_state.poll_task)
end

-- Idle timeout management
function MCP:scheduleIdleCheck()
    -- Cancel any existing idle check
    self:cancelIdleCheck()

    local timeout_minutes = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes", DEFAULT_IDLE_TIMEOUT_MINUTES)
    if timeout_minutes <= 0 or not shared_state.server_running then
        return  -- Idle timeout disabled or server not running
    end

    local timeout_seconds = timeout_minutes * 60
    local check_interval = math.min(30, timeout_seconds / 4)  -- Check at least every 30 seconds

    shared_state.idle_check_task = function()
        if not shared_state.server_running or not shared_state.last_interaction_time then
            return
        end

        local idle_time = os.time() - shared_state.last_interaction_time
        local time_until_stop = timeout_seconds - idle_time

        if time_until_stop <= 0 then
            -- Time's up, stop the server
            logger.info("MCP: Stopping server due to idle timeout")
            self:stopServer()
            -- Optionally turn off WiFi
            if G_reader_settings:isTrue("mcp_server_idle_timeout_wifi_off") then
                logger.info("MCP: Turning off WiFi due to idle timeout")
                NetworkMgr:turnOffWifi()
            end
        elseif time_until_stop <= IDLE_WARNING_SECONDS and not shared_state.idle_warning_widget then
            -- Show warning notification
            self:showIdleWarning(time_until_stop)
            -- Schedule final check for when timeout expires
            UIManager:scheduleIn(time_until_stop + 1, shared_state.idle_check_task)
        else
            -- Schedule next check
            local next_check = math.min(check_interval, time_until_stop - IDLE_WARNING_SECONDS + 1)
            UIManager:scheduleIn(next_check, shared_state.idle_check_task)
        end
    end

    UIManager:scheduleIn(check_interval, shared_state.idle_check_task)
end

function MCP:cancelIdleCheck()
    if shared_state.idle_check_task then
        UIManager:unschedule(shared_state.idle_check_task)
        shared_state.idle_check_task = nil
    end
end

function MCP:showIdleWarning(seconds_remaining)
    -- Create a notification that can be tapped to keep the server alive
    shared_state.idle_warning_widget = Notification:new{
        text = _("MCP will be stopped (tap to keep alive)"),
        timeout = seconds_remaining,
        toast = false,  -- Not a toast, so it captures the tap event
    }

    -- Override the tap handler to reset the idle timer
    local original_onTapClose = shared_state.idle_warning_widget.onTapClose
    shared_state.idle_warning_widget.onTapClose = function(widget)
        -- Reset the interaction time
        shared_state.last_interaction_time = os.time()
        logger.info("MCP: Idle timeout reset by user tap")

        -- Show confirmation
        UIManager:show(Notification:new{
            text = _("MCP server kept alive"),
            timeout = 2,
        })

        -- Reschedule idle checking
        self:scheduleIdleCheck()

        -- Close the warning widget
        shared_state.idle_warning_widget = nil
        if original_onTapClose then
            return original_onTapClose(widget)
        else
            UIManager:close(widget)
            return true
        end
    end

    UIManager:show(shared_state.idle_warning_widget)
end

function MCP:cancelIdleWarning()
    if shared_state.idle_warning_widget then
        UIManager:close(shared_state.idle_warning_widget)
        shared_state.idle_warning_widget = nil
    end
end

-- Auto-start handler
function MCP:onReaderReady()
    if G_reader_settings:isTrue("mcp_server_autostart") and not shared_state.server_running then
        -- Small delay to let the UI settle
        UIManager:scheduleIn(1, function()
            if NetworkMgr:isNetworkInfoAvailable() then
                logger.info("MCP: Auto-starting server")
                self:startServer()
            else
                logger.info("MCP: Auto-start skipped, network not available")
            end
        end)
    end
end

function MCP:showStatus()
    local status_text
    if shared_state.server_running then
        local ip = shared_state.server:getLocalIP()
        local port = shared_state.server.port
        local idle_timeout = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes", DEFAULT_IDLE_TIMEOUT_MINUTES)

        status_text = _("MCP Server is running\n\nConnection URL:\nhttp://") .. ip .. ":" .. port ..
                     _("\n\nProtocol: MCP ") .. shared_state.protocol.version

        if idle_timeout > 0 and shared_state.last_interaction_time then
            local idle_time = os.time() - shared_state.last_interaction_time
            local minutes = math.floor(idle_time / 60)
            local seconds = idle_time % 60
            status_text = status_text .. T(_("\n\nIdle time: %1m %2s"), minutes, seconds)
            status_text = status_text .. T(_("\nTimeout: %1 min"), idle_timeout)
        end
    else
        status_text = _("MCP Server is not running")
    end

    UIManager:show(InfoMessage:new{
        text = status_text,
        timeout = 5,
    })
end

function MCP:showAbout()
    local about_text = _([[MCP Server Plugin

This plugin provides a Model Context Protocol (MCP) server that allows AI assistants to interact with your books.

Features:
• Access book content and metadata
• Search within books
• Navigate to specific pages
• Get table of contents
• Reading statistics

To use:
1. Start the MCP server
2. Connect your AI assistant (e.g., Claude Desktop) to the displayed URL
3. Chat about your book!

Version: 1.0.0
Protocol: MCP 2025-03-26]])

    UIManager:show(InfoMessage:new{
        text = about_text,
    })
end

function MCP:onCloseDocument()
    -- Update UI reference when document changes
    -- The server keeps running, but tools/resources need the new UI
    if shared_state.server_running then
        logger.info("MCP: Document closed, UI reference will be updated on next init")
    end
end

function MCP:onSuspend()
    -- Stop server when device suspends to save battery
    if shared_state.server_running then
        self:stopServer()
    end
end

function MCP:onCloseWidget()
    -- Don't stop the server when widget closes (UI changes)
    -- Just log for debugging
    logger.dbg("MCP: onCloseWidget, server_running:", shared_state.server_running)
end

return MCP
