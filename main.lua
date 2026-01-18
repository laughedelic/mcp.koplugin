--[[
    MCP Server Plugin for KOReader
    Provides a Model Context Protocol (MCP) server that allows AI assistants
    to interact with book content on the e-reader device
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local MCPServer = require("mcp_server")
local MCPProtocol = require("mcp_protocol")
local MCPResources = require("mcp_resources")
local MCPTools = require("mcp_tools")

local MCP = WidgetContainer:extend{
    name = "mcp",
    is_doc_only = false,
    server = nil,
    protocol = nil,
    resources = nil,
    tools = nil,
    server_running = false,
    poll_task = nil,
}

function MCP:init()
    logger.info("Initializing MCP Plugin")

    -- Initialize MCP components
    self.server = MCPServer:new()
    self.protocol = MCPProtocol:new()
    self.resources = MCPResources:new()
    self.tools = MCPTools:new()

    -- Wire up components
    self.protocol:setResources(self.resources)
    self.protocol:setTools(self.tools)

    -- Add menu item
    self.ui.menu:registerToMainMenu(self)
end

function MCP:addToMainMenu(menu_items)
    menu_items.mcp = {
        text = _("MCP Server"),
        sub_item_table = {
            {
                text = _("Start Server"),
                callback = function()
                    self:startServer()
                end,
                enabled_func = function()
                    return not self.server_running
                end,
            },
            {
                text = _("Stop Server"),
                callback = function()
                    self:stopServer()
                end,
                enabled_func = function()
                    return self.server_running
                end,
            },
            {
                text = _("Server Status"),
                callback = function()
                    self:showStatus()
                end,
            },
            {
                text = _("About"),
                callback = function()
                    self:showAbout()
                end,
            },
        },
    }
end

function MCP:startServer()
    if self.server_running then
        UIManager:show(InfoMessage:new{
            text = _("MCP Server is already running"),
        })
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
    self.resources:setUI(self.ui)
    self.tools:setUI(self.ui)

    -- Start HTTP server
    local port = 8788
    local success = self.server:start(port, function(request)
        return self.protocol:handleRequest(request)
    end)

    if not success then
        UIManager:show(InfoMessage:new{
            text = _("Failed to start MCP Server. Port may be in use."),
            timeout = 3,
        })
        return
    end

    self.server_running = true

    -- Start polling for requests
    self:schedulePoll()

    -- Show success message with connection info
    local ip = self.server:getLocalIP()
    UIManager:show(InfoMessage:new{
        text = _("MCP Server started!\n\nConnect your AI assistant to:\nhttp://") .. ip .. ":" .. port,
        timeout = 5,
    })

    logger.info("MCP Server started on", ip .. ":" .. port)
end

function MCP:stopServer()
    if not self.server_running then
        return
    end

    -- Stop polling
    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
    end

    -- Stop server
    self.server:stop()
    self.server_running = false

    UIManager:show(InfoMessage:new{
        text = _("MCP Server stopped"),
        timeout = 2,
    })

    logger.info("MCP Server stopped")
end

function MCP:schedulePoll()
    if not self.server_running then
        return
    end

    self.poll_task = function()
        -- Poll for incoming requests
        self.server:pollOnce()

        -- Schedule next poll
        if self.server_running then
            UIManager:scheduleIn(0.1, self.poll_task)
        end
    end

    UIManager:scheduleIn(0.1, self.poll_task)
end

function MCP:showStatus()
    local status_text
    if self.server_running then
        local ip = self.server:getLocalIP()
        local port = self.server.port
        status_text = _("MCP Server is running\n\nConnection URL:\nhttp://") .. ip .. ":" .. port ..
                     _("\n\nProtocol: MCP ") .. self.protocol.version
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
Protocol: MCP 2024-11-05]])

    UIManager:show(InfoMessage:new{
        text = about_text,
    })
end

function MCP:onCloseDocument()
    -- Stop server when document is closed (optional)
    -- Uncomment if you want the server to stop automatically
    -- self:stopServer()
end

function MCP:onSuspend()
    -- Stop server when device suspends to save battery
    if self.server_running then
        self:stopServer()
    end
end

return MCP
