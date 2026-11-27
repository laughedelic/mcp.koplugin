--[[
    MCP Protocol Handler
    Implements the Model Context Protocol (MCP) using JSON-RPC 2.0
    Handles initialization, capability negotiation, and request routing
--]]

local rapidjson = require("rapidjson")
local logger = require("logger")

-- Protocol versions this server speaks, newest first.
-- (2026-07-28 "stateless" MCP is not supported yet; clients that speak both
-- generations fall back to these via the initialize handshake.)
local SUPPORTED_VERSIONS = { "2025-11-25", "2025-06-18", "2025-03-26" }

local function isSupportedVersion(v)
    for _, supported in ipairs(SUPPORTED_VERSIONS) do
        if v == supported then return true end
    end
    return false
end

local MCPProtocol = {
    version = SUPPORTED_VERSIONS[1], -- latest supported MCP protocol version
    supportedVersions = SUPPORTED_VERSIONS,
    serverInfo = {
        name = "koreader-mcp",
        title = "KOReader",
        version = "0.3.0",
    },
    capabilities = {},
    resources = nil,
    tools = nil,
    prompts = nil,
    clientFeatures = nil, -- For sampling, elicitation, logging
    initialized = false,

    -- Callback for sending notifications/requests to client
    sendToClient = nil,
}

function MCPProtocol:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function MCPProtocol:setResources(resources)
    self.resources = resources
    -- Subscriptions and list-change notifications are not advertised:
    -- neither transport can deliver server-initiated messages yet (local mode
    -- has no SSE stream, and the relay has no server-to-client channel), so
    -- clients would subscribe and wait for updates that never arrive.
    -- resources/subscribe is still accepted for clients that call it anyway.
    self.capabilities.resources = {
        subscribe = false,
        listChanged = false,
    }
end

function MCPProtocol:setTools(tools)
    self.tools = tools
    self.capabilities.tools = {
        listChanged = false,
    }
end

function MCPProtocol:setPrompts(prompts)
    self.prompts = prompts
    self.capabilities.prompts = {
        listChanged = false,
    }
end

function MCPProtocol:setClientFeatures(clientFeatures)
    self.clientFeatures = clientFeatures
    -- Server declares logging capability
    self.capabilities.logging = {}
end

-- Set callback for sending messages to client (notifications, requests)
function MCPProtocol:setSendCallback(callback)
    self.sendToClient = callback
    if self.clientFeatures then
        self.clientFeatures:setSendCallback(callback)
    end
end

