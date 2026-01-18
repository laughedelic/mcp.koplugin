--[[
    MCP Protocol Handler
    Implements the Model Context Protocol (MCP) using JSON-RPC 2.0
    Handles initialization, capability negotiation, and request routing
--]]

local rapidjson = require("rapidjson")
local logger = require("logger")

local MCPProtocol = {
    version = "2024-11-05",  -- MCP protocol version
    serverInfo = {
        name = "koreader-mcp",
        version = "1.0.0",
    },
    capabilities = {},
    resources = nil,
    tools = nil,
    initialized = false,
}

function MCPProtocol:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function MCPProtocol:setResources(resources)
    self.resources = resources
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

function MCPProtocol:handleRequest(request)
    -- Parse JSON-RPC request
    local ok, jsonRequest = pcall(rapidjson.decode, request.body)
    if not ok or not jsonRequest then
        logger.warn("Invalid JSON in MCP request:", request.body)
        return self:createErrorResponse(nil, -32700, "Parse error")
    end

    -- Validate JSON-RPC structure
    if jsonRequest.jsonrpc ~= "2.0" then
        return self:createErrorResponse(jsonRequest.id, -32600, "Invalid Request")
    end

    -- Route request to appropriate handler
    local method = jsonRequest.method
    local id = jsonRequest.id
    local params = jsonRequest.params or {}

    logger.dbg("MCP Request:", method, "ID:", id)

    -- Handle different MCP methods
    if method == "initialize" then
        return self:handleInitialize(id, params)
    elseif method == "initialized" then
        -- Notification, no response needed
        self.initialized = true
        return self:createNotificationResponse()
    elseif method == "ping" then
        return self:handlePing(id)
    elseif method == "resources/list" then
        return self:handleResourcesList(id, params)
    elseif method == "resources/read" then
        return self:handleResourcesRead(id, params)
    elseif method == "tools/list" then
        return self:handleToolsList(id, params)
    elseif method == "tools/call" then
        return self:handleToolsCall(id, params)
    else
        return self:createErrorResponse(id, -32601, "Method not found")
    end
end

function MCPProtocol:handleInitialize(id, params)
    logger.info("MCP Initialize request from:", params.clientInfo and params.clientInfo.name or "unknown")

    local result = {
        protocolVersion = self.version,
        capabilities = self.capabilities,
        serverInfo = self.serverInfo,
    }

    return self:createSuccessResponse(id, result)
end

function MCPProtocol:handlePing(id)
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

function MCPProtocol:handleToolsCall(id, params)
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

function MCPProtocol:createErrorResponse(id, code, message)
    local response = {
        jsonrpc = "2.0",
        id = id or rapidjson.null,
        error = {
            code = code,
            message = message,
        },
    }

    return {
        status = 200,  -- JSON-RPC errors still use HTTP 200
        statusText = "OK",
        headers = {},
        body = rapidjson.encode(response),
    }
end

function MCPProtocol:createNotificationResponse()
    -- Notifications don't get responses, return empty 204
    return {
        status = 204,
        statusText = "No Content",
        headers = {},
        body = "",
    }
end

return MCPProtocol
