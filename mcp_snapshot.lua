--[[
    Offline memory: the snapshot of what is being read

    When the user turns offline memory on, the reader sends the relay a
    snapshot of the open book, so connected AI apps can still answer questions
    while the reader is asleep or away. This module builds that snapshot and
    fits it into the relay's size limit. Sending it is mcp_memory.lua's job.

    Snapshot format v1 (JSON), also documented in the relay's README:
      v, taken_at, scope, retention_days,
      book      { title, authors, language, series, keywords, description, format, total_pages }
      position  { page, percent_finished, chapter { name, index, start_page, end_page } }
      toc       [ { index, title, page, depth } ]
      annotations [ { text, note, note_format, page, chapter, datetime, color, style } ]
      pages     [ { number, text } ]        (only with scope "pages")

    It never contains the book's file name or path.
--]]

local rapidjson = require("rapidjson")

local Snapshot = {
    VERSION = 1,
    -- Pages saved around the current one with scope "pages". Forward-leaning:
    -- by the time a question comes, the user has usually read on a little.
    PAGES_BEFORE = 2,
    PAGES_AFTER = 10,
    -- Caps on single fields, so one odd book can't crowd out everything else
    MAX_DESCRIPTION_BYTES = 2000,
    MAX_TITLE_BYTES = 300,
    MAX_HIGHLIGHT_BYTES = 4000,
    MAX_NOTE_BYTES = 8000,
    MAX_TOC_ENTRIES = 1500,
    MAX_ANNOTATIONS = 2000,
}

-- Mark a table as a JSON array, so an empty one encodes as [] and not {}
local function array(t)
    if rapidjson.array then
        return rapidjson.array(t)
    end
    return t
end

-- Cut a string to at most max_bytes without splitting a UTF-8 character
local function clip(value, max_bytes)
    if type(value) ~= "string" then
        return nil
    end
    if #value <= max_bytes then
        return value
    end
    local cut = max_bytes
    -- Step back over continuation bytes (10xxxxxx) to a character boundary
    while cut > 0 do
        local byte = value:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return value:sub(1, cut)
end
Snapshot._clip = clip

local function formatAuthors(authors)
    if type(authors) == "string" then
        return authors ~= "" and authors or nil
    elseif type(authors) == "table" and #authors > 0 then
        return table.concat(authors, ", ")
    end
    return nil
end

-- The page number of an annotation. Reflowable books keep a position string
-- in `page` and the number in `pageno`.
local function annotationPage(doc, item)
    if type(item.page) == "number" then
        return item.page
    end
    if type(item.pageno) == "number" then
        return item.pageno
    end
    if type(item.page) == "string" and doc.getPageFromXPointer then
        local ok, page = pcall(doc.getPageFromXPointer, doc, item.page)
        if ok and type(page) == "number" then
            return page
        end
    end
    return nil
end

-- Chapter that holds `page`: { name, index, start_page, end_page } or nil
local function chapterFor(toc, page, page_count)
    local current
    local next_start = page_count + 1
    for i, item in ipairs(toc) do
        local start = item.page or 0
        if start <= page then
            current = { name = item.title or "", index = i, start_page = start }
        elseif current then
            next_start = start
            break
        else
            break
        end
    end
    if not current then
        return nil
    end
    current.end_page = next_start - 1
    return current
end

--[[
    Build a snapshot of the open book.
    @param ui the reader UI (with .document)
    @param options table:
      scope: "position" (no page text) or "pages"
      retention_days: how long the relay may keep it
      page_text: function(page) -> string or nil, the text of one page as the
                 MCP tools return it (highlights marked inline)
    @return snapshot table, or nil when no book is open
--]]
function Snapshot.build(ui, options)
    local doc = ui and ui.document
    if not doc then
        return nil
    end
    options = options or {}
    local scope = options.scope == "pages" and "pages" or "position"

    local props = doc:getProps() or {}
    local page_count = doc:getPageCount() or 0
    local page = ui:getCurrentPage() or 1

    local snapshot = {
        v = Snapshot.VERSION,
        taken_at = os.time(),
        scope = scope,
        retention_days = options.retention_days,
        book = {
            title = clip(props.title, Snapshot.MAX_TITLE_BYTES) or "Unknown",
            authors = clip(formatAuthors(props.authors), Snapshot.MAX_TITLE_BYTES),
            language = clip(props.language, 40),
            series = clip(props.series, Snapshot.MAX_TITLE_BYTES),
            keywords = clip(props.keywords, 1000),
            description = clip(props.description, Snapshot.MAX_DESCRIPTION_BYTES),
            format = type(doc.file) == "string" and clip(doc.file:match("%.([^./\\]+)$"), 12) or nil,
            total_pages = page_count,
        },
        position = {
            page = page,
            percent_finished = page_count > 0 and math.floor(page / page_count * 10000 + 0.5) / 10000 or 0,
        },
        toc = array({}),
        annotations = array({}),
        pages = array({}),
    }

    -- Table of contents
    local ok_toc, toc = pcall(doc.getToc, doc)
    if ok_toc and type(toc) == "table" then
        for i, item in ipairs(toc) do
            if i > Snapshot.MAX_TOC_ENTRIES then
                break
            end
            table.insert(snapshot.toc, {
                index = i,
                title = clip(item.title, Snapshot.MAX_TITLE_BYTES) or "",
                page = item.page or 0,
                depth = item.depth or 1,
            })
        end
        snapshot.position.chapter = chapterFor(toc, page, page_count)
    end

    -- Highlights and notes
    local annotations = ui.annotation and ui.annotation.annotations
    if type(annotations) == "table" then
        for _, item in ipairs(annotations) do
            if #snapshot.annotations >= Snapshot.MAX_ANNOTATIONS then
                break
            end
            local has_note = type(item.note) == "string" and item.note ~= ""
            -- Plain bookmarks (no highlighted text, no note) say nothing useful
            if (type(item.text) == "string" and item.text ~= "") or has_note then
                table.insert(snapshot.annotations, {
                    text = clip(item.text, Snapshot.MAX_HIGHLIGHT_BYTES),
                    note = has_note and clip(item.note, Snapshot.MAX_NOTE_BYTES) or nil,
                    note_format = has_note and item.note_format or nil,
                    page = annotationPage(doc, item),
                    chapter = clip(item.chapter, Snapshot.MAX_TITLE_BYTES),
                    datetime = type(item.datetime) == "string" and item.datetime or nil,
                    color = type(item.color) == "string" and item.color or nil,
                    style = type(item.drawer) == "string" and item.drawer or nil,
                })
            end
        end
    end

    -- Page text around the current position
    if scope == "pages" and options.page_text and page_count > 0 then
        local first = math.max(1, page - (options.pages_before or Snapshot.PAGES_BEFORE))
        local last = math.min(page_count, page + (options.pages_after or Snapshot.PAGES_AFTER))
        for number = first, last do
            local ok_text, text = pcall(options.page_text, number)
            if ok_text and type(text) == "string" and text ~= "" then
                table.insert(snapshot.pages, { number = number, text = text })
            end
        end
    end

    return snapshot
