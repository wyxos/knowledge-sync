# Knowledge Sync

Synchronize the private root bootstrap from a Knowledge MCP server and install its bundled `knowledge-maintenance` skill for detected Codex, Claude Code, and Cursor installations. Codex receives `AGENTS.md` under `CODEX_HOME` (default `~/.codex`). Claude Code receives global `CLAUDE.md` under `CLAUDE_CONFIG_DIR` (default `~/.claude`). Cursor receives a dedicated **Knowledge MCP bootstrap** User Rule in its signed-in account, applying across projects and syncing across devices. Existing personal instructions are preserved; only the marked `KNOWLEDGE-MCP` block is managed.

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

On macOS, run an OAuth sync from a local Terminal. A non-interactive SSH session may be unable to read or update the login Keychain; when an existing entry is inaccessible, the installer stops before opening another browser sign-in. For remote sync, fetch the current bootstrap in an authenticated session, pass it with `--bootstrap-file`, and verify the managed targets. Do not treat a working copy on the remote machine as current without checking it first.

`KNOWLEDGE_MCP_TOKEN` and the explicit token options remain available for headless automation. The Bash installer requires `curl`, `jq`, `openssl`, and `python3` for interactive OAuth.

The first successful run also installs a persistent `knowledge-sync` command in the current user's PowerShell profile, `.bashrc`, or `.zshrc`. Open a new shell and run `knowledge-sync` to refresh later. Pass `-NoAlias` or `--no-alias` to skip this setup.

When the Codex CLI is available, the installer also checks for a global MCP server named `knowledge`. It registers the server at `<domain>/mcp/knowledge` when missing, leaves an identical registration unchanged, and refuses to overwrite a same-named server with a different URL. Codex starts its OAuth flow during registration when the server requires authentication. Pass `-NoCodexMcp` or `--no-codex-mcp` to skip MCP registration.

When Claude Code is detected, the installer updates its global `CLAUDE.md` and registers a user-scope HTTP MCP server named `knowledge` in `~/.claude.json`. It preserves other settings and matching registrations, and refuses a conflicting server. Authenticate the server through Claude Code's `/mcp` panel or run `claude mcp login knowledge` when the CLI is available. Restart Claude Code to reload the global instructions. Pass `-NoClaudeMcp` or `--no-claude-mcp` to skip its MCP registration. On macOS and Linux, registration requires Python 3.

When Cursor is detected (`agent`, `cursor-agent`, `cursor`, or the Cursor home directory), the installer registers the same Knowledge MCP URL in `~/.cursor/mcp.json`. An identical registration is left unchanged; a same-named server with a different URL is refused. Authenticate afterward in Cursor, or run `agent mcp login knowledge`. Pass `-NoCursorMcp` or `--no-cursor-mcp` to skip Cursor MCP registration.

### Cursor User Rule setup

Open Cursor desktop and sign in before running the installer. Python 3.8+ is required on every platform for account rule setup. The installer reads Cursor's existing sign-in from its local database in read-only mode and sends it only to Cursor's HTTPS account service. Credentials are never printed or saved by this step.

