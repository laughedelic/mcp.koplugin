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
    resources = nil,
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

function MCPTools:setResources(resources)
    self.resources = resources
end

--------------------------------------------------------------------------------
-- Helper: Get book context for enriching tool responses
--------------------------------------------------------------------------------

-- Format authors as a comma-separated string
local function formatAuthors(authors)
    if not authors then
        return nil
    elseif type(authors) == "string" then
        return authors
    elseif type(authors) == "table" then
        if #authors == 0 then return nil end
        return table.concat(authors, ", ")
    else
        return nil
    end
end

function MCPTools:getBookContext()
    if not self.ui or not self.ui.document then
        return nil
    end

    local doc = self.ui.document
    local props = doc:getProps()
    local current_page = doc:getCurrentPage()

    local context = {
        title = props.title or "Unknown",
        authors = formatAuthors(props.authors),
        current_page = current_page,
        total_pages = doc:getPageCount(),
    }

    -- Get current chapter
    if self.ui.toc and self.ui.toc.getTocTitleByPage then
        local chapter = self.ui.toc:getTocTitleByPage(current_page)
        if chapter and chapter ~= "" then
            context.chapter = chapter
        end
    end

    return context
end

function MCPTools:formatBookHeader(context)
    if not context then return "" end

    local header = ""
    if context.title then
        header = header .. "Book: " .. context.title
    end
    if context.authors then
        header = header .. " by " .. context.authors
    end
    if context.chapter then
        header = header .. "\nChapter: " .. context.chapter
    end
    header = header .. "\nPage " .. context.current_page .. " of " .. context.total_pages
    return header .. "\n\n"
end

function MCPTools:getContextResourceLink()
    -- Return a resource_link that clients can use to fetch the reading context
    -- This is simpler than embedded resources and doesn't require including content
    return {
        type = "resource_link",
        uri = "book://current/context",
        name = "Reading Context",
        description = "Current reading context including book metadata, chapter, page text, and selection",
        mimeType = "application/json",
    }
end

