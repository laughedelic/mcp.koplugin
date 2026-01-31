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
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local QRWidget = require("ui/widget/qrwidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local Size = require("ui/size")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local MCPServer = require("mcp_server")
local MCPProtocol = require("mcp_protocol")
local MCPResources = require("mcp_resources")
local MCPTools = require("mcp_tools")
local MCPPrompts = require("mcp_prompts")
local MCPRelay = require("mcp_relay")

-- Module-level state to persist across plugin instance recreation
-- (when switching between file browser and reader)
local shared_state = {
    server = nil,    -- shared HTTP server instance
    protocol = nil,  -- shared protocol instance
    resources = nil, -- shared resources instance
    tools = nil,     -- shared tools instance
    prompts = nil,   -- shared prompts instance
    relay = nil,     -- shared relay instance
    -- MCP server state (for UI - true when MCP is active in any mode)
    server_running = false,
    -- Internal state for cleanup
    local_http_running = false, -- local HTTP server active (local mode)
    relay_running = false,      -- cloud relay active (remote mode)
    relay_connected = false,
    relay_url = nil,
    poll_task = nil,
    relay_poll_task = nil,
    last_interaction_time = nil, -- timestamp of last MCP interaction
    idle_check_task = nil,       -- scheduled idle check function
    idle_warning_widget = nil,   -- reference to the warning notification widget
}

local MCP = WidgetContainer:extend {
    name = "mcp",
    is_doc_only = false,
}

-- Default settings
local DEFAULT_IDLE_TIMEOUT_MINUTES = 0 -- 0 = disabled
local IDLE_WARNING_SECONDS = 5         -- Show warning 5 seconds before stopping
local DEFAULT_RELAY_URL = "https://mcp-relay.laughedelic.workers.dev"

function MCP:init()
    logger.info("Initializing MCP Plugin instance")

    -- Initialize shared MCP components if not already created
    if not shared_state.server then
        logger.info("Creating new shared MCP components")
        shared_state.server = MCPServer:new()
        shared_state.protocol = MCPProtocol:new()
        shared_state.resources = MCPResources:new()
        shared_state.tools = MCPTools:new()
        shared_state.prompts = MCPPrompts:new()
        shared_state.relay = MCPRelay:new()

        -- Wire up components
        shared_state.protocol:setResources(shared_state.resources)
        shared_state.protocol:setTools(shared_state.tools)
        shared_state.protocol:setPrompts(shared_state.prompts)
        shared_state.tools:setResources(shared_state.resources)
        shared_state.prompts:setResources(shared_state.resources)

        -- Configure relay
        shared_state.relay:setRelayUrl(G_reader_settings:readSetting("mcp_relay_url", DEFAULT_RELAY_URL))
        local saved_device_id = G_reader_settings:readSetting("mcp_relay_device_id")
        if saved_device_id then
            shared_state.relay:setDeviceId(saved_device_id)
        end
        shared_state.relay:setDeviceName(G_reader_settings:readSetting("mcp_relay_device_name", "KOReader"))

        -- Set up relay callbacks
        shared_state.relay:setStatusCallback(function(connected, url)
            shared_state.relay_connected = connected
            shared_state.relay_url = url
            if connected then
                -- Save the device ID for reconnection
                G_reader_settings:saveSetting("mcp_relay_device_id", shared_state.relay:getDeviceId())
            end
        end)
    end

    -- Always update UI reference when plugin instance is created
    -- This ensures the tools/resources have access to the current UI
    shared_state.resources:setUI(self.ui)
    shared_state.tools:setUI(self.ui)
    shared_state.prompts:setUI(self.ui)

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
            local mode = self:getServerMode()
            if shared_state.server_running then
                if mode == "remote" then
                    if shared_state.relay_connected then
                        return _("MCP server: ☁ remote")
                    else
                        return _("MCP server: ☁ connecting...")
                    end
                else
                    return _("MCP server: local")
                end
            else
                -- Show configured mode when not running
                if mode == "remote" then
                    return _("MCP server (☁ remote)")
                else
                    return _("MCP server (local)")
                end
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
        hold_callback = function(touchmenu_instance)
            if shared_state.server_running then
                self:showServerDetails()
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
            else
                -- Toggle between local/remote mode when server is not running
                local current_mode = self:getServerMode()
                local new_mode = current_mode == "remote" and "local" or "remote"
                self:setServerMode(new_mode)
                UIManager:show(Notification:new {
                    text = new_mode == "remote" and _("Switched to remote mode (via cloud relay)") or _("Switched to local network mode"),
                    timeout = 2,
                })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end
        end,
    }

    -- Settings sub-menu in Network section
    menu_items.mcp_settings = {
        text = _("MCP server"),
        sorting_hint = "network",
        sub_item_table = self:buildSettingsMenu(),
    }
