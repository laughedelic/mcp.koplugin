local _ = require("gettext")
return {
    -- Deprecated in KOReader 2026.03 (the loader takes the name from the
    -- folder), but older loaders still need it to re-enable a disabled plugin
    name = "mcp",
    fullname = _("MCP Server"),
    description = _("Model Context Protocol server for AI-powered book interaction"),
    version = "0.8.1",
}
