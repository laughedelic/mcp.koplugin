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

function MCPServer:start(port, onRequest)
    if self.running then
        logger.warn("MCP Server already running")
        return false
    end

    self.port = port or self.port
    self.onRequest = onRequest

    -- Create and bind the server socket
    local server, err = socket.bind("0.0.0.0", self.port)
    if not server then
        logger.err("Failed to bind MCP server to port", self.port, ":", err)
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

    -- Set timeout for client operations
    client:settimeout(0.2)

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

    if self.onRequest then
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

    -- Send response
    self:sendResponse(client, response)
    client:close()
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
    resp = resp .. "Connection: close\r\n"
    resp = resp .. "Content-Type: application/json\r\n"

    -- Add custom headers
    for key, value in pairs(response.headers or {}) do
        resp = resp .. key .. ": " .. value .. "\r\n"
    end

    -- Add body
    local body = response.body or ""
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
