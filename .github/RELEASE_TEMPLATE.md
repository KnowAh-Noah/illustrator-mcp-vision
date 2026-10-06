## Changes in __VERSION__

- Add Illustrator support alongside After Effects, contributed by Noah Lewis (@nlewis-knowah): separate tools, ports, tokens, host code and documentation.
- Preserve Illustrator path geometry on invalid requests and retain recoverable outputs if export replacement fails.
- List source footage, native timing, interpretation overrides and eligibility through `ae_query media`, with an adapter contract for tools such as sam-ui.
- Read and set effect popup labels, map mask keys through layer time, reorder masks, and address newly created shape groups.
- Improve footage reads, font resolution, layer audio control and expression diagnostics.
- Validate render settings before removing overwrite targets, clean up render queue items, and correctly write and report numbered image sequences.

Validated with 199 unit tests, 78 live After Effects integration cases and 31 live Illustrator checks, plus targeted geometry, TIFF sequence and overwrite-preservation checks.

## Which file do I download?

| You are on | Download |
|---|---|
| **macOS** | `AE-MCP-Vision-__VERSION__-macOS.dmg` |
| **Windows** | `AE-MCP-Vision-__VERSION__-Windows.exe` |

Requires **After Effects 2022 (22.0) or later**, or **Illustrator 2023 (27.0) or later**. Quit both Adobe apps before installing. Illustrator validation used 30.3.0 on macOS; earlier supported versions were not exercised in this release check.

The `.zxp` is attached for people who already manage extensions by hand. It is
unsigned and needs `PlayerDebugMode` set manually — see
[INSTALL.md](https://github.com/VolksRat71/after-effects-mcp-vision/blob/main/docs/INSTALL.md#install).

### First run

The installers are **not code-signed**, so your OS objects the first time:

- **macOS 15 and later:** try to open the installer once, then go to
  **System Settings > Privacy & Security**, click **Open Anyway**, confirm, and
  enter an **administrator password**. Right-click > Open no longer works.
- **macOS 14 and earlier:** right-click the installer > **Open**, then **Open**.
- **Windows:** at *"Windows protected your PC"*, click **More info**, then
  **Run anyway**.

### Then

1. Open After Effects or Illustrator. Each app starts its own MCP server.
2. Open **Window > Extensions > AE MCP Vision** or **Illustrator MCP Vision**, pick your client, and copy the config.

Works with Claude Code, Claude Desktop, Codex, the ChatGPT desktop app, and any
MCP client that speaks Streamable HTTP or launches stdio servers —
[setup for each](https://github.com/VolksRat71/after-effects-mcp-vision/blob/main/docs/INSTALL.md#connect-a-client).

### Verifying a download

```
shasum -a 256 -c checksums.txt
```
