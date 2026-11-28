---
title: Set up
description: Install the KOReader MCP plugin, turn on the server and connect Claude or Gemini.
---

Setup takes about five minutes: install the plugin, turn on the server, then add the reader to your AI app.
{: .lede}

You need an e-reader (or phone or tablet) running [KOReader](https://koreader.rocks), Wi-Fi, and an AI app that can connect to a remote MCP server. Claude and Gemini are the two that have been tested.

## 1. Install the plugin

### From KOReader (recommended)

If you use the [App Store plugin](https://github.com/omer-faruq/appstore.koplugin) or a similar plugin manager, search it for "MCP" and install from there. You also get updates this way.

### By hand

1. Download the [latest release]({{ site.repo }}/releases/latest) and unpack it.
2. Rename the folder to `mcp.koplugin` if it has a different name, and copy it into the `plugins` folder inside KOReader's folder on your reader.
3. Restart KOReader.

To update, replace the folder with the new version.

## 2. Turn on the MCP server

1. With a book open, tap the top of the screen to open the menu and go to the **Tools** tab.
2. Tick **MCP server**.

The reader connects to the cloud relay and shows what you need for the next step: the server address and how to sign in. You can bring this up again at any time by long-pressing **MCP server** in the Tools menu.

Unless you run your own relay, the address is:

```
https://mcp-relay.laughedelic.workers.dev/mcp
```

> **What's the relay?** Most AI apps connect from their own servers, so they can't reach a device on your home Wi-Fi directly. The relay is a small open-source service that passes requests between the two. It doesn't store your books or notes. [More about it](privacy.html).

## 3. Connect your AI app

### Claude

1. Open [**Settings → Connectors → Add custom connector**](https://claude.ai/settings/connectors?modal=add-custom-connector).
2. Give it a name, such as "KOReader", and paste the server address.
3. Claude opens the relay's sign-in page. [Sign in](#signing-in) with what your reader shows.
4. Start a new chat. The connector is in the **+** menu.

Once added, the connector works in Claude on the web, desktop and mobile.

### Gemini

1. In the Gemini app, open **Settings → Developer mode → Create new** (app).
2. Paste the server address.
3. [Sign in](#signing-in) on the relay's page with what your reader shows.
4. Start a chat and ask about the book you're reading.

### Other apps

Any app that supports remote MCP servers with OAuth sign-in should work: add the server address as a new MCP server or connector and sign in when asked. If you try one, [tell us how it went]({{ site.repo }}/issues).

Apps that can reach your home network (some desktop tools can) can also connect without the relay. See [local mode](settings.html#local-mode).

### Signing in

What the sign-in page asks for depends on your plugin version.

- **A pairing code.** Newer versions of the plugin show a 6-digit code under **MCP server → Connect an AI app**. Type it into the sign-in page. Each code works once and expires after 10 minutes, so get a fresh one for each app you connect.
- **A device ID and passcode.** Version 0.9 and older show a device ID and a permanent 6-digit passcode. Enter both on the sign-in page. You can look them up under **Settings → Network → MCP server**.

## 4. Try it

Open a book on the reader, then ask your AI app:

> What am I reading right now?

If the answer names your book and where you are in it, everything works. Continue with [Using it](using.html). If not, see [Troubleshooting](troubleshooting.html).
