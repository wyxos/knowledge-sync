[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Domain = 'knowledge.test',
    [string] $Token = $env:KNOWLEDGE_MCP_TOKEN,
    [string] $Target,
    [string] $BootstrapFile,
    [switch] $NoAlias,
    [switch] $NoCodexMcp,
    [switch] $NoClaudeMcp,
    [switch] $NoCursorMcp,
    [switch] $NoCursorRule
)

$ErrorActionPreference = 'Stop'
$StartMarker = '<!-- KNOWLEDGE-MCP:BEGIN -->'
$EndMarker = '<!-- KNOWLEDGE-MCP:END -->'

function Resolve-KnowledgeBaseUrl([string] $Value) {
    $Value = $Value.Trim().TrimEnd('/')
    if ($Value -match '^https?://') { return $Value }
    return "https://$Value"
}

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return Join-Path $HOME '.codex'
}

function Get-CursorHome {
    if ($env:CURSOR_HOME) { return $env:CURSOR_HOME }
    return Join-Path $HOME '.cursor'
}

function Get-ClaudeHome {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return Join-Path $HOME '.claude'
}

function Get-ClaudeConfigPath {
    if ($env:CLAUDE_CONFIG_DIR) { return Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json' }
    return Join-Path $HOME '.claude.json'
}

function Test-CodexHarness {
    return [bool]((Get-Command codex -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath (Get-CodexHome)))
}

function Test-ClaudeHarness {
    return [bool]((Get-Command claude -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Get-ClaudeHome)) -or
        (Test-Path -LiteralPath (Get-ClaudeConfigPath)))
}

