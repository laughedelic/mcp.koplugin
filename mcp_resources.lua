--[[
    MCP Resources
    Implements MCP resources for accessing book content, metadata, and library
    Resources provide read-only access to book data with subscription support

    Resource URI schemes:
    - book://current/... - Currently open book resources
    - library://...      - Library-wide resources (books, authors, tags, collections)
--]]

local logger = require("logger")
local DocSettings = require("docsettings")
local rapidjson = require("rapidjson")

-- Normalize authors to always be a table (props.authors can be string or table)
local function normalizeAuthors(authors)
    if not authors then
        return {}
    elseif type(authors) == "string" then
        return { authors }
    elseif type(authors) == "table" then
        return authors
    else
        return {}
    end
end

local MCPResources = {
    ui = nil,
    -- Subscription tracking
    subscriptions = {}, -- Set of subscribed URIs
    -- Cached data for change detection
    _cache = {
        current_page = nil,
        selection_text = nil,
        document_file = nil,
    },
}

function MCPResources:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.subscriptions = {}
    o._cache = {
        current_page = nil,
        selection_text = nil,
        document_file = nil,
    }
    return o
end

function MCPResources:setUI(ui)
    self.ui = ui
end

--------------------------------------------------------------------------------
-- Resource Listing
--------------------------------------------------------------------------------

function MCPResources:list()
    local resources = {}

    -- Library resources (always available)
    self:addLibraryResources(resources)

    -- Book resources (only when document is open)
    if self.ui and self.ui.document then
        self:addCurrentBookResources(resources)
    end

    return resources
end

function MCPResources:addLibraryResources(resources)
    table.insert(resources, {
        uri = "library://books",
        name = "Library Books",
        description = "All books in the library with metadata and reading progress",
        mimeType = "application/json",
    })

    table.insert(resources, {
        uri = "library://collections",
        name = "Library Collections",
        description = "User-defined book collections",
        mimeType = "application/json",
    })

    table.insert(resources, {
        uri = "library://history",
        name = "Reading History",
        description = "Recently read books ordered by last access time",
        mimeType = "application/json",
    })
end

function MCPResources:addCurrentBookResources(resources)
    -- Primary reading context (composite resource - most useful for assistants)
    table.insert(resources, {
        uri = "book://current/context",
        name = "Reading Context",
        description =
        "Current reading context: book metadata, chapter, page content, and selection (if any). This is the primary resource for understanding what the user is currently reading.",
        mimeType = "application/json",
        annotations = {
            audience = { "assistant" },
            priority = 1.0, -- Highest priority - should be included in most interactions
        },
    })

    -- Book metadata
    table.insert(resources, {
        uri = "book://current/metadata",
        name = "Book Metadata",
        description = "Metadata about the currently open book (title, author, progress, etc.)",
        mimeType = "application/json",
    })

    -- Table of contents
    table.insert(resources, {
        uri = "book://current/toc",
        name = "Table of Contents",
        description = "Table of contents with chapter titles and page numbers",
        mimeType = "application/json",
    })

    -- Bookmarks (highlights and notes)
    table.insert(resources, {
        uri = "book://current/bookmarks",
        name = "Bookmarks",
        description = "All highlights and notes in the current book",
        mimeType = "application/json",
    })
end

--------------------------------------------------------------------------------
-- Resource Templates
--------------------------------------------------------------------------------

function MCPResources:listTemplates()
    local templates = {}

    -- Page range template
    table.insert(templates, {
        uriTemplate = "book://current/pages/{range}",
        name = "Page Range",
        description = "Get text content from a range of pages (e.g., '5', '10-15')",
    })

    -- Chapter template
    table.insert(templates, {
        uriTemplate = "book://current/chapters/{index}",
        name = "Chapter Content",
        description = "Get content of a specific chapter by its index in the TOC",
    })

    -- Library book by path template
    table.insert(templates, {
        uriTemplate = "library://books/{path}",
        name = "Book by Path",
        description = "Get details of a specific book by its file path",
    })

    return templates
end

--------------------------------------------------------------------------------
-- Resource Reading
--------------------------------------------------------------------------------

function MCPResources:read(uri)
    -- Parse URI scheme and path
    local scheme, path = uri:match("^([^:]+)://(.+)$")
    if not scheme then
        return nil
    end

    if scheme == "book" then
        return self:readBookResource(path)
    elseif scheme == "library" then
        return self:readLibraryResource(path)
    else
        return nil
    end
end

