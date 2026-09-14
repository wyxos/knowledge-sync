$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PWD '.tmp/cursor-review'
New-Item -ItemType Directory -Force $testRoot | Out-Null
$env:CURSOR_HOME = Join-Path $testRoot 'cursor'
$env:CODEX_HOME = Join-Path $testRoot 'codex'
New-Item -ItemType Directory -Force $env:CURSOR_HOME, $env:CODEX_HOME | Out-Null
$bootstrap = Join-Path $testRoot 'bootstrap.md'
Set-Content $bootstrap '# Bootstrap'
$config = Join-Path $env:CURSOR_HOME 'mcp.json'
$target = Join-Path $testRoot 'AGENTS.md'

foreach ($invalid in @('[]', 'null', 'false', '{"mcpServers":[]}', '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/mcp/knowledge","command":"local-server"}}}', '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/MCP/knowledge"}}}')) {
    Set-Content $config $invalid
    try {
        ./install.ps1 -BootstrapFile $bootstrap -Target $target -NoAlias -NoCodexMcp -NoCursorRule
        throw 'Expected invalid Cursor configuration to fail'
    } catch {
        if ("$_" -notmatch 'not a JSON object|Refusing to replace') { throw }
    }
    if ((Get-Content -Raw $config).Trim() -cne $invalid) { throw 'Invalid config was modified' }
}

Set-Content $config '{"mcpServers":{"other":{"command":"example","env":{"PRESERVE":"yes"}}},"custom":{"preserve":true}}'
./install.ps1 -BootstrapFile $bootstrap -NoAlias -NoCodexMcp -NoCursorRule
$saved = Get-Content -Raw $config
$parsed = $saved | ConvertFrom-Json
if ($parsed.mcpServers.other.env.PRESERVE -ne 'yes' -or $parsed.custom.preserve -ne $true) { throw 'Existing settings lost' }
./install.ps1 -BootstrapFile $bootstrap -NoAlias -NoCodexMcp -NoCursorRule -WhatIf
if ((Get-Content -Raw $config) -cne $saved) { throw 'Preview changed config' }

Push-Location $testRoot
try {
    & (Join-Path $PSScriptRoot '../install.ps1') -BootstrapFile $bootstrap -Target 'relative.md' -NoAlias -NoCodexMcp -NoCursorRule -NoCursorMcp
    if (-not (Test-Path 'relative.md')) { throw 'Bare relative target failed' }
} finally { Pop-Location }
Write-Host 'Cursor PowerShell regression checks passed.'
