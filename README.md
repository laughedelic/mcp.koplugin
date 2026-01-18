# MCP Server Plugin for KOReader

A KOReader plugin that implements a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server, enabling AI assistants to interact with your e-books in real-time.

## Features

- **Book Content Access**: AI assistants can read your current book's content at different scopes (current page, full text, specific page ranges)
- **Metadata Retrieval**: Access book metadata including title, author, reading progress, and statistics
- **Interactive Tools**: Search within books, navigate to pages, get table of contents
- **Real-time Communication**: MCP server runs directly on your e-reader device
- **Secure Local Network**: Server binds to your local network only

## What is MCP?

The Model Context Protocol (MCP) is an open standard that enables AI assistants to securely connect to external data sources and tools. This plugin implements an MCP server that exposes your KOReader book content and functionality to compatible AI assistants.

## Installation

1. Download or clone this repository
2. Copy the `mcp.koplugin` directory to your KOReader plugins folder:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Or use the path shown in KOReader's file browser
3. Restart KOReader
4. The plugin should appear in the menu

## Usage

### Starting the Server

1. Open a book in KOReader
2. Tap the menu (top of screen)
3. Navigate to **Tools → MCP Server → Start Server**
4. Note the connection URL displayed (e.g., `http://192.168.1.100:8788`)

### Connecting an AI Assistant

The MCP server uses HTTP/JSON-RPC 2.0 transport. You can connect any MCP-compatible client:

#### Claude Desktop (Example)

Add to your Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

```json
{
  "mcpServers": {
    "koreader": {
      "transport": "stdio",
      "command": "curl",
      "args": ["-X", "POST", "http://YOUR_DEVICE_IP:8788"]
    }
  }
}
```

Note: For better integration, you may want to create a custom MCP client wrapper that connects via HTTP.

### Chatting About Your Book

Once connected, you can ask your AI assistant questions like:

- "What is this book about?"
- "Summarize the current chapter"
- "Search for mentions of [character/topic]"
- "What page am I on and how much have I read?"
- "Show me the table of contents"

## MCP Resources

The plugin exposes these resources:

| Resource URI | Description |
|-------------|-------------|
| `book://current/metadata` | Book metadata (title, author, progress, etc.) |
| `book://current/page` | Current page text content |
| `book://current/text` | Full book text (limited to 100 pages) |
| `book://current/toc` | Table of contents |
| `book://current/statistics` | Reading statistics and progress |

## MCP Tools

The plugin provides these callable tools:

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_page_text` | Get text from specific page(s) | `start_page`, `end_page` (optional) |
| `search_book` | Search for text in the book | `query`, `case_sensitive` (optional) |
| `get_toc` | Get table of contents | None |
| `goto_page` | Navigate to a specific page | `page` |
| `get_selection` | Get currently selected text | None |
| `get_book_info` | Get detailed book information | None |

## Architecture

The plugin consists of several modular components:

- **main.lua**: Plugin entry point and UI integration
- **mcp_server.lua**: HTTP server implementation
- **mcp_protocol.lua**: JSON-RPC 2.0 / MCP protocol handler
- **mcp_resources.lua**: Resource implementations (book content, metadata)
- **mcp_tools.lua**: Tool implementations (search, navigation, etc.)

## Configuration

The server runs on port **8788** by default. You can modify this in `main.lua` if needed.

## Limitations

- Text extraction depends on document format (works best with EPUB, may be limited for PDF/DjVu)
- Full text retrieval is limited to 100 pages for performance
- Search is limited to 100 pages for performance
- Server stops automatically when device suspends (to save battery)

## Development

### Requirements

- KOReader (tested on version 2024+)
- Lua 5.1+ (included with KOReader)
- Network connectivity on your device

### Testing

To test the plugin:

1. Install the plugin as described above
2. Open a book in KOReader
3. Start the MCP server
4. Use a tool like `curl` to test the endpoint:

```bash
# Test initialize
curl -X POST http://YOUR_DEVICE_IP:8788 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {
        "name": "test-client",
        "version": "1.0.0"
      }
    }
  }'

# List resources
curl -X POST http://YOUR_DEVICE_IP:8788 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "resources/list",
    "params": {}
  }'
```

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

MIT License - feel free to use and modify as needed.

## Acknowledgments

- Built for [KOReader](https://github.com/koreader/koreader)
- Implements [Model Context Protocol](https://modelcontextprotocol.io) by Anthropic
- Inspired by [assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)

## References

- [KOReader Plugin Development](https://koreader.rocks/doc/topics/Development_guide.md.html)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/docs)
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification)