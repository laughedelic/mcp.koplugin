#!/usr/bin/env python3
"""End-to-end test: run the plugin inside a real KOReader and call it over MCP.

Starts a headless KOReader (desktop Linux build, on a virtual X display) with
the plugin installed and set to start its local MCP server when a book opens,
then talks to http://127.0.0.1:8788/mcp the way an MCP client would. Each test
book gets a fresh KOReader home directory, so runs don't affect each other.

Usage: e2e.py --koreader DIR --plugin DIR --work DIR [--only epub|pdf] [--keep-running]

run.sh downloads KOReader and calls this; see test/e2e/README.md.
"""
import argparse
import base64
import hashlib
import html
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = 8788
URL = f"http://127.0.0.1:{PORT}/mcp"
MODERN = "2026-07-28"
LEGACY = "2025-11-25"

# Never send test traffic through a proxy (CI runners and sandboxes set one)
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


# --------------------------------------------------------------------------
# Tiny MCP client
# --------------------------------------------------------------------------

class HTTPResult:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return json.loads(self.body) if self.body else None


# Where requests go: the plugin's local server, or a relay (with a token)
TARGET = {"url": URL, "token": None}


def http_post(payload, headers=None, timeout=30):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(TARGET["url"], data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if TARGET["token"]:
        req.add_header("Authorization", "Bearer " + TARGET["token"])
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with OPENER.open(req, timeout=timeout) as resp:
            return HTTPResult(resp.status, dict(resp.headers), resp.read().decode())
    except urllib.error.HTTPError as e:
        return HTTPResult(e.code, dict(e.headers), e.read().decode())


_next_id = 0


def modern(method, params=None, capabilities=None, extra_headers=None, timeout=30):
    """A 2026-07-28 (stateless) request. Returns the JSON-RPC message."""
    global _next_id
    _next_id += 1
    params = dict(params or {})
    params["_meta"] = {
        "io.modelcontextprotocol/protocolVersion": MODERN,
        "io.modelcontextprotocol/clientCapabilities": capabilities if capabilities is not None else {},
        "io.modelcontextprotocol/clientInfo": {"name": "koplugin-e2e", "version": "1"},
    }
    headers = {"MCP-Protocol-Version": MODERN, "Mcp-Method": method}
    name = params.get("name") if method in ("tools/call", "prompts/get") else params.get("uri")
    if name is not None:
        headers["Mcp-Name"] = "=?base64?" + base64.b64encode(name.encode()).decode() + "?="
    headers.update(extra_headers or {})
    res = http_post({"jsonrpc": "2.0", "id": _next_id, "method": method, "params": params}, headers, timeout)
    msg = res.json()
    if msg is None:
        raise AssertionError(f"{method}: empty response (HTTP {res.status})")
    return msg


def call_tool(name, arguments=None, **kw):
    """Call a tool; return (text, result)."""
    msg = modern("tools/call", {"name": name, "arguments": arguments or {}}, **kw)
    if "error" in msg:
        raise AssertionError(f"{name}: JSON-RPC error {msg['error']}")
    result = msg["result"]
    text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
    return text, result


# --------------------------------------------------------------------------
# KOReader process
# --------------------------------------------------------------------------

SETTINGS = """return {
    ["mcp_server_autostart"] = true,
    ["mcp_server_mode"] = "local",
    ["mcp_server_idle_timeout_minutes"] = 0,
    ["quickstart_shown_version"] = 999999999999,
    ["auto_restore_files"] = false,
}
"""


def port_open():
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", PORT)) == 0


class KOReader:
    def __init__(self, koreader_dir, plugin_dir, work, name, settings=SETTINGS):
        self.koreader_dir = Path(koreader_dir)
        self.home = work / f"home-{name}"
        self.log_path = work / f"koreader-{name}.log"
        if self.home.exists():
            shutil.rmtree(self.home)
        (self.home / "settings").mkdir(parents=True)
        (self.home / "settings.reader.lua").write_text(settings)
        # Copy, not symlink: KOReader reads the plugin directory name, and a
        # copy is what a real install looks like
        shutil.copytree(plugin_dir, self.home / "plugins" / "mcp.koplugin",
                        ignore=shutil.ignore_patterns(".git", ".github", ".e2e", "test", "scripts", "*.md"))
        self.proc = None

    def start(self, book, ready=port_open, timeout=90):
        if port_open():
            raise RuntimeError(f"port {PORT} is already in use; is another KOReader running?")
        env = dict(os.environ)
        env["KO_HOME"] = str(self.home)
        env.setdefault("EMULATE_READER_W", "758")
        env.setdefault("EMULATE_READER_H", "1024")
        env["NO_PROXY"] = "127.0.0.1,localhost"
        self.log = open(self.log_path, "w")
        self.proc = subprocess.Popen(["./reader.lua", str(book)], cwd=self.koreader_dir, env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"KOReader exited with {self.proc.returncode}; see {self.log_path}")
            if ready():
                return
            time.sleep(0.5)
        raise RuntimeError(f"MCP server did not start within {timeout}s; see {self.log_path}")

    def stop(self, timeout=30):
        """Quit like a user would (SDL turns SIGTERM into a quit event), so
        KOReader writes its settings and the book's sidecar."""
        if not self.proc or self.proc.poll() is not None:
            return
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait()
            raise RuntimeError("KOReader did not quit on SIGTERM")
        finally:
            self.log.close()
            # Anything still holding the plugin's port after KOReader quit
            # (for example a child process that inherited the socket)?
            ss = subprocess.run(["ss", "-tanpH", f"sport = :{PORT}"], capture_output=True, text=True).stdout
            ss = "\n".join(line for line in ss.splitlines() if not line.startswith("TIME-WAIT"))
            if ss.strip():
                print("   note: sockets on the MCP port after quitting:\n" +
                      "\n".join("     " + line for line in ss.splitlines()))
                ps = subprocess.run(["ps", "-o", "pid,ppid,pgid,stat,args", "-g", str(self.proc.pid)],
                                    capture_output=True, text=True).stdout
                print("   processes left in KOReader's group:\n" +
                      "\n".join("     " + line for line in ps.splitlines()))


def screenshot(path):
    if shutil.which("import") and os.environ.get("DISPLAY"):
        subprocess.run(["import", "-window", "root", str(path)], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --------------------------------------------------------------------------
# Test cases
# --------------------------------------------------------------------------

RABBIT = "a White Rabbit with pink eyes"
NOTE = "The **White Rabbit** appears."
NOTE2 = "Second thought."


def contains(haystack, needle, what):
    if needle not in haystack:
        raise AssertionError(f"{what}: expected {needle!r} in:\n{haystack[:2000]}")


def t_discover(ctx):
    r = modern("server/discover")["result"]
    assert MODERN in r["supportedVersions"], r
    assert r["capabilities"].get("tools") is not None, r


def t_legacy_initialize(ctx):
    res = http_post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": LEGACY, "capabilities": {}, "clientInfo": {"name": "koplugin-e2e", "version": "1"}}})
    r = res.json()["result"]
    assert r["protocolVersion"] == LEGACY, r
    note = http_post({"jsonrpc": "2.0", "method": "notifications/initialized"}, {"MCP-Protocol-Version": LEGACY})
    assert note.status == 202, note.status
    r = http_post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, {"MCP-Protocol-Version": LEGACY}).json()
    assert len(r["result"]["tools"]) >= 6, r


def t_bad_origin_rejected(ctx):
    res = http_post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                    {"MCP-Protocol-Version": LEGACY, "Origin": "https://evil.example"})
    assert res.status == 403, (res.status, res.body)


def t_tools_list(ctx):
    names = {t["name"] for t in modern("tools/list")["result"]["tools"]}
    expected = {"get_reading_context", "get_book_metadata", "read_pages", "search_book", "goto_page", "annotate"}
    assert expected <= names, names


def t_metadata(ctx):
    text, _ = call_tool("get_book_metadata")
    contains(text, "Alice", "get_book_metadata")
    contains(text, "Carroll", "get_book_metadata")


def t_resources(ctx):
    uris = [r["uri"] for r in modern("resources/list")["result"]["resources"]]
    assert uris, "no resources"
    r = modern("resources/read", {"uri": uris[0]})
    assert "result" in r and r["result"]["contents"], r


def t_reading_context(ctx):
    text, _ = call_tool("get_reading_context")
    contains(text, "Alice", "get_reading_context")


def t_read_pages(ctx):
    text, _ = call_tool("read_pages", {"pages": "1-3"})
    contains(text, "Alice was beginning", "read_pages")


def t_search(ctx):
    text, result = call_tool("search_book", {"query": "curiouser"})
    contains(text.lower(), "curiouser", "search_book")
    ctx["search"] = (text, result)


def t_goto_page(ctx):
    text, _ = call_tool("goto_page", {"page": 2})
    contains(text, "Navigated to page 2", "goto_page")
    call_tool("goto_page", {"page": 1})


