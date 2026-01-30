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

-- Fuzzy text matching using regex
-- This helps match text when LLMs replace typographic characters with ASCII equivalents
-- e.g., smart quotes (') vs straight quotes ('), em-dashes (—) vs hyphens (-)
--
-- Simple approach: replace punctuation and non-ASCII characters with regex wildcard (.)
-- This is intentionally loose - better to get multiple matches and pick the best one
-- than to miss the right match due to character encoding differences.

-- ASCII punctuation that should be replaced with wildcards
-- These have typographic equivalents that LLMs often swap
local WILDCARD_PUNCTUATION = {
    ["'"] = true, -- straight single quote (has smart quote equivalents)
    ['"'] = true, -- straight double quote (has smart quote equivalents)
    ["-"] = true, -- hyphen-minus (has en-dash, em-dash equivalents)
}

-- Characters that need regex escaping (ECMAScript regex special chars)
local REGEX_SPECIAL_CHARS = "[\\^$.*+?()%[%]{}|]"

-- Convert a plain text query to a fuzzy regex pattern
-- Replaces punctuation and non-ASCII characters with "." wildcard
local function textToFuzzyRegex(text)
    if not text then return nil end

    local result = ""
    local i = 1
    local len = #text

    while i <= len do
        local byte = string.byte(text, i)

        if byte < 128 then
            -- ASCII character
            local char = text:sub(i, i)
            if WILDCARD_PUNCTUATION[char] then
                -- Replace with wildcard
                result = result .. "."
            elseif char:match(REGEX_SPECIAL_CHARS) then
                -- Escape regex special char
                result = result .. "\\" .. char
            else
                result = result .. char
            end
            i = i + 1
        else
            -- Non-ASCII (UTF-8 multi-byte) - replace with wildcard
            -- Skip all continuation bytes (10xxxxxx pattern)
            local charLen = 1
            if byte >= 0xC0 and byte < 0xE0 then
                charLen = 2
            elseif byte >= 0xE0 and byte < 0xF0 then
                charLen = 3
            elseif byte >= 0xF0 then
                charLen = 4
            end
            result = result .. "."
            i = i + charLen
        end
    end

    return result
