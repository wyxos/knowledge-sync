[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Domain = 'knowledge.test',
    [string] $Token = $env:KNOWLEDGE_MCP_TOKEN,
    [string] $Target,
    [string] $BootstrapFile,
    [switch] $NoAlias
)

$ErrorActionPreference = 'Stop'
$StartMarker = '<!-- KNOWLEDGE-MCP:BEGIN -->'
$EndMarker = '<!-- KNOWLEDGE-MCP:END -->'

function Resolve-KnowledgeBaseUrl([string] $Value) {
    $Value = $Value.Trim().TrimEnd('/')
    if ($Value -match '^https?://') { return $Value }
    if ($Value.EndsWith('.test')) { return "http://$Value" }
    return "https://$Value"
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

    $parts = @($called.result.content | Where-Object type -eq 'text' | ForEach-Object text)
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
    if ($PSCmdlet.ShouldProcess($profilePath, 'Install persistent knowledge-sync command')) {
        New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
        [IO.File]::WriteAllText($profilePath, $updatedProfile, [Text.UTF8Encoding]::new($false))
        Write-Host "Persistent command installed in [$profilePath]. Open a new PowerShell session, then run: knowledge-sync"
    }
}

if (-not $Target) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    if (-not (Get-Command codex -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $codexHome)) {
        throw 'Codex was not detected. Install Codex, set CODEX_HOME, or pass -Target explicitly.'
    }
    $Target = Join-Path $codexHome 'AGENTS.md'
}

if ($BootstrapFile) {
    $bootstrap = Get-Content -Raw -LiteralPath $BootstrapFile
} else {
    if (-not $Token) {
        $secureToken = Read-Host 'Knowledge MCP access token' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        try { $Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    $baseUrl = Resolve-KnowledgeBaseUrl $Domain
    $bootstrap = Get-KnowledgeBootstrap "$baseUrl/mcp/knowledge" $Token
}

$existing = if (Test-Path -LiteralPath $Target) { Get-Content -Raw -LiteralPath $Target } else { '' }
$updated = Merge-ManagedBlock $existing $bootstrap
if ($updated -ceq $existing) { Write-Host "Knowledge bootstrap is already current in [$Target]."; exit 0 }

if ($PSCmdlet.ShouldProcess($Target, 'Install Knowledge MCP bootstrap')) {
    $directory = Split-Path -Parent $Target
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.knowledge-agents-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        Move-Item -Force -LiteralPath $temporary -Destination $Target
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -Force -LiteralPath $temporary }
    }
    Write-Host "Knowledge bootstrap installed in [$Target]."
}

if (-not $NoAlias) { Install-KnowledgeAlias $Domain }
