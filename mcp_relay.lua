--[[
    MCP Cloud Relay Client

    Connects to a cloud relay server to enable remote access to the MCP server
    from anywhere. Uses HTTP long-polling since KOReader doesn't have native
    WebSocket support.

    The relay flow:
    1. Device generates credentials locally (deviceId from Device.model + suffix, random passcode)
    2. Device registers with relay, sending deviceId + SHA-256 hash of passcode
    3. Relay stores the hash, returns public MCP URL
    4. Device shows passcode to user (who enters it in Claude Desktop / other MCP clients)
    5. MCP client authenticates via OAuth password grant (deviceId + passcode → JWT token)
    6. Device polls for incoming requests, forwards to local MCP server

    Implementation notes:
    - Uses non-blocking LuaSocket with settimeout(0) for truly async networking
    - Polls sockets via UIManager:scheduleIn for seamless UI integration
    - socket.select checks readability without blocking the main loop
    - Request guards prevent duplicate in-flight requests
    - SHA-256 hashing uses KOReader's ffi/sha2.lua (pure Lua implementation)
--]]

local json = require("json")
local logger = require("logger")
local socket = require("socket")
local ssl = require("ssl")
local url = require("socket.url")
local sha2 = require("ffi/sha2")
local Device = require("device")

local MCPRelay = {
    -- Configuration
    relay_url = "https://mcp-relay.laughedelic.workers.dev", -- Default relay URL
    device_id = nil,
    device_name = nil,
    public_url = nil,

    -- OAuth credentials (device-generated)
    passcode = nil,       -- 6-digit passcode (generated locally, shown to user)
    passcode_hash = nil,  -- SHA-256 hash of passcode (sent to relay for storage)
    token_endpoint = nil, -- OAuth token endpoint URL

    -- State
    connected = false,
    running = false,
    poll_scheduled = false,
    reconnect_scheduled = false,
    consecutive_empty_polls = 0, -- Track empty polls for adaptive polling

    -- Request guards (prevent duplicate in-flight requests)
    _registering = false,
    _polling = false,
    _sending_response = false,

    -- Active async requests (for non-blocking HTTP)
    _active_requests = {},

    -- Callbacks
    onRequest = nil,           -- function(request) -> response
    onStatusChange = nil,      -- function(connected, public_url)
    onFirstRegistration = nil, -- function(device_id, passcode, public_url) - called only on first registration with new passcode

    -- Timing (tuned for battery/responsiveness balance)
    poll_interval_min = 0.5,    -- minimum seconds between polls (when active)
    poll_interval_max = 5,      -- maximum seconds between polls (when idle)
    reconnect_delay = 5,        -- seconds before reconnect attempt
    request_timeout = 35,       -- seconds to wait for HTTP response (> server's 30s poll timeout)
    connect_timeout = 10,       -- seconds to wait for connection
    socket_poll_interval = 0.1, -- seconds between socket readability checks
}

function MCPRelay:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    -- Initialize instance-specific tables
    o._active_requests = {}
    return o
end

-- Generate a device ID using the actual device model + 4-char suffix
-- Example: "KoboClara-a7b2" or "Kindle-px9c"
function MCPRelay:generateDeviceId()
    -- Get the device model from KOReader's Device API
    -- Use ota_model if available (more specific), otherwise fall back to model
    local device_model = Device.ota_model or Device.model or "KOReader"

    -- Clean up the model name: remove spaces, special characters
    local clean_model = device_model:gsub("[^%w%-_]", "")

    -- Use os.time() with milliseconds from os.clock() for randomness
    math.randomseed(os.time() + math.floor(os.clock() * 1000))

    -- Generate 4-character suffix for uniqueness
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local suffix = ""
    for _ = 1, 4 do
        local idx = math.random(1, #chars)
        suffix = suffix .. chars:sub(idx, idx)
    end

    return clean_model .. "-" .. suffix
end

-- Generate a random 6-digit numeric passcode
function MCPRelay:generatePasscode()
    -- Use os.time() with milliseconds from os.clock() for randomness
    math.randomseed(os.time() + math.floor(os.clock() * 1000))

    local passcode = ""
    for _ = 1, 6 do
        passcode = passcode .. tostring(math.random(0, 9))
    end

    return passcode
end

-- Hash a passcode using SHA-256 (returns hex string)
function MCPRelay:hashPasscode(passcode)
    return sha2.sha256(passcode)
end

-- Generate new credentials (device ID + passcode + hash)
-- Returns: device_id, passcode, passcode_hash
function MCPRelay:generateCredentials()
    local device_id = self:generateDeviceId()
    local passcode = self:generatePasscode()
    local passcode_hash = self:hashPasscode(passcode)

    return device_id, passcode, passcode_hash
end

-- Set the relay server URL
function MCPRelay:setRelayUrl(relay_url)
    self.relay_url = relay_url
end

-- Set the device ID (for reconnection with same ID)
function MCPRelay:setDeviceId(device_id)
    self.device_id = device_id
end

-- Set a human-readable device name
function MCPRelay:setDeviceName(name)
    self.device_name = name
end

-- Set the stored passcode (for UI display and re-registration)
function MCPRelay:setPasscode(passcode)
    self.passcode = passcode
    if passcode then
        self.passcode_hash = self:hashPasscode(passcode)
    end
end

-- Set the passcode hash directly (for restoring from saved settings)
function MCPRelay:setPasscodeHash(hash)
    self.passcode_hash = hash
end

-- Get the passcode (only available during this session after generation)
function MCPRelay:getPasscode()
    return self.passcode
end

-- Get the passcode hash
function MCPRelay:getPasscodeHash()
    return self.passcode_hash
end

-- Get the token endpoint URL
function MCPRelay:getTokenEndpoint()
    return self.token_endpoint
end

-- Get the public URL for this device
function MCPRelay:getPublicUrl()
    return self.public_url
end

-- Get the current device ID
function MCPRelay:getDeviceId()
    return self.device_id
end

-- Check if connected to relay
function MCPRelay:isConnected()
    return self.connected
end

-- Set request handler callback
function MCPRelay:setRequestHandler(handler)
    self.onRequest = handler
end

-- Set status change callback
function MCPRelay:setStatusCallback(callback)
    self.onStatusChange = callback
end

-- Set first registration callback (called when device gets a new passcode)
function MCPRelay:setFirstRegistrationCallback(callback)
    self.onFirstRegistration = callback
end

--[[
    Non-blocking HTTP Request System

    Uses LuaSocket with settimeout(0) for non-blocking I/O.
    Polls sockets via UIManager:scheduleIn to integrate with KOReader's event loop.

    Flow:
    1. Create TCP socket, set timeout to 0 (non-blocking)
    2. Start async connect (returns immediately with "timeout")
    3. Poll with socket.select until connected
    4. Wrap with SSL and perform async handshake
    5. Send HTTP request
    6. Poll for response data
    7. Parse and return via callback
--]]

-- Parse URL into components
function MCPRelay:parseUrl(request_url)
    local parsed = url.parse(request_url)
    return {
        host = parsed.host,
        port = tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80),
        path = (parsed.path or "/") .. (parsed.query and ("?" .. parsed.query) or ""),
        scheme = parsed.scheme,
    }
end

-- Create HTTP request string
function MCPRelay:buildHttpRequest(method, parsed_url, body, extra_headers)
    local headers = {
        ["Host"] = parsed_url.host,
        ["User-Agent"] = "KOReader-MCP-Plugin/1.0",
        ["Accept"] = "application/json",
        ["Connection"] = "close",
    }

    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end

    -- Merge extra headers
    if extra_headers then
        for k, v in pairs(extra_headers) do
            headers[k] = v
        end
    end

    local request_lines = {
        string.format("%s %s HTTP/1.1", method or "GET", parsed_url.path),
    }

    for name, value in pairs(headers) do
        table.insert(request_lines, string.format("%s: %s", name, value))
    end

    table.insert(request_lines, "") -- Empty line before body
    table.insert(request_lines, body or "")

    return table.concat(request_lines, "\r\n")
end

-- Parse HTTP response
function MCPRelay:parseHttpResponse(raw_response)
    local response = {
        code = nil,
        headers = {},
        body = "",
    }

    -- Split headers and body
    local header_end = raw_response:find("\r\n\r\n")
    if not header_end then
        return response
    end

    local header_part = raw_response:sub(1, header_end - 1)
    response.body = raw_response:sub(header_end + 4)

    -- Parse status line
    local status_line = header_part:match("^([^\r\n]+)")
    if status_line then
        response.code = tonumber(status_line:match("HTTP/%d%.%d (%d+)"))
    end

    -- Parse headers
    for line in header_part:gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:]+):%s*(.+)$")
        if name then
            response.headers[name:lower()] = value
        end
    end

    return response