function Test-CursorHarness {
    if (Get-Command agent -ErrorAction SilentlyContinue) { return $true }
    if (Get-Command cursor-agent -ErrorAction SilentlyContinue) { return $true }
    if (Get-Command cursor -ErrorAction SilentlyContinue) { return $true }
    if ($env:CURSOR_USER_DATA_DIR -and (Test-Path -LiteralPath $env:CURSOR_USER_DATA_DIR)) { return $true }
    $userData = if ($IsMacOS) { Join-Path $HOME 'Library/Application Support/Cursor' }
        elseif ($IsLinux) { Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'Cursor' }
        else { Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Cursor' }
    if (Test-Path -LiteralPath $userData) { return $true }
    return [bool](Test-Path -LiteralPath (Get-CursorHome))
}

function Get-KnowledgeTargets {
    if ($Target) { return @($Target) }

    $paths = [System.Collections.Generic.List[string]]::new()
    if (Test-CodexHarness) { $paths.Add((Join-Path (Get-CodexHome) 'AGENTS.md')) }
    if (Test-ClaudeHarness) { $paths.Add((Join-Path (Get-ClaudeHome) 'CLAUDE.md')) }
    if ($paths.Count -eq 0 -and -not (Test-CursorHarness)) {
        throw 'No Codex, Claude, or Cursor installation was detected. Install one, set its configuration directory, or pass -Target explicitly.'
    }
    return @($paths)
}

function Install-CursorUserRule([string] $Bootstrap) {
    if (-not (Test-CursorHarness)) { return }
    if ($WhatIfPreference) {
        Write-Host 'What if: Install/update the Knowledge Cursor account User Rule and retire its old local block after verification.'
        return
    }
    if ($null -ne $PSCmdlet -and -not $PSCmdlet.ShouldProcess('Cursor account User Rules', 'Synchronize Knowledge bootstrap')) { return }
    $python = $null
    foreach ($candidate in @('python3', 'python', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            & $command.Source -c 'import sys, sqlite3; assert sys.version_info >= (3, 8)' 2>$null
            if ($LASTEXITCODE -eq 0) { $python = $command.Source; break }
        }
    }
    if (-not $python) { throw 'Python 3.8+ is required to install the Cursor User Rule. Install Python, or use -NoCursorRule to skip it explicitly.' }
    # Generated from cursor_user_rule.py by tools/embed_cursor_rule.py.
    $helper = @'
# CURSOR-USER-RULE:BEGIN
"""Cursor account User Rule installer, embedded in both standalone installers.

Uses the same internal Connect API as Cursor desktop (verified with 3.20.17).
Reads its existing sign-in from SQLite without changing Cursor's database.
Run tools/embed_cursor_rule.py after editing this file.
"""

import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

START = "<!-- KNOWLEDGE-MCP:BEGIN -->"
END = "<!-- KNOWLEDGE-MCP:END -->"
TITLE = "Knowledge MCP bootstrap"
FRONTMATTER = "---\ndescription: Knowledge MCP bootstrap\nalwaysApply: true\n---"
API = "https://api2.cursor.sh/aiserver.v1.AiService/"


def managed_span(text):
    if START not in text and END not in text:
        return None
    if text.count(START) != 1 or text.count(END) != 1:
        raise RuntimeError("Knowledge rule contains invalid managed markers; left unchanged.")
    start, end = text.index(START), text.index(END)
    if end < start:
        raise RuntimeError("Knowledge rule contains reversed managed markers; left unchanged.")
    return start, end + len(END)


def make_block(bootstrap):
    if not bootstrap.strip() or START in bootstrap or END in bootstrap:
        raise RuntimeError("Bootstrap must be nonempty and contain no reserved markers.")
    return (START + "\n<!-- Generated from Knowledge MCP. Changes inside this block will be replaced. -->\n\n"
            + bootstrap.strip() + "\n" + END)


def cursor_data_dir():
    override = os.environ.get("CURSOR_USER_DATA_DIR")
    if override:
        return Path(override).expanduser()
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "Cursor"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/Cursor"
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "Cursor"


def access_token():
    database = cursor_data_dir() / "User/globalStorage/state.vscdb"
    if not database.is_file():
        raise RuntimeError("Open Cursor desktop and sign in, then rerun knowledge-sync. "
                           "For a custom --user-data-dir, set CURSOR_USER_DATA_DIR. "
                           "To skip the account rule, use -NoCursorRule / --no-cursor-rule.")
    try:
        connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            row = connection.execute("SELECT value FROM ItemTable WHERE key=?",
                                     ("cursorAuth/accessToken",)).fetchone()
        finally:
            connection.close()
    except sqlite3.Error:
        raise RuntimeError("Could not read Cursor's sign-in. Open Cursor and retry.") from None
    if not row or not isinstance(row[0], str) or not row[0].strip():
        raise RuntimeError("Sign in to Cursor desktop, then rerun knowledge-sync.")
    return row[0]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class CursorAPI:
    def __init__(self, token):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def __call__(self, method, payload):
        if method not in ("KnowledgeBaseList", "KnowledgeBaseAdd", "KnowledgeBaseUpdate"):
            raise RuntimeError("Unsupported Cursor operation.")
        request = urllib.request.Request(API + method, data=json.dumps(payload).encode("utf-8"),
                                         headers={"Authorization": "Bearer " + self.token,
                                                  "Content-Type": "application/json",
                                                  "Connect-Protocol-Version": "1"})
        try:
            with self.opener.open(request, timeout=30) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise RuntimeError("Cursor rejected its saved sign-in. Open Cursor, sign in again, and rerun.") from None
            raise RuntimeError(f"Cursor User Rule API returned HTTP {error.code}; setup is incomplete. "
                               "This internal API may have changed. Rerun to check before retrying a write.") from None
        except (urllib.error.URLError, TimeoutError, ValueError, OSError):
            raise RuntimeError("Cursor User Rule request failed; setup could not be verified. "
                               "Rerun to check the existing rule before retrying a write.") from None
        if not isinstance(result, dict) or result.get("success") is not True:
            raise RuntimeError("Cursor did not confirm the User Rule operation; setup is incomplete.")
        return result


def list_rules(api):
    result = api("KnowledgeBaseList", {"limit": 100})
    rules = result.get("allResults", [])
    if not isinstance(rules, list) or len(rules) >= 100:
        raise RuntimeError("Cursor returned an invalid or possibly incomplete rule list; refusing to write.")
    for rule in rules:
        if (not isinstance(rule, dict) or not isinstance(rule.get("id"), str) or not rule["id"]
                or not isinstance(rule.get("knowledge", ""), str)
                or not isinstance(rule.get("title", ""), str)):
            raise RuntimeError("Cursor returned an invalid rule; refusing to write.")
    return rules


def backup(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        os.chmod(path, 0o600)
        output.write(text)


def retire_local_rule(path, backup_dir):
    if not path.is_file():
        return
    existing = path.read_text(encoding="utf-8-sig")
    span = managed_span(existing)
    if span is None:
        return
    remaining = existing[:span[0]] + existing[span[1]:]
    # Keep personal content active. Only retire a file containing our block and
    # our exact generated frontmatter, or our block alone.
    generated_only = remaining.strip() in ("", FRONTMATTER)
    saved = backup_dir / ("local-rule-" + uuid.uuid4().hex + ".mdc")
    backup(saved, existing)
    if generated_only:
        path.unlink()
    else:
        fd, temporary = tempfile.mkstemp(prefix=".knowledge-rule-", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(remaining)
            os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(f"Retired the local Knowledge block; personal content preserved. Backup: [{saved}]")


def sync_rule(bootstrap, api, legacy_path, backup_dir):
    block = make_block(bootstrap)
    rules = list_rules(api)
    matches = [r for r in rules if START in r.get("knowledge", "") or END in r.get("knowledge", "")]
    if len(matches) > 1:
        raise RuntimeError("Multiple managed Cursor rules found; resolve duplicates in Cursor Settings before retrying.")
    if not matches and any(r.get("title") == TITLE for r in rules):
        raise RuntimeError("An unmanaged Cursor rule has the Knowledge title; refusing to overwrite it.")
    # Validate the old file before any account write or cleanup.
    if legacy_path.is_file():
        managed_span(legacy_path.read_text(encoding="utf-8-sig"))
    if matches:
        rule = matches[0]
        if rule.get("isGenerated"):
            raise RuntimeError("The managed block belongs to a generated memory; refusing to change it.")
        existing = rule["knowledge"]
        start, end = managed_span(existing)
        desired = existing[:start] + block + existing[end:]
        rule_id = rule["id"]
        if desired != existing:
            backup(backup_dir / ("account-rule-" + uuid.uuid4().hex + ".json"),
                   json.dumps(rule, ensure_ascii=False, indent=2) + "\n")
            api("KnowledgeBaseUpdate", {"id": rule_id, "title": rule.get("title", TITLE), "knowledge": desired})
    else:
        desired = block + "\n"
        result = api("KnowledgeBaseAdd", {"title": TITLE, "knowledge": desired})
        rule_id = result.get("id")
        if not isinstance(rule_id, str) or not rule_id:
            raise RuntimeError("Cursor did not return a rule ID. Rerun to check whether it was saved.")
    # A read-back must confirm exactly one managed rule before retiring the old
    # local block. No automatic retry of potentially successful writes.
    verified = list_rules(api)
    matches = [r for r in verified if START in r.get("knowledge", "") or END in r.get("knowledge", "")]
    if len(matches) != 1 or matches[0]["id"] != rule_id or matches[0].get("knowledge") != desired:
        raise RuntimeError("Cursor User Rule read-back did not match. Local rule retained; rerun to check.")
    retire_local_rule(legacy_path, backup_dir)
    print("Knowledge bootstrap verified in Cursor's account User Rules. Restart Cursor to refresh its cached rules.")


def main():
    options = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
    bootstrap = options["bootstrap"]
    make_block(bootstrap)
    if options.get("dry_run"):
        print("Would install/update the Knowledge Cursor account User Rule and retire its old local block after verification.")
        return
    legacy = Path(options["cursor_home"]).expanduser() / "rules/knowledge-mcp.mdc"
    sync_rule(bootstrap, CursorAPI(access_token()), legacy,
              Path.home() / ".knowledge-sync/cursor-rule-backups")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print("Cursor User Rule setup failed: " + str(error), file=sys.stderr)
        sys.exit(1)
# CURSOR-USER-RULE:END
'@
    $payload = @{ bootstrap = $Bootstrap; cursor_home = Get-CursorHome } | ConvertTo-Json -Compress
    $previousEncoding = $OutputEncoding
    try {
        $OutputEncoding = [Text.UTF8Encoding]::new($false)
        $payload | & $python -c $helper
        if ($LASTEXITCODE -ne 0) { throw 'Cursor User Rule setup is incomplete. See the error above, then rerun knowledge-sync.' }
    } finally { $OutputEncoding = $previousEncoding }
}

function Save-TextFile([string] $Path, [string] $Content) {
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.knowledge-agents-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        Move-Item -Force -LiteralPath $temporary -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -Force -LiteralPath $temporary }
    }
}

function Install-CodexMcp([string] $McpUrl) {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        Write-Warning 'Codex CLI was not found; skipped Knowledge MCP registration.'
        return
    }

    $existingJson = & $codex.Source mcp get knowledge --json 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingJson) {
        $existing = ($existingJson -join "`n") | ConvertFrom-Json
        $existingUrl = [string] $existing.transport.url
        if ($existing.transport.type -ne 'streamable_http' -or $existingUrl.TrimEnd('/') -ne $McpUrl.TrimEnd('/')) {
            throw "Codex already has an MCP server named [knowledge] configured for [$existingUrl]. Refusing to replace it with [$McpUrl]."
        }
        Write-Host "Knowledge MCP is already registered in Codex at [$existingUrl]."
        return
    }

    if ($WhatIfPreference) {
        Write-Host "What if: Register Knowledge MCP in Codex at [$McpUrl]."
        return
    }

    & $codex.Source mcp add knowledge --url $McpUrl
    if ($LASTEXITCODE -ne 0) { throw 'Codex could not register the Knowledge MCP server.' }
    Write-Host 'Knowledge MCP registered in Codex. Codex completes OAuth authentication during registration when the server requires it.'
}

