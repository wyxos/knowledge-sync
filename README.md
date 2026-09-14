# Knowledge Sync

Synchronize the private root bootstrap from a Knowledge MCP server for detected Codex and Cursor installations. Codex receives `AGENTS.md` under `CODEX_HOME` (default `~/.codex`). For Cursor, the installer saves a bootstrap file at `~/.cursor/rules/knowledge-mcp.mdc`; connect it through a Cursor User Rule as described below. Existing personal instructions are preserved; only the marked `KNOWLEDGE-MCP` block is managed.

The Knowledge content and access token are never stored in this public repository.

## Windows

Download, inspect, and run:

```powershell
$path = Join-Path $env:TEMP 'knowledge-sync.ps1'
irm https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.ps1 -OutFile $path
Get-Content $path
& $path
```

One-line invocation:

```powershell
irm https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.ps1 | iex
```

Specify another domain:

```powershell
& $path -Domain knowledge.example.com
```

## macOS and Linux

Download, inspect, and run:

```bash
path="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.sh -o "$path"
less "$path"
bash "$path"
rm "$path"
```

One-line invocation:

```bash
curl -fsSL https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.sh | bash
```

Specify another domain:

```bash
bash "$path" --domain knowledge.example.com
```

Or pass arguments to a piped invocation:

```bash
curl -fsSL https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.sh | bash -s -- --domain knowledge.example.com
```

The default domain is `knowledge.test`. Domains without a scheme use HTTPS. Pass an explicit `http://` URL only for an HTTP-only development server.

On first use, the installer opens the Knowledge OAuth authorization page in your browser. After approval, Windows protects the credentials with DPAPI, macOS uses Keychain, and Linux uses Secret Service when `secret-tool` is available. Linux falls back to a user-readable-only file with an explicit warning when no keyring CLI exists. Later runs reuse or refresh the OAuth session automatically.

`KNOWLEDGE_MCP_TOKEN` and the explicit token options remain available for headless automation. The Bash installer requires `curl`, `jq`, `openssl`, and `python3` for interactive OAuth.

The first successful run also installs a persistent `knowledge-sync` command in the current user's PowerShell profile, `.bashrc`, or `.zshrc`. Open a new shell and run `knowledge-sync` to refresh later. Pass `-NoAlias` or `--no-alias` to skip this setup.

When the Codex CLI is available, the installer also checks for a global MCP server named `knowledge`. It registers the server at `<domain>/mcp/knowledge` when missing, leaves an identical registration unchanged, and refuses to overwrite a same-named server with a different URL. Codex starts its OAuth flow during registration when the server requires authentication. Pass `-NoCodexMcp` or `--no-codex-mcp` to skip MCP registration.

When Cursor is detected (`agent`, `cursor-agent`, `cursor`, or the Cursor home directory), the installer registers the same Knowledge MCP URL in `~/.cursor/mcp.json`. An identical registration is left unchanged; a same-named server with a different URL is refused. Authenticate afterward in Cursor, or run `agent mcp login knowledge`. Pass `-NoCursorMcp` or `--no-cursor-mcp` to skip Cursor MCP registration.

Cursor's [documented global rules](https://cursor.com/docs/rules) are User Rules configured in Settings / Customize > Rules. Saving a file under the home `.cursor/rules` directory alone does not establish that it will load automatically. Add this User Rule once, replacing the path with the absolute path printed by the installer:

```text
At the start of each conversation, read C:/Users/YOUR_USER/.cursor/rules/knowledge-mcp.mdc and apply its Knowledge bootstrap instructions before task-specific work.
```

On macOS or Linux, use `/Users/YOUR_USER/.cursor/rules/knowledge-mcp.mdc` or `/home/YOUR_USER/.cursor/rules/knowledge-mcp.mdc`. `CURSOR_HOME` overrides the output directory for this installer; it does not configure Cursor itself. Cursor MCP registration in Bash requires Python 3. The `NoCursorMcp` option skips MCP registration only; it still refreshes the bootstrap file for a detected Cursor installation.

When no explicit target is supplied, the installer detects Codex and Cursor independently and updates each present harness. Detection looks for the CLI (`codex`, `agent`, `cursor-agent`, or `cursor`) or the harness home directory (`CODEX_HOME` / `~/.codex`, `CURSOR_HOME` / `~/.cursor`). If neither harness is found, pass `-Target` / `--target` explicitly.

## Testing without a server

Both installers accept a local bootstrap file and custom target:

```powershell
./install.ps1 -BootstrapFile ./bootstrap.md -Target ./tmp/AGENTS.md -NoAlias -NoCodexMcp -NoCursorMcp
```

```bash
./install.sh --bootstrap-file ./bootstrap.md --target ./tmp/AGENTS.md --no-alias --no-codex-mcp --no-cursor-mcp
```