end

-- Non-blocking HTTP request using LuaSocket + UIManager scheduling
function MCPRelay:httpRequestAsync(request_url, method, body, callback, extra_headers)
    local UIManager = require("ui/uimanager")
    local parsed = self:parseUrl(request_url)
    local is_https = parsed.scheme == "https"

    -- Generate unique request ID for tracking
    local request_id = tostring(socket.gettime()) .. "_" .. math.random(1000, 9999)
    local start_time = socket.gettime()

    logger.dbg("MCP Relay: Starting async request", request_id, method or "GET", request_url)

    -- Request state
    local state = {
        id = request_id,
        phase = "connecting", -- connecting, handshake, sending, receiving
        sock = nil,
        ssl_sock = nil,
        response_buffer = {},
        start_time = start_time,
        timeout_at = start_time + self.request_timeout,
        connect_timeout_at = start_time + self.connect_timeout,
    }

    -- Store active request
    self._active_requests[request_id] = state

    -- Cleanup function
    local function cleanup(success, response)
        if state.ssl_sock then
            pcall(function() state.ssl_sock:close() end)
        elseif state.sock then
            pcall(function() state.sock:close() end)
        end
        self._active_requests[request_id] = nil

        local elapsed = socket.gettime() - start_time
        if success then
            logger.dbg("MCP Relay: Request completed in", string.format("%.2fs", elapsed), request_id)
        else
            logger.dbg("MCP Relay: Request failed after", string.format("%.2fs", elapsed), request_id)
        end

        if callback then
            callback(response)
        end
    end

    -- Error handler
    local function on_error(err)
        logger.warn("MCP Relay: Request error:", err, "phase:", state.phase)
        cleanup(false, { code = nil, body = "", error = err })
    end

    -- Create TCP socket with non-blocking mode
    local sock = socket.tcp()
    sock:settimeout(0) -- Non-blocking
    state.sock = sock

    -- Start async connect
    local res, err = sock:connect(parsed.host, parsed.port)
    if err and err ~= "timeout" then
        on_error("Connect failed: " .. tostring(err))
        return
    end

    -- Poll function - called repeatedly via UIManager:scheduleIn
    local poll_socket
    poll_socket = function()
        -- Check if relay was stopped
        if not self.running then
            cleanup(false, { code = nil, body = "", error = "Relay stopped" })
            return
        end

        -- Check for timeout
        local now = socket.gettime()
        if now > state.timeout_at then
            on_error("Request timeout")
            return
        end

        if state.phase == "connecting" then
            -- Check connect timeout separately
            if now > state.connect_timeout_at then
                on_error("Connect timeout")
                return
            end

            -- Check if socket is writable (connected)
            local _, writable, err = socket.select(nil, { state.sock }, 0)
            if err then
                on_error("Select error: " .. tostring(err))
                return
            end

            if writable and #writable > 0 then
                -- Connected! Move to handshake or sending
                if is_https then
                    state.phase = "handshake"
                    -- Wrap socket with SSL
                    local ssl_params = {
                        mode = "client",
                        protocol = "any",
                        verify = "none", -- TODO: proper cert verification
                        options = { "all", "no_sslv3" },
                    }

                    local ssl_sock, wrap_err = ssl.wrap(state.sock, ssl_params)
                    if not ssl_sock then
                        on_error("SSL wrap failed: " .. tostring(wrap_err))
                        return
                    end

                    -- Set SNI (Server Name Indication) - required for Cloudflare and most modern hosts
                    ssl_sock:sni(parsed.host)

                    ssl_sock:settimeout(0) -- Non-blocking
                    state.ssl_sock = ssl_sock
                else
                    state.phase = "sending"
                end
            end
        end

        if state.phase == "handshake" then
            -- Continue SSL handshake
            local ok, err = state.ssl_sock:dohandshake()
            if ok then
                state.phase = "sending"
            elseif err == "wantread" or err == "wantwrite" or err == "timeout" then
                -- Handshake in progress, continue polling
            else
                on_error("SSL handshake failed: " .. tostring(err))
                return
            end
        end

        if state.phase == "sending" then
            -- Send HTTP request
            local active_sock = state.ssl_sock or state.sock
            local request_str = self:buildHttpRequest(method, parsed, body, extra_headers)

            local sent, err = active_sock:send(request_str)
            if sent then
                state.phase = "receiving"
            elseif err == "timeout" or err == "wantwrite" then
                -- Would block, continue polling
            else
                on_error("Send failed: " .. tostring(err))
                return
            end
        end

        if state.phase == "receiving" then
            -- Poll for readable data
            local active_sock = state.ssl_sock or state.sock
            local readable, _, err = socket.select({ active_sock }, nil, 0)

            if readable and #readable > 0 then
                -- Data available, read it
                local chunk, err, partial = active_sock:receive("*a")
                local data = chunk or partial

                if data and #data > 0 then
                    table.insert(state.response_buffer, data)
                end

                if err == "closed" then
                    -- Connection closed, response complete
                    local raw_response = table.concat(state.response_buffer)
                    local response = self:parseHttpResponse(raw_response)
                    cleanup(true, response)
                    return
                elseif err and err ~= "timeout" and err ~= "wantread" then
                    on_error("Receive error: " .. tostring(err))
                    return
                end
            end
        end

        -- Schedule next poll
        UIManager:scheduleIn(self.socket_poll_interval, poll_socket)
    end

    -- Start polling
    UIManager:scheduleIn(self.socket_poll_interval, poll_socket)
