--[[
    MCP Prompts
    Implements MCP prompts for guided interactions with AI reading assistants
    Prompts provide structured templates for common reading companion scenarios
--]]

local logger = require("logger")
local rapidjson = require("rapidjson")

local MCPPrompts = {
  ui = nil,
  resources = nil,
}

function MCPPrompts:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function MCPPrompts:setUI(ui)
  self.ui = ui
end

function MCPPrompts:setResources(resources)
  self.resources = resources
end

--------------------------------------------------------------------------------
-- Prompt Definitions
--------------------------------------------------------------------------------

-- All available prompts with their metadata and templates
local PROMPTS = {
  -- Primary reading companion prompt
  {
    name = "explain",
    title = "Explain This",
    description =
    "Explain the selected text or current page content. Great for understanding difficult passages, concepts, or terminology.",
    arguments = {
      {
        name = "question",
        description = "Optional specific question about the content",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}

      -- System-like guidance as first user message
      local instruction = "You are a reading companion helping the user understand what they're reading. "
      if context.selection then
        instruction = instruction .. "The user has selected specific text they want explained. "
      else
        instruction = instruction .. "Focus on the current page content. "
      end
      instruction = instruction ..
      "Provide a clear, accessible explanation. If the text references concepts, terms, or context from earlier in the book, help clarify those connections."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context as embedded resource
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- User's specific question or general request
      local request = args.question or "Please explain this to me."
      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Summarize content
  {
    name = "summarize",
    title = "Summarize",
    description =
    "Summarize the current chapter, a range of pages, or the book so far. Useful for recapping or reviewing content.",
    arguments = {
      {
        name = "scope",
        description =
        "What to summarize: 'page', 'chapter', 'book-so-far', or a page range like '10-25' (default: chapter)",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}
      local scope = args.scope or "chapter"

      local instruction = "You are a reading companion helping the user review what they've read. "
      instruction = instruction ..
      "Provide a concise but comprehensive summary that captures the key points, main arguments, or plot developments. "
      instruction = instruction .. "Use the reading context to understand the current position in the book."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- Scope-specific request
      local request
      if scope == "page" then
        request = "Please summarize the current page."
      elseif scope == "chapter" then
        request =
        "Please summarize the current chapter. Use the table of contents to understand the chapter boundaries, and read the chapter content if needed."
      elseif scope == "book-so-far" then
        request =
        "Please summarize what I've read so far in this book (up to the current page). You may need to read previous chapters to provide a complete summary."
      elseif scope:match("^%d+%-%d+$") or scope:match("^%d+$") then
        request = "Please summarize pages " .. scope .. ". Use the read_pages tool to get the content."
      else
        request = "Please summarize the current chapter."
      end

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Discuss the book/topic
  {
    name = "discuss",
    title = "Let's Discuss",
    description =
    "Start a conversation about the book, its themes, ideas, or related topics. The assistant will engage as a knowledgeable reading companion.",
    arguments = {
      {
        name = "topic",
        description = "Optional topic or question to start the discussion",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}

      local instruction =
      "You are a thoughtful reading companion engaging in discussion about the book the user is reading. "
      instruction = instruction ..
      "Be conversational and intellectually curious. Share insights, ask thought-provoking questions, and explore ideas together. "
      instruction = instruction ..
      "Draw connections to related works, real-world applications, or broader themes when relevant."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- Start the discussion
      local request = args.topic or
      "What aspects of what I'm reading would you like to discuss? What themes or ideas stand out to you?"
      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Research about the book
  {
    name = "research",
    title = "Research This Book",
    description =
    "Get background information about the book, author, historical context, or related works. Uses web search when available.",
    arguments = {
      {
        name = "focus",
        description =
        "What to research: 'author', 'historical-context', 'reviews', 'similar-books', or a specific question",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}
      local focus = args.focus

      local instruction = "You are a research assistant helping the user learn more about the book they're reading. "
      instruction = instruction .. "Use web search if available to find accurate, up-to-date information. "
      instruction = instruction ..
      "Cite sources when possible and distinguish between factual information and analysis/opinion."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context for book info
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- Focus-specific request
      local request
      if focus == "author" then
        request = "Tell me about the author of this book - their background, other works, and writing style."
      elseif focus == "historical-context" then
        request =
        "What's the historical context of this book? When was it written, what was happening at that time, and how does it relate to the content?"
      elseif focus == "reviews" then
        request = "What do critics and readers think of this book? Find notable reviews and common opinions."
      elseif focus == "similar-books" then
        request = "What books are similar to this one? Recommend related works I might enjoy."
      elseif focus then
        request = focus
      else
        request = "Give me background information about this book that would enrich my reading experience."
      end

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Take a note
  {
    name = "note",
    title = "Take a Note",
    description =
    "Create a note or annotation for the current passage. The assistant can help formulate and save the note.",
    arguments = {
      {
        name = "thought",
        description = "Your thought or reaction to capture (assistant will help refine and save it)",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}

      local instruction = "You are helping the user take notes while reading. "
      instruction = instruction .. "Help them articulate their thoughts clearly and concisely. "
      instruction = instruction ..
      "Once the note is finalized, use the annotate tool to save it as a highlight with note in the book. "
      instruction = instruction .. "Keep notes brief but meaningful - they should be useful for future reference."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- User's thought or prompt for assistance
      local request
      if args.thought then
        request = "I want to note: " .. args.thought .. "\n\nHelp me refine this note and save it."
      elseif context.selection then
        request = "I want to annotate this selected passage. Help me formulate a note for it."
      else
        request = "Help me capture a note about what I'm reading. What would be worth noting here?"
      end

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Quiz me
  {
    name = "quiz",
    title = "Quiz Me",
    description = "Test your understanding with questions about what you've read. Great for study and retention.",
    arguments = {
      {
        name = "difficulty",
        description = "Question difficulty: 'easy', 'medium', 'hard' (default: medium)",
        required = false,
      },
      {
        name = "scope",
        description = "What to quiz on: 'page', 'chapter', or 'book-so-far' (default: chapter)",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}
      local difficulty = args.difficulty or "medium"
      local scope = args.scope or "chapter"

      local instruction = "You are a study assistant helping the user test their comprehension. "
      instruction = instruction .. "Ask thoughtful questions that test understanding, not just recall. "
      instruction = instruction .. "Wait for the user's answer before revealing the correct response. "
      instruction = instruction .. "Be encouraging but honest in your feedback."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- Quiz request
      local scope_text = scope == "page" and "current page" or scope == "book-so-far" and "what I've read so far" or
      "current chapter"
      local request = string.format(
        "Quiz me on the %s with %s difficulty questions. Read the relevant content if needed, then ask me one question at a time.",
        scope_text, difficulty
      )

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Translate passage
  {
    name = "translate",
    title = "Translate",
    description = "Translate the selected text or current page into another language.",
    arguments = {
      {
        name = "language",
        description = "Target language for translation (e.g., 'Spanish', 'French', 'Japanese')",
        required = true,
      },
    },
    template = function(args, context)
      local messages = {}

      local instruction = "You are a translation assistant. "
      instruction = instruction ..
      "Provide an accurate translation that preserves the meaning, tone, and style of the original. "
      instruction = instruction .. "If there are culturally-specific terms or idioms, explain them briefly."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- Translation request
      local request
      if context.selection then
        request = "Translate the selected text into " .. args.language .. "."
      else
        request = "Translate the current page into " .. args.language .. "."
      end

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },

  -- Book recommendations
  {
    name = "recommend",
    title = "Recommend Books",
    description =
    "Get personalized book recommendations based on your current book, reading history, and library. Can suggest similar books, more from the author, similar authors, or general recommendations.",
    arguments = {
      {
        name = "what",
        description =
        "What to recommend: 'similar-books', 'more-from-author', 'similar-authors', 'from-library', 'surprise-me', or describe what you're looking for",
        required = false,
      },
    },
    template = function(args, context)
      local messages = {}
      local what = args.what or "similar-books"

      local instruction =
      "You are a knowledgeable librarian and book recommender helping the reader discover their next book. "
      instruction = instruction .. "Consider the user's current book and their library/reading history when available. "
      instruction = instruction ..
      "Provide thoughtful recommendations with brief explanations of why each book might appeal to them. "
      instruction = instruction .. "Feel free to use web search to find accurate book information and recommendations."

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = instruction,
        },
      })

      -- Include reading context for current book
      table.insert(messages, {
        role = "user",
        content = {
          type = "resource",
          resource = context.reading_context_resource,
        },
      })

      -- Include library info if available
      if context.library_available then
        table.insert(messages, {
          role = "user",
          content = {
            type = "resource",
            resource = {
              uri = "library://books",
              mimeType = "application/json",
              text = context.library_books or "[]",
            },
          },
        })
      end

      -- Recommendation request based on criteria
      local request
      if what == "similar-books" then
        request =
        "Recommend books similar to what I'm currently reading. Consider theme, style, genre, and what makes this book appealing."
      elseif what == "more-from-author" then
        request =
        "What other books by this author should I read? Tell me about their other notable works and which might be the best next read."
      elseif what == "similar-authors" then
        request =
        "Recommend authors who write in a similar style or explore similar themes to this book's author. Suggest their best works to start with."
      elseif what == "from-library" then
        request =
        "Looking at my library, what should I read next? Consider what I've been reading and suggest something from my existing collection."
      elseif what == "surprise-me" then
        request =
        "Surprise me with an unexpected recommendation! Based on what I'm reading, suggest something I might not have considered but could love."
      else
        request = "I'm looking for: " .. what .. "\n\nPlease recommend books that match this."
      end

      table.insert(messages, {
        role = "user",
        content = {
          type = "text",
          text = request,
        },
      })

      return messages
    end,
  },
}

--------------------------------------------------------------------------------
-- Public Interface
--------------------------------------------------------------------------------

function MCPPrompts:list()
  local prompts = {}

  for _, prompt in ipairs(PROMPTS) do
    table.insert(prompts, {
      name = prompt.name,
      title = prompt.title,
      description = prompt.description,
      arguments = prompt.arguments,
    })
  end

  return prompts
end

function MCPPrompts:get(name, arguments)
  -- Find the prompt definition
  local promptDef
  for _, p in ipairs(PROMPTS) do
    if p.name == name then
      promptDef = p
      break
    end
  end

  if not promptDef then
    return nil, "Prompt not found: " .. name
  end

  -- Validate required arguments
  if promptDef.arguments then
    for _, arg in ipairs(promptDef.arguments) do
      if arg.required and (not arguments or not arguments[arg.name]) then
        return nil, "Missing required argument: " .. arg.name
      end
    end
  end

  -- Build context for the template
  local context = self:buildContext()

  -- Generate messages from template
  local messages = promptDef.template(arguments or {}, context)

  return {
    description = promptDef.description,
    messages = messages,
  }
end

--------------------------------------------------------------------------------
-- Context Building
--------------------------------------------------------------------------------

function MCPPrompts:buildContext()
  local context = {
    selection = nil,
    reading_context_resource = nil,
    library_available = false,
    library_books = nil,
  }

  -- Get current selection if any
  if self.ui and self.ui.highlight and self.ui.highlight.selected_text then
    context.selection = self.ui.highlight.selected_text.text
  end

  -- Build reading context resource
  if self.resources then
    local reading_context = self.resources:read("book://current/context")
    if reading_context and reading_context[1] then
      context.reading_context_resource = {
        uri = "book://current/context",
        mimeType = reading_context[1].mimeType or "application/json",
        text = reading_context[1].text,
      }
    end

    -- Check if library is available and get books list
    local books = self.resources:read("library://books")
    if books and books[1] then
      context.library_available = true
      context.library_books = books[1].text
    end
  end

  -- Fallback if no reading context resource
  if not context.reading_context_resource then
    context.reading_context_resource = {
      uri = "book://current/context",
      mimeType = "text/plain",
      text = "No book is currently open.",
    }
  end

  return context
end

return MCPPrompts