function MCPProtocol:handleRequest(request)
    -- Streamable HTTP: the MCP endpoint only accepts POST. This server offers
    -- no standalone SSE stream (GET) and no sessions to terminate (DELETE).
    local http_method = request.method and request.method:upper() or "POST"
    if http_method ~= "POST" then
        return {
            status = 405,
            statusText = "Method Not Allowed",
            headers = { ["Allow"] = "POST" },
            body = "",
        }
    end

    -- Parse JSON-RPC request
    local ok, jsonRequest = pcall(rapidjson.decode, request.body)
    if not ok or not jsonRequest then
        -- Log detailed error information for debugging
        local body_preview = request.body or "(empty)"
        if #body_preview > 200 then
            body_preview = body_preview:sub(1, 200) .. "... (truncated, total " .. #request.body .. " bytes)"
        end
        local error_msg = not ok and tostring(jsonRequest) or "JSON decoded to nil/false"
        logger.warn("Invalid JSON in MCP request:")
        logger.warn("  Error:", error_msg)
        logger.warn("  Body:", body_preview)
        logger.warn("  Content-Length:", request.headers and request.headers["content-length"] or "unknown")
        return self:createErrorResponse(nil, -32700, "Parse error", 400)
    end

    -- JSON-RPC batches were removed in MCP 2025-06-18 and never supported here
    if type(jsonRequest) ~= "table" or jsonRequest[1] ~= nil then
        return self:createErrorResponse(nil, -32600, "Invalid Request: batches are not supported", 400)
    end

    -- Validate JSON-RPC structure
    if jsonRequest.jsonrpc ~= "2.0" then
        return self:createErrorResponse(jsonRequest.id, -32600, "Invalid Request", 400)
    end

    -- Route request to appropriate handler
    local method = jsonRequest.method
    local id = jsonRequest.id
    local params = jsonRequest.params

    -- rapidjson decodes JSON null as a sentinel; treat it as absent
    if id == rapidjson.null then id = nil end
    if params == rapidjson.null then params = nil end

    -- JSON-RPC: method is a string, id a string or number, params structured
    if (method ~= nil and type(method) ~= "string")
        or (id ~= nil and type(id) ~= "string" and type(id) ~= "number")
        or (params ~= nil and type(params) ~= "table") then
        local reply_id = (type(id) == "string" or type(id) == "number") and id or nil
        return self:createErrorResponse(reply_id, -32600, "Invalid Request", 400)
    end
    params = params or {}

    logger.dbg("MCP Request:", method, "ID:", id)

    -- Reject protocol versions we don't speak. Clients send MCP-Protocol-Version
    -- on every request after initialization (MCP 2025-06-18+). A client that
    -- also speaks stateless MCP (2026-07-28+) tries that first; this plain 400
    -- (deliberately not a 2026-07-28 error code) makes it fall back to the
    -- initialize handshake, which is exempt from the check.
    local headers = request.headers or {}
    local header_version = headers["mcp-protocol-version"]
    if header_version and method ~= "initialize" and not isSupportedVersion(header_version) then
        return self:createErrorResponse(id, -32600,
            "Unsupported protocol version: " .. header_version ..
            " (supported: " .. table.concat(SUPPORTED_VERSIONS, ", ") .. ")",
            400, { supported = SUPPORTED_VERSIONS, requested = header_version })
    end

    -- A JSON-RPC response from the client (to a server-initiated request)
    if method == nil then
        if id ~= nil and (jsonRequest.result ~= nil or jsonRequest.error ~= nil) then
            self:handleClientResponse(jsonRequest)
            return self:createAcceptedResponse()
        end
        return self:createErrorResponse(id, -32600, "Invalid Request", 400)
    end

    -- Notifications (no id) never get a JSON-RPC response: HTTP 202 Accepted
    if id == nil then
        local ok_notification, notification_err = pcall(self.handleNotification, self, method, params)
        if not ok_notification then
            logger.warn("MCP: Error handling notification", method, notification_err)
        end
        return self:createAcceptedResponse()
    end

    -- Version this request speaks. Clients on 2025-06-18+ send the header on
    -- every request; a missing one means 2025-03-26 (per spec). Not the version
    -- initialize negotiated: one protocol instance serves every client.
    local request_version = header_version or "2025-03-26"

    -- Handle different MCP methods
    if method == "initialize" then
        return self:handleInitialize(id, params)
    elseif method == "ping" then
        return self:handlePing(id)
    elseif method == "logging/setLevel" then
        return self:handleLoggingSetLevel(id, params)
    elseif method == "resources/list" then
        return self:handleResourcesList(id, params)
    elseif method == "resources/read" then
        return self:handleResourcesRead(id, params)
    elseif method == "resources/templates/list" then
        return self:handleResourcesTemplatesList(id, params)
    elseif method == "resources/subscribe" then
        return self:handleResourcesSubscribe(id, params)
    elseif method == "resources/unsubscribe" then
        return self:handleResourcesUnsubscribe(id, params)
    elseif method == "tools/list" then
        return self:handleToolsList(id, params)
    elseif method == "tools/call" then
        return self:handleToolsCall(id, params, request_version)
    elseif method == "prompts/list" then
        return self:handlePromptsList(id, params)
    elseif method == "prompts/get" then
        return self:handlePromptsGet(id, params)
    else
        return self:createErrorResponse(id, -32601, "Method not found")
    end
end

function MCPProtocol:handleInitialize(id, params)
    logger.info("MCP Initialize request from:", params.clientInfo and params.clientInfo.name or "unknown")

    -- Store client capabilities for client features
    if self.clientFeatures and params.capabilities then
        self.clientFeatures:setClientCapabilities(params.capabilities)
        logger.dbg("MCP: Client capabilities:", rapidjson.encode(params.capabilities))
    end

    -- Version negotiation: answer with the client's version if we support it,
    -- otherwise with our latest (the client then decides whether to proceed)
    local requested = params.protocolVersion
    local negotiated = isSupportedVersion(requested) and requested or self.version
    if requested ~= negotiated then
        logger.info("MCP: Client requested protocol", requested, "- offering", negotiated)
    end
    self.negotiatedVersion = negotiated

    local result = {
        protocolVersion = negotiated,
        capabilities = self.capabilities,
        serverInfo = self.serverInfo,
        instructions = "Access to the book the user is reading in KOReader on their e-reader. "
            .. "Start with get_reading_context to see the current book, page and selection.",
    }

    return self:createSuccessResponse(id, result)
end

-- Handle a client notification (no response is sent)
function MCPProtocol:handleNotification(method, params)
    if method == "notifications/initialized" or method == "initialized" then
        self.initialized = true
    elseif method == "notifications/cancelled" then
        -- Requests are handled synchronously, so there is nothing to cancel
        logger.dbg("MCP: Client cancelled request", params and params.requestId)
    else
        self:handleClientNotification({ method = method, params = params })
    end
end