end

-- HTTP request entry point
function MCPRelay:httpRequest(request_url, method, body, callback, extra_headers)
    self:httpRequestAsync(request_url, method, body, callback, extra_headers)
end

-- HTTP POST helper
function MCPRelay:httpPost(request_url, body, callback, extra_headers)
    self:httpRequest(request_url, "POST", body, callback, extra_headers)
end

-- HTTP GET helper
function MCPRelay:httpGet(request_url, callback, extra_headers)
    self:httpRequest(request_url, "GET", nil, callback, extra_headers)
end

-- Standard headers for device requests
function MCPRelay:getDeviceHeaders()
    if not self.device_id then
        return {}
    end
    return {
        ["X-Device-Id"] = self.device_id,
    }
end

-- Register with the relay server
-- On first registration: generates credentials locally and sends hash to relay
-- On re-registration: uses stored hash for verification
function MCPRelay:register(callback)
    -- Guard against duplicate registration requests
    if self._registering then
        logger.dbg("MCP Relay: Registration already in progress, skipping")
        return
    end

    -- Check if this is a first registration (no credentials yet)
    local is_first_registration = not self.device_id or not self.passcode_hash

    if is_first_registration then
        -- Generate new credentials locally
        local device_id, passcode, passcode_hash = self:generateCredentials()
        self.device_id = device_id
        self.passcode = passcode -- Save for display to user
        self.passcode_hash = passcode_hash

        logger.info("MCP Relay: Generated new credentials for device:", self.device_id)
    end

    local register_url = self.relay_url .. "/register"

    local payload_data = {
        deviceId = self.device_id,
        deviceName = self.device_name,
        passcodeHash = self.passcode_hash, -- Always send hash for verification
        version = "2.0.0",
    }

    local payload = json.encode(payload_data)

    logger.info("MCP Relay: Registering with relay at", register_url,
        is_first_registration and "(first time)" or "(reconnection)")
    local register_start_time = socket.gettime()
    self._registering = true

    self:httpPost(register_url, payload, function(response)
        local elapsed = socket.gettime() - register_start_time
        self._registering = false

        if not self.running then
            -- Relay was stopped while registering
            return
        end

        if not response or response.code ~= 200 then
            local error_msg = response and response.code or "Connection failed"
            logger.err("MCP Relay: Registration failed after", string.format("%.2fs", elapsed), "-", error_msg)
            if callback then
                callback(false, "Registration failed: " .. tostring(error_msg))
            end
            return
        end

        local ok, data = pcall(json.decode, response.body)
        if not ok or data.error then
            local error_msg = (data and data.error) or "Invalid response"
            logger.err("MCP Relay: Registration error after", string.format("%.2fs", elapsed), "-", error_msg)
            if callback then
                callback(false, error_msg)
            end
            return
        end

        -- Save the public URL and token endpoint
        self.public_url = data.relayUrl or (self.relay_url .. "/mcp")
        self.token_endpoint = data.tokenEndpoint or (self.relay_url .. "/oauth/token")
        self.connected = true
        self.reconnect_scheduled = false -- Clear reconnect flag on successful connection

        logger.info("MCP Relay: Registered successfully in", string.format("%.2fs", elapsed), "- public URL:",
            self.public_url)

        -- On first registration, call callback to show passcode to user
        -- (passcode was generated locally, so we have it available)
        if is_first_registration and self.passcode then
            logger.info("MCP Relay: First registration complete, showing credentials to user")

            -- Call first registration callback to show setup info
            if self.onFirstRegistration then
                self.onFirstRegistration(self.device_id, self.passcode, self.public_url, self.token_endpoint)
            end

            -- Clear the plaintext passcode from memory after showing
            -- (keep the hash for re-registration)
            -- Note: We keep it for now so the user can view it in settings
            -- self.passcode = nil
        end

        -- Notify status change
        if self.onStatusChange then
            self.onStatusChange(true, self.public_url)
        end

        if callback then
            callback(true)
        end
    end, self:getDeviceHeaders())
