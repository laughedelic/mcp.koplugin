--[[
    MCP Protocol Handler
    Implements the Model Context Protocol (MCP) using JSON-RPC 2.0 over
    Streamable HTTP.

    The server is "dual-era":
    - Legacy clients (protocol 2025-03-26 to 2025-11-25) open with the
      `initialize` handshake.
    - Modern clients (protocol 2026-07-28, stateless) send the protocol
      version and their capabilities in every request's `_meta`, may call
      `server/discover`, and receive user-input requests (elicitation) as
      `input_required` results instead of server-initiated requests.
    Both are served on the same endpoint; each request is answered on its own.
--]]

local rapidjson = require("rapidjson")
local logger = require("logger")
local MRTR = require("mcp_mrtr")

-- Stateless protocol versions (per-request _meta, no initialize), newest first
local MODERN_VERSIONS = { "2026-07-28" }
-- Handshake-based protocol versions, newest first
local LEGACY_VERSIONS = { "2025-11-25", "2025-06-18", "2025-03-26" }

local ALL_VERSIONS = {}
for _, v in ipairs(MODERN_VERSIONS) do ALL_VERSIONS[#ALL_VERSIONS + 1] = v end
for _, v in ipairs(LEGACY_VERSIONS) do ALL_VERSIONS[#ALL_VERSIONS + 1] = v end

local META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
local META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
local META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
local META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"

-- JSON-RPC error codes
local PARSE_ERROR = -32700
local INVALID_REQUEST = -32600
local METHOD_NOT_FOUND = -32601
local INVALID_PARAMS = -32602
local INTERNAL_ERROR = -32603
-- MCP 2026-07-28 error codes
local HEADER_MISMATCH = -32020
local UNSUPPORTED_PROTOCOL_VERSION = -32022

-- Cache hints for modern results (CacheableResult). Everything here is
-- personal (the user's books), so caches must never be shared.
local CACHE_STATIC = { ttlMs = 3600000, cacheScope = "private" } -- tool/prompt/template lists
local CACHE_LIVE = { ttlMs = 0, cacheScope = "private" }         -- depends on the open book and page

-- Methods whose name is mirrored into the Mcp-Name header
local MCP_NAME_SOURCE = {
    ["tools/call"] = "name",
    ["prompts/get"] = "name",
    ["resources/read"] = "uri",
}

local INSTRUCTIONS = "Access to the book the user is reading in KOReader on their e-reader. "
    .. "Start with get_reading_context to see the current book, page and selection."

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local MCPProtocol = {
    version = LEGACY_VERSIONS[1], -- latest handshake-based version
    supportedVersions = ALL_VERSIONS,
    serverInfo = {
        name = "koreader-mcp",
        title = "KOReader",
        version = "0.3.0",
    },
    capabilities = {},
    resources = nil,
    tools = nil,
    prompts = nil,
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
    -- Subscriptions and list-change notifications are not advertised: no
    -- transport delivers server-initiated messages yet. In 2026-07-28 they
    -- would come through a subscriptions/listen stream instead.
    -- resources/subscribe is still accepted for legacy clients that call it.
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

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

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
        local body_preview = request.body or "(empty)"
        if #body_preview > 200 then
            body_preview = body_preview:sub(1, 200) .. "... (truncated, total " .. #request.body .. " bytes)"
        end
        logger.warn("Invalid JSON in MCP request:", not ok and tostring(jsonRequest) or "decoded to nil", body_preview)
        return self:createErrorResponse(nil, PARSE_ERROR, "Parse error", 400)
    end

    -- JSON-RPC batches were removed in MCP 2025-06-18 and never supported here
    if type(jsonRequest) ~= "table" or jsonRequest[1] ~= nil then
        return self:createErrorResponse(nil, INVALID_REQUEST, "Invalid Request: batches are not supported", 400)
    end

    if jsonRequest.jsonrpc ~= "2.0" then
        return self:createErrorResponse(jsonRequest.id, INVALID_REQUEST, "Invalid Request", 400)
    end

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
        return self:createErrorResponse(reply_id, INVALID_REQUEST, "Invalid Request", 400)
    end
    params = params or {}

    local headers = request.headers or {}
    local header_version = headers["mcp-protocol-version"]
    local meta = type(params._meta) == "table" and params._meta or {}

    logger.dbg("MCP Request:", method, "ID:", id)

    -- A request carrying per-request metadata, or announcing a stateless
    -- version, is served by the 2026-07-28 rules. initialize always means a
    -- legacy client (or a dual-era client falling back to the handshake).
    if meta[META_PROTOCOL_VERSION] ~= nil
        or (method ~= "initialize" and contains(MODERN_VERSIONS, header_version)) then
        return self:handleModernMessage(jsonRequest, method, id, params, meta, headers)
    end

    return self:handleLegacyMessage(jsonRequest, method, id, params, headers)
end

--------------------------------------------------------------------------------
-- Legacy (initialize-based) protocol: 2025-03-26 .. 2025-11-25
--------------------------------------------------------------------------------

function MCPProtocol:handleLegacyMessage(jsonRequest, method, id, params, headers)
    -- Reject protocol versions we don't speak. Clients send MCP-Protocol-Version
    -- on every request after initialization (2025-06-18+). initialize itself
    -- is exempt: it carries its version in the body and is negotiated.
    local header_version = headers["mcp-protocol-version"]
    if header_version and method ~= "initialize" and not contains(LEGACY_VERSIONS, header_version) then
        return self:createErrorResponse(id, INVALID_REQUEST,
            "Unsupported protocol version: " .. header_version ..
            " (supported: " .. table.concat(ALL_VERSIONS, ", ") .. ")",
            400, { supported = ALL_VERSIONS, requested = header_version })
    end

    -- A JSON-RPC response from the client: this server sends no requests,
    -- so there is nothing to match it to
    if method == nil then
        if id ~= nil and (jsonRequest.result ~= nil or jsonRequest.error ~= nil) then
            logger.dbg("MCP: Ignoring unexpected client response", id)
            return self:createAcceptedResponse()
        end
        return self:createErrorResponse(id, INVALID_REQUEST, "Invalid Request", 400)
    end

    -- Notifications (no id) never get a JSON-RPC response: HTTP 202 Accepted
    if id == nil then
        local ok_notification, notification_err = pcall(self.handleNotification, self, method, params)
        if not ok_notification then
            logger.warn("MCP: Error handling notification", method, notification_err)
        end
        return self:createAcceptedResponse()
    end

    if method == "initialize" then
        return self:handleInitialize(id, params)
    elseif method == "ping" then
        return self:createSuccessResponse(id, {})
    elseif method == "resources/subscribe" or method == "resources/unsubscribe" then
        return self:respond(id, self:resourcesSubscription(method, params))
    end

    -- Version this request speaks. Clients on 2025-06-18+ send the header on
    -- every request; a missing one means 2025-03-26 (per spec). Not the version
    -- initialize negotiated: one protocol instance serves every client.
    local version = header_version or "2025-03-26"
    local result, err = self:dispatch(method, params, { modern = false, version = version })
    if result == nil and err == nil then
        return self:createErrorResponse(id, METHOD_NOT_FOUND, "Method not found")
    end
    return self:respond(id, result, err)
end

function MCPProtocol:handleInitialize(id, params)
    logger.info("MCP Initialize request from:", params.clientInfo and params.clientInfo.name or "unknown")

    -- Version negotiation: answer with the client's version if we support it,
    -- otherwise with our latest (the client then decides whether to proceed)
    local requested = params.protocolVersion
    local negotiated = contains(LEGACY_VERSIONS, requested) and requested or self.version
    if requested ~= negotiated then
        logger.info("MCP: Client requested protocol", requested, "- offering", negotiated)
    end
    self.negotiatedVersion = negotiated

    return self:createSuccessResponse(id, {
        protocolVersion = negotiated,
        capabilities = self.capabilities,
        serverInfo = self.serverInfo,
        instructions = INSTRUCTIONS,
    })
end

-- Handle a client notification (no response is sent)
function MCPProtocol:handleNotification(method, params)
    if method == "notifications/initialized" or method == "initialized" then
        self.initialized = true
    elseif method == "notifications/cancelled" then
        -- Requests are handled synchronously, so there is nothing to cancel
        logger.dbg("MCP: Client cancelled request", params and params.requestId)
    else
        logger.dbg("MCP: Ignoring notification", method)
    end
end

function MCPProtocol:resourcesSubscription(method, params)
    if not self.resources then
        return nil, { code = INTERNAL_ERROR, message = "Resources not available" }
    end
    if not params.uri then
        return nil, { code = INVALID_PARAMS, message = "Invalid params: missing uri" }
    end
    local ok, err = pcall(function()
        if method == "resources/subscribe" then
            self.resources:subscribe(params.uri)
        else
            self.resources:unsubscribe(params.uri)
        end
    end)
    if not ok then
        logger.err("Error updating resource subscription:", err)
        return nil, { code = INTERNAL_ERROR, message = "Internal error" }
    end
    return {}
end

--------------------------------------------------------------------------------
-- Modern (stateless) protocol: 2026-07-28
--------------------------------------------------------------------------------

function MCPProtocol:handleModernMessage(jsonRequest, method, id, params, meta, headers)
    -- Clients send only requests (and, on stdio, cancellations) in this revision
    if method == nil then
        return self:createErrorResponse(id, INVALID_REQUEST, "Invalid Request: clients must not send responses", 400)
    end
    if id == nil then
        logger.dbg("MCP: Ignoring notification", method)
        return self:createAcceptedResponse()
    end

    -- Version: required in _meta, and must be one we speak
    local version = meta[META_PROTOCOL_VERSION]
    if type(version) ~= "string" then
        return self:createErrorResponse(id, INVALID_PARAMS,
            "Invalid params: _meta is missing " .. META_PROTOCOL_VERSION, 400)
    end
    if not contains(MODERN_VERSIONS, version) then
        return self:createErrorResponse(id, UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version", 400,
            { supported = ALL_VERSIONS, requested = version })
    end
    if type(meta[META_CLIENT_CAPABILITIES]) ~= "table" then
        return self:createErrorResponse(id, INVALID_PARAMS,
            "Invalid params: _meta is missing " .. META_CLIENT_CAPABILITIES, 400)
    end

    -- Streamable HTTP mirrors body fields into headers; they must agree
    local mismatch = self:checkMirroredHeaders(method, params, version, headers)
    if mismatch then
        return self:createErrorResponse(id, HEADER_MISMATCH, mismatch, 400)
    end

    local client_info = meta[META_CLIENT_INFO]
    if type(client_info) == "table" and client_info.name then
        logger.dbg("MCP: Request from", client_info.name, client_info.version)
    end

    local ctx = {
        modern = true,
        clientCapabilities = meta[META_CLIENT_CAPABILITIES],
        inputResponses = params.inputResponses,
        requestState = params.requestState,
    }

    local result, err, cache
    if method == "server/discover" then
        result, cache = {
            supportedVersions = ALL_VERSIONS,
            capabilities = self:modernCapabilities(),
            instructions = INSTRUCTIONS,
        }, CACHE_STATIC
    else
        result, err, cache = self:dispatch(method, params, ctx)
        if result == nil and err == nil then
            -- Removed in 2026-07-28 (ping, logging/setLevel, resources/subscribe,
            -- initialize) or never implemented
            return self:createErrorResponse(id, METHOD_NOT_FOUND, "Method not found: " .. tostring(method), 404)
        end
    end

    if err then
        return self:respond(id, nil, err)
    end

    result.resultType = result.resultType or "complete"
    result._meta = result._meta or {}
    result._meta[META_SERVER_INFO] = self.serverInfo
    -- Interim input_required results aren't cacheable
    if cache and result.resultType == "complete" then
        result.ttlMs = cache.ttlMs
        result.cacheScope = cache.cacheScope
    end
    return self:createSuccessResponse(id, result)
end

-- @return an error message, or nil if the headers match the body
function MCPProtocol:checkMirroredHeaders(method, params, version, headers)
    local header_version = headers["mcp-protocol-version"]
    if header_version == nil then
        return "Header mismatch: MCP-Protocol-Version header is missing"
    elseif header_version ~= version then
        return "Header mismatch: MCP-Protocol-Version header value '" .. header_version
            .. "' does not match body value '" .. version .. "'"
    end

    local header_method = headers["mcp-method"]
    if header_method == nil then
        return "Header mismatch: Mcp-Method header is missing"
    elseif header_method ~= method then
        return "Header mismatch: Mcp-Method header value '" .. header_method
            .. "' does not match body value '" .. tostring(method) .. "'"
    end

    local name_field = MCP_NAME_SOURCE[method]
    if name_field then
        local raw = headers["mcp-name"]
        if raw == nil then
            return "Header mismatch: Mcp-Name header is missing"
        end
        local decoded = MRTR.decodeHeaderValue(raw)
        if decoded == nil then
            return "Header mismatch: Mcp-Name header has invalid Base64 encoding"
        elseif decoded ~= params[name_field] then
            return "Header mismatch: Mcp-Name header does not match params." .. name_field
        end
    end
    return nil
end

-- Capabilities as advertised to stateless clients
function MCPProtocol:modernCapabilities()
    local caps = {}
    if self.capabilities.tools then caps.tools = {} end
    if self.capabilities.prompts then caps.prompts = {} end
    if self.capabilities.resources then caps.resources = {} end
    return caps
end

--------------------------------------------------------------------------------
-- Shared method implementations
--------------------------------------------------------------------------------

-- Run a server method.
-- @param ctx table: { modern, clientCapabilities, inputResponses, requestState }
-- @return result, error ({code, message}), cache hint; or nothing if the
--         method is unknown
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

function MCPProtocol:dispatch(method, params, ctx)
    if method == "tools/list" then
        if not self.tools then return nil, { code = INTERNAL_ERROR, message = "Tools not available" } end
        return self:safely("listing tools", function()
            return { tools = self.tools:list() }
        end, CACHE_STATIC)

    elseif method == "tools/call" then
        if not self.tools then return nil, { code = INTERNAL_ERROR, message = "Tools not available" } end
        if not params.name then
            return nil, { code = INVALID_PARAMS, message = "Invalid params: missing name" }
        end
        local arguments = type(params.arguments) == "table" and params.arguments or {}
        local ok, result = pcall(function()
            return self.tools:call(params.name, arguments, ctx)
        end)
        if not ok then
            -- Tool execution errors are results the model can see, not protocol errors
            logger.err("Error calling tool:", result)
            return {
                content = { { type = "text", text = "Error: " .. tostring(result) } },
                isError = true,
            }
        end
        if not result then
            return nil, { code = INVALID_PARAMS, message = "Unknown tool: " .. tostring(params.name) }
        end
        return adaptToolResult(result, ctx and ctx.version)

    elseif method == "resources/list" then
        if not self.resources then return nil, { code = INTERNAL_ERROR, message = "Resources not available" } end
        return self:safely("listing resources", function()
            return { resources = self.resources:list() }
        end, CACHE_LIVE)

    elseif method == "resources/templates/list" then
        if not self.resources then return nil, { code = INTERNAL_ERROR, message = "Resources not available" } end
        return self:safely("listing resource templates", function()
            return { resourceTemplates = self.resources:listTemplates() or {} }
        end, CACHE_STATIC)

    elseif method == "resources/read" then
        if not self.resources then return nil, { code = INTERNAL_ERROR, message = "Resources not available" } end
        if not params.uri then
            return nil, { code = INVALID_PARAMS, message = "Invalid params: missing uri" }
        end
        local result, err = self:safely("reading resource", function()
            return self.resources:read(params.uri)
        end)
        if err then return nil, err end
        if not result then
            return nil, { code = INVALID_PARAMS, message = "Resource not found: " .. tostring(params.uri) }
        end
        return { contents = result }, nil, CACHE_LIVE

    elseif method == "prompts/list" then
        if not self.prompts then return nil, { code = INTERNAL_ERROR, message = "Prompts not available" } end
        return self:safely("listing prompts", function()
            return { prompts = self.prompts:list() }
        end, CACHE_STATIC)

    elseif method == "prompts/get" then
        if not self.prompts then return nil, { code = INTERNAL_ERROR, message = "Prompts not available" } end
        if not params.name then
            return nil, { code = INVALID_PARAMS, message = "Invalid params: missing name" }
        end
        local arguments = type(params.arguments) == "table" and params.arguments or {}
        local ok, result, prompt_err = pcall(function()
            return self.prompts:get(params.name, arguments)
        end)
        if not ok then
            logger.err("Error getting prompt:", result)
            return nil, { code = INTERNAL_ERROR, message = "Internal error" }
        end
        if not result then
            return nil, { code = INVALID_PARAMS, message = prompt_err or "Prompt not found" }
        end
        return result
    end
    -- unknown method: return nothing
end

-- Run fn under pcall; map failures to an internal error
function MCPProtocol:safely(what, fn, cache)
    local ok, result = pcall(fn)
    if not ok then
        logger.err("Error " .. what .. ":", result)
        return nil, { code = INTERNAL_ERROR, message = "Internal error" }
    end
    return result, nil, cache
end

-- Turn a dispatch outcome into an HTTP response
function MCPProtocol:respond(id, result, err)
    if err then
        return self:createErrorResponse(id, err.code, err.message, err.http_status, err.data)
    end
    return self:createSuccessResponse(id, result)
end

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

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

return MCPProtocol