end

--[[
    Encode a snapshot as JSON no larger than max_bytes, dropping the least
    useful parts first: pages farthest from the current one, then the oldest
    highlights, then deep table-of-contents entries, then the description.
    The snapshot table is changed in place to what was encoded.
    @return json string, or nil if even the minimum doesn't fit
--]]
function Snapshot.encode(snapshot, max_bytes)
    local function encode()
        local ok, encoded = pcall(rapidjson.encode, snapshot)
        return ok and type(encoded) == "string" and encoded or nil
    end
    local encoded = encode()
    if not encoded then
        return nil
    end
    if not max_bytes or #encoded <= max_bytes then
        return encoded
    end

    -- 1. Pages, farthest from the current position first (ahead before behind)
    local current = snapshot.position.page
    while #encoded > max_bytes and #snapshot.pages > 0 do
        local pages = snapshot.pages
        local behind = current - pages[1].number
        local ahead = pages[#pages].number - current
        if #pages > 1 and behind > ahead then
            table.remove(pages, 1)
        else
            table.remove(pages)
        end
        encoded = encode()
    end

    -- 2. Highlights and notes: keep the newest half, as often as needed
    while #encoded > max_bytes and #snapshot.annotations > 0 do
        local items = snapshot.annotations
        local order = {}
        for i, item in ipairs(items) do
            order[i] = { index = i, datetime = item.datetime or "" }
        end
        table.sort(order, function(a, b)
            if a.datetime ~= b.datetime then
                return a.datetime > b.datetime
            end
            return a.index > b.index
        end)
        local keep = {}
        for i = 1, math.floor(#order / 2) do
            keep[order[i].index] = true
        end
        local kept = array({})
        for i, item in ipairs(items) do
            if keep[i] then
                table.insert(kept, item)
            end
        end
        snapshot.annotations = kept
        encoded = encode()
    end

    -- 3. Table of contents: top level only, then nothing
    if #encoded > max_bytes and #snapshot.toc > 0 then
        local top = array({})
        for _, item in ipairs(snapshot.toc) do
            if (item.depth or 1) <= 1 then
                table.insert(top, item)
            end
        end
        snapshot.toc = top
        encoded = encode()
        if #encoded > max_bytes then
            snapshot.toc = array({})
            encoded = encode()
        end
    end

    -- 4. The description
    if #encoded > max_bytes and snapshot.book.description then
        snapshot.book.description = nil
        encoded = encode()
    end

    if #encoded > max_bytes then
        return nil
    end
    return encoded
end

--[[
    A cheap signature of what a snapshot would contain, to skip sending the
    same thing twice. Stays on the device.
--]]
function Snapshot.fingerprint(ui, options)
    local doc = ui and ui.document
    if not doc then
        return nil
    end
    options = options or {}
    local annotations = ui.annotation and ui.annotation.annotations or {}
    local newest = ""
    local notes = 0
    for _, item in ipairs(annotations) do
        if type(item.datetime_updated) == "string" and item.datetime_updated > newest then
            newest = item.datetime_updated
        end
        if type(item.datetime) == "string" and item.datetime > newest then
            newest = item.datetime
        end
        if type(item.note) == "string" then
            notes = notes + #item.note
        end
    end
    return table.concat({
        tostring(doc.file),
        tostring(ui:getCurrentPage()),
        tostring(doc:getPageCount()),
        tostring(#annotations),
        newest,
        tostring(notes),
        tostring(options.scope),
        tostring(options.retention_days),
    }, "|")
end

return Snapshot
