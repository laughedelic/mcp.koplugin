# Privacy policy

_Last updated: 2026-11-28_

This policy covers the KOReader MCP plugin and the public cloud relay at `https://mcp-relay.laughedelic.workers.dev`, which is run by the plugin's maintainer ([laughedelic](https://github.com/laughedelic)) on Cloudflare Workers. It applies when you connect an AI app (such as Claude or Gemini) to KOReader through that relay. In local network mode, nothing goes through the relay and this policy doesn't apply beyond the plugin itself.

## What the plugin does

The plugin runs on your e-reader. It answers requests from the AI apps you connect: it reads the book you have open (text, metadata, table of contents, your highlights and notes), searches it, turns pages, and adds highlights or notes when you ask. It only answers requests while the MCP server is on. If you turn on offline memory (see below), it also keeps a saved copy on the relay up to date while the server is off. Through the relay, it only acts on requests from apps you have paired. In local network mode there is no sign-in, so any device on your network that can reach the reader can send it requests.

## What passes through the relay

Requests from your AI app and your e-reader's answers pass through the relay. These can contain book text, metadata, your highlights and notes, and whatever the AI app sends in its requests. The relay forwards them and **does not store them**. They exist in the relay's memory only while a request is in flight: an unanswered request is dropped after 30 seconds.

When your e-reader is asleep or away, the relay answers your AI app itself: it says that the reader is offline and when it was last connected. Unless you have turned on offline memory, that answer contains nothing from your books.

## What the relay stores

| Data | Why | How long |
| --- | --- | --- |
| Device ID (made from your device type plus random characters), device name ("KOReader" unless you change it), plugin version, first and last connection times | To route requests to your e-reader | Until you ask for it to be deleted |
| SHA-256 hashes of your device secret and your legacy passcode | To authenticate your e-reader | Until you ask for it to be deleted |
| SHA-256 hash of a pairing code and the device it belongs to | To pair an AI app | Until it is used or replaced; it stops working after 10 minutes and is deleted at the next cleanup |
| AI app registrations (app name and callback URLs, as the app sends them) and OAuth grants and tokens for your device | So connected apps can reach your e-reader | Grants until you disconnect the app from **Connected apps** on the reader; access tokens expire after 1 hour |
| The plugin's list of tools and prompts (their names and descriptions, nothing from your books) and the time the relay last heard from your e-reader | To tell a connected AI app that the reader is offline, and since when | Until you ask for it to be deleted |
| A public encryption key for each connected AI app | To encrypt the offline memory copy for that app | Until you disconnect the app, or 90 days after the app last called |
| The offline memory copy, encrypted (**only if you turn offline memory on**) | So connected AI apps can answer while your e-reader is offline | See below |
| IP address of a failed pairing attempt, with a counter | To limit guessing of pairing codes | Counts for 10 minutes; deleted at the next cleanup after that |

## Offline memory (optional, off by default)

If you turn on **Offline memory** in the MCP server settings, your e-reader sends the relay a copy of what you are reading, so connected AI apps can still answer questions while the e-reader is asleep or away. Nothing is sent for this purpose unless you turn it on, and the reader asks you to confirm first.

The copy holds:

- the book's title, author, language, series, keywords and description, and its number of pages (never the file name or path)
- the page and chapter you are on
- the table of contents
- your highlights and notes in that book
- if you choose **Also save the pages around my place**: the text of the page you are on, 2 pages before it and 10 after

There is one copy per e-reader, for the book you had open last. While you read with WiFi on, the e-reader replaces it about once a minute, also while the MCP server is off. It never turns WiFi on to do this. The copy can be at most 256 KB.

How it is protected:

- The relay encrypts the copy as soon as it arrives. The key that opens it exists only inside the sign-in of each AI app you connected, which the relay can use only while that app presents its valid access token. A copy of the relay's storage alone can't be read.
- The copy is readable inside the relay's program at two moments: when it arrives from your e-reader, before it is encrypted, and when one of your connected AI apps asks about your book while the e-reader is offline. It is not logged and not used for anything else.
- Only your e-reader (with its device secret) can save, replace or delete the copy. Only AI apps you connected can get answers from it, and those answers say that they come from a saved copy.

When it is deleted:

- when you set offline memory to **Off** (right away, or as soon as the e-reader is next online)
- when you reset the device ID or change the relay URL (the same way)
- 30 days after its last update (you can choose 1 or 7 days instead)
- when you disconnect the last AI app that could open it
- whenever a newer copy replaces it

## Logs

The relay writes one log line when a device registers (device ID, plugin version, whether a device secret is set, the plugin's User-Agent) and one when an AI app is paired (device ID, app name, sign-in method). Errors are logged too. Logs never contain book content, notes, tokens, secrets, or codes. They are kept by Cloudflare Workers Logs for its standard retention period (a few days).

## Who else processes data

The relay runs on [Cloudflare Workers](https://www.cloudflare.com/privacypolicy/), which processes the traffic and stores the data above. The AI app you connect receives the book content it asks for and handles it under its own privacy policy. Nothing is sold, shared for advertising, or used to train models by this project.

## Your choices

- **Disconnect an app**: on the reader, MCP server → Connected apps, then tap the app.
- **Turn off offline memory**: on the reader, MCP server → Offline memory → Off. This deletes the saved copy.
- **Start over**: reset the device ID in the MCP server settings. The reader registers under a new ID.
- **Delete your data**: open an issue at [github.com/laughedelic/mcp.koplugin/issues](https://github.com/laughedelic/mcp.koplugin/issues) with your device ID (or ask for a private contact there), and the stored records for that device will be deleted.
- **Run your own relay**: the relay is open source ([koreader-mcp-cloud-relay](https://github.com/laughedelic/koreader-mcp-cloud-relay)); set its URL in the plugin settings.

## Changes

Changes to this policy are made in this file, and its history is public in the repository.