function Install-ClaudeMcp([string] $McpUrl) {
    if (-not (Test-ClaudeHarness)) { return }

    $configPath = Get-ClaudeConfigPath
    $config = $null
    if (Test-Path -LiteralPath $configPath) {
        $raw = Get-Content -Raw -LiteralPath $configPath
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            if (-not $raw.TrimStart().StartsWith('{')) { throw "Claude config at [$configPath] is not a JSON object." }
            try { $config = $raw | ConvertFrom-Json }
            catch { throw "Claude config at [$configPath] is not valid JSON." }
        }
    }
    if ($null -eq $config) { $config = [pscustomobject]@{} }
    if ($config -isnot [pscustomobject]) { throw "Claude config at [$configPath] is not a JSON object." }
    if (-not $config.PSObject.Properties['mcpServers'] -or $null -eq $config.mcpServers) {
        $config | Add-Member -Force -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }
    $servers = $config.mcpServers
    if ($servers -isnot [pscustomobject]) { throw "Claude mcpServers in [$configPath] is not a JSON object." }

    if ($servers.PSObject.Properties['knowledge']) {
        $existing = $servers.knowledge
        $existingUrl = if ($existing -is [pscustomobject]) { [string] $existing.url } else { '' }
        if ($existing -isnot [pscustomobject] -or
            $existing.type -cnotin @('http', 'streamable-http') -or
            $existing.command -or $existingUrl.TrimEnd('/') -cne $McpUrl.TrimEnd('/')) {
            throw "Claude already has an MCP server named [knowledge] configured for [$existingUrl]. Refusing to replace it with [$McpUrl]."
        }
        Write-Host "Knowledge MCP is already registered in Claude at [$existingUrl]."
        return
    }

    if ($WhatIfPreference) {
        Write-Host "What if: Register Knowledge MCP in Claude at [$McpUrl]."
        return
    }
    $servers | Add-Member -NotePropertyName knowledge -NotePropertyValue ([pscustomobject]@{ type = 'http'; url = $McpUrl })
    if ($null -eq $PSCmdlet -or $PSCmdlet.ShouldProcess($configPath, 'Register Knowledge MCP in Claude')) {
        Save-TextFile $configPath (($config | ConvertTo-Json -Depth 100 -WarningAction Stop) + "`n")
        Write-Host 'Knowledge MCP registered in Claude. Run: claude mcp login knowledge'
    }
}

