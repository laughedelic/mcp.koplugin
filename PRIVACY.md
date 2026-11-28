# Privacy policy

_Last updated: 2026-11-28_

This policy covers the KOReader MCP plugin and the public cloud relay at `https://mcp-relay.laughedelic.workers.dev`, which is run by the plugin's maintainer ([laughedelic](https://github.com/laughedelic)) on Cloudflare Workers. It applies when you connect an AI app (such as Claude or Gemini) to KOReader through that relay. In local network mode, nothing goes through the relay and this policy doesn't apply beyond the plugin itself.

## What the plugin does

The plugin runs on your e-reader. It answers requests from the AI apps you connect: it reads the book you have open (text, metadata, table of contents, your highlights and notes), searches it, turns pages, and adds highlights or notes when you ask. It only acts on requests from apps you have paired, and only while the MCP server is running.

## What passes through the relay

Requests from your AI app and your e-reader's answers pass through the relay. These can contain book text, metadata, your highlights and notes, and whatever the AI app sends in its requests. The relay forwards them and **does not store them**. They exist in the relay's memory only while a request is in flight (at most about 30 seconds).

## What the relay stores

| Data | Why | How long |
| --- | --- | --- |
| Device ID (made from your device type plus random characters), device name ("KOReader" unless you change it), plugin version, first and last connection times | To route requests to your e-reader | Until you ask for it to be deleted |
| SHA-256 hashes of your device secret and (for older plugins) your passcode | To authenticate your e-reader | Until you ask for it to be deleted |
| SHA-256 hash of a pairing code and the device it belongs to | To pair an AI app | Until it is used, replaced, or 10 minutes pass |
| AI app registrations (app name and callback URLs, as the app sends them) and OAuth grants and tokens for your device | So connected apps can reach your e-reader | Grants until you disconnect the app from **Connected apps** on the reader; access tokens expire after 1 hour |
| IP address of a failed pairing attempt, with a counter | To limit guessing of pairing codes | 10 minutes |

## Logs

The relay writes one log line when a device registers (device ID, plugin version, whether a device secret is set, the plugin's User-Agent) and one when an AI app is paired (device ID, app name, sign-in method). Errors are logged too. Logs never contain book content, notes, tokens, secrets, or codes. They are kept by Cloudflare Workers Logs for its standard retention period (a few days).

## Who else processes data

The relay runs on [Cloudflare Workers](https://www.cloudflare.com/privacypolicy/), which processes the traffic and stores the data above. The AI app you connect receives the book content it asks for and handles it under its own privacy policy. Nothing is sold, shared for advertising, or used to train models by this project.

## Your choices

- **Disconnect an app**: on the reader, MCP server → Connected apps, then tap the app.
- **Start over**: reset the device ID in the MCP server settings. The reader registers under a new ID.
- **Delete your data**: open an issue at [github.com/laughedelic/mcp.koplugin/issues](https://github.com/laughedelic/mcp.koplugin/issues) with your device ID (or ask for a private contact there), and the stored records for that device will be deleted.
- **Run your own relay**: the relay is open source ([koreader-mcp-cloud-relay](https://github.com/laughedelic/koreader-mcp-cloud-relay)); set its URL in the plugin settings.

## Changes

Changes to this policy are made in this file, and its history is public in the repository.