function MCPTools:list()
    local tools = {}

    -- Get current reading context (returns the book://current/context resource)
    table.insert(tools, {
        name = "get_reading_context",
        description =
        "Get the current reading context including book metadata, current chapter, page text, and selection (if any). This is the primary way to understand what the user is currently reading.",
        inputSchema = {
            type = "object",
            properties = {
                extra_pages_before = {
                    type = "number",
                    description = "Number of pages before current page to include (default: 0, max: 5)",
                },
                extra_pages_after = {
                    type = "number",
                    description = "Number of pages after current page to include (default: 0, max: 5)",
                },
            },
        },
        -- Tool annotations for client decision-making
        annotations = {
            readOnlyHint = true,     -- Does not modify any data
            destructiveHint = false, -- No data is destroyed
            idempotentHint = true,   -- Same result if called multiple times
            openWorldHint = false,   -- Only accesses local book data
        },
    })

    -- Get book metadata (for clients that don't support resources)
    table.insert(tools, {
        name = "get_book_metadata",
        description =
        "Get full metadata about the currently open book (title, authors, language, series, description, format, page count, reading progress). Use this for detailed book information. The book://current/metadata resource provides the same data.",
        inputSchema = {
            type = "object",
            properties = {},
        },
        annotations = {
            readOnlyHint = true,
            destructiveHint = false,
            idempotentHint = true,
            openWorldHint = false,
        },
    })

    -- Read specific pages or chapters
    table.insert(tools, {
        name = "read_pages",
        description =
        "Read text content from specific pages. Use this to explore context beyond the current page, such as reading ahead, going back, or reading a specific chapter.",
        inputSchema = {
            type = "object",
            properties = {
                pages = {
                    type = "string",
                    description = "Page number or range to read (e.g., '5', '10-15'). Maximum 20 pages per request.",
                },
                chapter = {
                    type = "number",
                    description =
                    "Chapter index to read (from table of contents). Use get_reading_context to see the TOC. Takes precedence over 'pages' if both provided.",
                },
            },
        },
        annotations = {
            readOnlyHint = true,
            destructiveHint = false,
            idempotentHint = true,
            openWorldHint = false,
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
        annotations = {
            readOnlyHint = true,
            destructiveHint = false,
            idempotentHint = true, -- Same search returns same results
            openWorldHint = false,
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
        annotations = {
            readOnlyHint = false,    -- Changes the current view state
            destructiveHint = false, -- No data is destroyed
            idempotentHint = true,   -- Going to page N multiple times has same result
            openWorldHint = false,
        },
    })

    -- Add note or highlight to text
    table.insert(tools, {
        name = "annotate",
        description =
        "Add a highlight or note to text. Creates a highlight when note is omitted. Behavior depends on inputs: (1) No text/positions: uses the current UI selection (fails if none). (2) Only start/end positions: annotates that location (e.g. positions from search_book results). (3) Only text: searches for the text in the book to find its position automatically.",
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
                    description = "Optional: Start position (XPointer) from search_book results.",
                },
                ["end"] = {
                    type = "string",
                    description = "Optional: End position (XPointer) from search_book results.",
                },
            },
        },
        annotations = {
            readOnlyHint = false,    -- Creates data (annotations)
            destructiveHint = false, -- Does not delete existing data
            idempotentHint = false,  -- Calling multiple times creates multiple annotations
            openWorldHint = false,
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
    if name == "get_reading_context" then
        return self:getReadingContext(arguments)
    elseif name == "get_book_metadata" then
        return self:getBookMetadata(arguments)
    elseif name == "read_pages" then
        return self:readPages(arguments)
    elseif name == "search_book" then
        return self:searchBook(arguments)
    elseif name == "goto_page" then
        return self:gotoPage(arguments)
    elseif name == "annotate" then
        return self:annotate(arguments)
    else
        return nil -- Tool not found
    end
end

function MCPTools:getReadingContext(args)
    -- Return reading context as both structured data and text (for compatibility)
    -- plus a resource link (for clients that can subscribe to updates)

    if not self.ui or not self.ui.document then
        return {
            content = {
                { type = "text", text = "No document is currently open" },
            },
        }
    end

    args = args or {}
    local extra_pages_before = math.min(args.extra_pages_before or 0, 5)
    local extra_pages_after = math.min(args.extra_pages_after or 0, 5)

    local doc = self.ui.document
    local props = doc:getProps()
    local current_page = doc:getCurrentPage()
    local page_count = doc:getPageCount()

    -- Build structured context with sections:
    -- book: title, authors, total_pages
    -- chapter: name, start_page, end_page
    -- selection: text the user has selected (optional)
    -- current_page: number, text (with highlights marked inline)

    local context = {
        book = {
            title = props.title or "Unknown",
            authors = formatAuthors(props.authors),
            total_pages = page_count,
        },
    }

    -- Get current chapter info with page bounds
    local chapter_info = self:getChapterInfo(current_page)
    if chapter_info then
        context.chapter = chapter_info
    end

    -- Get selection if available (actual text selection only)
    if self.ui.highlight and self.ui.highlight.selected_text then
        local selected = self.ui.highlight.selected_text
        if selected.text and selected.text ~= "" then
            context.selection = selected.text
        end
    end

    -- Build current_page section with text (highlights marked inline)
    context.current_page = {
        number = current_page,
    }

    -- Get page text with highlights marked inline
    if self.resources then
        local pageText = self:getPageTextWithHighlights(current_page)
        if pageText and pageText ~= "" then
            context.current_page.text = pageText
        end
    end

    -- Add extra pages if requested (as a single text blob)
    if extra_pages_before > 0 or extra_pages_after > 0 then
        local extra_text = ""

        -- Pages before
        for i = extra_pages_before, 1, -1 do
            local page_num = current_page - i
            if page_num >= 1 then
                local pageText = self:getPageTextWithHighlights(page_num)
                if pageText and pageText ~= "" then
                    extra_text = extra_text .. "== Page " .. page_num .. " ==\n\n" .. pageText .. "\n\n"
                end
            end
        end

        -- Current page marker
        extra_text = extra_text .. "== Current page: " .. current_page .. " ==\n\n"
        if context.current_page.text then
            extra_text = extra_text .. context.current_page.text .. "\n\n"
        end

        -- Pages after
        for i = 1, extra_pages_after do
            local page_num = current_page + i
            if page_num <= page_count then
                local pageText = self:getPageTextWithHighlights(page_num)
                if pageText and pageText ~= "" then
                    extra_text = extra_text .. "== Page " .. page_num .. " ==\n\n" .. pageText .. "\n\n"
                end
            end
        end

        if extra_text ~= "" then
            context.pages_text = extra_text
            -- Remove current_page.text since it's in pages_text now
            context.current_page.text = nil
        end
    end

    -- Build text representation for clients without structured data support
    local textResponse = self:formatReadingContext(context)

    return {
        content = {
            { type = "text", text = textResponse },
            self:getContextResourceLink(),
        },
        structuredContent = context,
    }
end

function MCPTools:getBookMetadata(args)
    -- Return full book metadata for clients that don't support resources
    if not self.ui or not self.ui.document then
        return {
            content = {
                { type = "text", text = "No document is currently open" },
            },
        }
    end

    local doc = self.ui.document
    local props = doc:getProps()
    local DocSettings = require("docsettings")

    local metadata = {
        title = props.title or "Unknown",
        authors = formatAuthors(props.authors),
        language = props.language,
        series = props.series,
        keywords = props.keywords,
        description = props.description,
        file = doc.file,
        format = doc.file:match("%.([^.]+)$"),
        total_pages = doc:getPageCount(),
    }

    -- Get reading progress from settings
    local doc_settings = DocSettings:open(doc.file)
    if doc_settings then
        metadata.percent_finished = doc_settings:readSetting("percent_finished") or 0
        metadata.current_page = doc_settings:readSetting("last_page") or doc:getCurrentPage()
    end

    -- Build text representation
    local textResponse = "Book Metadata\n" .. string.rep("=", 40) .. "\n\n"
    textResponse = textResponse .. "Title: " .. metadata.title .. "\n"
    if metadata.authors then
        textResponse = textResponse .. "Authors: " .. metadata.authors .. "\n"
    end
    if metadata.language then
        textResponse = textResponse .. "Language: " .. metadata.language .. "\n"
    end
    if metadata.series then
        textResponse = textResponse .. "Series: " .. metadata.series .. "\n"
    end
    if metadata.description then
        textResponse = textResponse .. "\nDescription:\n" .. metadata.description .. "\n"
    end
    textResponse = textResponse .. "\nFormat: " .. (metadata.format or "unknown") .. "\n"
    textResponse = textResponse .. "Pages: " .. metadata.total_pages .. "\n"
    textResponse = textResponse .. "Progress: " .. math.floor((metadata.percent_finished or 0) * 100) .. "%\n"
    textResponse = textResponse .. "\nResource: book://current/metadata\n"

    return {
        content = {
            { type = "text", text = textResponse },
            {
                type = "resource_link",
                uri = "book://current/metadata",
                name = "Book Metadata",
                description = "Full metadata about the currently open book",
                mimeType = "application/json",
            },
        },
        structuredContent = metadata,
    }
end

-- Helper: Get chapter info with start/end pages
function MCPTools:getChapterInfo(page)
    local doc = self.ui.document
    local toc = doc:getToc()

    if not toc or #toc == 0 then
        return nil
    end

    -- Find the chapter containing the current page
    local current_chapter = nil
    local next_chapter_page = doc:getPageCount() + 1

    for i, item in ipairs(toc) do
        local chapter_page = item.page or 0
        if chapter_page <= page then
            current_chapter = {
                name = item.title or "",
                start_page = chapter_page,
                index = i,
            }
        end
        if chapter_page > page and not current_chapter then
            break
        end
        if current_chapter and chapter_page > page then
            next_chapter_page = chapter_page
            break
        end
    end

    if current_chapter then
        current_chapter.end_page = next_chapter_page - 1
        return current_chapter
    end

    return nil
end

-- Helper: Get all highlights on a page (for marking in text)
function MCPTools:getHighlightsForPage(page)
    local highlights = {}

    if self.ui.annotation and self.ui.annotation.annotations then
        for _, item in ipairs(self.ui.annotation.annotations) do
            if item.page == page then
                table.insert(highlights, {
                    text = item.text,
                    note = item.note,
                })
            end
        end
    end

    return highlights
end

-- Helper: Get page text with highlights marked inline using markdown
-- Format: text **highlighted text** text, or **highlighted text** (Note: note text) if there's a note
function MCPTools:getPageTextWithHighlights(page)
    if not self.resources then return nil end

    local pageText = self.resources:extractPageText(page)
    if not pageText or pageText == "" then return nil end

    local highlights = self:getHighlightsForPage(page)
    if #highlights == 0 then return pageText end

    -- Sort highlights by length (longest first) to avoid partial replacements
    table.sort(highlights, function(a, b)
        return #(a.text or "") > #(b.text or "")
    end)

    -- Mark each highlight in the text
    for _, h in ipairs(highlights) do
        if h.text and h.text ~= "" then
            local replacement
            if h.note and h.note ~= "" then
                replacement = "**" .. h.text .. "** (Note: " .. h.note .. ")"
            else
                replacement = "**" .. h.text .. "**"
            end
            -- Simple string replacement (first occurrence)
            local escaped_text = h.text:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
            pageText = pageText:gsub(escaped_text, replacement, 1)
        end
    end

    return pageText
end

-- Helper: Format reading context as text for clients without structured data support
function MCPTools:formatReadingContext(context)
    local text = ""

    -- Book header
    if context.book then
        text = text .. context.book.title
        if context.book.authors then
            text = text .. " by " .. context.book.authors
        end
        text = text .. "\n"
    end

    -- Chapter info
    if context.chapter then
        text = text .. "Chapter: " .. context.chapter.name
        text = text .. " (pages " .. context.chapter.start_page .. "-" .. context.chapter.end_page .. ")\n"
    end

    -- If we have pages_text (extra pages were requested), use that
    if context.pages_text then
        text = text .. "\n" .. context.pages_text
    else
        -- Just current page
        if context.current_page then
            text = text .. "Page " .. context.current_page.number
            if context.book and context.book.total_pages then
                text = text .. " of " .. context.book.total_pages
            end
            text = text .. "\n\n"

            if context.current_page.text then
                text = text .. context.current_page.text
            end
        end
    end

    -- Selection (actual text selection)
    if context.selection then
        text = text .. "\n\n--- Selected text ---\n" .. context.selection
    end

    return text
end

function MCPTools:readPages(args)
    if not self.ui or not self.ui.document then
        return {
            content = {
                { type = "text", text = "No document is currently open" },
            },
        }
    end

    if not self.resources then
        return {
            content = {
                { type = "text", text = "Error: Resources not available" },
            },
            isError = true,
        }
    end

    local doc = self.ui.document
    local chapter_index = args.chapter and tonumber(args.chapter)
    local pages_range = args.pages

    -- Prefer chapter if specified
    if chapter_index then
        local contents = self.resources:read("book://current/chapters/" .. chapter_index)
        if contents and contents[1] then
            local result = contents[1]
            return {
                content = {
                    { type = "text", text = result.text or "No content available" },
                },
            }
        else
            return {
                content = {
                    { type = "text", text = "Error: Invalid chapter index or chapter not found" },
                },
                isError = true,
            }
        end
    end

    -- Fall back to pages range
    if pages_range then
        local contents = self.resources:read("book://current/pages/" .. pages_range)
        if contents and contents[1] then
            local result = contents[1]
            return {
                content = {
                    { type = "text", text = result.text or "No content available" },
                },
            }
        else
            return {
                content = {
                    { type = "text", text = "Error: Invalid page range" },
                },
                isError = true,
            }
        end
    end

    -- No valid input provided - give helpful error
    local page_count = doc:getPageCount()
    local current_page = doc:getCurrentPage()
    return {
        content = {
            { type = "text", text = "Please specify 'pages' (e.g., '5' or '10-15') or 'chapter' (index from TOC).\nCurrent page: " .. current_page .. " of " .. page_count },
        },
        isError = true,
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
            -- Build structured results
            local structuredResults = {
                query = query,
                total_count = #results,
                results = {},
            }

            -- Add book context header for text response
            local bookContext = self:getBookContext()
            local resultText = self:formatBookHeader(bookContext)
            resultText = resultText .. "Found " .. #results .. " results:\n\n"

            for i, item in ipairs(results) do
                -- Get page number
                local pageno
                if doc.getPageFromXPointer and item.start then
                    pageno = doc:getPageFromXPointer(item.start)
                else
                    pageno = item.start or 0
                end

                -- Build structured result item
                local resultItem = {
                    page = pageno,
                    matched_text = item.matched_text or query,
                    context_before = item.prev_text,
                    context_after = item.next_text,
                }
                if item.start then
                    resultItem.start = tostring(item.start)
                end
                if item["end"] then
                    resultItem["end"] = tostring(item["end"])
                end
                table.insert(structuredResults.results, resultItem)

                -- Build text context
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
                    self:getContextResourceLink(),
                },
                structuredContent = structuredResults,
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