def t_highlight(ctx):
    text, _ = call_tool("annotate", {"text": RABBIT})
    contains(text, "Added highlight", "annotate (highlight)")
    screenshot(ctx["work"] / f"{ctx['name']}-highlight.png")


def t_highlight_duplicate(ctx):
    text, _ = call_tool("annotate", {"text": RABBIT})
    contains(text, "already exists", "annotate (duplicate)")


def t_add_note(ctx):
    text, _ = call_tool("annotate", {"text": RABBIT, "note": NOTE, "note_format": "markdown"})
    contains(text, "Added note to existing highlight", "annotate (note on existing)")


def t_append_note(ctx):
    text, _ = call_tool("annotate", {"text": RABBIT, "note": NOTE2, "if_note_exists": "append"})
    contains(text, "Appended", "annotate (append)")


def t_overwrite_needs_answer(ctx):
    # A client with form elicitation gets an input_required result instead of
    # a silent overwrite; nothing changes until it answers
    msg = modern("tools/call", {"name": "annotate", "arguments": {"text": RABBIT, "note": "Replacement"}},
                 capabilities={"elicitation": {"form": {}}})
    r = msg.get("result", {})
    assert r.get("resultType") == "input_required", msg
    # A client without elicitation gets a text answer, also without changes
    text, _ = call_tool("annotate", {"text": RABBIT, "note": "Replacement"})
    contains(text, "already has a different note", "annotate (no elicitation)")


def t_new_note(ctx):
    text, _ = call_tool("annotate", {"text": "Curiouser and curiouser", "note": "Plain note"})
    contains(text, "Added highlight with note", "annotate (new note)")


def t_positions_epub(ctx):
    _, result = call_tool("search_book", {"query": "golden key"})
    sc = result.get("structuredContent") or {}
    blob = json.dumps(sc) + json.dumps(result.get("content"))
    start = end = None
    for item in (sc.get("results") or []):
        start, end = item.get("start"), item.get("end")
        if start and end:
            break
    if not (start and end):
        raise AssertionError(f"search_book returned no start/end positions: {blob[:1500]}")
    text, _ = call_tool("annotate", {"start": start, "end": end})
    contains(text, "Added highlight", "annotate (positions)")


def t_positions_pdf(ctx):
    _, result = call_tool("annotate", {"start": "/body/DocFragment[1]", "end": "/body/DocFragment[1]"})
    assert result.get("isError"), result


def t_bad_tool_input(ctx):
    _, result = call_tool("annotate", {"text": "this text is not in the book at all"})
    assert result.get("isError"), result


def check_sidecar(book):
    """After quitting, the highlights must be in the book's sidecar file."""
    sdr = book.with_suffix(".sdr")
    files = list(sdr.glob("metadata.*.lua")) if sdr.exists() else []
    if not files:
        raise AssertionError(f"no sidecar in {sdr}")
    data = files[0].read_text()
    for needle in ("White Rabbit with pink eyes", "**White Rabbit** appears.", "Second thought.",
                   "Curiouser and curiouser", "Plain note"):
        contains(data, needle, f"sidecar {files[0].name}")
    return files[0]


COMMON = [t_discover, t_legacy_initialize, t_bad_origin_rejected, t_tools_list, t_metadata, t_resources,
          t_reading_context, t_read_pages, t_search, t_goto_page, t_highlight, t_highlight_duplicate,
          t_add_note, t_append_note, t_overwrite_needs_answer, t_new_note, t_bad_tool_input]
