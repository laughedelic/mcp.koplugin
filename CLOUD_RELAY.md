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

**Responsibilities:**
- Connect to cloud relay on startup (when enabled)
- Receive forwarded MCP requests
- Forward requests to local MCP server
- Send responses back through relay
- Auto-reconnect on disconnection
- Display connection status and relay URL

## Protocol Specification

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
