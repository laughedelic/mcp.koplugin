--[[
    MCP Client Features
    Implements server-initiated requests to the client:
    - Sampling: Request LLM completions from the client
    - Elicitation: Request user input through the client
    - Logging: Send log messages to the client

    These features require support from the MCP client (host application).
    The server stores client capabilities during initialization and only
    uses features the client has declared support for.
--]]

local logger = require("logger")
local rapidjson = require("rapidjson")

local MCPClientFeatures = {
  -- Client capabilities (set during initialization)
  client_capabilities = {},

  -- Callback for sending requests/notifications to the client
  -- Set by the relay or server module
  sendToClient = nil,

  -- Request ID counter for JSON-RPC
  _request_id = 0,

  -- Pending requests awaiting response
  _pending_requests = {},

  -- Log level filter (client can set this)
  log_level = "debug",
}

-- Log level severity (RFC 5424)
local LOG_LEVELS = {
  debug = 1,
  info = 2,
  notice = 3,
  warning = 4,
  error = 5,
  critical = 6,
  alert = 7,
  emergency = 8,
}

function MCPClientFeatures:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  o.client_capabilities = {}
  o._pending_requests = {}
  o._request_id = 0
  o.log_level = "debug"
  return o
end

--------------------------------------------------------------------------------
-- Capability Management
--------------------------------------------------------------------------------

-- Store client capabilities from initialization
function MCPClientFeatures:setClientCapabilities(capabilities)
  self.client_capabilities = capabilities or {}
  logger.dbg("MCP: Client capabilities set:", rapidjson.encode(self.client_capabilities))
end

-- Check if client supports sampling
function MCPClientFeatures:supportsSampling()
  return self.client_capabilities.sampling ~= nil
end

-- Check if client supports sampling with tools
function MCPClientFeatures:supportsSamplingWithTools()
  return self.client_capabilities.sampling
      and self.client_capabilities.sampling.tools ~= nil
end

-- Check if client supports elicitation
function MCPClientFeatures:supportsElicitation()
  return self.client_capabilities.elicitation ~= nil
end

-- Check if client supports form mode elicitation
function MCPClientFeatures:supportsFormElicitation()
  if not self.client_capabilities.elicitation then
    return false
  end
  -- Empty elicitation capability means form mode only (backward compat)
  local elicit = self.client_capabilities.elicitation
  return elicit.form ~= nil or (elicit.form == nil and elicit.url == nil)
end

-- Check if client supports URL mode elicitation
function MCPClientFeatures:supportsUrlElicitation()
  return self.client_capabilities.elicitation
      and self.client_capabilities.elicitation.url ~= nil
end

-- Check if client supports roots
function MCPClientFeatures:supportsRoots()
  return self.client_capabilities.roots ~= nil
end

-- Set the callback function for sending messages to client
function MCPClientFeatures:setSendCallback(callback)
  self.sendToClient = callback
end

--------------------------------------------------------------------------------
-- Logging (Server → Client notifications)
--------------------------------------------------------------------------------

-- Set minimum log level (called when client sends logging/setLevel)
function MCPClientFeatures:setLogLevel(level)
  if LOG_LEVELS[level] then
    self.log_level = level
    logger.info("MCP: Log level set to", level)
    return true
  end
  return false, "Invalid log level"
end

-- Send a log message notification to the client
-- level: debug, info, notice, warning, error, critical, alert, emergency
-- loggerName: optional logger name for filtering
-- data: any JSON-serializable data
function MCPClientFeatures:log(level, loggerName, data)
  -- Check if level passes filter
  local level_num = LOG_LEVELS[level] or 2
  local filter_num = LOG_LEVELS[self.log_level] or 1

  if level_num < filter_num then
    return     -- Filtered out
  end

  if not self.sendToClient then
    return     -- No way to send
  end

  local notification = {
    jsonrpc = "2.0",
    method = "notifications/message",
    params = {
      level = level,
      logger = loggerName or "koreader-mcp",
      data = data,
    },
  }

  self.sendToClient(notification)
end

-- Convenience logging methods
function MCPClientFeatures:logDebug(loggerName, data)
  self:log("debug", loggerName, data)
end

function MCPClientFeatures:logInfo(loggerName, data)
  self:log("info", loggerName, data)
end

function MCPClientFeatures:logWarning(loggerName, data)
  self:log("warning", loggerName, data)