SUITES = {
    "epub": COMMON + [t_positions_epub],
    "pdf": COMMON + [t_positions_pdf],
}


def run_suite(name, book, args, work):
    print(f"\n== {name}: {book.name}")
    sdr = book.with_suffix(".sdr")
    if sdr.exists():
        shutil.rmtree(sdr)
    ko = KOReader(args.koreader, args.plugin, work, name)
    failures = []
    try:
        t0 = time.time()
        ko.start(book)
        print(f"   KOReader up, MCP server listening ({time.time() - t0:.1f}s)")
        ctx = {"work": work, "name": name}
        for test in SUITES[name]:
            try:
                test(ctx)
                print(f"   ok    {test.__name__[2:]}")
            except Exception as e:  # noqa: BLE001 - report every failure
                failures.append(test.__name__)
                print(f"   FAIL  {test.__name__[2:]}: {e}")
                if os.environ.get("E2E_VERBOSE"):
                    traceback.print_exc()
        if args.keep_running:
            print(f"   KOReader is still running on {URL}; press Enter to quit it")
            input()
    except Exception as e:  # noqa: BLE001
        failures.append("startup")
        print(f"   FAIL  startup: {e}")
    finally:
        try:
            ko.stop()
        except Exception as e:  # noqa: BLE001
            failures.append("quit")
            print(f"   FAIL  quit: {e}")
    if "startup" not in failures:
        try:
            f = check_sidecar(book)
            print(f"   ok    highlights saved to {f.parent.name}/{f.name}")
        except Exception as e:  # noqa: BLE001
            failures.append("sidecar")
            print(f"   FAIL  sidecar: {e}")
    if failures:
        print(f"   KOReader log: {ko.log_path}")
        print("   ---- last 40 log lines ----")
        lines = ko.log_path.read_text(errors="replace").splitlines()
        print("\n".join("   | " + line for line in lines[-40:]))
    return failures


# --------------------------------------------------------------------------
# Through a relay (a local `wrangler dev` of koreader-mcp-cloud-relay)
# --------------------------------------------------------------------------

def relay_settings(relay, device_id, secret):
    return f"""return {{
    ["mcp_server_autostart"] = true,
    ["mcp_server_mode"] = "remote",
    ["mcp_server_idle_timeout_minutes"] = 0,
    ["quickstart_shown_version"] = 999999999999,
    ["mcp_relay_url"] = "{relay}",
    ["mcp_relay_device_id"] = "{device_id}",
    ["mcp_relay_passcode"] = "246810",
    ["mcp_relay_device_secret"] = "{secret}",
    ["mcp_relay_device_name"] = "e2e reader",
}}
"""


