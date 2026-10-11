param([string] $Installer, [string] $FixtureRoot)
$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $FixtureRoot 'bootstrap.md'
$profileFixture = Join-Path $FixtureRoot 'profile.ps1'
$env:KNOWLEDGE_SYNC_PROFILE = $profileFixture
$env:KNOWLEDGE_SYNC_TEST_INSTALLER = $Installer

# Install the real persisted command into a task-owned fixture profile.
& $Installer -Domain 'knowledge.example.test' -BootstrapFile $bootstrap -Target (Join-Path $FixtureRoot 'initial.md') -NoSkills -NoCodexMcp -NoClaudeMcp -NoCursorMcp -NoCursorRule
. $profileFixture
$originalProfile = [IO.File]::ReadAllText($profileFixture)

# Only the downloaded script transport is mocked. The generated function and
# actual native installer both run; no live network or account writes occur.
function global:Invoke-RestMethod {
    param($Headers, $Uri)
    if ($Uri -ne 'https://api.github.com/repos/wyxos/knowledge-sync/contents/install.ps1') {
        throw 'Unexpected network operation in offline alias test.'
    }
    [IO.File]::ReadAllText($env:KNOWLEDGE_SYNC_TEST_INSTALLER) + "`n" + '$global:KNOWLEDGE_SYNC_TEST_BOUND = @{} + $PSBoundParameters'
}

knowledge-sync -BootstrapFile $bootstrap -NoSkills -NoCodexMcp -NoClaudeMcp -NoCursorMcp -NoCursorRule
$bound = $global:KNOWLEDGE_SYNC_TEST_BOUND
if ($bound.Domain -ne 'knowledge.example.test' -or $bound.BootstrapFile -ne $bootstrap) { throw 'Domain or BootstrapFile was not forwarded.' }
foreach ($name in @('NoAlias', 'NoSkills', 'NoCodexMcp', 'NoClaudeMcp', 'NoCursorMcp', 'NoCursorRule')) {
    if (-not $bound[$name]) { throw "Switch [$name] was not forwarded." }
}
$codexTarget = Join-Path $env:CODEX_HOME 'AGENTS.md'
if (-not (Test-Path -LiteralPath $codexTarget)) { throw 'Persisted command did not install the bootstrap.' }
if ((Test-Path -LiteralPath (Join-Path $FixtureRoot '.agents/skills')) -or
    (Test-Path -LiteralPath (Join-Path $env:CLAUDE_CONFIG_DIR 'skills')) -or
    (Test-Path -LiteralPath (Join-Path $env:CURSOR_HOME 'mcp.json')) -or
    (Test-Path -LiteralPath (Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json'))) { throw 'Skip switches did not prevent skill/MCP setup.' }
if ([IO.File]::ReadAllText($profileFixture) -cne $originalProfile) { throw 'Persisted command unexpectedly rewrote its own profile.' }

$before = [IO.File]::ReadAllText($codexTarget)
[IO.File]::WriteAllText($bootstrap, '# Preview change')
knowledge-sync -Domain 'other.example.test' -BootstrapFile $bootstrap -NoSkills -NoCodexMcp -NoClaudeMcp -NoCursorMcp -NoCursorRule -WhatIf
if ($global:KNOWLEDGE_SYNC_TEST_BOUND.Domain -ne 'other.example.test' -or -not $global:KNOWLEDGE_SYNC_TEST_BOUND.WhatIf) { throw 'Explicit Domain or WhatIf was not forwarded.' }
if ([IO.File]::ReadAllText($codexTarget) -cne $before) { throw 'Persisted command preview changed the bootstrap.' }

# Keep the persisted parameter list aligned with the installer as flags evolve.
$native = Get-Command $Installer
$persisted = Get-Command knowledge-sync
foreach ($name in $native.Parameters.Keys) {
    if (-not $persisted.Parameters.ContainsKey($name)) { throw "Persisted command does not accept installer parameter [$name]." }
}
Write-Host 'Persisted PowerShell command named-parameter checks passed.'