The full bootstrap is saved as an account [User Rule](https://cursor.com/help/customization/rules), so it does not depend on reading a machine-specific file path. Restart Cursor after installation to refresh its cached rules. Later runs update the same managed block without duplicating the rule or replacing personal instructions. A conflicting unmanaged title, duplicate managed rules, missing sign-in, or failed API operation stops the installer with an explicit error.

This integration uses Cursor's **internal account rule API**, verified with Cursor desktop 3.20.17. It is not a supported public API and may need maintenance when Cursor changes it. The installer verifies the saved content by reading it back; an unverified operation never triggers cleanup. If it reports an uncertain save, rerun it to inspect the existing rule before attempting another write. It does not automatically retry writes or sign you in.

On migration, the installer backs up the old managed `~/.cursor/rules/knowledge-mcp.mdc` under `~/.knowledge-sync/cursor-rule-backups` before removing its generated block. A generated-only file is retired; any personal content remains in the active local file. Account rules are also backed up before updates. Unmanaged files and other account rules are preserved. If you previously added a manual rule pointing to that local file, remove that pointer in Cursor Settings after the new account rule is verified.

`CURSOR_HOME` overrides the local MCP and legacy-file location only; it does not configure Cursor itself. `CURSOR_USER_DATA_DIR` selects Cursor's data directory when you run it with a custom `--user-data-dir`. Defaults are `%APPDATA%/Cursor` on Windows, `~/Library/Application Support/Cursor` on macOS, and `${XDG_CONFIG_HOME:-~/.config}/Cursor` on Linux. CLI-only installations without a desktop sign-in must skip account rule setup explicitly.

`-NoCursorRule` / `--no-cursor-rule` skips the account rule and its migration. `-NoCursorMcp` / `--no-cursor-mcp` skips only MCP registration. An explicit `-Target` / `--target` writes the bootstrap to that file and skips account rule changes; MCP registration remains controlled by its separate flags. Cursor MCP registration in Bash also requires Python 3.

When no explicit target is supplied, the installer detects Codex, Claude Code, and Cursor independently and updates each present harness. Claude detection looks for the `claude` CLI, `CLAUDE_CONFIG_DIR` / `~/.claude`, or its global `~/.claude.json` file. Codex detection looks for its CLI or home directory; Cursor detection also checks its desktop data directory. If none is found, pass `-Target` / `--target` explicitly.

### Bundled Knowledge maintenance skill

Every normal `knowledge-sync` run installs or updates the bundled skill alongside the bootstrap. The skill contains reusable record maintenance, linking, privacy review and synchronization procedures. It contains no personal Knowledge records, private account information or service credentials. Downloaded files and piped invocations are standalone: both installers embed the helper and skill payload, and do not fetch another repository at runtime.

| Detected local harness | Skill discovery location |
| --- | --- |
| Codex or Cursor | `~/.agents/skills/knowledge-maintenance` (one shared copy) |
| Claude Code | `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/knowledge-maintenance` |

These are native local discovery locations. [Codex](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) and [Cursor](https://cursor.com/docs/skills#skill-directories) both discover the shared user skills directory. [Claude Code](https://code.claude.com/docs/en/skills) discovers its own personal skills directory. An existing link for the entire Claude skills root can share the same directory; the installer resolves roots and writes each physical target once. `CODEX_HOME` and `CURSOR_HOME` still select bootstrap/MCP output but do not move `~/.agents/skills`. `CURSOR_HOME` does not configure Cursor's own skill discovery. The installer never changes settings, permissions, account sync preferences or policies to enable skills. Older clients or policy-restricted sessions may require an update or local administrator action; local installation does not verify a running client's catalog or support remote/cloud skill discovery. Restart the relevant client and confirm the skill is visible.

Python 3.8+ is required for managed skill setup on every platform. Missing harnesses are reported and skipped. `-NoSkills` / `--no-skills` explicitly skips skill setup; an explicit `-Target` / `--target` also skips it. MCP registration flags and Cursor rule flags remain independent. `-WhatIf` / `--dry-run` checks skill targets and prints the proposed locations without writing skill files.

At installation, `references/service.json` is generated locally from `-Domain` / `--domain`; it contains only the base and MCP URLs. No URL is hard-coded in the skill. The files use owner-only permissions on Unix and inherit the destination's existing user-profile ACLs on Windows. The public source must not contain generated service metadata or private guidance.

Each managed installation has a `.knowledge-sync.json` ownership manifest with SHA-256 checksums. An unchanged run leaves files and timestamps alone. An update verifies the current files, stages the new package, replaces the directory and reads the result back. A failed directory swap restores the previous installation. An unmanaged same-named skill, a conflicting copy in another native/legacy home, malformed ownership metadata, local edits, missing files, extra files or links inside the skill stop setup before bootstrap/MCP/profile changes. Existing content is left intact; explicitly preserve and migrate the conflicting skill or run with the skill skip option. The installer does not automatically adopt or overwrite personal copies. Keep custom procedures in a separately named skill rather than editing the managed package.

The reviewable source is `skills/knowledge-maintenance/` and `knowledge_skill.py`. After changing either, run `python tools/embed_knowledge_skill.py`; `python tools/embed_knowledge_skill.py --check` checks both embedded copies for drift. Changes belong to this repository's source release, so the persistent command receives the new skill payload the next time it downloads the updated installer.

## Testing without a server

Both installers accept a local bootstrap file and custom target:

```powershell
./install.ps1 -BootstrapFile ./bootstrap.md -Target ./tmp/AGENTS.md -NoAlias -NoCodexMcp -NoClaudeMcp -NoCursorMcp
```

```bash
./install.sh --bootstrap-file ./bootstrap.md --target ./tmp/AGENTS.md --no-alias --no-codex-mcp --no-claude-mcp --no-cursor-mcp
```

Run `python -m unittest discover -s tests -p 'test_*.py' -v` for offline account-rule, migration and managed skill tests, including downloaded/piped native installer runs. Skill tests cover install/update, idempotency, URL binding, custom harness homes, all-target conflicts, local changes, safe rollback, skip/preview semantics and embedded payload drift. Link tests run when the host supports link creation. Fixtures use isolated homes and synthetic service URLs; tests never install skills in your real home. In a restricted sandbox, select a writable task-owned `TEMP` / `TMP` / `TMPDIR` before running the suite.

Run `tests/claude.ps1` on Windows or `bash tests/claude.sh` on macOS/Linux for Claude configuration checks. Run `bash tests/keychain.sh` to check that an inaccessible macOS Keychain entry does not trigger a new OAuth prompt. Test credentials and transport are isolated from the real accounts. The account-rule helper is maintained in `cursor_user_rule.py` and embedded in both installers so downloaded and piped invocations remain standalone. After editing it, run `python tools/embed_cursor_rule.py`; CI checks that the copies match.
