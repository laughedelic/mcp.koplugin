--[[
    MCP HTTP Server
    Implements a simple HTTP server for handling MCP (Model Context Protocol) requests
    Based on the notificationlistener.koplugin implementation
--]]

local socket = require("socket")
local logger = require("logger")

local MCPServer = {
    port = 8788,  -- Default port for MCP server
    server = nil,
    running = false,
}

function MCPServer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Force kill any process using the port
function MCPServer:forceReleasePort(port)
    logger.info("MCP: Attempting to release port", port)
    -- Try to find and kill any process using this port
    os.execute(string.format("fuser -k %d/tcp 2>/dev/null", port))
    -- Give it a moment to release
    socket.sleep(0.2)
end

-- Check if port is available
function MCPServer:isPortAvailable(port)
    local test = socket.tcp()
    test:setoption("reuseaddr", true)
    local ok = test:bind("0.0.0.0", port)
    test:close()
    return ok ~= nil
end

function MCPServer:start(port, onRequest, forceRestart)
    if self.running and not forceRestart then
        logger.warn("MCP Server already running")
        return false
    end

    -- If force restart, stop existing server first
    if self.running then
        self:stop()
        socket.sleep(0.1)
    end

    self.port = port or self.port
    self.onRequest = onRequest

    -- Force release port if it might be stuck
    if not self:isPortAvailable(self.port) then
        logger.warn("MCP: Port", self.port, "appears to be in use, attempting to release")
        self:forceReleasePort(self.port)
    end

    -- Create TCP socket
    local server = socket.tcp()
    if not server then
        logger.err("Failed to create TCP socket")
        return false
    end

    -- Allow address reuse to avoid "address already in use" errors
    server:setoption("reuseaddr", true)

    -- Bind to all interfaces with retry logic
    local ok, err
    local retries = 3
    for i = 1, retries do
        ok, err = server:bind("0.0.0.0", self.port)
        if ok then break end
        logger.warn("MCP: Bind attempt", i, "failed:", err, "- retrying...")
        server:close()
        self:forceReleasePort(self.port)
        server = socket.tcp()
        server:setoption("reuseaddr", true)
    end
    if not ok then
        logger.err("Failed to bind MCP server to port", self.port, ":", err)
        server:close()
        return false
    end

    -- Start listening for connections (backlog of 5 pending connections)
    ok, err = server:listen(5)
    if not ok then
        logger.err("Failed to listen on port", self.port, ":", err)
        server:close()
        return false
    end

    -- Set non-blocking mode for async operation
    server:settimeout(0)
    self.server = server
    self.running = true

    logger.info("MCP Server started on port", self.port)
    return true
end

function MCPServer:stop()
    if not self.running then
        return
    end

    if self.server then
        self.server:close()
        self.server = nil
    end

    self.running = false
    logger.info("MCP Server stopped")
end

function MCPServer:pollOnce()
    if not self.running or not self.server then
        return
    end

    -- Accept incoming connection
    local client, err = self.server:accept()
    if not client then
        -- No connection available (non-blocking mode)
        return
    end

    -- Set timeout for client operations (longer timeout for slow e-reader devices)
    client:settimeout(5)

    -- Parse the HTTP request
    local request = self:parseRequest(client)
    if not request then
        client:close()
        return
    end

    -- Handle the request and get response
    local response = {
        status = 200,
        statusText = "OK",
        headers = {},
        body = ""
    }

    local origin = request.headers["origin"]
    local rejection = self:checkRequest(request)
    if rejection then
        response = rejection
    elseif request.method == "OPTIONS" then
        -- CORS preflight from a browser-based MCP client on an allowed origin
        response = { status = 204, statusText = "No Content", headers = {}, body = "" }
    elseif self.onRequest then
        local ok, result = pcall(self.onRequest, request)
        if ok and result then
            response = result
        else
            logger.err("Error handling MCP request:", result or "unknown error")
            response.status = 500
            response.statusText = "Internal Server Error"
            response.body = "Internal server error"
        end
    end

    -- Browser-based clients (e.g. MCP Inspector) need CORS headers
    if origin and not rejection then
        response.headers = response.headers or {}
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] =
            "Content-Type, Accept, Authorization, MCP-Protocol-Version, Mcp-Session-Id"
        response.headers["Vary"] = "Origin"
    end

    -- Send response
    self:sendResponse(client, response)
    client:close()