end

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
        description =
        "Get text content from a specific page or range of pages. If no page is specified, returns the current page's text.",
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

    -- Add note or highlight to text
    table.insert(tools, {
        name = "annotate",
        description =
        "Add a highlight or note to text. Creates a highlight when note is omitted. Behavior depends on inputs: (1) No text/positions: uses the current UI selection (fails if none). (2) Only start/end positions: annotates that location (e.g. positions from get_selection). (3) Only text: searches for the text in the book to find its position automatically.",
        inputSchema = {
            type = "object",
            properties = {
                note = {
                    type = "string",
                    description =
                    "Optional note text to attach to the highlight. If omitted, only a highlight is created.",
                },
                text = {
                    type = "string",
                    description =
                    "Optional: The exact text to highlight. If provided without positions, the text will be searched in the book to find its location.",
                },
                start = {
                    type = "string",
                    description = "Optional: Start position (XPointer) from get_selection or search_book results.",
                },
                ["end"] = {
                    type = "string",
                    description = "Optional: End position (XPointer) from get_selection or search_book results.",
                },
            },
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
    elseif name == "annotate" then
        return self:annotate(arguments)
    else
        return nil -- Tool not found
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
    local locationInfo = nil

    for page = startPage, endPage do
        local pageText = nil
        local pageStartXP = nil
        local pageEndXP = nil

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
                pageStartXP = startXP
                pageEndXP = endXP
            elseif startXP then
                -- For the last page, try getting text from the XPointer
                -- using getTextFromXPointer which gets a paragraph
                if doc.getTextFromXPointer then
                    pageText = doc:getTextFromXPointer(startXP)
                    pageStartXP = startXP
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
            text = text .. "=== Page " .. page .. " ===\n" .. pageText .. "\n"
            -- Add location info for each page (useful for annotation tool)
            if pageStartXP then
                text = text .. "Location: start=" .. tostring(pageStartXP)
                if pageEndXP then
                    text = text .. ", end=" .. tostring(pageEndXP)
                end
                text = text .. "\n"
            end
            text = text .. "\n"
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
        local nb_context_words = 5 -- words before/after match for context
        local max_hits = 100       -- limit results
        local case_insensitive = not caseSensitive

        -- Convert query to a fuzzy regex pattern that matches both ASCII and typographic variants
        -- This handles cases where LLMs replace smart quotes with straight quotes or vice versa
        local fuzzyPattern = textToFuzzyRegex(query)
        local use_regex = true

        logger.dbg("MCP search: Using fuzzy regex pattern:", fuzzyPattern)
        local results = doc:findAllText(fuzzyPattern, case_insensitive, nb_context_words, max_hits, use_regex)

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

                resultText = resultText .. "Page " .. pageno .. ": " .. context

                -- Include XPointer positions for annotation support
                if item.start then
                    resultText = resultText .. "\n  start=" .. tostring(item.start)
                    if item["end"] then
                        resultText = resultText .. ", end=" .. tostring(item["end"])
                    end
                end

                resultText = resultText .. "\n\n"

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
        local selected = self.ui.highlight.selected_text
        local text = selected.text
        if text and text ~= "" then
            local response = "Selected text:\n\n" .. text

            -- Add location details if available for use with annotate tool
            if selected.pos0 and selected.pos1 then
                response = response ..
                    "\n\nLocation: start=" .. tostring(selected.pos0) .. ", end=" .. tostring(selected.pos1)
                if selected.chapter then
                    response = response .. "\nChapter: " .. tostring(selected.chapter)
                end
            end

            return {
                content = {
                    {
                        type = "text",
                        text = response,
                    },
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

function MCPTools:annotate(args)
    -- This function adds a highlight or note to text
    -- If note is provided, it creates a highlight with a note
    -- If note is omitted, it creates just a highlight

    local Event = require("ui/event")

    local note_text = args.note
    local provided_text = args.text
    local arg_start = args.start
    local arg_end = args["end"]

    local doc = self.ui.document

    -- Get current selection if available
    local selected = nil
    if self.ui.highlight and self.ui.highlight.selected_text then
        selected = self.ui.highlight.selected_text
    end

    -- Determine what to highlight based on input combinations:
    -- 1. No text/positions: use current selection
    -- 2. Only positions (start/end): use those positions
    -- 3. Only text: search for it to find positions
    -- 4. Text + positions: use both as provided
    local text_to_highlight, start_pos, end_pos

    if arg_start and arg_end then
        -- Positions provided - use them
        start_pos = arg_start
        end_pos = arg_end
        text_to_highlight = provided_text -- may be nil, that's ok

        -- If no text provided with positions, try to get it from selection or leave nil
        if not text_to_highlight and selected and selected.text then
            text_to_highlight = selected.text
        end
    elseif provided_text then
        -- Only text provided - search for it to find positions
        if not doc.findAllText then
            return {
                content = {
                    { type = "text", text = "Error: Cannot search for text position - fulltext search not available for this document type" },
                },
                isError = true,
            }
        end

        -- Convert text to a fuzzy regex pattern that matches both ASCII and typographic variants
        -- This handles cases where LLMs replace smart quotes with straight quotes or vice versa
        local fuzzyPattern = textToFuzzyRegex(provided_text)
        local use_regex = true

        logger.dbg("MCP annotate: Using fuzzy regex pattern:", fuzzyPattern)
        local results = doc:findAllText(fuzzyPattern, true, 0, 5, use_regex)

        if not results or #results == 0 then
            return {
                content = {
                    { type = "text", text = "Error: Could not find the text in the book. Try using more distinctive words or check the exact spelling." },
                },
                isError = true,
            }
        end

        -- Use the first match
        local match = results[1]
        if not match.start or not match["end"] then
            return {
                content = {
                    { type = "text", text = "Error: Found the text but could not determine its position" },
                },
                isError = true,
            }
        end

        start_pos = match.start
        end_pos = match["end"]
        text_to_highlight = match.matched_text or provided_text

        -- Warn if multiple matches found
        if #results > 1 then
            logger.dbg("MCP annotate: Multiple matches found for text, using first one")
        end
    elseif selected and selected.text and selected.text ~= "" then
        -- No text/positions provided - use current selection
        if not selected.pos0 or not selected.pos1 then
            return {
                content = {
                    { type = "text", text = "Error: Current selection is missing position information. Cannot add highlight without location data." },
                },
                isError = true,
            }
        end
        text_to_highlight = selected.text
        start_pos = selected.pos0
        end_pos = selected.pos1
    else
        return {
            content = {
                { type = "text", text = "Error: No text selected and no text or position information provided" },
            },
            isError = true,
        }
    end

    -- Get chapter information if available
    -- Prefer chapter from selection if available, otherwise try to get from TOC
    local chapter = nil
    if selected and selected.chapter then
        chapter = selected.chapter
    elseif self.ui.toc and self.ui.toc.getTocTitleByPage then
        local pg_or_xp = self.ui.paging and doc:getCurrentPage() or start_pos
        chapter = self.ui.toc:getTocTitleByPage(pg_or_xp)
    end
    if chapter == "" then
        chapter = nil
    end

    -- Check if annotation module is available (modern KOReader)
    if not self.ui.annotation then
        return {
            content = {
                { type = "text", text = "Error: Annotation module not available" },
            },
            isError = true,
        }
    end

    -- Check for duplicates using the annotation module's match function
    local annotations = self.ui.annotation.annotations or {}
    for i, existing in ipairs(annotations) do
        local matches = false
        if self.ui.rolling then
            -- For rolling documents, compare xpointers
            matches = existing.pos0 == start_pos and existing.pos1 == end_pos
        else
            -- For paging documents, compare position tables
            matches = existing.page == (self.ui.paging and start_pos.page or start_pos)
                and existing.pos0 and start_pos
                and existing.pos0.x == start_pos.x and existing.pos0.y == start_pos.y
                and existing.pos1 and end_pos
                and existing.pos1.x == end_pos.x and existing.pos1.y == end_pos.y
        end

        if matches then
            -- If a note is provided and different from existing, update it
            if note_text and note_text ~= "" and existing.note ~= note_text then
                existing.note = note_text
                existing.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
                -- Notify the UI about the modification
                self.ui:handleEvent(Event:new("AnnotationsModified", { existing }))

                return {
                    content = {
                        { type = "text", text = "Updated note on existing highlight" },
                    },
                }
            else
                -- Highlight already exists with same or no note
                return {
                    content = {
                        { type = "text", text = "A highlight already exists at this location" },
                    },
                }
            end
        end
    end

    -- Create the annotation item (modern format)
    local pg_or_xp = self.ui.paging and start_pos.page or start_pos
    local item = {
        page = pg_or_xp,
        pos0 = start_pos,
        pos1 = end_pos,
        text = text_to_highlight,
        chapter = chapter,
        drawer = self.ui.highlight and self.ui.highlight.view and self.ui.highlight.view.highlight
            and self.ui.highlight.view.highlight.saved_drawer or "lighten",
        color = self.ui.highlight and self.ui.highlight.view and self.ui.highlight.view.highlight
            and self.ui.highlight.view.highlight.saved_color or "yellow",
    }

    -- Add note if provided
    if note_text and note_text ~= "" then
        item.note = note_text
    end

    -- Add the annotation using the modern API
    local index = self.ui.annotation:addItem(item)

    -- Notify the UI about the new annotation
    local event_data = { item, index_modified = index }
    if note_text and note_text ~= "" then
        event_data.nb_notes_added = 1
    else
        event_data.nb_highlights_added = 1
    end
    self.ui:handleEvent(Event:new("AnnotationsModified", event_data))

    -- Build concise response message
    local response
    if note_text and note_text ~= "" then
        response = "Added highlight with note"
    else
        response = "Added highlight"
    end

    return {
        content = {
            { type = "text", text = response },
        },
    }
end

return MCPTools
