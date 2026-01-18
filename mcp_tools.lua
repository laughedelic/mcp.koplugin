--[[
    MCP Tools
    Implements MCP tools for interacting with the book
    Tools are callable functions that allow AI assistants to perform actions
--]]

local logger = require("logger")
local rapidjson = require("rapidjson")

local MCPTools = {
    ui = nil,
}

function MCPTools:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function MCPTools:setUI(ui)
    self.ui = ui
end

function MCPTools:list()
    local tools = {}

    -- Get text from page range
    table.insert(tools, {
        name = "get_page_text",
        description = "Get text content from a specific page or range of pages",
        inputSchema = {
            type = "object",
            properties = {
                start_page = {
                    type = "number",
                    description = "Starting page number (1-indexed)",
                },
                end_page = {
                    type = "number",
                    description = "Ending page number (optional, defaults to start_page)",
                },
            },
            required = { "start_page" },
        },
    })

    -- Search in book
    table.insert(tools, {
        name = "search_book",
        description = "Search for text in the current book",
        inputSchema = {
            type = "object",
            properties = {
                query = {
                    type = "string",
                    description = "Search query text",
                },
                case_sensitive = {
                    type = "boolean",
                    description = "Whether search should be case sensitive (default: false)",
                },
            },
            required = { "query" },
        },
    })

    -- Get book outline/TOC
    table.insert(tools, {
        name = "get_toc",
        description = "Get the table of contents for the current book",
        inputSchema = {
            type = "object",
            properties = {},
        },
    })

    -- Navigate to page
    table.insert(tools, {
        name = "goto_page",
        description = "Navigate to a specific page in the book",
        inputSchema = {
            type = "object",
            properties = {
                page = {
                    type = "number",
                    description = "Page number to navigate to (1-indexed)",
                },
            },
            required = { "page" },
        },
    })

    -- Get current selection (if any)
    table.insert(tools, {
        name = "get_selection",
        description = "Get the currently selected/highlighted text",
        inputSchema = {
            type = "object",
            properties = {},
        },
    })

    -- Get book info
    table.insert(tools, {
        name = "get_book_info",
        description = "Get detailed information about the current book",
        inputSchema = {
            type = "object",
            properties = {},
        },
    })

    return tools
end

function MCPTools:call(name, arguments)
    if not self.ui or not self.ui.document then
        return {
            content = {
                {
                    type = "text",
                    text = "Error: No book is currently open",
                },
            },
            isError = true,
        }
    end

    -- Route to appropriate tool handler
    if name == "get_page_text" then
        return self:getPageText(arguments)
    elseif name == "search_book" then
        return self:searchBook(arguments)
    elseif name == "get_toc" then
        return self:getTOC(arguments)
    elseif name == "goto_page" then
        return self:gotoPage(arguments)
    elseif name == "get_selection" then
        return self:getSelection(arguments)
    elseif name == "get_book_info" then
        return self:getBookInfo(arguments)
    else
        return nil  -- Tool not found
    end
end

function MCPTools:getPageText(args)
    local doc = self.ui.document
    local startPage = tonumber(args.start_page)
    local endPage = tonumber(args.end_page) or startPage

    if not startPage then
        return {
            content = {
                { type = "text", text = "Error: Invalid start_page" },
            },
            isError = true,
        }
    end

    local pageCount = doc:getPageCount()
    startPage = math.max(1, math.min(startPage, pageCount))
    endPage = math.max(startPage, math.min(endPage, pageCount))

    -- Limit range to 20 pages for safety
    if endPage - startPage > 20 then
        endPage = startPage + 20
    end

    local text = ""
    if doc.getPageText then
        for page = startPage, endPage do
            local pageText = doc:getPageText(page)
            if pageText then
                text = text .. "=== Page " .. page .. " ===\n" .. pageText .. "\n\n"
            end
        end
    else
        text = "Error: Text extraction not available for this document type"
    end

    return {
        content = {
            { type = "text", text = text },
        },
    }
end

function MCPTools:searchBook(args)
    local query = args.query
    if not query or query == "" then
        return {
            content = {
                { type = "text", text = "Error: Empty search query" },
            },
            isError = true,
        }
    end

    local caseSensitive = args.case_sensitive or false
    local doc = self.ui.document

    -- Use KOReader's search functionality if available
    local results = {}

    if doc.getPageText then
        local pageCount = doc:getPageCount()
        -- Limit search to first 100 pages for performance
        local maxPages = math.min(pageCount, 100)

        for page = 1, maxPages do
            local pageText = doc:getPageText(page)
            if pageText then
                local searchText = pageText
                local searchQuery = query

                if not caseSensitive then
                    searchText = searchText:lower()
                    searchQuery = searchQuery:lower()
                end

                if searchText:find(searchQuery, 1, true) then
                    table.insert(results, {
                        page = page,
                        preview = pageText:sub(1, 200) .. "...",
                    })
                end
            end
        end
    end

    local resultText = "Found " .. #results .. " results:\n\n"
    for i, result in ipairs(results) do
        resultText = resultText .. "Page " .. result.page .. ":\n" .. result.preview .. "\n\n"
        if i >= 10 then
            resultText = resultText .. "... and " .. (#results - 10) .. " more results"
            break
        end
    end

    return {
        content = {
            { type = "text", text = resultText },
        },
    }
end

function MCPTools:getTOC(args)
    local doc = self.ui.document
    local toc = doc:getToc()

    if not toc or #toc == 0 then
        return {
            content = {
                { type = "text", text = "No table of contents available for this book" },
            },
        }
    end

    local tocText = "Table of Contents:\n\n"
    for _, item in ipairs(toc) do
        local indent = string.rep("  ", item.depth or 0)
        tocText = tocText .. indent .. item.title .. " (page " .. (item.page or "?") .. ")\n"
    end

    return {
        content = {
            { type = "text", text = tocText },
        },
    }
end

function MCPTools:gotoPage(args)
    local page = tonumber(args.page)
    if not page then
        return {
            content = {
                { type = "text", text = "Error: Invalid page number" },
            },
            isError = true,
        }
    end

    local doc = self.ui.document
    local pageCount = doc:getPageCount()
    page = math.max(1, math.min(page, pageCount))

    -- Navigate to page
    self.ui:handleEvent(require("ui/event").Event:new("GotoPage", page))

    return {
        content = {
            { type = "text", text = "Navigated to page " .. page },
        },
    }
end

function MCPTools:getSelection(args)
    -- Try to get current selection from highlight module
    if self.ui.highlight and self.ui.highlight.selected_text then
        local text = self.ui.highlight.selected_text.text
        if text and text ~= "" then
            return {
                content = {
                    { type = "text", text = "Selected text:\n\n" .. text },
                },
            }
        end
    end

    return {
        content = {
            { type = "text", text = "No text is currently selected" },
        },
    }
end

function MCPTools:getBookInfo(args)
    local doc = self.ui.document
    local props = doc:getProps()

    local info = {
        title = props.title or "Unknown",
        authors = props.authors or {},
        language = props.language,
        series = props.series,
        description = props.description,
        file = doc.file,
        total_pages = doc:getPageCount(),
        current_page = doc:getCurrentPage(),
        format = doc.file:match("%.([^.]+)$"),
    }

    -- Get reading progress
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(doc.file)
    if doc_settings then
        info.percent_finished = doc_settings:readSetting("percent_finished") or 0
    end

    local infoText = rapidjson.encode(info, { pretty = true })

    return {
        content = {
            { type = "text", text = infoText },
        },
    }
end

return MCPTools