function MCPResources:readBookResource(path)
    if not self.ui or not self.ui.document then
        return nil
    end

    -- Static resources
    if path == "current/context" then
        return { self:getReadingContext() }
    elseif path == "current/metadata" then
        return { self:getMetadata() }
    elseif path == "current/toc" then
        return { self:getTableOfContents() }
    elseif path == "current/bookmarks" then
        return { self:getBookmarks() }
    end

    -- Parameterized resources
    local pages_range = path:match("^current/pages/(.+)$")
    if pages_range then
        return { self:getPageRange(pages_range) }
    end

    local chapter_index = path:match("^current/chapters/(%d+)$")
    if chapter_index then
        return { self:getChapterContent(tonumber(chapter_index)) }
    end

    return nil
end

function MCPResources:readLibraryResource(path)
    if path == "books" then
        return { self:getLibraryBooks() }
    elseif path == "collections" then
        return { self:getCollections() }
    elseif path == "history" then
        return { self:getReadingHistory() }
    end

    -- Book by path
    local book_path = path:match("^books/(.+)$")
    if book_path then
        return { self:getBookByPath(book_path) }
    end

    return nil
end

--------------------------------------------------------------------------------
-- Reading Context (Composite Resource)
--------------------------------------------------------------------------------

function MCPResources:getReadingContext()
    local doc = self.ui.document
    local props = doc:getProps()
    local current_page = doc:getCurrentPage()
    local page_count = doc:getPageCount()

    -- Build context object
    local context = {
        book = {
            title = props.title or "Unknown",
            authors = normalizeAuthors(props.authors),
            file = doc.file,
            format = doc.file:match("%.([^.]+)$"),
        },
        position = {
            current_page = current_page,
            total_pages = page_count,
            percent = math.floor((current_page / page_count) * 100),
        },
    }

    -- Get current chapter from TOC
    if self.ui.toc and self.ui.toc.getTocTitleByPage then
        local chapter = self.ui.toc:getTocTitleByPage(current_page)
        if chapter and chapter ~= "" then
            context.chapter = chapter
        end
    end

    -- Get current page text
    context.page_text = self:extractPageText(current_page)

    -- Get selection if available
    if self.ui.highlight and self.ui.highlight.selected_text then
        local selected = self.ui.highlight.selected_text
        if selected.text and selected.text ~= "" then
            context.selection = {
                text = selected.text,
            }
            if selected.chapter then
                context.selection.chapter = selected.chapter
            end
        end
    end

    return {
        uri = "book://current/context",
        mimeType = "application/json",
        text = rapidjson.encode(context),
    }
end

--------------------------------------------------------------------------------
-- Book Metadata
--------------------------------------------------------------------------------