end

function MCPClientFeatures:logError(loggerName, data)
  self:log("error", loggerName, data)
end

--------------------------------------------------------------------------------
-- Resource Notifications (Server → Client)
--------------------------------------------------------------------------------

-- Notify client that a subscribed resource has been updated
function MCPClientFeatures:notifyResourceUpdated(uri)
  if not self.sendToClient then
    return
  end

  local notification = {
    jsonrpc = "2.0",
    method = "notifications/resources/updated",
    params = {
      uri = uri,
    },
  }

  self.sendToClient(notification)
  self:logDebug("resources", { event = "resource_updated", uri = uri })
end

-- Notify client that the resource list has changed
function MCPClientFeatures:notifyResourceListChanged()
  if not self.sendToClient then
    return
  end

  local notification = {
    jsonrpc = "2.0",
    method = "notifications/resources/list_changed",
  }

  self.sendToClient(notification)
  self:logDebug("resources", { event = "list_changed" })
end

--------------------------------------------------------------------------------
-- Progress Notifications (Server → Client)
--------------------------------------------------------------------------------

-- Send progress notification for a long-running operation
-- progressToken: the token provided by the client in the request
-- progress: current progress value (must increase with each call)
-- total: optional total value (omit if unknown)
-- message: optional human-readable progress message
function MCPClientFeatures:notifyProgress(progressToken, progress, total, message)
  if not self.sendToClient then
    return
  end

  if not progressToken then
    return     -- No token means client doesn't want progress updates
  end

  local params = {
    progressToken = progressToken,
    progress = progress,
  }

  if total then
    params.total = total
  end

  if message then
    params.message = message
  end

  local notification = {
    jsonrpc = "2.0",
    method = "notifications/progress",
    params = params,
  }

  self.sendToClient(notification)
end

--------------------------------------------------------------------------------
-- Sampling (Server → Client requests)
--------------------------------------------------------------------------------

-- Get the next request ID
function MCPClientFeatures:_nextRequestId()
  self._request_id = self._request_id + 1
  return self._request_id
end

-- Request LLM sampling from the client
-- This is an async operation - the response will be returned via callback
--
-- options:
--   messages: array of {role: "user"|"assistant", content: {type, text/data/...}}
--   systemPrompt: optional system prompt string
--   maxTokens: maximum tokens to generate
--   modelPreferences: optional {hints: [{name: string}], costPriority, speedPriority, intelligencePriority}
--   stopSequences: optional array of strings
--   temperature: optional 0-1
--   tools: optional array of tool definitions (if client supports sampling.tools)
--   toolChoice: optional {mode: "auto"|"required"|"none"}
--
-- callback: function(result, error) called when response received
--   result: {role, content, model, stopReason} or nil on error
--   error: error message string or nil on success
function MCPClientFeatures:requestSampling(options, callback)
  if not self:supportsSampling() then
    if callback then
      callback(nil, "Client does not support sampling")
    end
    return
  end

  if not self.sendToClient then
    if callback then
      callback(nil, "No connection to client")
    end
    return
  end

  local requestId = self:_nextRequestId()

  local params = {
    messages = options.messages or {},
    maxTokens = options.maxTokens or 1000,
  }

  if options.systemPrompt then
    params.systemPrompt = options.systemPrompt
  end

  if options.modelPreferences then
    params.modelPreferences = options.modelPreferences
  end

  if options.stopSequences then
    params.stopSequences = options.stopSequences
  end

  if options.temperature then
    params.temperature = options.temperature
  end

  -- Only include tools if client supports it
  if options.tools and self:supportsSamplingWithTools() then
    params.tools = options.tools
    if options.toolChoice then
      params.toolChoice = options.toolChoice
    end
  end

  local request = {
    jsonrpc = "2.0",
    id = requestId,
    method = "sampling/createMessage",
    params = params,
  }

  -- Store callback for when response arrives
  self._pending_requests[requestId] = {
    callback = callback,
    created_at = os.time(),
    method = "sampling/createMessage",
  }

  self:logDebug("sampling", {
    event = "request_sent",
    id = requestId,
    message_count = #params.messages,
    max_tokens = params.maxTokens,
  })

  self.sendToClient(request)

  return requestId
end