function MCPProtocol:handlePing(id)
    return self:createSuccessResponse(id, {})
end

function MCPProtocol:handleLoggingSetLevel(id, params)
    local level = params.level
    if not level then
        return self:createErrorResponse(id, -32602, "Invalid params: missing level")
    end

    if self.clientFeatures then
        local ok, err = self.clientFeatures:setLogLevel(level)
        if not ok then
            return self:createErrorResponse(id, -32602, err)
        end
    end

    return self:createSuccessResponse(id, {})
end

function MCPProtocol:handleResourcesList(id, params)
    if not self.resources then
        return self:createErrorResponse(id, -32603, "Resources not available")
    end

    local ok, result = pcall(function()
        return self.resources:list()
    end)

    if not ok then
        logger.err("Error listing resources:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    return self:createSuccessResponse(id, { resources = result })
end

function MCPProtocol:handleResourcesRead(id, params)
    if not self.resources then
        return self:createErrorResponse(id, -32603, "Resources not available")
    end

    local uri = params.uri
    if not uri then
        return self:createErrorResponse(id, -32602, "Invalid params: missing uri")
    end

    local ok, result = pcall(function()
        return self.resources:read(uri)
    end)

    if not ok then
        logger.err("Error reading resource:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    if not result then
        return self:createErrorResponse(id, -32602, "Resource not found")
    end

    return self:createSuccessResponse(id, { contents = result })
end

function MCPProtocol:handleResourcesTemplatesList(id, params)
    if not self.resources then
        return self:createErrorResponse(id, -32603, "Resources not available")
    end

    local ok, result = pcall(function()
        return self.resources:listTemplates()
    end)

    if not ok then
        logger.err("Error listing resource templates:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    return self:createSuccessResponse(id, { resourceTemplates = result or {} })
end

function MCPProtocol:handleResourcesSubscribe(id, params)
    if not self.resources then
        return self:createErrorResponse(id, -32603, "Resources not available")
    end

    local uri = params.uri
    if not uri then
        return self:createErrorResponse(id, -32602, "Invalid params: missing uri")
    end

    local ok, result = pcall(function()
        return self.resources:subscribe(uri)
    end)

    if not ok then
        logger.err("Error subscribing to resource:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    return self:createSuccessResponse(id, {})
end

function MCPProtocol:handleResourcesUnsubscribe(id, params)
    if not self.resources then
        return self:createErrorResponse(id, -32603, "Resources not available")
    end

    local uri = params.uri
    if not uri then
        return self:createErrorResponse(id, -32602, "Invalid params: missing uri")
    end

    local ok, result = pcall(function()
        return self.resources:unsubscribe(uri)
    end)

    if not ok then
        logger.err("Error unsubscribing from resource:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    return self:createSuccessResponse(id, {})
end

function MCPProtocol:handleToolsList(id, params)
    if not self.tools then
        return self:createErrorResponse(id, -32603, "Tools not available")
    end

    local ok, result = pcall(function()
        return self.tools:list()
    end)

    if not ok then
        logger.err("Error listing tools:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    return self:createSuccessResponse(id, { tools = result })
end

-- resource_link content was added in 2025-06-18; older clients reject it,
-- so give them the link as text instead
local function adaptToolResult(result, version)
    if version ~= "2025-03-26" or type(result) ~= "table" or type(result.content) ~= "table" then
        return result
    end
    for i, item in ipairs(result.content) do
        if type(item) == "table" and item.type == "resource_link" then
            result.content[i] = {
                type = "text",
                text = (item.name or "Resource") .. ": " .. tostring(item.uri),
            }
        end
    end
    return result
end

function MCPProtocol:handleToolsCall(id, params, version)
    if not self.tools then
        return self:createErrorResponse(id, -32603, "Tools not available")
    end

    local name = params.name
    local arguments = params.arguments or {}

    if not name then
        return self:createErrorResponse(id, -32602, "Invalid params: missing name")
    end

    local ok, result = pcall(function()
        return self.tools:call(name, arguments)
    end)

    if not ok then
        logger.err("Error calling tool:", result)
        return self:createErrorResponse(id, -32603, tostring(result))
    end

    if not result then
        return self:createErrorResponse(id, -32602, "Tool not found")
    end

    return self:createSuccessResponse(id, adaptToolResult(result, version))
end

function MCPProtocol:handlePromptsList(id, params)
    if not self.prompts then
        return self:createErrorResponse(id, -32603, "Prompts not available")
    end

    local ok, result = pcall(function()
        return self.prompts:list()
    end)

    if not ok then
        logger.err("Error listing prompts:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    return self:createSuccessResponse(id, { prompts = result })
end

function MCPProtocol:handlePromptsGet(id, params)
    if not self.prompts then
        return self:createErrorResponse(id, -32603, "Prompts not available")
    end

    local name = params.name
    local arguments = params.arguments or {}

    if not name then
        return self:createErrorResponse(id, -32602, "Invalid params: missing name")
    end

    local ok, result, err = pcall(function()
        return self.prompts:get(name, arguments)
    end)

    if not ok then
        logger.err("Error getting prompt:", result)
        return self:createErrorResponse(id, -32603, "Internal error")
    end

    if not result then
        -- result is nil, err contains the error message from prompts:get
        return self:createErrorResponse(id, -32602, err or "Prompt not found")
    end

    return self:createSuccessResponse(id, result)
end

function MCPProtocol:createSuccessResponse(id, result)
    local response = {
        jsonrpc = "2.0",
        id = id,
        result = result,
    }

    return {
        status = 200,
        statusText = "OK",
        headers = {},
        body = rapidjson.encode(response),
    }
end

local STATUS_TEXT = {
    [200] = "OK",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
}

-- @param http_status optional HTTP status (default 200: JSON-RPC errors for
--        well-formed requests are still delivered with HTTP 200)
-- @param data optional error data
function MCPProtocol:createErrorResponse(id, code, message, http_status, data)
    local response = {
        jsonrpc = "2.0",
        id = id or rapidjson.null,
        error = {
            code = code,
            message = message,
            data = data,
        },
    }

    http_status = http_status or 200
    return {
        status = http_status,
        statusText = STATUS_TEXT[http_status] or "Error",
        headers = {},
        body = rapidjson.encode(response),
    }
end

function MCPProtocol:createAcceptedResponse()
    -- Streamable HTTP: notifications and responses get 202 with no body
    return {
        status = 202,
        statusText = "Accepted",
        headers = {},
        body = "",
    }
end

-- Kept for compatibility with older callers
function MCPProtocol:createNotificationResponse()
    return self:createAcceptedResponse()
end

--------------------------------------------------------------------------------
-- Server → Client Notifications
--------------------------------------------------------------------------------

-- Send a resource update notification
function MCPProtocol:notifyResourceUpdated(uri)
    if self.clientFeatures then
        self.clientFeatures:notifyResourceUpdated(uri)
    end
end

-- Send a resource list changed notification
function MCPProtocol:notifyResourceListChanged()
    if self.clientFeatures then
        self.clientFeatures:notifyResourceListChanged()
    end
end

-- Send a progress notification
function MCPProtocol:notifyProgress(progressToken, progress, total, message)
    if self.clientFeatures then
        self.clientFeatures:notifyProgress(progressToken, progress, total, message)
    end
end

-- Log a message to the client
function MCPProtocol:log(level, loggerName, data)
    if self.clientFeatures then
        self.clientFeatures:log(level, loggerName, data)
    end
end

--------------------------------------------------------------------------------
-- Server → Client Requests (via clientFeatures)
--------------------------------------------------------------------------------

-- Request sampling from the client
function MCPProtocol:requestSampling(options, callback)
    if self.clientFeatures then
        return self.clientFeatures:requestSampling(options, callback)
    else
        if callback then callback(nil, "Client features not available") end
    end
end

-- Simple ask helper
function MCPProtocol:ask(prompt, callback)
    if self.clientFeatures then
        return self.clientFeatures:ask(prompt, callback)
    else
        if callback then callback(nil, "Client features not available") end
    end
end

-- Request form elicitation
function MCPProtocol:requestFormElicitation(options, callback)
    if self.clientFeatures then
        return self.clientFeatures:requestFormElicitation(options, callback)
    else
        if callback then callback(nil, "Client features not available") end
    end
end

-- Request user confirmation
function MCPProtocol:confirm(message, callback)
    if self.clientFeatures then
        return self.clientFeatures:confirm(message, callback)
    else
        if callback then callback(false, "Client features not available") end
    end
end

-- Request text input
function MCPProtocol:requestText(message, options, callback)
    if self.clientFeatures then
        return self.clientFeatures:requestText(message, options, callback)
    else
        if callback then callback(nil, "Client features not available") end
    end
end

-- Request choice from options
function MCPProtocol:requestChoice(message, options, callback)
    if self.clientFeatures then
        return self.clientFeatures:requestChoice(message, options, callback)
    else
        if callback then callback(nil, "Client features not available") end
    end
end

-- Handle response from client (for pending sampling/elicitation requests)
function MCPProtocol:handleClientResponse(response)
    if self.clientFeatures then
        return self.clientFeatures:handleResponse(response)
    end
    return false
end

-- Handle notification from client
function MCPProtocol:handleClientNotification(notification)
    if self.clientFeatures then
        return self.clientFeatures:handleNotification(notification)
    end
    return false
end

return MCPProtocol