function MCPResources:getMetadata()
    local doc = self.ui.document
    local props = doc:getProps()

    local data = {
        title = props.title or "Unknown",
        authors = normalizeAuthors(props.authors),
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
        data.current_page = doc_settings:readSetting("last_page") or doc:getCurrentPage()
    end

    return {
        uri = "book://current/metadata",
        mimeType = "application/json",
        text = rapidjson.encode(data),
    }
end

--------------------------------------------------------------------------------
-- Table of Contents
--------------------------------------------------------------------------------

function MCPResources:getTableOfContents()
    local doc = self.ui.document
    local toc = doc:getToc()

    local tocData = {
        chapters = {},
    }

    if toc then
        for i, item in ipairs(toc) do
            table.insert(tocData.chapters, {
                index = i,
                title = item.title or "",
                page = item.page or 0,
                depth = item.depth or 0,
            })
        end
    end

    return {
        uri = "book://current/toc",
        mimeType = "application/json",
        text = rapidjson.encode(tocData),
    }
end

--------------------------------------------------------------------------------
-- Bookmarks (Highlights and Notes)
--------------------------------------------------------------------------------

function MCPResources:getBookmarks()
    local bookmarks = {
        highlights = {},
        notes = {},
    }

    if self.ui.annotation and self.ui.annotation.annotations then
        for _, item in ipairs(self.ui.annotation.annotations) do
            local bookmark = {
                text = item.text,
                page = item.page,
                chapter = item.chapter,
                datetime = item.datetime,
            }

            if item.note and item.note ~= "" then
                bookmark.note = item.note
                table.insert(bookmarks.notes, bookmark)
            else
                table.insert(bookmarks.highlights, bookmark)
            end
        end
    end

    return {
        uri = "book://current/bookmarks",
        mimeType = "application/json",
        text = rapidjson.encode(bookmarks),
    }
end

--------------------------------------------------------------------------------
-- Page Range Resource
--------------------------------------------------------------------------------

function MCPResources:getPageRange(range)
    local doc = self.ui.document
    local page_count = doc:getPageCount()

    -- Parse range: "5" or "10-15"
    local start_page, end_page
    local dash_pos = range:find("-")
    if dash_pos then
        start_page = tonumber(range:sub(1, dash_pos - 1))
        end_page = tonumber(range:sub(dash_pos + 1))
    else
        start_page = tonumber(range)
        end_page = start_page
    end

    if not start_page then
        return {
            uri = "book://current/pages/" .. range,
            mimeType = "text/plain",
            text = "Error: Invalid page range format",
        }
    end

    -- Clamp to valid range
    start_page = math.max(1, math.min(start_page, page_count))
    end_page = end_page and math.max(start_page, math.min(end_page, page_count)) or start_page

    -- Limit to 20 pages
    if end_page - start_page > 20 then
        end_page = start_page + 20
    end

    local text = ""
    for page = start_page, end_page do
        local page_text = self:extractPageText(page)
        if page_text and page_text ~= "" then
            text = text .. "=== Page " .. page .. " ===\n" .. page_text .. "\n\n"
        end
    end

    return {
        uri = "book://current/pages/" .. range,
        mimeType = "text/plain",
        text = text ~= "" and text or "No text available for specified pages",
    }
end

--------------------------------------------------------------------------------
-- Chapter Content Resource
--------------------------------------------------------------------------------

function MCPResources:getChapterContent(index)
    local doc = self.ui.document
    local toc = doc:getToc()

    if not toc or index < 1 or index > #toc then
        return {
            uri = "book://current/chapters/" .. index,
            mimeType = "text/plain",
            text = "Error: Invalid chapter index",
        }
    end

    local chapter = toc[index]
    local start_page = chapter.page or 1

    -- Find end page (next chapter's page or end of book)
    local end_page = doc:getPageCount()
    if toc[index + 1] then
        end_page = (toc[index + 1].page or end_page) - 1
    end

    -- Limit chapter to 50 pages
    if end_page - start_page > 50 then
        end_page = start_page + 50
    end

    local text = "Chapter: " .. (chapter.title or "Untitled") .. "\n"
    text = text .. "Pages: " .. start_page .. "-" .. end_page .. "\n\n"

    for page = start_page, end_page do
        local page_text = self:extractPageText(page)
        if page_text and page_text ~= "" then
            text = text .. page_text .. "\n\n"
        end
    end

    return {
        uri = "book://current/chapters/" .. index,
        mimeType = "text/plain",
        text = text,
    }
end

--------------------------------------------------------------------------------
-- Library Resources
--------------------------------------------------------------------------------

function MCPResources:getLibraryBooks()
    local books = {}

    -- Try to use ReadHistory for recently read books with metadata
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for _, item in ipairs(ReadHistory.hist) do
            local book = {
                file = item.file,
                title = item.text or item.file:match("([^/]+)$"),
            }

            -- Try to get additional metadata from doc settings
            if item.file then
                local doc_settings = DocSettings:open(item.file)
                if doc_settings then
                    local props = doc_settings:readSetting("doc_props") or {}
                    book.authors = normalizeAuthors(props.authors)
                    book.percent_finished = doc_settings:readSetting("percent_finished") or 0
                    book.last_read = item.time
                end
            end

            table.insert(books, book)
        end
    end

    return {
        uri = "library://books",
        mimeType = "application/json",
        text = rapidjson.encode({ books = books }),
    }
end

function MCPResources:getCollections()
    local collections = {}

    local ok, ReadCollection = pcall(require, "readcollection")
    if ok and ReadCollection then
        local coll = ReadCollection:read()
        if coll then
            for name, items in pairs(coll) do
                table.insert(collections, {
                    name = name,
                    book_count = #items,
                })
            end
        end
    end

    return {
        uri = "library://collections",
        mimeType = "application/json",
        text = rapidjson.encode({ collections = collections }),
    }
end

function MCPResources:getReadingHistory()
    local history = {}

    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        -- Return last 20 books
        local count = math.min(20, #ReadHistory.hist)
        for i = 1, count do
            local item = ReadHistory.hist[i]
            table.insert(history, {
                file = item.file,
                title = item.text or item.file:match("([^/]+)$"),
                last_read = item.time,
            })
        end
    end

    return {
        uri = "library://history",
        mimeType = "application/json",
        text = rapidjson.encode({ history = history }),
    }
end

function MCPResources:getBookByPath(path)
    -- URL decode the path
    path = path:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)

    local doc_settings = DocSettings:open(path)
    if not doc_settings then
        return {
            uri = "library://books/" .. path,
            mimeType = "application/json",
            text = rapidjson.encode({ error = "Book not found" }),
        }
    end

    local props = doc_settings:readSetting("doc_props") or {}
    local book = {
        file = path,
        title = props.title or path:match("([^/]+)$"),
        authors = normalizeAuthors(props.authors),
        language = props.language,
        series = props.series,
        description = props.description,
        percent_finished = doc_settings:readSetting("percent_finished") or 0,
    }

    return {
        uri = "library://books/" .. path,
        mimeType = "application/json",
        text = rapidjson.encode(book),
    }
end

--------------------------------------------------------------------------------
-- Subscription Management
--------------------------------------------------------------------------------

function MCPResources:subscribe(uri)
    self.subscriptions[uri] = true
    logger.dbg("MCP: Subscribed to resource:", uri)
    return true
end

function MCPResources:unsubscribe(uri)
    self.subscriptions[uri] = nil
    logger.dbg("MCP: Unsubscribed from resource:", uri)
    return true
end

function MCPResources:getSubscriptions()
    local uris = {}
    for uri, _ in pairs(self.subscriptions) do
        table.insert(uris, uri)
    end
    return uris
end

-- Check if any subscribed resources have changed
-- Returns list of changed URIs
function MCPResources:checkForChanges()
    local changed = {}

    if not self.ui or not self.ui.document then
        -- Document closed - check if it was open before
        if self._cache.document_file then
            self._cache.document_file = nil
            self._cache.current_page = nil
            self._cache.selection_text = nil
            -- All book resources are now invalid
            for uri, _ in pairs(self.subscriptions) do
                if uri:match("^book://") then
                    table.insert(changed, uri)
                end
            end
        end
        return changed
    end

    -- Check document change
    local current_file = self.ui.document.file
    if current_file ~= self._cache.document_file then
        self._cache.document_file = current_file
        self._cache.current_page = nil
        self._cache.selection_text = nil
        -- All book resources changed
        for uri, _ in pairs(self.subscriptions) do
            if uri:match("^book://") then
                table.insert(changed, uri)
            end
        end
        return changed
    end

    -- Check page change
    local current_page = self.ui.document:getCurrentPage()
    if current_page ~= self._cache.current_page then
        self._cache.current_page = current_page
        if self.subscriptions["book://current/context"] then
            table.insert(changed, "book://current/context")
        end
    end

    -- Check selection change
    local selection_text = nil
    if self.ui.highlight and self.ui.highlight.selected_text then
        selection_text = self.ui.highlight.selected_text.text
    end
    if selection_text ~= self._cache.selection_text then
        self._cache.selection_text = selection_text
        if self.subscriptions["book://current/context"] then
            -- Only add if not already added
            local already_added = false
            for _, uri in ipairs(changed) do
                if uri == "book://current/context" then
                    already_added = true
                    break
                end
            end
            if not already_added then
                table.insert(changed, "book://current/context")
            end
        end
    end

    return changed
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Extract text from a single page
function MCPResources:extractPageText(page)
    local doc = self.ui.document
    local page_count = doc:getPageCount()

    if page < 1 or page > page_count then
        return nil
    end

    local text = nil

    -- For reflowable documents (EPUB), try getTextFromXPointers
    if doc.getPageXPointer and doc.getTextFromXPointers then
        local startXP = doc:getPageXPointer(page)
        local endXP = nil
        if page < page_count then
            endXP = doc:getPageXPointer(page + 1)
        end
        if startXP and endXP then
            text = doc:getTextFromXPointers(startXP, endXP, false)
        elseif startXP and doc.getTextFromXPointer then
            text = doc:getTextFromXPointer(startXP)
        end
    end

    -- For paged documents (PDF), try getPageTextBoxes
    if not text and doc.getPageTextBoxes then
        local textBoxes = doc:getPageTextBoxes(page)
        text = self:extractTextFromBoxes(textBoxes)
    end

    -- Fallback
    if not text and doc.getPageText then
        text = doc:getPageText(page)
    end

    return text
end

-- Extract text from text boxes structure (for PDF/DjVu)
function MCPResources:extractTextFromBoxes(textBoxes)
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

return MCPResources