def relay_request(relay, path, data=None, headers=None, form=False):
    """Returns (status, headers, body text). Doesn't follow redirects."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
    req = urllib.request.Request(relay + path, data=body, method="POST" if body is not None else "GET")
    if body is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded" if form else "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


def b64url(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def oauth_pair(relay, code):
    """Connect an AI app the way Claude does: dynamic client registration,
    the sign-in form with a pairing code, PKCE token exchange."""
    redirect = "http://localhost:9/callback"
    st, _, body = relay_request(relay, "/oauth/register", {
        "client_name": "koplugin e2e", "redirect_uris": [redirect], "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]})
    assert st == 201, (st, body)
    client_id = json.loads(body)["client_id"]
    verifier = b64url(os.urandom(32))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    q = urllib.parse.urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": redirect,
                                "scope": "mcp:access", "state": "s", "code_challenge": challenge,
                                "code_challenge_method": "S256"})
    st, _, page = relay_request(relay, "/authorize?" + q)
    assert st == 200, (st, page[:500])
    m = re.search(r'name="oauth_state"\s+value="([^"]+)"', page)
    assert m, "no oauth_state on the sign-in page"
    st, h, body = relay_request(relay, "/authorize", {"oauth_state": html.unescape(m.group(1)),
                                                       "pairing_code": code}, form=True)
    assert st == 302, (st, body[:500])
    auth_code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
    st, _, body = relay_request(relay, "/oauth/token", {
        "grant_type": "authorization_code", "code": auth_code, "redirect_uri": redirect,
        "client_id": client_id, "code_verifier": verifier}, form=True)
    assert st == 200, (st, body)
    return json.loads(body)["access_token"]


RELAY_TESTS = [t_discover, t_legacy_initialize, t_tools_list, t_metadata, t_reading_context, t_read_pages,
               t_search, t_goto_page, t_highlight, t_add_note, t_overwrite_needs_answer]


def run_relay_suite(relay, book, args, work):
    name = "relay"
    print(f"\n== {name}: {book.name} through {relay}")
    sdr = book.with_suffix(".sdr")
    if sdr.exists():
        shutil.rmtree(sdr)
    device_id = "e2e-" + os.urandom(4).hex()
    secret = b64url(os.urandom(32))
    device_headers = {"X-Device-Id": device_id, "Authorization": "Device " + secret}
    ko = KOReader(args.koreader, args.plugin, work, name, relay_settings(relay, device_id, secret))
    failures = []
    pairing = {}

    def registered():
        # The plugin has registered once the relay hands it a pairing code
        st, _, body = relay_request(relay, "/pairing-code", {}, device_headers)
        if st == 200:
            pairing["code"] = json.loads(body)["code"]
            return True
        return False

    try:
        t0 = time.time()
        ko.start(book, ready=registered)
        print(f"   KOReader up, registered with the relay ({time.time() - t0:.1f}s)")
        TARGET["url"] = relay + "/mcp"
        TARGET["token"] = oauth_pair(relay, pairing["code"])
        print("   ok    paired an app with a pairing code (OAuth + PKCE)")
        ctx = {"work": work, "name": name}
        for test in RELAY_TESTS:
            try:
                test(ctx)
                print(f"   ok    {test.__name__[2:]}")
            except Exception as e:  # noqa: BLE001
                failures.append(test.__name__)
                print(f"   FAIL  {test.__name__[2:]}: {e}")
                if os.environ.get("E2E_VERBOSE"):
                    traceback.print_exc()
        TARGET["token"] = None
        res = http_post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, {"MCP-Protocol-Version": LEGACY})
        if res.status == 401:
            print("   ok    no_token_rejected")
        else:
            failures.append("no_token_rejected")
            print(f"   FAIL  no_token_rejected: HTTP {res.status} {res.body[:300]}")
    except Exception as e:  # noqa: BLE001
        failures.append("startup")
        print(f"   FAIL  startup: {e}")
    finally:
        TARGET["url"], TARGET["token"] = URL, None
        try:
            ko.stop()
        except Exception as e:  # noqa: BLE001
            failures.append("quit")
            print(f"   FAIL  quit: {e}")
    if failures:
        print(f"   KOReader log: {ko.log_path}")
        lines = ko.log_path.read_text(errors="replace").splitlines()
        print("\n".join("   | " + line for line in lines[-40:]))
    return failures


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--koreader", required=True, help="directory with KOReader's reader.lua")
    p.add_argument("--plugin", required=True, help="plugin directory (the repository root)")
    p.add_argument("--work", required=True, help="scratch directory for books, homes and logs")
    p.add_argument("--only", choices=sorted(SUITES) + ["relay"])
    p.add_argument("--relay", help="also run the relay suite against this relay URL (e.g. http://127.0.0.1:8787)")
    p.add_argument("--keep-running", action="store_true", help="leave KOReader up after the tests until Enter")
    args = p.parse_args()

    work = Path(args.work).resolve()
    books = work / "books"
    subprocess.run([sys.executable, str(HERE / "make_books.py"), str(books)], check=True, stdout=subprocess.DEVNULL)

    failed = {}
    names = [args.only] if args.only else sorted(SUITES) + (["relay"] if args.relay else [])
    for name in names:
        if name == "relay":
            if not args.relay:
                p.error("--only relay needs --relay URL")
            f = run_relay_suite(args.relay.rstrip("/"), books / "alice.epub", args, work)
        else:
            f = run_suite(name, books / f"alice.{name}", args, work)
        if f:
            failed[name] = f
    print()
    if failed:
        print("FAILED: " + "; ".join(f"{k}: {', '.join(v)}" for k, v in failed.items()))
        sys.exit(1)
    print("All e2e tests passed")


if __name__ == "__main__":
    main()
