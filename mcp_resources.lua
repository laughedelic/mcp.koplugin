--[[
    MCP Resources
    Implements MCP resources for accessing book content and metadata
    Resources provide read-only access to book data
--]]

local logger = require("logger")
local DocSettings = require("docsettings")

local MCPResources = {
    ui = nil,
}

function MCPResources:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function MCPResources:setUI(ui)
    self.ui = ui
end

function MCPResources:list()
    local resources = {}

    -- Only provide resources if a document is open
    if not self.ui or not self.ui.document then
        return resources
    end

    -- Book metadata resource
    table.insert(resources, {
        uri = "book://current/metadata",
        name = "Current Book Metadata",
        description = "Metadata about the currently open book (title, author, progress, etc.)",
        mimeType = "application/json",
    })

    -- Current page/location content
    table.insert(resources, {
        uri = "book://current/page",
        name = "Current Page Content",
        description = "Text content of the current page or screen",
        mimeType = "text/plain",
    })

    -- Full book text (for smaller books)
    table.insert(resources, {
        uri = "book://current/text",
        name = "Full Book Text",
        description = "Complete text content of the current book",
        mimeType = "text/plain",
    })

    -- Table of contents
    table.insert(resources, {
        uri = "book://current/toc",
        name = "Table of Contents",
        description = "Table of contents for the current book",
        mimeType = "application/json",
    })

    -- Book statistics
    table.insert(resources, {
        uri = "book://current/statistics",
        name = "Reading Statistics",
        description = "Reading progress and statistics for the current book",
        mimeType = "application/json",
    })

    return resources
end

function MCPResources:read(uri)
    if not self.ui or not self.ui.document then
        return nil
    end

    -- Route to appropriate resource handler
    if uri == "book://current/metadata" then
        return { self:getMetadata() }
    elseif uri == "book://current/page" then
        return { self:getCurrentPageText() }
    elseif uri == "book://current/text" then
        return { self:getFullText() }
    elseif uri == "book://current/toc" then
        return { self:getTableOfContents() }
    elseif uri == "book://current/statistics" then
        return { self:getStatistics() }
    else
        return nil
    end
end

function MCPResources:getMetadata()
    local doc = self.ui.document
    local props = doc:getProps()

    local metadata = {
        uri = "book://current/metadata",
        mimeType = "application/json",
    }

    -- Build metadata object
    local data = {
        title = props.title or "Unknown",
        authors = props.authors or {},
        language = props.language,
        series = props.series,
        keywords = props.keywords,
        description = props.description,
        file = doc.file,
        pages = doc:getPageCount(),
        format = doc.file:match("%.([^.]+)$"),
    }

    -- Get reading progress from settings
    local doc_settings = DocSettings:open(doc.file)
    if doc_settings then
        data.percent_finished = doc_settings:readSetting("percent_finished") or 0
        data.current_page = doc_settings:readSetting("last_page") or 1
    end

    metadata.text = require("rapidjson").encode(data)
    return metadata
end

function MCPResources:getCurrentPageText()
    local doc = self.ui.document

    -- Get current page number
    local current_page = doc:getCurrentPage()

    -- Try to get text from current page
    local text = ""
    if doc.getPageText then
        text = doc:getPageText(current_page) or ""
    elseif doc.getTextFromPositions then
        -- For some document types, we need to get text from positions
        -- This is a simplified approach
        text = "[Page text extraction not fully implemented for this document type]"
    end

    return {
        uri = "book://current/page",
        mimeType = "text/plain",
        text = text,
    }
end

function MCPResources:getFullText()
    local doc = self.ui.document
    local pageCount = doc:getPageCount()

    -- Limit full text to reasonable size (first 100 pages or less)
    local maxPages = math.min(pageCount, 100)
    local text = ""

    if doc.getPageText then
        for i = 1, maxPages do
            local pageText = doc:getPageText(i)
            if pageText then
                text = text .. pageText .. "\n\n"
            end
        end

        if pageCount > maxPages then
            text = text .. "\n[... truncated, showing first " .. maxPages .. " of " .. pageCount .. " pages ...]"
        end
    else
        text = "[Full text extraction not available for this document type]"
    end

    return {
        uri = "book://current/text",
        mimeType = "text/plain",
        text = text,
    }
end

function MCPResources:getTableOfContents()
    local doc = self.ui.document

    local toc = doc:getToc()
    local tocData = {
        chapters = {},
    }

    if toc then
        for _, item in ipairs(toc) do
            table.insert(tocData.chapters, {
                title = item.title or "",
                page = item.page or 0,
                depth = item.depth or 0,
            })
        end
    end

    return {
        uri = "book://current/toc",
        mimeType = "application/json",
        text = require("rapidjson").encode(tocData),
    }
end

function MCPResources:getStatistics()
    local doc = self.ui.document
    local doc_settings = DocSettings:open(doc.file)

    local stats = {
        total_pages = doc:getPageCount(),
        current_page = doc:getCurrentPage(),
        percent_finished = 0,
    }

    if doc_settings then
        stats.percent_finished = doc_settings:readSetting("percent_finished") or 0
        stats.total_time_in_sec = doc_settings:readSetting("summary").total_time_in_sec or 0
        stats.performance_in_pages = doc_settings:readSetting("summary").performance_in_pages or {}
    end

    return {
        uri = "book://current/statistics",
        mimeType = "application/json",
        text = require("rapidjson").encode(stats),
    }
end

return MCPResources
