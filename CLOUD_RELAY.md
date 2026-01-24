# Cloud Relay Integration Plan

This document describes the architecture and implementation plan for adding cloud relay support to the KOReader MCP plugin, enabling remote access from Claude Desktop, Claude Mobile, and other MCP clients without complex network configuration.

## Problem Statement

The MCP server runs on an e-reader device behind NAT/firewall. Claude Desktop and Mobile apps cannot connect to local network addresses. Users need a way to access their e-reader's MCP server from anywhere without:
- Complex VPN setup (Tailscale, etc.)
- Port forwarding configuration
- Technical networking knowledge

## Solution: Cloud Relay

A lightweight WebSocket relay hosted on Cloudflare Workers that bridges the e-reader (which initiates an outbound connection) with MCP clients (which connect via standard HTTPS).

## Architecture

```
┌─────────────────────┐                              ┌──────────────────┐
│  KOReader e-reader  │                              │   Cloud Relay    │
│  ┌───────────────┐  │     WebSocket (outbound)     │  (Cloudflare)    │
│  │  MCP Server   │  │ ─────────────────────────►   │                  │
│  │  (port 8788)  │  │ ◄─────────────────────────   │  ┌────────────┐  │
│  └───────┬───────┘  │                              │  │  Durable   │  │
│          │          │                              │  │  Object    │  │
│  ┌───────▼───────┐  │                              │  │  (per      │  │
│  │ Relay Client  │  │                              │  │   device)  │  │
│  │ (WebSocket)   │  │                              │  └────────────┘  │
│  └───────────────┘  │                              └────────┬─────────┘
└─────────────────────┘                                       │
                                                              │ HTTPS
                                                              ▼
                                                     ┌──────────────────┐
                                                     │  MCP Clients     │
                                                     │  - Claude Desktop│
                                                     │  - Claude Mobile │
                                                     │  - Other tools   │
                                                     └──────────────────┘
```

## Components

### 1. Cloud Relay (Cloudflare Workers)

**Location:** Separate repository `mcp-relay-cloudflare`

**Technology:**
- Cloudflare Workers (edge compute)
- Durable Objects (stateful WebSocket handling)
- TypeScript

**Responsibilities:**
- Accept WebSocket connections from e-readers
- Generate unique device IDs
- Forward HTTP MCP requests to connected devices via WebSocket
- Return responses back to HTTP clients
- Handle connection lifecycle (ping/pong, reconnection)

### 2. Relay Client (KOReader Plugin Addition)

**Location:** `mcp.koplugin/mcp_relay.lua`

**Technology:**
- Lua with LuaSocket (HTTP long-polling as WebSocket fallback)
- Or shell-based WebSocket via `websocat` if available

**Responsibilities:**
- Connect to cloud relay on startup (when enabled)
- Receive forwarded MCP requests
- Forward requests to local MCP server
- Send responses back through relay
- Auto-reconnect on disconnection
- Display connection status and relay URL

## Protocol Specification

### Device → Relay (WebSocket Messages)

```typescript
// Device registration (sent on connect)
interface RegisterMessage {
  type: "register";
  deviceId?: string;  // Optional: reuse previous ID
  deviceName?: string; // Optional: human-readable name
}

// Response to an MCP request
interface ResponseMessage {
  type: "response";
  requestId: string;
  status: number;
  headers?: Record<string, string>;
  body: string;  // JSON string
}

// Pong response to keep-alive
interface PongMessage {
  type: "pong";
}
```

### Relay → Device (WebSocket Messages)

```typescript
// Registration confirmation
interface RegisteredMessage {
  type: "registered";
  deviceId: string;
  relayUrl: string;  // Full URL for MCP clients
}

// Forwarded MCP request
interface RequestMessage {
  type: "request";
  requestId: string;
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;  // JSON string
}

// Keep-alive ping
interface PingMessage {
  type: "ping";
}

// Error notification
interface ErrorMessage {
  type: "error";
  message: string;
}
```

### MCP Client → Relay (HTTP)

Standard HTTP requests to the device's relay URL:

```
POST https://mcp-relay.workers.dev/{deviceId}/mcp
Content-Type: application/json

{"jsonrpc": "2.0", "method": "initialize", "params": {...}, "id": 1}
```

The relay:
1. Looks up the device's WebSocket connection
2. Forwards the request as a `RequestMessage`
3. Waits for the `ResponseMessage` (with timeout)
4. Returns the response to the HTTP client

## Security Model

### Device Identity
- **Device ID**: 12-character alphanumeric string (e.g., `k7x9m2p4q8r1`)
- Generated randomly on first connection
- Stored locally on device for reconnection
- Acts as a bearer token (knowing the ID = access to the device)

### Security Properties
- ✅ All traffic encrypted (HTTPS/WSS)
- ✅ Device initiates connection (no inbound ports needed)
- ✅ Device ID is secret (72 bits of entropy)
- ✅ No user accounts or passwords required
- ⚠️ Anyone with the device ID can access the MCP server
- ⚠️ No rate limiting in MVP (add later if needed)

