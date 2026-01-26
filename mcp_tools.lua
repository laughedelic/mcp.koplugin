--[[
    MCP Tools
    Implements MCP tools for interacting with the book
    Tools are callable functions that allow AI assistants to perform actions
--]]

local logger = require("logger")
local rapidjson = require("rapidjson")
local Event = require("ui/event")

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
        description = "Get text content from a specific page or range of pages. If no page is specified, returns the current page's text.",
        inputSchema = {
            type = "object",
            properties = {
                start_page = {
                    type = "number",
                    description = "Starting page number (1-indexed). Defaults to current page if omitted.",
                },
                end_page = {
                    type = "number",
                    description = "Ending page number (optional, defaults to start_page)",
                },
            },
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

-- Helper function to extract text from text boxes structure
local function extractTextFromBoxes(textBoxes)
    if not textBoxes then return nil end
    
    local lines = {}
    for _, line in ipairs(textBoxes) do
        local words = {}
        if type(line) == "table" then
            for _, word in ipairs(line) do
                if type(word) == "table" and word.word then
                    table.insert(words, word.word)
                elseif type(word) == "string" then
                    table.insert(words, word)
                end
            end
        end
        if #words > 0 then
            table.insert(lines, table.concat(words, " "))
        end
    end
    
    if #lines > 0 then
        return table.concat(lines, "\n")
    end
    return nil
end

function MCPTools:getPageText(args)
    local doc = self.ui.document
    -- Default to current page if start_page is not provided
    local startPage = tonumber(args.start_page) or doc:getCurrentPage()
    local endPage = tonumber(args.end_page) or startPage

    local pageCount = doc:getPageCount()
    startPage = math.max(1, math.min(startPage, pageCount))
    endPage = math.max(startPage, math.min(endPage, pageCount))

    -- Limit range to 20 pages for safety
    if endPage - startPage > 20 then
        endPage = startPage + 20
    end

    local text = ""
    local hasText = false
    
    for page = startPage, endPage do
        local pageText = nil
        
        -- For reflowable documents (EPUB, etc.), try getTextFromXPointers first
        -- This is the most reliable method for CRE documents
        if not pageText and doc.getPageXPointer and doc.getTextFromXPointers then
            local startXP = doc:getPageXPointer(page)
            local endXP = nil
            if page < pageCount then
                endXP = doc:getPageXPointer(page + 1)
            end
            if startXP and endXP then
                -- getTextFromXPointers returns text directly, not a table
                pageText = doc:getTextFromXPointers(startXP, endXP, false)
            elseif startXP then
                -- For the last page, try getting text from the XPointer
                -- using getTextFromXPointer which gets a paragraph
                if doc.getTextFromXPointer then
                    pageText = doc:getTextFromXPointer(startXP)
                end
            end
        end
        
        -- For paged documents (PDF, DjVu), try getPageTextBoxes
        if not pageText and doc.getPageTextBoxes then
            local textBoxes = doc:getPageTextBoxes(page)
            pageText = extractTextFromBoxes(textBoxes)
        end
        
        -- Fallback: try the generic getPageText if available
        if not pageText and doc.getPageText then
            pageText = doc:getPageText(page)
        end
        
        if pageText and pageText ~= "" then
            hasText = true
            text = text .. "=== Page " .. page .. " ===\n" .. pageText .. "\n\n"
        else
            text = text .. "=== Page " .. page .. " ===\n(No text available)\n\n"
        end
    end
    
    if not hasText then
        text = "Text extraction not available for this document type or no text found in the specified pages."
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

    -- Use KOReader's native findAllText for fulltext search
    -- This is the same method used by the built-in "Fulltext search" feature
    if doc.findAllText then
        local nb_context_words = 5  -- words before/after match for context
        local max_hits = 100        -- limit results
        local case_insensitive = not caseSensitive
        local use_regex = false
        
        local results = doc:findAllText(query, case_insensitive, nb_context_words, max_hits, use_regex)
        
        if results and #results > 0 then
            local resultText = "Found " .. #results .. " results:\n\n"
            for i, item in ipairs(results) do
                -- Get page number
                local pageno
                if doc.getPageFromXPointer and item.start then
                    pageno = doc:getPageFromXPointer(item.start)
                else
                    pageno = item.start or "?"
                end
                
                -- Build context text
                local context = ""
                if item.prev_text then
                    context = context .. item.prev_text .. " "
                end
                context = context .. "**" .. (item.matched_text or query) .. "**"
                if item.next_text then
                    context = context .. " " .. item.next_text
                end
                
                resultText = resultText .. "Page " .. pageno .. ": " .. context .. "\n\n"
                
                if i >= 20 then
                    resultText = resultText .. "... and " .. (#results - 20) .. " more results"
                    break
                end
            end
            return {
                content = {
                    { type = "text", text = resultText },
                },
            }
        else
            return {
                content = {
                    { type = "text", text = "No results found for: " .. query },
                },
            }
        end
    end
    
    -- Fallback: for documents without findAllText, return an error
    return {
        content = {
            { type = "text", text = "Fulltext search is not available for this document type." },
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

    -- Add current location to navigation history so "go back" works
    if self.ui.link and self.ui.link.addCurrentLocationToStack then
        self.ui.link:addCurrentLocationToStack()
    end

    -- Navigate to page using proper Event
    self.ui:handleEvent(Event:new("GotoPage", page))

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