end

-- Poll for incoming requests
function MCPRelay:pollForRequests()
    -- Guard against duplicate polls
    if self._polling then
        logger.dbg("MCP Relay: Poll already in progress, skipping")
        return
    end

    if not self.connected or not self.running then
        logger.dbg("MCP Relay: Not connected or not running, skipping poll")
        return
    end

    local poll_url = self.relay_url .. "/poll"
    local poll_start_time = socket.gettime()

    self._polling = true
    self.poll_scheduled = false

    self:httpGet(poll_url, function(response)
        local poll_elapsed = socket.gettime() - poll_start_time
        self._polling = false

        if not self.running then
            -- Stopped while waiting for response
            return
        end

        if not response or not response.code then
            -- Connection error - mark as disconnected and try to reconnect
            logger.warn("MCP Relay: Poll failed after", string.format("%.2fs", poll_elapsed), "- no response")
            self:handleDisconnect()
            return
        end

        local status = response.code

        if status == 204 then
            -- No pending requests, track for adaptive polling
            self.consecutive_empty_polls = self.consecutive_empty_polls + 1
            logger.dbg("MCP Relay: Poll returned 204 (no requests) in", string.format("%.2fs", poll_elapsed))
            self:scheduleNextPoll()
            return
        end

        if status == 410 then
            -- Device session expired, need to re-register
            logger.info("MCP Relay: Session expired after", string.format("%.2fs", poll_elapsed), "- re-registering")
            self:handleDisconnect()
            return
        end

        if status ~= 200 then
            logger.warn("MCP Relay: Unexpected poll status:", status, "after", string.format("%.2fs", poll_elapsed))
            self:scheduleNextPoll()
            return
        end

        -- Parse the request
        logger.info("MCP Relay: Poll received request in", string.format("%.2fs", poll_elapsed))
        self:handlePollResponse(response.body)
    end, self:getDeviceHeaders())
