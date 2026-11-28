---
title: Troubleshooting
description: Fixes for common problems connecting an AI app to KOReader.
---

## The assistant says it can't reach the reader

Check the reader, in this order:

1. **Is it awake?** A sleeping reader can't answer. Wake it up.
2. **Is Wi-Fi on?** KOReader turns Wi-Fi off to save battery on many devices.
3. **Is the MCP server running?** Open the **Tools** menu. **MCP server** should be ticked and show "remote". If an [idle timeout](settings.html) is set, the server may have stopped by itself.
4. **Is a book open?** Questions about "this book" need one. Library questions work from the file browser too.

Then ask again. There is no need to reconnect the app.

## The server won't start, or stays on "connecting"

- **"Network not available"**: connect to Wi-Fi first.
- **Stuck connecting to the relay**: check the reader's date and time. If the clock is far off, the secure connection to the relay fails.
- **"The cloud relay connection stopped"**: if the message says the relay rejected the credentials, reset the device ID under **Settings → Network → MCP server**, then connect your AI app again.

## The sign-in page rejects my code

- A pairing code works once and for 10 minutes. Get a new one from **MCP server → Connect an AI app**.
- With a device ID and passcode, check both for typos. The relay locks sign-in for a while after several wrong tries; wait a few minutes.

## Adding a note hangs in Claude

When a passage already has a note, the plugin asks what to do with it. Regular Claude chats show the question. Chats inside a Claude project currently can't, so the request waits and then gives up without changing anything. Either ask in a regular chat, or tell Claude up front: "replace the existing note" or "add it below the existing note".

## The assistant can't find the passage to highlight

Highlighting works by finding the exact text in the book. Select the passage on the reader and ask to "highlight my selection", or quote enough of it to be unambiguous.

## Something else

[Open an issue]({{ site.repo }}/issues) and include your device, KOReader version, plugin version, and the AI app you use.