### Future Enhancements
- Optional: Pairing codes for additional security
- Optional: Time-limited session tokens
- Optional: IP allowlisting

## Implementation Plan

### Phase 1: Relay Server (Cloudflare Worker)

**Files to create:**
```
mcp-relay-cloudflare/
├── src/
│   ├── index.ts          # Worker entry point, HTTP routing
│   ├── relay.ts          # Durable Object for device connections
│   └── types.ts          # Shared TypeScript types
├── wrangler.toml         # Cloudflare configuration
├── package.json
├── tsconfig.json
└── README.md
```

**Key implementation details:**

1. **Durable Object (`MCPRelay`)**
   - One instance per device ID
   - Manages WebSocket connection state
   - Handles request/response correlation
   - Implements ping/pong keep-alive

2. **HTTP Handler**
   - `POST /{deviceId}/mcp` → Forward to device
   - `GET /{deviceId}/status` → Check device online status
   - `WebSocket /{deviceId}/ws` → Device connection endpoint

### Phase 2: Plugin Integration

**Files to modify/create:**
```
mcp.koplugin/
├── mcp_relay.lua         # NEW: Relay client implementation
├── main.lua              # MODIFY: Add relay menu, lifecycle
├── mcp_server.lua        # No changes needed
└── mcp_protocol.lua      # No changes needed
```

**Key implementation details:**

1. **Relay Client (`mcp_relay.lua`)**
   - HTTP long-polling (KOReader doesn't have WebSocket support)
   - Fallback: Shell out to curl for chunked transfer
   - Device ID persistence in plugin settings
   - Connection state management
   - Request forwarding to local MCP server

2. **UI Integration (`main.lua`)**
   - New submenu: "Cloud Relay"
   - Toggle: Enable/Disable relay
   - Display: Connection status
   - Display: Relay URL (copyable)
   - Action: Regenerate device ID

### Phase 3: Polish & Documentation

1. Add QR code generation for relay URL (for mobile setup)
2. Add auto-start option for relay
3. Update README with cloud relay instructions
4. Test with Claude Desktop and Mobile

## User Experience Flow

### First-Time Setup

1. User opens KOReader menu: **Settings → Network → MCP Server → Cloud Relay**
2. User taps **"Enable Cloud Relay"**
3. Plugin connects to relay, receives device ID
4. Plugin displays:
   ```
   ┌────────────────────────────────────────┐
   │         Cloud Relay Connected          │
   ├────────────────────────────────────────┤
   │                                        │
   │  Your MCP URL:                         │
   │  https://mcp-relay.workers.dev/        │
   │          k7x9m2p4q8r1/mcp              │
   │                                        │
   │  [Copy to Clipboard]                   │
   │                                        │
   │  Add this URL to Claude Desktop        │
   │  or scan QR code on mobile.            │
   │                                        │
   └────────────────────────────────────────┘
   ```
5. User adds URL to Claude Desktop config or scans QR on mobile
6. Done! Claude can now talk to the e-reader

### Subsequent Sessions

1. If auto-start enabled: Relay connects automatically with saved device ID
2. Same URL continues to work
3. Status shown in MCP Server menu item

## Deployment

### Relay Server

```bash
# In mcp-relay-cloudflare directory
npm install
npx wrangler deploy
```

The relay will be available at: `https://mcp-relay.<your-subdomain>.workers.dev/`

For production, configure a custom domain like `mcp.koreader.dev`.

### Plugin

No deployment needed - users install the updated plugin as usual.

## Cost Estimation (Cloudflare Free Tier)

| Resource                | Free Tier Limit | Expected Usage |
| ----------------------- | --------------- | -------------- |
| Worker Requests         | 100,000/day     | ~1,000/day     |
| Durable Object Requests | 1,000,000/month | ~10,000/month  |
| Durable Object Storage  | 1 GB            | ~1 MB          |
| WebSocket Messages      | Included        | ~10,000/day    |

**Conclusion:** Free tier is more than sufficient for this use case.

## Open Questions

1. **WebSocket vs Long-Polling**: KOReader's Lua environment may not support WebSocket natively. Need to evaluate:
   - LuaSocket with manual WebSocket frame handling
   - HTTP long-polling as simpler alternative
   - Shell out to `websocat` or `curl` for streaming

2. **Connection Persistence**: E-readers have aggressive power management. Need to handle:
   - Frequent disconnections
   - Quick reconnection with same device ID
   - Grace period before marking device offline

3. **Custom Domain**: Should we set up `mcp.koreader.dev` or similar for nicer URLs?

## Timeline

- **Day 1**: Relay server implementation + basic testing
- **Day 2**: Plugin client implementation + UI
- **Day 3**: Integration testing + documentation

---

*Last updated: January 2026*