end

-- Handle the poll response body
function MCPRelay:handlePollResponse(response_body)
    -- We got a response with content, reset the empty poll counter
    self.consecutive_empty_polls = 0

    -- Parse the request
    local ok, request_data = pcall(json.decode, response_body)
    if not ok then
        logger.err("MCP Relay: Failed to parse poll response")
        self:scheduleNextPoll()
        return
    end

    -- Handle the request
    if request_data.type == "request" and request_data.requestId then
        self:handleRelayedRequest(request_data)
    elseif request_data.type == "server_response" and request_data.requestId then
        -- Response to a server-initiated request
        self:handleServerResponse(request_data)
        self:scheduleNextPoll()
    elseif request_data.type == "ping" then
        -- Ping from server means connection is healthy, but no real request
        -- Don't count as "empty" since it's just a keep-alive
        logger.dbg("MCP Relay: Received ping from server")
        self:sendPong()
        self:scheduleNextPoll()
    else
        -- Unknown request type, just schedule next poll
        logger.dbg("MCP Relay: Unknown response type:", request_data.type)
        self:scheduleNextPoll()
    end
end

-- Handle a response to a server-initiated request
function MCPRelay:handleServerResponse(response_data)
    local request_id = tostring(response_data.requestId)
    logger.dbg("MCP Relay: Received server response for request", request_id)

    self._pending_server_requests = self._pending_server_requests or {}
    local callback = self._pending_server_requests[request_id]

    if callback then
        self._pending_server_requests[request_id] = nil

        -- Parse the response body
        local ok, response = pcall(json.decode, response_data.body or "{}")
        if ok then
            callback(response)
        else
            callback(nil, "Failed to parse response")
        end
    else
        logger.warn("MCP Relay: No callback for server response", request_id)
    end
end

-- Handle a request relayed from the cloud
function MCPRelay:handleRelayedRequest(request_data)
    local request_start_time = socket.gettime()
    logger.info("MCP Relay: Handling relayed request", request_data.requestId)

    local mcp_request = {
        method = request_data.method or "POST",
        path = request_data.path or "/mcp",
        headers = request_data.headers or {},
        body = request_data.body or "",
    }

    local mcp_response = {
        status = 200,
        body = "",
    }

    -- Call the local MCP handler
    if self.onRequest then
        local ok, result = pcall(self.onRequest, mcp_request)
        if ok and result then
            mcp_response = result
        else
            logger.err("MCP Relay: Error handling request:", result or "unknown")
            mcp_response.status = 500
            mcp_response.body = json.encode({
                jsonrpc = "2.0",
                error = { code = -32000, message = "Internal error" },
                id = nil,
            })
        end
    end

    local process_time = socket.gettime() - request_start_time
    logger.dbg("MCP Relay: Request processed locally in", string.format("%.3fs", process_time))

    -- Send response back to relay
    self:sendResponse(request_data.requestId, mcp_response, request_start_time)
end

-- Send response back to the relay
function MCPRelay:sendResponse(request_id, response, request_start_time)
    local response_url = self.relay_url .. "/response"

    local payload = json.encode({
        type = "response",
        requestId = request_id,
        status = response.status or 200,
        headers = response.headers,
        body = response.body or "",
    })

    self:httpPost(response_url, payload, function(resp)
        local total_time = request_start_time and (socket.gettime() - request_start_time) or 0
        if not resp or resp.code ~= 200 then
            logger.warn("MCP Relay: Failed to send response:", resp and resp.code, "after",
                string.format("%.2fs", total_time))
        else
            logger.info("MCP Relay: Request", request_id, "completed in", string.format("%.2fs", total_time),
                "(total round-trip)")
        end
        -- Schedule next poll after sending response
        self:scheduleNextPoll()
    end, self:getDeviceHeaders())
end

-- Schedule the next poll using UIManager (with adaptive interval)
function MCPRelay:scheduleNextPoll()
    if not self.running or not self.connected then
        return
    end

    -- Prevent duplicate scheduling
    if self.poll_scheduled or self._polling then
        logger.dbg("MCP Relay: Poll already scheduled or in progress")
        return
    end

    -- Adaptive polling: increase interval after consecutive empty polls
    -- This saves battery when there's no activity
    local interval = self.poll_interval_min
    if self.consecutive_empty_polls > 0 then
        -- Exponential backoff: double interval for each empty poll, up to max
        interval = math.min(
            self.poll_interval_min * (2 ^ math.min(self.consecutive_empty_polls, 4)),
            self.poll_interval_max
        )
    end

    self.poll_scheduled = true

    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(interval, function()
        self:pollForRequests()
    end)
end

-- Send pong in response to ping
function MCPRelay:sendPong()
    local pong_url = self.relay_url .. "/pong"
    self:httpPost(pong_url, json.encode({ type = "pong" }), function(resp)
        -- Pong sent, no need to handle response
    end, self:getDeviceHeaders())
end

-- Send a notification to the client (server-initiated message)
-- notification: a JSON-RPC 2.0 notification object
function MCPRelay:sendNotification(notification)
    if not self.running or not self.connected then
        logger.dbg("MCP Relay: Cannot send notification - not connected")
        return false
    end

    local notify_url = self.relay_url .. "/notify"

    local payload = json.encode({
        type = "notification",
        body = json.encode(notification),
    })

    logger.dbg("MCP Relay: Sending notification:", notification.method)

    self:httpPost(notify_url, payload, function(resp)
        if not resp or resp.code ~= 200 then
            logger.warn("MCP Relay: Failed to send notification:", resp and resp.code)
        else
            logger.dbg("MCP Relay: Notification sent successfully")
        end
    end, self:getDeviceHeaders())

    return true
end

-- Send a request to the client (server-initiated, expects response)
-- request: a JSON-RPC 2.0 request object with id
-- callback: function(response) called when client responds
function MCPRelay:sendRequest(request, callback)
    if not self.running or not self.connected then
        logger.dbg("MCP Relay: Cannot send request - not connected")
        if callback then
            callback(nil, "Not connected")
        end
        return false
    end

    local req_url = self.relay_url .. "/request"

    local payload = json.encode({
        type = "server_request",
        requestId = tostring(request.id),
        body = json.encode(request),
    })

    logger.dbg("MCP Relay: Sending server request:", request.method, "id:", request.id)

    -- Store callback for when we get response
    self._pending_server_requests = self._pending_server_requests or {}
    if callback then
        self._pending_server_requests[tostring(request.id)] = callback
    end

    self:httpPost(req_url, payload, function(resp)
        if not resp or resp.code ~= 200 then
            logger.warn("MCP Relay: Failed to send server request:", resp and resp.code)
            -- Call callback with error
            local cb = self._pending_server_requests[tostring(request.id)]
            if cb then
                self._pending_server_requests[tostring(request.id)] = nil
                cb(nil, "Failed to send request")
            end
        else
            logger.dbg("MCP Relay: Server request sent, awaiting response")
            -- Response will come through the poll mechanism
        end
    end, self:getDeviceHeaders())

    return true
end

-- Handle disconnection
function MCPRelay:handleDisconnect()
    -- Don't trigger reconnect if already reconnecting or registering
    if self._registering or self.reconnect_scheduled then
        logger.dbg("MCP Relay: Already handling reconnection")
        return
    end

    local was_connected = self.connected
    self.connected = false
    self._polling = false
    self.poll_scheduled = false

    if was_connected and self.onStatusChange then
        self.onStatusChange(false, nil)
    end

    -- Schedule reconnect
    if self.running then
        self:scheduleReconnect()
    end
end

-- Schedule a reconnection attempt
function MCPRelay:scheduleReconnect()
    -- Prevent duplicate reconnect scheduling
    if self.reconnect_scheduled or self._registering then
        logger.dbg("MCP Relay: Reconnect already scheduled or registration in progress")
        return
    end

    logger.info("MCP Relay: Scheduling reconnect in", self.reconnect_delay, "seconds")
    self.reconnect_scheduled = true

    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(self.reconnect_delay, function()
        if not self.running then
            self.reconnect_scheduled = false
            return
        end

        if self.connected then
            -- Already reconnected (maybe via another path)
            self.reconnect_scheduled = false
            return
        end

        self:register(function(success)
            if success then
                -- Start polling after successful reconnection
                self:scheduleNextPoll()
            else
                -- Try again later
                self.reconnect_scheduled = false
                self:scheduleReconnect()
            end
        end)
    end)
end

-- Start the relay client
function MCPRelay:start()
    if self.running then
        logger.warn("MCP Relay: Already running")
        return false
    end

    logger.info("MCP Relay: Starting")
    self.running = true

    -- Reset all state flags
    self.consecutive_empty_polls = 0
    self.poll_scheduled = false
    self.reconnect_scheduled = false
    self._registering = false
    self._polling = false
    self._sending_response = false
    self._active_requests = {} -- Clear any stale requests

    -- Register with relay
    self:register(function(success, err)
        if success then
            -- Start polling after successful registration
            self:scheduleNextPoll()
        else
            logger.err("MCP Relay: Initial registration failed:", err)
            -- Will retry via reconnect mechanism
            self:scheduleReconnect()
        end
    end)

    return true, self.device_id
end

-- Stop the relay client
function MCPRelay:stop()
    if not self.running then
        return
    end

    logger.info("MCP Relay: Stopping")
    self.running = false
    self.connected = false

    -- Reset all state flags
    self.poll_scheduled = false
    self.reconnect_scheduled = false
    self._registering = false
    self._polling = false
    self._sending_response = false
    self.consecutive_empty_polls = 0

    -- Cancel any active requests (they will clean up on next poll)
    -- Note: The requests will check self.running and clean up gracefully
    for id, state in pairs(self._active_requests) do
        logger.dbg("MCP Relay: Cancelling active request", id)
        if state.ssl_sock then
            pcall(function() state.ssl_sock:close() end)
        elseif state.sock then
            pcall(function() state.sock:close() end)
        end
    end
    self._active_requests = {}

    -- Notify status change
    if self.onStatusChange then
        self.onStatusChange(false, nil)
    end
end

return MCPRelay
