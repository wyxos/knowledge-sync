# Knowledge Sync

Synchronize the private root bootstrap from a Knowledge MCP server into Codex's global `AGENTS.md`. Existing personal instructions are preserved; only the marked `KNOWLEDGE-MCP` block is managed.

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

When no explicit target is supplied, the installer verifies that the `codex` command or Codex home directory exists before updating the global `AGENTS.md`.

## Testing without a server

Both installers accept a local bootstrap file and custom target:

```powershell
./install.ps1 -BootstrapFile ./bootstrap.md -Target ./tmp/AGENTS.md -NoAlias
```

```bash
./install.sh --bootstrap-file ./bootstrap.md --target ./tmp/AGENTS.md --no-alias
```