function Install-CursorMcp([string] $McpUrl) {
    if (-not (Test-CursorHarness)) { return }

    $configPath = Join-Path (Get-CursorHome) 'mcp.json'
    $config = $null
    if (Test-Path -LiteralPath $configPath) {
        $raw = Get-Content -Raw -LiteralPath $configPath
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            if (-not $raw.TrimStart().StartsWith('{')) {
                throw "Cursor MCP config at [$configPath] is not a JSON object."
            }
            try { $config = $raw | ConvertFrom-Json }
            catch { throw "Cursor MCP config at [$configPath] is not valid JSON." }
        }
    }
    if ($null -eq $config) { $config = [pscustomobject]@{ mcpServers = [pscustomobject]@{} } }
    if ($config -isnot [pscustomobject]) {
        throw "Cursor MCP config at [$configPath] is not a JSON object."
    }
    if (-not $config.PSObject.Properties['mcpServers'] -or $null -eq $config.mcpServers) {
        $config | Add-Member -Force -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }

    $servers = $config.mcpServers
    if ($servers -isnot [pscustomobject]) {
        throw "Cursor MCP mcpServers in [$configPath] is not a JSON object."
    }
    $existing = $null
    if ($servers -is [System.Collections.IDictionary]) {
        if ($servers.Contains('knowledge')) { $existing = $servers['knowledge'] }
    } elseif ($servers.PSObject.Properties['knowledge']) {
        $existing = $servers.knowledge
    }

    if ($null -ne $existing) {
        $existingUrl = [string] $existing.url
        if ($existing -isnot [pscustomobject] -or $existing.command -or $existingUrl.TrimEnd('/') -cne $McpUrl.TrimEnd('/')) {
            throw "Cursor already has an MCP server named [knowledge] configured for [$existingUrl]. Refusing to replace it with [$McpUrl]."
        }
        Write-Host "Knowledge MCP is already registered in Cursor at [$existingUrl]."
        return
    }

    if ($WhatIfPreference) {
        Write-Host "What if: Register Knowledge MCP in Cursor at [$McpUrl]."
        return
    }

    $entry = [pscustomobject]@{ url = $McpUrl }
    if ($servers -is [System.Collections.IDictionary]) {
        $servers['knowledge'] = $entry
    } else {
        $servers | Add-Member -NotePropertyName knowledge -NotePropertyValue $entry
    }

    if ($null -eq $PSCmdlet -or $PSCmdlet.ShouldProcess($configPath, 'Register Knowledge MCP in Cursor')) {
        Save-TextFile $configPath (($config | ConvertTo-Json -Depth 100 -WarningAction Stop) + "`n")
        Write-Host 'Knowledge MCP registered in Cursor. Authenticate it in Cursor or run: agent mcp login knowledge'
    }
}

