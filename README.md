# MCP Server Plugin for KOReader

A KOReader plugin that implements a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server, enabling AI assistants to interact with your e-books in real-time.

## Features

- **Book Content Access**: AI assistants can read your current book's content at different scopes (current page, full text, specific page ranges)
- **Metadata Retrieval**: Access book metadata including title, author, reading progress, and statistics
- **Interactive Tools**: Search within books, navigate to pages, get table of contents
- **Real-time Communication**: MCP server runs directly on your e-reader device
- **Secure Local Network**: Server binds to your local network only
- **Auto-start**: Optionally start the server automatically when KOReader launches
- **Idle Timeout**: Automatically stop the server after a period of inactivity to save battery
- **Power Management**: Option to turn off WiFi when idle timeout triggers

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

There are two ways to access the MCP server controls:

#### Quick Toggle (Tools Menu)

1. Open a book in KOReader
2. Tap the menu (top of screen)
3. Navigate to **Tools → MCP server**
4. The menu item shows server status and connection info when running
5. Tap to toggle the server on/off
6. Long-press to see detailed status

#### Full Settings (Network Menu)

1. Tap the menu
2. Navigate to **Settings → Network → MCP server**
3. Configure server settings:
   - **Start server automatically**: Enable to start the server when KOReader launches (requires WiFi)
   - **Idle timeout**: Set inactivity period (0-120 minutes) before auto-stopping the server
   - **Turn off WiFi on idle timeout**: Save battery by disabling WiFi when server stops due to idle timeout

When the idle timeout is enabled, you'll see a warning notification 5 seconds before the server stops. Tap the notification to reset the idle timer and keep the server alive.

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

| Resource URI                | Description                                   |
| --------------------------- | --------------------------------------------- |
| `book://current/metadata`   | Book metadata (title, author, progress, etc.) |
| `book://current/page`       | Current page text content                     |
| `book://current/text`       | Full book text (limited to 100 pages)         |
| `book://current/toc`        | Table of contents                             |
| `book://current/statistics` | Reading statistics and progress               |

## MCP Tools

The plugin provides these callable tools:

| Tool            | Description                    | Parameters                           |
| --------------- | ------------------------------ | ------------------------------------ |
| `get_page_text` | Get text from specific page(s) | `start_page`, `end_page` (optional)  |
| `search_book`   | Search for text in the book    | `query`, `case_sensitive` (optional) |
| `get_toc`       | Get table of contents          | None                                 |
| `goto_page`     | Navigate to a specific page    | `page`                               |
| `get_selection` | Get currently selected text    | None                                 |
| `get_book_info` | Get detailed book information  | None                                 |

## Architecture

The plugin consists of several modular components:

- **main.lua**: Plugin entry point and UI integration
- **mcp_server.lua**: HTTP server implementation
- **mcp_protocol.lua**: JSON-RPC 2.0 / MCP protocol handler
- **mcp_resources.lua**: Resource implementations (book content, metadata)
- **mcp_tools.lua**: Tool implementations (search, navigation, etc.)

## Configuration

The plugin supports the following configuration options (stored in KOReader's settings):

- **Port**: Server runs on port **8788** by default (can be modified in `main.lua`)
- **Auto-start** (`mcp_server_autostart`): Start server automatically when KOReader launches (default: disabled)
- **Idle timeout** (`mcp_server_idle_timeout_minutes`): Minutes of inactivity before stopping server (default: 0/disabled, range: 0-120)
- **WiFi disable on timeout** (`mcp_server_idle_timeout_wifi_off`): Turn off WiFi when idle timeout triggers (default: disabled)

These settings can be configured through the **Settings → Network → MCP server** menu.

## Limitations

- Text extraction depends on document format (works best with EPUB, may be limited for PDF/DjVu)
- Full text retrieval is limited to 100 pages for performance
- Search is limited to 100 pages for performance
- Server stops automatically when device suspends (to save battery)
- Idle timeout warning appears 5 seconds before server stops (tap to keep alive)

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
      "protocolVersion": "2025-03-26",
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

### Troubleshooting

If you can't connect to the MCP server:

1. **Verify the device IP address**: Make sure you're using the correct IP shown in the server status
2. **Check network connectivity**: Ensure your computer and e-reader are on the same network
3. **Try pinging the device**: `ping YOUR_DEVICE_IP` to verify basic connectivity
4. **WiFi isolation**: Some routers have "AP isolation" or "Client isolation" enabled, which prevents devices from communicating with each other. Check your router settings
5. **Firewall on device**: Some e-readers may have firewall rules blocking incoming connections. On Kindle devices, the plugin attempts to open the port automatically
6. **Port availability**: Try a different port if 8788 is blocked by your network

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
