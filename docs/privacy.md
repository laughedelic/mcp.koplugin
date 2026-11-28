---
title: Privacy and security
description: What the cloud relay sees and stores, how sign-in works, and how to run your own relay.
---

The short version: your books stay on your reader. When you ask about one, the parts the assistant asks for travel to your AI app, and nowhere else.
{: .lede}

## Who sees what

- **Your reader** holds the books, highlights and notes. The plugin only answers requests while the MCP server is on.
- **The relay** passes requests and answers between your AI app and your reader. It doesn't store book text, highlights or notes. It does keep what it needs to route and authorize requests: your reader's device ID, hashed sign-in secrets, and which apps you've connected.
- **Your AI app** receives whatever it asked the reader for (the current page, search results, your highlights and so on) and handles it under its own privacy policy.

In [local mode](settings.html#local-mode) there is no relay at all.

## How the relay keeps others out

- Your AI app signs in through a standard OAuth flow and gets an access token that is tied to your reader and expires after an hour.
- Secrets are generated on the reader. The relay only ever receives their hashes.
- The reader proves who it is with its own secret, so knowing your device ID isn't enough to receive your requests.
- All traffic is encrypted, and the plugin checks the relay's certificate before sending anything. If your reader's date is far off, this check fails. Set the date and time and try again.

## Starting over

To cut off every connected app at once, reset the device ID under **Settings → Network → MCP server**. The reader registers again under a new ID with new sign-in details, and you connect your apps again.

## Running your own relay

The relay is [open source]({{ site.repo | replace: "mcp.koplugin", "koreader-mcp-cloud-relay" }}) and runs on Cloudflare Workers' free tier. Deploy your own copy, then enter its address under **Settings → Network → MCP server → Relay server**. From then on, nothing passes through anyone's server but yours.

The public relay is run by the plugin's developer for as long as it stays within the free tier.

## A fair warning

This is early software from one developer, offered without guarantees. The code for both the [plugin]({{ site.repo }}) and the relay is open, and reviews are welcome.