function ConvertTo-Base64Url([byte[]] $Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-OAuthStorePath([string] $BaseUrl) {
    $key = (ConvertTo-Base64Url ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($BaseUrl)))).Substring(0, 16)
    return Join-Path (Join-Path $HOME '.knowledge-sync') "oauth-$key.dat"
}

function Save-OAuthCredentials([string] $Path, [object] $Credentials) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory -WhatIf:$false | Out-Null
    $plain = [Text.Encoding]::UTF8.GetBytes(($Credentials | ConvertTo-Json -Depth 10 -Compress))
    $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllText($Path, [Convert]::ToBase64String($protected), [Text.UTF8Encoding]::new($false))
}

function Read-OAuthCredentials([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $protected = [Convert]::FromBase64String((Get-Content -Raw -LiteralPath $Path))
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    } catch {
        Write-Warning "Stored OAuth credentials could not be read and will be replaced."
        return $null
    }
}

function Invoke-OAuthTokenRequest([string] $Endpoint, [hashtable] $Body) {
    return Invoke-RestMethod -Uri $Endpoint -Method Post -ContentType 'application/x-www-form-urlencoded' -Body $Body
}

function Save-TokenResponse([string] $StorePath, [object] $Response, [string] $ClientId, [string] $ClientSecret, [string] $TokenEndpoint, [string] $Resource) {
    $credentials = [ordered]@{
        access_token = [string] $Response.access_token
        refresh_token = [string] $Response.refresh_token
        expires_at = [DateTimeOffset]::UtcNow.AddSeconds([int] $Response.expires_in).ToUnixTimeSeconds()
        client_id = $ClientId
        client_secret = $ClientSecret
        token_endpoint = $TokenEndpoint
        resource = $Resource
    }
    Save-OAuthCredentials $StorePath $credentials
    return $credentials
}