end

-- Hosts that may appear in an Origin header. Anything else is a web page on
-- another site trying to reach this server through the user's browser
-- (DNS rebinding), which the MCP spec requires servers to reject.
function MCPServer:isAllowedOrigin(origin)
    if origin == "null" then
        return false
    end
    local host = origin:match("^%a[%w+.-]*://%[([^%]]+)%]") -- [IPv6]
        or origin:match("^%a[%w+.-]*://([^/:]+)")
    if not host then
        return false
    end
    host = host:lower()
    if host == "localhost" or host == "127.0.0.1" or host == "::1" then
        return true
    end
    local local_ip = self:getLocalIP()
    return local_ip ~= nil and host == local_ip
end

-- Transport-level validation shared by all requests.
-- @return an error response, or nil if the request may proceed
function MCPServer:checkRequest(request)
    local origin = request.headers["origin"]
    if origin and not self:isAllowedOrigin(origin) then
        logger.warn("MCP: Rejected request from origin", origin)
        return {
            status = 403,
            statusText = "Forbidden",
            headers = {},
            body = '{"jsonrpc":"2.0","error":{"code":-32600,"message":"Origin not allowed"}}',
        }
    end

    -- The MCP endpoint is /mcp; / is accepted too for URLs configured without a path
    if request.path ~= "/mcp" and request.path ~= "/mcp/" and request.path ~= "/" then
        return {
            status = 404,
            statusText = "Not Found",
            headers = {},
            body = '{"jsonrpc":"2.0","error":{"code":-32601,"message":"Not found: the MCP endpoint is /mcp"}}',
        }
    end

    return nil
end

function MCPServer:parseRequest(client)
    local request = {
        method = "",
        path = "",
        headers = {},
        body = ""
    }

    -- Read request line
    local line, err = client:receive("*l")
    if not line then
        logger.warn("Failed to read request line:", err)
        return nil
    end

    -- Parse request line: METHOD PATH HTTP/VERSION
    local method, uri = line:match("^(%S+)%s+(%S+)%s+HTTP/")
    if not method or not uri then
        logger.warn("Invalid request line:", line)
        return nil
    end

    request.method = method
    request.path = uri:match("^([^?]*)")  -- Remove query string

    -- Read headers
    while true do
        line, err = client:receive("*l")
        if not line or line == "" then
            break
        end

        local key, value = line:match("^([^:]+):%s*(.*)$")
        if key and value then
            request.headers[key:lower()] = value
        end
    end

    -- Read body if present
    local contentLength = tonumber(request.headers["content-length"] or 0)
    if contentLength > 0 then
        -- Limit body size to 1MB for safety
        if contentLength > 1024 * 1024 then
            logger.warn("Request body too large:", contentLength)
            return nil
        end

        local body, err = client:receive(contentLength)
        if body then
            request.body = body
        else
            logger.warn("Failed to read request body:", err)
        end
    end

    return request
end

function MCPServer:sendResponse(client, response)
    local statusText = response.statusText or "OK"
    local status = response.status or 200

    -- Build response
    local resp = "HTTP/1.1 " .. status .. " " .. statusText .. "\r\n"

    -- Add default headers
    local body = response.body or ""
    resp = resp .. "Connection: close\r\n"
    if #body > 0 and not (response.headers and response.headers["Content-Type"]) then
        resp = resp .. "Content-Type: application/json\r\n"
    end

    -- Add custom headers
    for key, value in pairs(response.headers or {}) do
        resp = resp .. key .. ": " .. value .. "\r\n"
    end

    -- Add body
    resp = resp .. "Content-Length: " .. #body .. "\r\n"
    resp = resp .. "\r\n"
    resp = resp .. body

    -- Send response
    client:send(resp)
end

function MCPServer:getLocalIP()
    -- Get local IP by creating a UDP connection (no data sent)
    local udp = socket.udp()
    udp:setpeername("8.8.8.8", 80)
    local ip, _ = udp:getsockname()
    udp:close()
    return ip
end

return MCPServer
