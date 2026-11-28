---
title: Settings and modes
description: The MCP server's settings in KOReader, and the difference between cloud relay and local mode.
---

## Where things are

- **Tools → MCP server** turns the server on and off. Long-press it to see connection details or to switch between remote and local mode.
- **Settings → Network → MCP server** has everything else.

Long-press any item in a KOReader menu to read its help text.

## Settings

<div class="table-scroll" markdown="1">

| Setting | What it does |
| --- | --- |
| Start server automatically | Starts the MCP server when KOReader starts. Needs Wi-Fi. |
| Idle timeout | Stops the server after this many minutes without a request. Off by default. Five seconds before stopping, the reader shows a notice; tap it to keep the server running. |
| Turn off WiFi on idle timeout | Also turns Wi-Fi off when the idle timeout stops the server. |
| Local network only / Remote (via cloud relay) | Chooses the [mode](#modes). |
| Relay server | The relay's address. Change it only if you [run your own](privacy.html#running-your-own-relay). |
| Device ID | The name your reader is registered under at the relay. Tap to reset it and get new sign-in details. |

</div>

## Modes

### Remote mode (cloud relay)

This is the default, and the mode to use with Claude, Gemini and other apps that connect from the cloud. Your reader keeps a connection open to the relay, and your AI app talks to the relay. It works from anywhere: the reader can be on your home Wi-Fi while you chat from your phone on mobile data.

See [Privacy and security](privacy.html) for what the relay does and doesn't see.

### Local mode

In local mode the reader listens on your Wi-Fi network and nothing leaves it. The address looks like `http://192.168.1.50:8788` and is shown when the server starts.

Local mode only helps if your AI app runs on a device on the same network and connects from that device. Many apps, Claude's mobile app among them, connect from their own servers and can't reach it. It has been tested with GitHub Copilot in VS Code:

```json
"koreader": {
  "type": "http",
  "url": "http://192.168.1.50:8788"
}
```

> **Only on networks you trust.** Local mode has no sign-in. Any device on the same network can send the reader requests. Web pages you visit can't: the plugin rejects requests that come from other sites.