function Get-OAuthAccessToken([string] $BaseUrl) {
    $storePath = Get-OAuthStorePath $BaseUrl
    $stored = Read-OAuthCredentials $storePath
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($stored -and $stored.access_token -and [long] $stored.expires_at -gt ($now + 60)) {
        return [string] $stored.access_token
    }
    if ($stored -and $stored.refresh_token) {
        try {
            $body = @{
                grant_type = 'refresh_token'; refresh_token = [string] $stored.refresh_token
                client_id = [string] $stored.client_id; resource = [string] $stored.resource
            }
            if ($stored.client_secret) { $body.client_secret = [string] $stored.client_secret }
            $refreshed = Invoke-OAuthTokenRequest ([string] $stored.token_endpoint) $body
            return [string] (Save-TokenResponse $storePath $refreshed ([string] $stored.client_id) ([string] $stored.client_secret) ([string] $stored.token_endpoint) ([string] $stored.resource)).access_token
        } catch {
            Write-Warning 'The saved OAuth session could not be refreshed; signing in again.'
        }
    }

    $resourceMetadata = Invoke-RestMethod -Uri "$BaseUrl/.well-known/oauth-protected-resource/mcp/knowledge"
    $resource = [string] $resourceMetadata.resource
    $issuer = [string] @($resourceMetadata.authorization_servers)[0]
    $metadata = Invoke-RestMethod -Uri "$($issuer.TrimEnd('/'))/.well-known/oauth-authorization-server"

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    $redirectUri = "http://127.0.0.1:$port/callback"
    $registration = Invoke-RestMethod -Uri $metadata.registration_endpoint -Method Post -ContentType 'application/json' -Body (@{
        client_name = 'Knowledge Sync'; redirect_uris = @($redirectUri)
        grant_types = @('authorization_code', 'refresh_token'); response_types = @('code')
        token_endpoint_auth_method = 'client_secret_post'; application_type = 'native'; scope = 'mcp:use'
    } | ConvertTo-Json -Depth 5 -Compress)

    $verifier = ConvertTo-Base64Url ([Security.Cryptography.RandomNumberGenerator]::GetBytes(64))
    $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state = ConvertTo-Base64Url ([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $query = @{
        response_type = 'code'; client_id = [string] $registration.client_id; redirect_uri = $redirectUri
        state = $state; code_challenge = $challenge; code_challenge_method = 'S256'; scope = 'mcp:use'; resource = $resource
    }.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string] $_.Value))" }
    $authorizeUrl = [string] $metadata.authorization_endpoint + '?' + ($query -join '&')
    Write-Host 'Opening the browser to authenticate Knowledge Sync...'
    Start-Process $authorizeUrl -WhatIf:$false

    try {
        $accept = $listener.AcceptTcpClientAsync()
        if (-not $accept.Wait([TimeSpan]::FromMinutes(5))) { throw 'OAuth authentication timed out.' }
        $connection = $accept.Result
        $reader = [IO.StreamReader]::new($connection.GetStream(), [Text.Encoding]::ASCII, $false, 1024, $true)
        $requestLine = $reader.ReadLine()
        $requestTarget = ($requestLine -split ' ')[1]
        $callback = [Uri] "http://127.0.0.1$requestTarget"
        $parameters = [Web.HttpUtility]::ParseQueryString($callback.Query)
        $message = if ($parameters['code']) { 'Authentication complete. You can close this window.' } else { 'Authentication failed. Return to the terminal.' }
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($message)
        $responseBytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n")
        $connection.GetStream().Write($responseBytes, 0, $responseBytes.Length)
        $connection.GetStream().Write($bodyBytes, 0, $bodyBytes.Length)
        $connection.Close()
    } finally {
        $listener.Stop()
    }
    if ($parameters['state'] -ne $state) { throw 'OAuth state did not match.' }
    if (-not $parameters['code']) { throw "OAuth authorization failed: $($parameters['error'])" }

    $tokenBody = @{
        grant_type = 'authorization_code'; code = [string] $parameters['code']; redirect_uri = $redirectUri
        code_verifier = $verifier; client_id = [string] $registration.client_id; resource = $resource
    }
    if ($registration.client_secret) { $tokenBody.client_secret = [string] $registration.client_secret }
    $tokenResponse = Invoke-OAuthTokenRequest ([string] $metadata.token_endpoint) $tokenBody
    return [string] (Save-TokenResponse $storePath $tokenResponse ([string] $registration.client_id) ([string] $registration.client_secret) ([string] $metadata.token_endpoint) $resource).access_token
}

