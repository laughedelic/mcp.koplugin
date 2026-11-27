--[[
    MCP Multi Round-Trip Requests (MCP 2026-07-28)

    In stateless MCP a server that needs input from the user (elicitation)
    doesn't send its own request to the client. It answers the original
    request with an "input_required" result; the client asks the user and
    retries the original request with `inputResponses` and the opaque
    `requestState` echoed back.

    This module builds those results and protects `requestState`: it is
    signed with a per-run random key and bound to the tool call it was
    issued for, with a short expiry, so a client can't replay it on a
    different call.

    Pure Lua (no bit library), so it also runs in plain Lua test VMs.
--]]

local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")

local MRTR = {}

local STATE_TTL_SECONDS = 600 -- the user may take a while to answer

--------------------------------------------------------------------------------
-- Base64 (RFC 4648, standard alphabet)
--------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do
    B64_INDEX[B64:sub(i, i)] = i - 1
end

function MRTR.base64Encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

-- @return decoded string, or nil if the input isn't valid base64
function MRTR.base64Decode(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%s", "")
    if #text % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #text, 4 do
        local chunk = text:sub(i, i + 3)
        local n, pad = 0, 0
        for j = 1, 4 do
            local ch = chunk:sub(j, j)
            local v
            if ch == "=" then
                -- padding only at the end of the last chunk
                if i + 3 ~= #text or j < 3 then return nil end
                pad = pad + 1
                v = 0
            else
                if pad > 0 then return nil end
                v = B64_INDEX[ch]
                if not v then return nil end
            end
            n = n * 64 + v
        end
        local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
        out[#out + 1] = bytes:sub(1, 3 - pad)
    end
    return table.concat(out)
end

-- Decode an HTTP header value that may use the MCP Base64 sentinel
-- (`=?base64?...?=`), as Mcp-Name does for non-ASCII names and URIs
function MRTR.decodeHeaderValue(value)
    if type(value) ~= "string" then return value end
    local encoded = value:match("^=%?base64%?(.*)%?=$")
    if encoded then
        return MRTR.base64Decode(encoded)
    end
    return value
end

--------------------------------------------------------------------------------
-- Signed request state
--------------------------------------------------------------------------------

-- Per-run signing key: states don't survive a KOReader restart, which is fine
-- (the client then just gets asked again)
local signing_key

local function getSigningKey()
    if not signing_key then
        local f = io and io.open and io.open("/dev/urandom", "rb")
        local bytes = f and f:read(32)
        if f then f:close() end
        if not bytes or #bytes < 32 then
            bytes = tostring(os.time()) .. tostring(os.clock()) .. tostring({})
        end
        signing_key = sha2.sha256(bytes)
    end
    return signing_key
end

local function sign(payload)
    local key = getSigningKey()
    -- Keyed hash with the key on both sides (no length-extension)
    return sha2.sha256(key .. "\n" .. payload .. "\n" .. key)
end

-- Stable digest of a tool call, so a state is only accepted on the same call
function MRTR.callDigest(method, name, arguments)
    local keys = {}
    for k in pairs(arguments or {}) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = { method or "", name or "" }
    for _, k in ipairs(keys) do
        local v = arguments[k]
        parts[#parts + 1] = k .. "=" .. (type(v) == "table" and rapidjson.encode(v) or tostring(v))
    end
    return sha2.sha256(table.concat(parts, "\0"))
end

-- @param step string: which question this state belongs to
-- @param digest string: from MRTR.callDigest
-- @param data table|nil: extra server data to carry across the retry
function MRTR.encodeState(step, digest, data)
    local payload = MRTR.base64Encode(rapidjson.encode({
        s = step,
        d = digest,
        e = os.time() + STATE_TTL_SECONDS,
        x = data,
    }))
    return payload .. "." .. sign(payload)
end

-- @return the state table, or nil and an error message
function MRTR.decodeState(state, digest)
    if type(state) ~= "string" then
        return nil, "missing request state"
    end
    local payload, signature = state:match("^([%w+/=]+)%.(%x+)$")
    if not payload or signature ~= sign(payload) then
        return nil, "invalid request state"
    end
    local ok, decoded = pcall(rapidjson.decode, MRTR.base64Decode(payload) or "")
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid request state"
    end
    if type(decoded.e) ~= "number" or decoded.e < os.time() then
        return nil, "request state expired"
    end
    if decoded.d ~= digest then
        return nil, "request state belongs to a different request"
    end
    return decoded
end

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------

-- Whether the client declared form-mode elicitation on this request
function MRTR.supportsFormElicitation(client_capabilities)
    local elicitation = type(client_capabilities) == "table" and client_capabilities.elicitation
    if type(elicitation) ~= "table" then
        return false
    end
    -- An empty elicitation capability means form mode (backward compatible)
    return next(elicitation) == nil or elicitation.form ~= nil
end

-- Build an InputRequiredResult with one form elicitation
-- @param key string: identifier of the input request
-- @param message string: what to ask the user
-- @param schema table: requestedSchema (flat object of primitive properties)
-- @param state string: from MRTR.encodeState
function MRTR.elicitForm(key, message, schema, state)
    return {
        resultType = "input_required",
        inputRequests = {
            [key] = {
                method = "elicitation/create",
                params = {
                    mode = "form",
                    message = message,
                    requestedSchema = schema,
                },
            },
        },
        requestState = state,
    }
end

-- Read the user's answer to an elicitation from a retry
-- @return action ("accept", "decline", "cancel") and content table, or nil
function MRTR.getElicitResponse(input_responses, key)
    local response = type(input_responses) == "table" and input_responses[key]
    if type(response) ~= "table" or type(response.action) ~= "string" then
        return nil
    end
    return response.action, type(response.content) == "table" and response.content or {}
end

return MRTR