-- Simple sampling helper - send a text prompt and get text response
-- prompt: string to send to the LLM
-- callback: function(response_text, error)
function MCPClientFeatures:ask(prompt, callback)
  local options = {
    messages = {
      {
        role = "user",
        content = {
          type = "text",
          text = prompt,
        },
      },
    },
    maxTokens = 1000,
  }

  self:requestSampling(options, function(result, error)
    if error then
      if callback then callback(nil, error) end
      return
    end

    -- Extract text from response
    local text = nil
    if result and result.content then
      if result.content.type == "text" then
        text = result.content.text
      elseif type(result.content) == "table" then
        -- Array of content blocks
        local parts = {}
        for _, block in ipairs(result.content) do
          if block.type == "text" then
            table.insert(parts, block.text)
          end
        end
        text = table.concat(parts, "\n")
      end
    end

    if callback then callback(text, nil) end
  end)
end

--------------------------------------------------------------------------------
-- Elicitation (Server → Client requests)
--------------------------------------------------------------------------------

-- Request user input via form mode elicitation
--
-- options:
--   message: human-readable message explaining why input is needed
--   requestedSchema: JSON Schema for the expected response (flat objects only)
--     Properties can be: string, number, integer, boolean, or enum
--
-- callback: function(result, error)
--   result: {action: "accept"|"decline"|"cancel", content: {property: value, ...}}
--   error: error message string or nil
function MCPClientFeatures:requestFormElicitation(options, callback)
  if not self:supportsFormElicitation() then
    if callback then
      callback(nil, "Client does not support form elicitation")
    end
    return
  end

  if not self.sendToClient then
    if callback then
      callback(nil, "No connection to client")
    end
    return
  end

  local requestId = self:_nextRequestId()

  local params = {
    mode = "form",
    message = options.message or "Please provide the requested information",
    requestedSchema = options.requestedSchema or {
      type = "object",
      properties = {},
    },
  }

  local request = {
    jsonrpc = "2.0",
    id = requestId,
    method = "elicitation/create",
    params = params,
  }

  self._pending_requests[requestId] = {
    callback = callback,
    created_at = os.time(),
    method = "elicitation/create",
  }

  self:logDebug("elicitation", {
    event = "form_request_sent",
    id = requestId,
    message = options.message,
  })

  self.sendToClient(request)

  return requestId
end

-- Request user confirmation (simple yes/no elicitation)
-- message: the question to ask
-- callback: function(confirmed, error)
--   confirmed: true if user accepted, false if declined/cancelled
function MCPClientFeatures:confirm(message, callback)
  local schema = {
    type = "object",
    properties = {
      confirm = {
        type = "boolean",
        title = "Confirm",
        description = message,
        default = false,
      },
    },
  }

  self:requestFormElicitation({
    message = message,
    requestedSchema = schema,
  }, function(result, error)
    if error then
      if callback then callback(false, error) end
      return
    end

    local confirmed = result
        and result.action == "accept"
        and result.content
        and result.content.confirm == true

    if callback then callback(confirmed, nil) end
  end)
end

-- Request text input from user
-- message: prompt to show
-- options: {title, description, default, minLength, maxLength}
-- callback: function(text, error)
function MCPClientFeatures:requestText(message, options, callback)
  options = options or {}

  local schema = {
    type = "object",
    properties = {
      input = {
        type = "string",
        title = options.title or "Input",
        description = options.description,
        default = options.default,
        minLength = options.minLength,
        maxLength = options.maxLength,
      },
    },
    required = { "input" },
  }

  self:requestFormElicitation({
    message = message,
    requestedSchema = schema,
  }, function(result, error)
    if error then
      if callback then callback(nil, error) end
      return
    end

    if result and result.action == "accept" and result.content then
      if callback then callback(result.content.input, nil) end
    else
      if callback then callback(nil, "User cancelled") end
    end
  end)
end