function Read-McpJson([string] $Body, [int] $Id) {
    $candidates = @($Body -split "`r?`n" | ForEach-Object {
        if ($_ -match '^data:\s*(.+)$') { $Matches[1] }
    })
    if ($Body.TrimStart().StartsWith('{')) { $candidates += $Body.Trim() }

    foreach ($candidate in $candidates) {
        try {
            $value = $candidate | ConvertFrom-Json
            if ($value.id -eq $Id) { return $value }
        } catch { }
    }

    throw "Knowledge MCP did not return a JSON-RPC response for request $Id."
}

function Invoke-McpRequest([string] $Url, [hashtable] $Headers, [object] $Payload) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Post -Headers $Headers `
        -ContentType 'application/json' -Body ($Payload | ConvertTo-Json -Depth 10 -Compress)
}

function Get-KnowledgeBootstrap([string] $Url, [string] $AccessToken) {
    $headers = @{
        Accept = 'application/json, text/event-stream'
        Authorization = "Bearer $AccessToken"
        'X-Knowledge-Machine' = 'Windows - ' + [Environment]::MachineName
    }
    $initialize = Invoke-McpRequest $Url $headers @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
            protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{
                name = 'knowledge-sync'; version = '0.1.0'
            }
        }
    }
    $initialized = Read-McpJson $initialize.Content 1
    if ($initialized.error) { throw "Knowledge MCP initialization failed: $($initialized.error.message)" }

    $sessionId = $initialize.Headers['MCP-Session-Id']
    if ($sessionId) { $headers['MCP-Session-Id'] = [string] $sessionId }
    $headers['MCP-Protocol-Version'] = [string] $initialized.result.protocolVersion

    Invoke-McpRequest $Url $headers @{
        jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{}
    } | Out-Null

    $response = Invoke-McpRequest $Url $headers @{
        jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{
            name = 'bootstrap_context'; arguments = @{}
        }
    }
    $called = Read-McpJson $response.Content 2
    if ($called.error) { throw "bootstrap_context failed: $($called.error.message)" }
    if ($called.result.isError) { throw 'bootstrap_context returned an MCP tool error.' }

    $parts = @($called.result.content | Where-Object type -eq 'text' | ForEach-Object { $_.text })
    return ($parts -join '').Trim()
}

function Merge-ManagedBlock([string] $Existing, [string] $Bootstrap) {
    if ([string]::IsNullOrWhiteSpace($Bootstrap)) { throw 'Refusing to install an empty bootstrap.' }
    if ($Bootstrap.Contains($StartMarker) -or $Bootstrap.Contains($EndMarker)) {
        throw 'The bootstrap contains reserved Knowledge MCP markers.'
    }

    $block = "$StartMarker`n<!-- Generated from Knowledge MCP. Changes inside this block will be replaced. -->`n`n$($Bootstrap.Trim())`n$EndMarker"
    $start = $Existing.IndexOf($StartMarker)
    $end = $Existing.IndexOf($EndMarker)
    if (($start -lt 0) -xor ($end -lt 0) -or ($start -ge 0 -and $end -lt $start)) {
        throw 'The target AGENTS.md contains an incomplete or invalid managed block.'
    }
    if ($start -lt 0) {
        if ([string]::IsNullOrWhiteSpace($Existing)) { return "$block`n" }
        return "$($Existing.TrimEnd())`n`n$block`n"
    }

    $after = $end + $EndMarker.Length
    return $Existing.Substring(0, $start) + $block + $Existing.Substring($after)
}

