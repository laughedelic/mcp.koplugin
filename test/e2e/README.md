# End-to-end tests

These tests run the plugin inside a real KOReader (the desktop Linux build, on
a virtual X display) and talk to it the way an AI app does. They cover what
the unit-level checks can't: that the plugin loads in KOReader, starts its
server when a book opens, and that the tools work against KOReader's real
document engines (crengine for EPUB, MuPDF for PDF), including writing
highlights and notes that survive a restart.

```sh
test/e2e/run.sh                                   # EPUB and PDF, local server
RELAY_DIR=../koreader-mcp-cloud-relay test/e2e/run.sh   # also through a local relay
test/e2e/run.sh --only pdf                        # one suite
test/e2e/run.sh --only epub --keep-running        # leave KOReader up to poke at it
```

Needs Linux x86_64 with `curl`, `xz`, `python3` and `Xvfb` (or a real X
display; set `DISPLAY` and you can watch). ImageMagick's `import` is used for
screenshots if it is installed. The relay suite needs `bun`. The first run
downloads KOReader into `.e2e/` (set `KOREADER_VERSION` for another release);
logs, screenshots and the books' sidecar folders end up there too.

CI runs all of it on every pull request (`.github/workflows/e2e.yml`), against
the relay branch with the same name as the pull request's branch if there is
one, otherwise the relay's `main` branch, or the branch named when started by
hand.

## What happens

1. `make_books.py` writes a small EPUB and PDF (three chapters of *Alice's
   Adventures in Wonderland*, public domain).
2. For each book, KOReader starts with a fresh home directory (`KO_HOME`) whose
   settings enable the plugin's autostart in local mode, then opens the book.
3. `e2e.py` calls the server at `http://127.0.0.1:8788/mcp` with the
   2026-07-28 (stateless) protocol and the 2025-11-25 handshake: discovery,
   tools and resources, reading, search, navigation, highlights, notes in
   markdown, appending, the overwrite question (elicitation form or text
   answer), errors, and a rejected cross-site `Origin`.
4. KOReader is quit with SIGTERM (a normal quit, through SDL) and the test
   checks the highlights and notes were written to the book's sidecar file.
5. Relay suite: the plugin starts in remote mode against the local relay with a
   preset device ID and secret, the test gets a pairing code with that secret,
   connects an app through OAuth (dynamic registration, pairing code, PKCE)
   and runs the main tool calls through the relay.

6. Offline memory suite (EPUB and PDF, `--only memory`): the plugin starts in
   remote mode with offline memory set to save nearby pages, an app pairs,
   adds a note and turns the page, and the test waits for the plugin's
   snapshot to reach the relay. Then KOReader quits and the same app asks
   again: the answers must come from the saved copy, with the page text the
   reader returned while it was running. Skipped when the relay has no
   offline memory.

## What this can't test

- Kindle-specific code: the firewall (`iptables`) rules, power management and
  suspend, real WiFi on and off, e-ink refresh, the touch UI.
- TLS from the device: the local relay is plain HTTP, so LuaSec, the CA bundle
  and certificate checks are not exercised here.
- The public relay on Cloudflare and real AI apps (Claude, ChatGPT, Gemini);
  the OAuth flow is the relay's, driven by a script.
- Menus and dialogs: tests talk to the plugin over MCP only. Anything that
  needs a tap (for example a confirmation dialog) would block.
