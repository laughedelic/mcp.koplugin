---
title: Reference
description: The MCP resources, tools and prompts the KOReader plugin provides, and the protocol versions it speaks.
---

For the curious, and for anyone connecting a client that isn't covered in [Set up](setup.html). This is everything the server offers over the [Model Context Protocol](https://modelcontextprotocol.io).
{: .lede}

## Tools

<div class="table-scroll" markdown="1">

| Tool | What it does | Parameters |
| --- | --- | --- |
| `get_reading_context` | Current book, chapter, page and selection | `extra_pages_before`, `extra_pages_after` (optional) |
| `get_book_metadata` | Title, author, progress and statistics | None |
| `read_pages` | Text of pages or a chapter | `pages` (such as `"5"` or `"10-15"`), `chapter` (index) |
| `search_book` | Full-text search in the book | `query`, `case_sensitive` (optional) |
| `goto_page` | Turns the reader to a page | `page` |
| `annotate` | Adds a highlight or note (EPUB, FB2, PDF, DjVu and more) | `note`, `note_format`, `text`, `start`, `end`, `if_note_exists` (all optional) |

</div>

Every tool carries MCP annotations. The first four are marked read-only. `goto_page` and `annotate` change something on the reader.

## Resources

<div class="table-scroll" markdown="1">

| Resource | Contents |
| --- | --- |
| `book://current/context` | Current page, chapter and selection |
| `book://current/metadata` | Title, author, progress and more |
| `book://current/toc` | Table of contents |
| `book://current/bookmarks` | Bookmarks and highlights |
| `book://current/pages/{range}` | Text of pages, such as `5` or `10-15` |
| `book://current/chapters/{idx}` | Text of a chapter by index |
| `library://books` | Every book in the library |
| `library://collections` | Collections |
| `library://history` | Reading history |
| `library://books/{path}` | Metadata for one book |

</div>

## Prompts

`explain`, `summarize`, `discuss`, `research`, `note`, `quiz`, `translate` and `recommend`. [Using it](using.html#ready-made-prompts) describes each one.

## Protocol versions

<div class="table-scroll" markdown="1">

| Client speaks | How it connects |
| --- | --- |
| 2026-07-28 (stateless) | Every request carries its version and capabilities in `_meta`; `server/discover` describes the server |
| 2025-03-26 to 2025-11-25 | `initialize` handshake; the server answers with the client's version |

</div>

Both run on the same endpoint. Clients that speak both try 2026-07-28 first and fall back automatically.

## Asking before overwriting a note

With 2026-07-28 clients that declare form elicitation, `annotate` asks the user before changing a note that already exists: replace it, add below it, or keep it. The question travels inside the tool result (an `input_required` result) and the client retries the call with the answer, so it works through the relay without an extra channel. With other clients, the tool leaves the note alone and asks the assistant to check with you and call again with `if_note_exists`.

## Not supported

- **Sampling and server logging.** Deprecated in MCP 2026-07-28 and not implemented.
- **Live change notifications** for page turns and book changes. Planned through the 2026-07-28 `subscriptions/listen` stream. Until then the server doesn't advertise resource subscriptions.

## Endpoints

- Through the relay: `https://mcp-relay.laughedelic.workers.dev/mcp`, with OAuth 2.1 (authorization code with PKCE, dynamic client registration).
- Local mode: `http://<reader-ip>:8788/` or `/mcp`, no authentication. Requests with an `Origin` header are accepted only from `localhost` or the reader's own address.