function Install-KnowledgeAlias([string] $DefaultDomain) {
    $profilePath = if ($env:KNOWLEDGE_SYNC_PROFILE) { $env:KNOWLEDGE_SYNC_PROFILE } else { $PROFILE.CurrentUserAllHosts }
    $profileDirectory = Split-Path -Parent $profilePath
    $aliasStart = '# KNOWLEDGE-SYNC:BEGIN'
    $aliasEnd = '# KNOWLEDGE-SYNC:END'
    $escapedDomain = $DefaultDomain.Replace("'", "''")
    $aliasBlock = @"
$aliasStart
function global:knowledge-sync {
    param(
        [string] `$Domain = '$escapedDomain',
        [Parameter(ValueFromRemainingArguments = `$true)] [object[]] `$Arguments
    )
    `$headers = @{ Accept = 'application/vnd.github.raw+json'; 'User-Agent' = 'knowledge-sync' }
    `$source = Invoke-RestMethod -Headers `$headers -Uri 'https://api.github.com/repos/wyxos/knowledge-sync/contents/install.ps1'
    & ([scriptblock]::Create([string] `$source)) -Domain `$Domain -NoAlias @Arguments
}
$aliasEnd
"@
    $existingProfile = if (Test-Path -LiteralPath $profilePath) { Get-Content -Raw -LiteralPath $profilePath } else { '' }
    $pattern = '(?s)' + [regex]::Escape($aliasStart) + '.*?' + [regex]::Escape($aliasEnd)
    $updatedProfile = if ($existingProfile -match $pattern) {
        [regex]::Replace($existingProfile, $pattern, $aliasBlock.TrimEnd())
    } elseif ([string]::IsNullOrWhiteSpace($existingProfile)) {
        $aliasBlock
    } else {
        $existingProfile.TrimEnd() + "`n`n" + $aliasBlock
    }

    if ($updatedProfile -ceq $existingProfile) { return }
    if ($null -eq $PSCmdlet -or $PSCmdlet.ShouldProcess($profilePath, 'Install persistent knowledge-sync command')) {
        New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
        [IO.File]::WriteAllText($profilePath, $updatedProfile, [Text.UTF8Encoding]::new($false))
        Write-Host "Persistent command installed in [$profilePath]. Open a new PowerShell session, then run: knowledge-sync"
    }
}

if ($BootstrapFile) {
    $bootstrap = Get-Content -Raw -LiteralPath $BootstrapFile
} else {
    if (-not $Token) {
        $Token = Get-OAuthAccessToken (Resolve-KnowledgeBaseUrl $Domain)
    }
    $baseUrl = Resolve-KnowledgeBaseUrl $Domain
    $bootstrap = Get-KnowledgeBootstrap "$baseUrl/mcp/knowledge" $Token
}

foreach ($path in @(Get-KnowledgeTargets)) {
    $existing = if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path } else { '' }
    $updated = Merge-ManagedBlock $existing $bootstrap
    if ($updated -ceq $existing) {
        Write-Host "Knowledge bootstrap is already current in [$path]."
    } elseif ($null -eq $PSCmdlet -or $PSCmdlet.ShouldProcess($path, 'Install Knowledge MCP bootstrap')) {
        Save-TextFile $path $updated
        Write-Host "Knowledge bootstrap installed in [$path]."
    }
}

if (-not $NoAlias) { Install-KnowledgeAlias $Domain }
if (-not $NoCodexMcp) { Install-CodexMcp "$(Resolve-KnowledgeBaseUrl $Domain)/mcp/knowledge" }
if (-not $NoClaudeMcp) { Install-ClaudeMcp "$(Resolve-KnowledgeBaseUrl $Domain)/mcp/knowledge" }
if (-not $NoCursorMcp) { Install-CursorMcp "$(Resolve-KnowledgeBaseUrl $Domain)/mcp/knowledge" }
if (-not $Target -and -not $NoCursorRule) { Install-CursorUserRule $bootstrap }
