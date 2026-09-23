$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PWD '.tmp/claude-review'
New-Item -ItemType Directory -Force $testRoot | Out-Null
$env:CODEX_HOME = Join-Path $testRoot 'codex'
$env:CLAUDE_CONFIG_DIR = Join-Path $testRoot 'claude'
New-Item -ItemType Directory -Force $env:CODEX_HOME, $env:CLAUDE_CONFIG_DIR | Out-Null
$bootstrap = Join-Path $testRoot 'bootstrap.md'
Set-Content -LiteralPath $bootstrap -Value '# Bootstrap' -Encoding utf8
$claudeMd = Join-Path $env:CLAUDE_CONFIG_DIR 'CLAUDE.md'
Set-Content -LiteralPath $claudeMd -Value '# Personal Claude guidance' -Encoding utf8
$config = Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'
Set-Content -LiteralPath $config -Value '{"mcpServers":{"other":{"command":"example"}},"custom":{"preserve":true}}' -Encoding utf8

./install.ps1 -BootstrapFile $bootstrap -NoAlias -NoCodexMcp -NoCursorMcp -NoCursorRule
$savedMd = Get-Content -Raw -LiteralPath $claudeMd
$savedConfig = Get-Content -Raw -LiteralPath $config
$parsed = $savedConfig | ConvertFrom-Json
if ($savedMd -notmatch '# Personal Claude guidance' -or $savedMd -notmatch '# Bootstrap') { throw 'Claude instructions were not merged' }
if ($parsed.custom.preserve -ne $true -or $parsed.mcpServers.other.command -ne 'example') { throw 'Existing Claude config was lost' }
if ($parsed.mcpServers.knowledge.type -cne 'http' -or $parsed.mcpServers.knowledge.url -cne 'https://knowledge.test/mcp/knowledge') { throw 'Claude MCP was not registered globally' }

./install.ps1 -BootstrapFile $bootstrap -NoAlias -NoCodexMcp -NoCursorMcp -NoCursorRule
if ((Get-Content -Raw -LiteralPath $claudeMd) -cne $savedMd -or (Get-Content -Raw -LiteralPath $config) -cne $savedConfig) { throw 'Repeat run changed Claude configuration' }

Set-Content -LiteralPath $bootstrap -Value '# Updated bootstrap' -Encoding utf8
./install.ps1 -BootstrapFile $bootstrap -NoAlias -NoCodexMcp -NoCursorMcp -NoCursorRule -WhatIf
if ((Get-Content -Raw -LiteralPath $claudeMd) -cne $savedMd -or (Get-Content -Raw -LiteralPath $config) -cne $savedConfig) { throw 'Preview changed Claude configuration' }
./install.ps1 -BootstrapFile $bootstrap -NoAlias -NoCodexMcp -NoCursorMcp -NoCursorRule
if ((Get-Content -Raw -LiteralPath $claudeMd) -notmatch '# Updated bootstrap') { throw 'Claude bootstrap was not refreshed' }

foreach ($invalid in @('[]', 'null', 'false', '{"mcpServers":[]}', '{"mcpServers":{"knowledge":{"type":"http","url":"https://other.example/mcp"}}}', '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/mcp/knowledge"}}}')) {
    Set-Content -LiteralPath $config -Value $invalid -Encoding utf8
    try {
        ./install.ps1 -BootstrapFile $bootstrap -Target (Join-Path $testRoot 'target.md') -NoAlias -NoCodexMcp -NoCursorMcp -NoCursorRule
        throw 'Expected invalid Claude configuration to fail'
    } catch {
        if ("$_" -notmatch 'not a JSON object|Refusing to replace') { throw }
    }
    if ((Get-Content -Raw -LiteralPath $config).Trim() -cne $invalid) { throw 'Invalid Claude config was modified' }
}
Write-Host 'Claude PowerShell regression checks passed.'