end

-- Get the current server mode setting
function MCP:getServerMode()
    return G_reader_settings:readSetting("mcp_server_mode", "remote")
end

-- Set the server mode
function MCP:setServerMode(mode)
    G_reader_settings:saveSetting("mcp_server_mode", mode)
end

-- Build the settings menu dynamically
function MCP:buildSettingsMenu()
    return {
        -- Auto-start
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
        -- Idle timeout
        {
            text_func = function()
                local timeout = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes",
                    DEFAULT_IDLE_TIMEOUT_MINUTES)
                if timeout > 0 then
                    return T(_("Idle timeout: %1 min"), timeout)
                else
                    return _("Idle timeout: disabled")
                end
            end,
            help_text = _(
                "Automatically stop the server after a period of inactivity. A warning notification will appear before stopping, which can be tapped to keep the server alive."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local timeout = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes",
                    DEFAULT_IDLE_TIMEOUT_MINUTES)
                local idle_dialog = SpinWidget:new {
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
        -- Server Mode as radio buttons
        {
            text = _("Remote (via cloud relay)"),
            help_text = _(
                "Connect via cloud relay for access from anywhere (Claude Desktop, Claude Mobile, etc.) without complex network setup."),
            checked_func = function()
                return self:getServerMode() == "remote"
            end,
            radio = true,
            callback = function()
                self:setServerMode("remote")
                -- If server is running, restart with new mode
                if shared_state.server_running then
                    self:stopServer()
                    self:startServer()
                end
            end,
        },
        {
            text = _("Local network only"),
            help_text = _("Run MCP server on local network only. Clients must be on the same WiFi network."),
            checked_func = function()
                return self:getServerMode() == "local"
            end,
            radio = true,
            callback = function()
                self:setServerMode("local")
                -- If server is running, restart with new mode
                if shared_state.server_running then
                    self:stopServer()
                    self:startServer()
                end
            end,
            separator = true,
        },
        -- Cloud Relay Settings (enabled in remote mode)
        {
            text_func = function()
                local relay_url = G_reader_settings:readSetting("mcp_relay_url", DEFAULT_RELAY_URL)
                -- Show just the domain name
                local domain = relay_url:match("://([^/]+)")
                return T(_("Relay server: %1"), domain or relay_url)
            end,
            help_text = _("The cloud relay server URL. Change this only if you're running your own relay."),
            enabled_func = function()
                return self:getServerMode() == "remote"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local relay_url = G_reader_settings:readSetting("mcp_relay_url", DEFAULT_RELAY_URL)
                local input_dialog
                input_dialog = InputDialog:new {
                    title = _("Cloud relay server URL"),
                    input = relay_url,
                    input_hint = DEFAULT_RELAY_URL,
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(input_dialog)
                                end,
                            },
                            {
                                text = _("Reset"),
                                callback = function()
                                    input_dialog:setInputText(DEFAULT_RELAY_URL)
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local new_url = input_dialog:getInputText()
                                    if new_url and new_url ~= "" then
                                        local old_url = G_reader_settings:readSetting("mcp_relay_url", DEFAULT_RELAY_URL)
                                        G_reader_settings:saveSetting("mcp_relay_url", new_url)
                                        shared_state.relay:setRelayUrl(new_url)
                                        -- Restart server if running in remote mode and URL changed
                                        if shared_state.relay_running and new_url ~= old_url then
                                            self:stopServer()
                                            self:startServer()
                                        end
                                    end
                                    UIManager:close(input_dialog)
                                    if touchmenu_instance then
                                        touchmenu_instance:updateItems()
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(input_dialog)
                input_dialog:onShowKeyboard()
            end,
        },
        {
            text_func = function()
                local device_id = G_reader_settings:readSetting("mcp_relay_device_id")
                if device_id then
                    return T(_("Device ID: %1"), device_id)
                else
                    return _("Device ID: (not set)")
                end
            end,
            help_text = _("Your unique device identifier. Reset to get a new relay URL."),
            enabled_func = function()
                return self:getServerMode() == "remote"
            end,
            callback = function(touchmenu_instance)
                local device_id = G_reader_settings:readSetting("mcp_relay_device_id")
                local message = device_id
                    and T(_("Current device ID:\n%1\n\nDo you want to reset it? This will change your relay URL."),
                        device_id)
                    or _("No device ID set yet. It will be generated when you first connect to the cloud relay.")

                local ConfirmBox = require("ui/widget/confirmbox")
                local mcp_self = self
                UIManager:show(ConfirmBox:new {
                    text = message,
                    ok_text = _("Reset"),
                    ok_callback = function()
                        G_reader_settings:delSetting("mcp_relay_device_id")
                        shared_state.relay:setDeviceId(nil)
                        -- Restart server if running in remote mode
                        if shared_state.relay_running then
                            mcp_self:stopServer()
                            mcp_self:startServer()
                            UIManager:show(Notification:new {
                                text = _("Server restarting with new Device ID"),
                                timeout = 3,
                            })
                        else
                            UIManager:show(Notification:new {
                                text = _("Device ID will be regenerated on next connect"),
                                timeout = 3,
                            })
                        end
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
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
    }
end

function MCP:startServer()
    if shared_state.server_running then
        -- Already running, nothing to do
        return
    end

    -- Check if WiFi is on and connected
    if NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
        -- Already connected, start directly
        self:doStartServer()
        return
    end

    -- WiFi is off or not connected - turn it on and wait for connection
    logger.info("MCP: WiFi not connected, turning it on...")
    NetworkMgr:turnOnWifiAndWaitForConnection(function()
        logger.info("MCP: WiFi connected, continuing server start")
        self:doStartServer()
    end)
end

-- Internal function to actually start the server (called after WiFi is ready)
function MCP:doStartServer()
    -- Double-check network is available
    if not NetworkMgr:isConnected() then
        UIManager:show(Notification:new {
            text = _("Failed to start: network not available"),
            timeout = 3,
        })
        return
    end

    -- Update UI reference for resources and tools
    shared_state.resources:setUI(self.ui)
    shared_state.tools:setUI(self.ui)

    local mode = self:getServerMode()

    if mode == "remote" then
        -- Remote mode: only start cloud relay (no local server needed)
        self:startRelay(true)
    else
        -- Local mode: start local HTTP server only
        self:startLocalServer(false)
    end
end

-- Start the local HTTP server
-- @param silent boolean: if true, don't show notification (used when relay will show it)
-- @return boolean: true if started successfully
function MCP:startLocalServer(silent)
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
        UIManager:show(Notification:new {
            text = _("Failed to start MCP server"),
            timeout = 3,
        })
        return false
    end

    shared_state.server_running = true
    shared_state.local_http_running = true
    shared_state.last_interaction_time = os.time()

    -- Start polling for requests
    self:schedulePoll()

    -- Start idle timeout checking
    self:scheduleIdleCheck()

    -- Show notification only if not in silent mode
    if not silent then
        local ip = shared_state.server:getLocalIP()
        UIManager:show(Notification:new {
            text = T(_("MCP server started (local): %1:%2"), ip, port),
            timeout = 4,
        })
    end

    logger.info("MCP Server started on port", port)
    return true
end

function MCP:stopServer()
    if not shared_state.server_running then
        return
    end

    -- Stop relay if running (remote mode)
    if shared_state.relay_running then
        self:stopRelay(true) -- silent mode
    end

    -- Stop local HTTP server if running (local mode)
    if shared_state.local_http_running then
        -- Stop polling
        if shared_state.poll_task then
            UIManager:unschedule(shared_state.poll_task)
            shared_state.poll_task = nil
        end

        -- Stop server
        shared_state.server:stop()
        shared_state.local_http_running = false

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
    end

    -- Mark MCP server as stopped
    shared_state.server_running = false

    -- Stop idle checking
    self:cancelIdleCheck()
    self:cancelIdleWarning()
    shared_state.last_interaction_time = nil

    UIManager:show(Notification:new {
        text = _("MCP server stopped"),
        timeout = 2,
    })

    logger.info("MCP Server stopped")
end

function MCP:schedulePoll()
    if not shared_state.local_http_running then
        return
    end

    shared_state.poll_task = function()
        -- Poll for incoming requests
        shared_state.server:pollOnce()

        -- Schedule next poll (poll more frequently for better responsiveness)
        if shared_state.local_http_running then
            UIManager:scheduleIn(0.05, shared_state.poll_task)
        end
    end

    UIManager:scheduleIn(0.05, shared_state.poll_task)
end

-- Cloud Relay management
-- @param show_notification boolean: if true, show startup notification
function MCP:startRelay(show_notification)
    if shared_state.relay_running then
        return true
    end

    logger.info("MCP: Starting cloud relay")

    -- Set up the request handler to forward to the MCP protocol handler
    shared_state.relay:setRequestHandler(function(request)
        -- Update last interaction time for idle timeout
        shared_state.last_interaction_time = os.time()
        self:cancelIdleWarning()
        return shared_state.protocol:handleRequest(request)
    end)

    local success, device_id = shared_state.relay:start()
    if success then
        shared_state.server_running = true
        shared_state.relay_running = true
        shared_state.last_interaction_time = os.time()

        -- Start idle timeout checking
        self:scheduleIdleCheck()

        if show_notification then
            UIManager:show(Notification:new {
                text = _("MCP server started (☁ remote)"),
                timeout = 4,
            })
        end
        return true
    else
        UIManager:show(Notification:new {
            text = _("Failed to start MCP server (relay error)"),
            timeout = 3,
        })
        return false
    end
end

-- @param silent boolean: if true, don't show notification
function MCP:stopRelay(silent)
    if not shared_state.relay_running then
        return
    end

    logger.info("MCP: Stopping cloud relay")

    -- Stop polling
    if shared_state.relay_poll_task then
        UIManager:unschedule(shared_state.relay_poll_task)
        shared_state.relay_poll_task = nil
    end

    shared_state.relay:stop()
    shared_state.relay_running = false
    shared_state.relay_connected = false
    shared_state.relay_url = nil

    -- Only show notification if not silent
    if not silent then
        UIManager:show(Notification:new {
            text = _("Cloud relay stopped"),
            timeout = 2,
        })
    end
end

-- Show server details dialog with connection info, QR code (for remote mode), and action buttons
function MCP:showServerDetails()
    local mode = self:getServerMode()

    if not shared_state.server_running then
        UIManager:show(InfoMessage:new {
            text = _("MCP Server is not running.\n\nUse the MCP server toggle in the Tools menu to start it."),
        })
        return
    end

    local mcp_self = self
    local url
    local title
    local is_remote = mode == "remote"

    if is_remote then
        if shared_state.relay_connected and shared_state.relay_url then
            url = shared_state.relay_url
            title = _("MCP Server (☁ Remote)")
        elseif shared_state.relay_running then
            -- Still connecting
            UIManager:show(InfoMessage:new {
                text = _("Cloud relay is connecting...\n\nDevice ID: ") .. (shared_state.relay:getDeviceId() or _("generating...")) ..
                    _("\n\nPlease wait for the connection to be established."),
            })
            return
        else
            UIManager:show(InfoMessage:new {
                text = _("Cloud relay not connected.\n\nCheck your network connection and try restarting the server."),
            })
            return
        end
    else
        local ip = shared_state.server:getLocalIP()
        local port = shared_state.server.port
        url = "http://" .. ip .. ":" .. port
        title = _("MCP Server (Local)")
    end

    -- Create the dialog content
    local dialog_content = VerticalGroup:new { align = "center" }

    -- Add QR code for remote mode
    if is_remote then
        local qr_size = math.min(Screen:getWidth(), Screen:getHeight()) * 0.5
        local qr_widget = QRWidget:new {
            text = url,
            width = qr_size,
            height = qr_size,
        }
        table.insert(dialog_content, CenterContainer:new {
            dimen = { w = Screen:getWidth() * 0.8, h = qr_size },
            qr_widget,
        })
        table.insert(dialog_content, VerticalSpan:new { width = Size.padding.large })
    end

    -- Add URL text
    local url_widget = TextBoxWidget:new {
        text = url,
        width = Screen:getWidth() * 0.75,
        face = Font:getFace("cfont", 18),
        alignment = "center",
    }
    table.insert(dialog_content, CenterContainer:new {
        dimen = { w = Screen:getWidth() * 0.8, h = url_widget:getSize().h },
        url_widget,
    })

    -- Add settings hint text
    local settings_hint = TextBoxWidget:new {
        text = _("Settings: ☰ Menu → Network → MCP server"),
        width = Screen:getWidth() * 0.75,
        face = Font:getFace("cfont", 14),
        alignment = "center",
    }
    table.insert(dialog_content, VerticalSpan:new { width = Size.padding.default })
    table.insert(dialog_content, CenterContainer:new {
        dimen = { w = Screen:getWidth() * 0.8, h = settings_hint:getSize().h },
        settings_hint,
    })

    -- Create the dialog with buttons
    local details_dialog
    details_dialog = ButtonDialog:new {
        title = title,
        width_factor = 0.9,
        buttons = {
            {
                {
                    text = _("Setup Instructions"),
                    callback = function()
                        UIManager:close(details_dialog)
                        mcp_self:showSetupInstructions()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(details_dialog)
                    end,
                },
            },
        },
    }

    -- Add the QR/URL content to the dialog
    details_dialog:addWidget(dialog_content)

    UIManager:show(details_dialog)
end

-- Show setup instructions for MCP clients
function MCP:showSetupInstructions()
    local mode = self:getServerMode()
    local instructions

    if mode == "remote" and shared_state.relay_url then
        instructions = _("To connect an MCP client:\n\n" ..
            "Claude Desktop/Mobile:\n" ..
            "1. Open Settings → MCP Servers\n" ..
            "2. Add new server with URL:\n   ") .. shared_state.relay_url .. _("\n" ..
            "3. Save and start chatting!\n\n" ..
            "ChatGPT (with MCP plugin):\n" ..
            "1. Enable MCP plugin\n" ..
            "2. Configure server URL\n" ..
            "3. Connect and chat\n\n" ..
            "The QR code contains the server URL for easy mobile setup.")
    else
        local ip = shared_state.server:getLocalIP()
        local port = shared_state.server.port
        local url = "http://" .. ip .. ":" .. port
        instructions = _("To connect an MCP client:\n\n" ..
            "1. Ensure your device is on the same WiFi network\n" ..
            "2. Configure your MCP client with URL:\n   ") .. url .. _("\n" ..
            "3. Connect and start chatting!\n\n" ..
            "Note: Local mode requires devices to be on the same network. " ..
            "For remote access, switch to Remote (cloud relay) mode in settings.")
    end

    UIManager:show(InfoMessage:new {
        text = instructions,
    })
end

-- Idle timeout management
function MCP:scheduleIdleCheck()
    -- Cancel any existing idle check
    self:cancelIdleCheck()

    local timeout_minutes = G_reader_settings:readSetting("mcp_server_idle_timeout_minutes", DEFAULT_IDLE_TIMEOUT_MINUTES)
    if timeout_minutes <= 0 or not shared_state.server_running then
        return -- Idle timeout disabled or server not running
    end

    local timeout_seconds = timeout_minutes * 60
    local check_interval = math.min(30, timeout_seconds / 4) -- Check at least every 30 seconds

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
    shared_state.idle_warning_widget = Notification:new {
        text = _("MCP will be stopped (tap to keep alive)"),
        timeout = seconds_remaining,
        toast = false, -- Not a toast, so it captures the tap event
    }

    -- Override the tap handler to reset the idle timer
    local original_onTapClose = shared_state.idle_warning_widget.onTapClose
    shared_state.idle_warning_widget.onTapClose = function(widget)
        -- Reset the interaction time
        shared_state.last_interaction_time = os.time()
        logger.info("MCP: Idle timeout reset by user tap")

        -- Show confirmation
        UIManager:show(Notification:new {
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
    -- Redirect to the new details popup
    self:showServerDetails()
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

    UIManager:show(InfoMessage:new {
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