-- Request choice from enum options
-- message: prompt to show
-- options: {title, choices: {value1, value2, ...} or {{value, title}, ...}}
-- callback: function(choice, error)
function MCPClientFeatures:requestChoice(message, options, callback)
  options = options or {}

  local enumValues = {}
  local hasTitle = false

  for _, choice in ipairs(options.choices or {}) do
    if type(choice) == "table" then
      hasTitle = true
      break
    end
  end

  local schema = {
    type = "object",
    properties = {
      choice = {
        type = "string",
        title = options.title or "Choice",
      },
    },
    required = { "choice" },
  }

  if hasTitle then
    local oneOf = {}
    for _, choice in ipairs(options.choices or {}) do
      if type(choice) == "table" then
        table.insert(oneOf, { const = choice[1], title = choice[2] })
      else
        table.insert(oneOf, { const = choice, title = choice })
      end
    end
    schema.properties.choice.oneOf = oneOf
  else
    schema.properties.choice.enum = options.choices or {}
  end

  if options.default then
    schema.properties.choice.default = options.default
  end

  self:requestFormElicitation({
    message = message,
    requestedSchema = schema,
  }, function(result, error)
    if error then
      if callback then callback(nil, error) end
      return
    end

    if result and result.action == "accept" and result.content then
      if callback then callback(result.content.choice, nil) end
    else
      if callback then callback(nil, "User cancelled") end
    end
  end)
end

-- Request URL mode elicitation (for OAuth, sensitive data, etc.)
--
-- options:
--   message: human-readable message explaining the interaction
--   url: the URL the user should navigate to
--   elicitationId: unique identifier for this elicitation
--
-- callback: function(result, error)
--   result: {action: "accept"|"decline"|"cancel"}
function MCPClientFeatures:requestUrlElicitation(options, callback)
  if not self:supportsUrlElicitation() then
    if callback then
      callback(nil, "Client does not support URL elicitation")
    end
    return
  end

  if not self.sendToClient then
    if callback then
      callback(nil, "No connection to client")
    end
    return
  end

  local requestId = self:_nextRequestId()

  local params = {
    mode = "url",
    message = options.message or "Please complete the interaction",
    url = options.url,
    elicitationId = options.elicitationId or tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999)),
  }

  local request = {
    jsonrpc = "2.0",
    id = requestId,
    method = "elicitation/create",
    params = params,
  }

  self._pending_requests[requestId] = {
    callback = callback,
    created_at = os.time(),
    method = "elicitation/create",
    elicitationId = params.elicitationId,
  }

  self:logDebug("elicitation", {
    event = "url_request_sent",
    id = requestId,
    url = options.url,
    elicitationId = params.elicitationId,
  })

  self.sendToClient(request)

  return requestId, params.elicitationId
end

--------------------------------------------------------------------------------
-- Response Handling
--------------------------------------------------------------------------------

-- Handle a response from the client for a pending request
-- Returns true if this was a response to a pending request, false otherwise
function MCPClientFeatures:handleResponse(response)
  local id = response.id
  if not id then
    return false
  end

  local pending = self._pending_requests[id]
  if not pending then
    return false
  end

  -- Remove from pending
  self._pending_requests[id] = nil

  -- Handle error response
  if response.error then
    self:logWarning(pending.method, {
      event = "request_failed",
      id = id,
      error_code = response.error.code,
      error_message = response.error.message,
    })

    if pending.callback then
      pending.callback(nil, response.error.message or "Request failed")
    end
    return true
  end

  -- Handle success response
  self:logDebug(pending.method, {
    event = "request_succeeded",
    id = id,
  })

  if pending.callback then
    pending.callback(response.result, nil)
  end

  return true
end

-- Handle a notification from the client
function MCPClientFeatures:handleNotification(notification)
  local method = notification.method
  local params = notification.params or {}

  if method == "notifications/elicitation/complete" then
    -- URL mode elicitation completed
    self:logDebug("elicitation", {
      event = "url_elicitation_complete",
      elicitationId = params.elicitationId,
    })
    -- Note: The actual callback is triggered by the response to the request,
    -- this notification is just informational
    return true
  end

  return false
end

-- Clean up old pending requests (call periodically)
function MCPClientFeatures:cleanupPendingRequests(max_age_seconds)
  max_age_seconds = max_age_seconds or 300   -- 5 minutes default
  local now = os.time()
  local expired = {}

  for id, pending in pairs(self._pending_requests) do
    if now - pending.created_at > max_age_seconds then
      table.insert(expired, id)
    end
  end

  for _, id in ipairs(expired) do
    local pending = self._pending_requests[id]
    self._pending_requests[id] = nil

    self:logWarning(pending.method, {
      event = "request_timeout",
      id = id,
    })

    if pending.callback then
      pending.callback(nil, "Request timed out")
    end
  end

  return #expired
end

return MCPClientFeatures
