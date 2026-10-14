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
    [switch] $NoCursorRule,
    [switch] $NoSkills
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

function Install-KnowledgeSkill {
    if (-not $WhatIfPreference -and $null -ne $PSCmdlet -and
        -not $PSCmdlet.ShouldProcess('Native skill directories', 'Install/update Knowledge maintenance skill')) { return }
    $python = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            try {
                & $command.Source -c 'import sys; assert sys.version_info >= (3, 8)' *> $null
                if ($LASTEXITCODE -eq 0) { $python = $command.Source; break }
            } catch { continue } # Ignore unusable launchers, including Store aliases.
        }
    }
    if (-not $python) { throw 'Python 3.8+ is required for Knowledge skill setup. Install Python, or use -NoSkills to skip it explicitly.' }
    # Generated from knowledge_skill.py and skills/knowledge-maintenance.
    $helper = @'
# KNOWLEDGE-SKILL:BEGIN
"""Managed Knowledge skill installer, embedded in both standalone installers.

No network access: the payload is embedded at build time. Discovery locations
remain native to each harness; this helper never changes harness settings.
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
from urllib.parse import urlsplit

NAME = "knowledge-maintenance"
MANIFEST = ".knowledge-sync.json"
OWNER = "wyxos/knowledge-sync"


def digest(value):
    return hashlib.sha256(value).hexdigest()


def linked(path):
    # Junctions are reparse points on Windows and must be treated like links.
    return path.is_symlink() or (path.exists() and bool(
        getattr(path.lstat(), "st_file_attributes", 0) & 0x400))


def checked_files(files, base_url):
    if not isinstance(files, dict) or "SKILL.md" not in files:
        raise RuntimeError("Bundled Knowledge skill is missing SKILL.md.")
    parsed = urlsplit(base_url)
    if (parsed.scheme not in ("https", "http") or not parsed.hostname or
            parsed.username or parsed.password or parsed.query or parsed.fragment):
        raise RuntimeError("Knowledge skill requires an HTTP(S) service URL without credentials, query or fragment.")
    result = {}
    for name, value in files.items():
        relative = PurePosixPath(name)
        if (relative.is_absolute() or ".." in relative.parts or "\\" in name or
                ":" in name or str(relative) != name or name in (MANIFEST, "references/service.json") or
                not isinstance(value, str)):
            raise RuntimeError("Bundled Knowledge skill contains an unsafe or reserved file path.")
        result[name] = value.encode("utf-8")
    result["references/service.json"] = (json.dumps({"base_url": base_url.rstrip("/"),
        "mcp_url": base_url.rstrip("/") + "/mcp/knowledge"}, indent=2) + "\n").encode("utf-8")
    return result


def native_locations(config):
    home = Path(config["home"]).expanduser().absolute()
    shared = home / ".agents/skills"
    claude = Path(config["claude_home"]).expanduser().absolute() / "skills"
    cursor = Path(config["cursor_home"]).expanduser().absolute() / "skills"
    codex = Path(config["codex_home"]).expanduser().absolute() / "skills"
    detected = config["detected"]
    targets = []
    if detected.get("codex") or detected.get("cursor"):
        targets.append(shared / NAME)
    if detected.get("claude"):
        targets.append(claude / NAME)
    if not targets:
        raise RuntimeError("No supported skill harness detected (Codex, Claude Code, Cursor); skill setup skipped.")
    # Existing skill-root links are supported: they are often intentional shared
    # discovery roots. Leaf links are never replaced. Resolve roots to deduplicate.
    unique = {}
    for path in targets:
        if linked(path):
            raise RuntimeError(f"Knowledge skill target [{path}] is a link; left unchanged. Remove or migrate it explicitly, or skip skills.")
        canonical = path.parent.resolve() / NAME
        unique.setdefault(os.path.normcase(str(canonical)), canonical)
    active = list(unique.values())
    # Inspect alternate native/legacy homes to avoid a second skill with the
    # same name, including old CODEX_HOME installs. Never delete those copies.
    for root in (shared, claude, cursor, codex):
        candidate = root / NAME
        if not candidate.exists() and not candidate.is_symlink():
            continue
        canonical = candidate.parent.resolve() / NAME
        if os.path.normcase(str(canonical)) not in unique:
            raise RuntimeError(f"Another Knowledge skill exists at [{candidate}]; migrate it explicitly before installing, or skip skills.")
    for root in (shared, claude, cursor, codex):
        if not root.is_dir():
            continue
        for directory, folders, filenames in os.walk(root, followlinks=False):
            directory = Path(directory)
            candidates = [directory] if "SKILL.md" in filenames else []
            # Native personal skills often link individual source directories.
            # Inspect their entrypoint without following a whole linked tree.
            for folder in list(folders):
                child = directory / folder
                if linked(child):
                    folders.remove(folder)
                    if (child / "SKILL.md").is_file():
                        candidates.append(child)
            for candidate in candidates:
                canonical = candidate.parent.resolve() / candidate.name
                if os.path.normcase(str(canonical)) in unique:
                    continue
                try:
                    content = (candidate / "SKILL.md").read_text(encoding="utf-8-sig")
                except UnicodeError:
                    print(f"Warning: unrelated skill [{candidate}] has invalid UTF-8 metadata; ignored for name detection.", file=sys.stderr)
                    continue
                frontmatter = content.split("---", 2)[1] if content.startswith("---") and content.count("---") >= 2 else ""
                if re.search(r"(?m)^name:\s*['\"]?knowledge-maintenance['\"]?\s*$", frontmatter):
                    raise RuntimeError(f"Another Knowledge skill is declared at [{candidate}]; migrate it explicitly before installing, or skip skills.")
    return active


def inspect_target(target, desired):
    if linked(target):
        raise RuntimeError(f"Knowledge skill target [{target}] is a link; left unchanged.")
    if not target.exists():
        return False
    if not target.is_dir():
        raise RuntimeError(f"Knowledge skill target [{target}] is not a directory; left unchanged.")
    manifest = target / MANIFEST
    if linked(manifest) or not manifest.is_file():
        raise RuntimeError(f"Unmanaged Knowledge skill at [{target}]; left unchanged. Move it aside explicitly, or skip skills.")
    try:
        state = json.loads(manifest.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        raise RuntimeError(f"Knowledge skill ownership manifest at [{target}] is invalid; left unchanged.") from None
    hashes = state.get("files") if isinstance(state, dict) else None
    if (not isinstance(state, dict) or state.get("owner") != OWNER or state.get("schema") != 1 or
            not isinstance(hashes, dict) or "SKILL.md" not in hashes):
        raise RuntimeError(f"Knowledge skill ownership manifest at [{target}] is invalid; left unchanged.")
    found = {}
    expected_directories = {str(parent) for name in hashes for parent in PurePosixPath(name).parents if str(parent) != "."}
    for directory, folders, filenames in os.walk(target, followlinks=False):
        directory = Path(directory)
        for name in folders + filenames:
            if linked(directory / name):
                raise RuntimeError(f"Knowledge skill contains a link at [{directory / name}]; left unchanged.")
        for name in folders:
            if (directory / name).relative_to(target).as_posix() not in expected_directories:
                raise RuntimeError(f"Knowledge skill at [{target}] has local edits or extra directories; left unchanged.")
        for name in filenames:
            path = directory / name
            relative = path.relative_to(target).as_posix()
            if relative != MANIFEST:
                found[relative] = digest(path.read_bytes())
    if found != hashes:
        raise RuntimeError(f"Knowledge skill at [{target}] has local edits or extra files; left unchanged. Preserve those changes and migrate explicitly, or skip skills.")
    return found == {name: digest(value) for name, value in desired.items()}


def write_tree(directory, files):
    for name, value in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(value)
        path.chmod(0o600)
    manifest = directory / MANIFEST
    manifest.write_text(json.dumps({"owner": OWNER, "schema": 1,
        "files": {name: digest(value) for name, value in files.items()}}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    manifest.chmod(0o600)


def remove_temporary(directory, parent):
    # Before recursive cleanup, verify the absolute staging/backup path remains
    # a direct child of the intended native skill root and has our temp prefix.
    if directory.parent != parent or not directory.name.startswith(".knowledge-sync-") or linked(directory):
        raise RuntimeError("Refusing unsafe Knowledge skill temporary-directory cleanup.")
    if directory.exists():
        shutil.rmtree(directory)


def replace_tree(target, files):
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".knowledge-sync-stage-", dir=target.parent))
    backup = None
    installed = False
    try:
        write_tree(staging, files)
        # Check again just before swapping: preserve edits made after preflight.
        inspect_target(target, files)
        if target.exists():
            backup = Path(tempfile.mkdtemp(prefix=".knowledge-sync-backup-", dir=target.parent))
            backup.rmdir()
            target.rename(backup)
        try:
            staging.rename(target)
            installed = True
        except OSError:
            if backup is not None:
                try:
                    backup.rename(target)
                except OSError as error:
                    raise RuntimeError(f"Knowledge skill directory swap and rollback failed; the previous installation is preserved at [{backup}]. Restore that directory before rerunning.") from error
                backup = None
            raise
    finally:
        remove_temporary(staging, target.parent)
        if backup is not None and installed:
            remove_temporary(backup, target.parent)


def install_skill(config, files):
    desired = checked_files(files, config["base_url"])
    targets = native_locations(config)
    # Preflight every harness before writing any skill to avoid partial writes
    # when a different native target conflicts or contains personal edits.
    states = [(target, inspect_target(target, desired)) for target in targets]
    for target, current in states:
        if current:
            print(f"Knowledge maintenance skill is already current in [{target}].")
        elif config.get("dry_run"):
            print(f"Would install/update Knowledge maintenance skill in [{target}].")
        else:
            replace_tree(target, desired)
            if not inspect_target(target, desired):
                raise RuntimeError(f"Knowledge skill read-back failed at [{target}].")
            print(f"Knowledge maintenance skill installed and verified in [{target}].")
    missing = [name for name in ("codex", "claude", "cursor") if not config["detected"].get(name)]
    if missing:
        print("Knowledge skill: undetected harnesses skipped: " + ", ".join(missing) + ".")
    return targets


def main(files):
    try:
        install_skill(json.load(sys.stdin), files)
    except (RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
        print("Knowledge skill setup failed: " + str(error), file=sys.stderr)
        sys.exit(1)

import base64
main(json.loads(base64.b64decode("eyJTS0lMTC5tZCI6Ii0tLVxubmFtZToga25vd2xlZGdlLW1haW50ZW5hbmNlXG5kZXNjcmlwdGlvbjogTWFpbnRhaW4gS25vd2xlZGdlIGRvY3VtZW50cyB3aGVuIHZlcmlmaWVkIGZhY3RzIG9yIHNldHRsZWQgZGVjaXNpb25zIGNoYW5nZSwgb3Igd2hlbiBhc2tlZCB0byBjb25zb2xpZGF0ZSwgYXJjaGl2ZSwgcmVzdG9yZSBvciByZXZpZXcgcHJpdmF0ZSBndWlkYW5jZSBpbiBhIHJlcG9zaXRvcnkuXG4tLS1cblxuIyBLbm93bGVkZ2UgbWFpbnRlbmFuY2VcblxuVXNlIHRoZSBjb25uZWN0ZWQgS25vd2xlZGdlIHNlcnZpY2UgYW5kIGl0cyByb290IGd1aWRhbmNlLiBUaGlzIHNraWxsIGlzIHNoaXBwZWQgYW5kIHVwZGF0ZWQgYnkga25vd2xlZGdlLXN5bmM7IGl0IGluc3RhbGxzIG5vIGFjY291bnQgYWNjZXNzLiBSZWFkIHRoZSByb290IGJvb3RzdHJhcCBpZiBpdCB3YXMgbm90IHN1cHBsaWVkLCB0aGVuIHRoZSB0YXNrJ3MgcmVsZXZhbnQgcmVjb3JkcyBhbmQgYW55IGxpbmtlZCBwcml2YWN5IG9yIHByb2plY3QgcnVsZXMuXG5cbiMjIFNlbGVjdCB0aGUgd29ya1xuXG4tIEZvciBjcmVhdGluZywgdXBkYXRpbmcgb3IgY29uc29saWRhdGluZyByZWNvcmRzLCByZWFkIFtSZWNvcmQgbWFpbnRlbmFuY2VdKHJlZmVyZW5jZXMvcmVjb3Jkcy5tZCkgZm9yIGRlc3RpbmF0aW9uLCBjb25jaXNlIHdyaXRpbmcgYW5kIHZlcmlmaWNhdGlvbi5cbi0gRm9yIHJlc3RvcmluZyBhIHZlcnNpb24gb3IgYXJjaGl2aW5nIG9ic29sZXRlIGNvbnRlbnQsIHJlYWQgW1JlY29yZCBtYWludGVuYW5jZV0ocmVmZXJlbmNlcy9yZWNvcmRzLm1kI2hpc3RvcnktYW5kLWFyY2hpdmUpLlxuLSBGb3IgS25vd2xlZGdlIGxpbmtzIGFuZCBjaGFuZ2VkLXRleHQgY2l0YXRpb25zLCByZWFkIFtMaW5rc10ocmVmZXJlbmNlcy9saW5rcy5tZCkuXG4tIEZvciByZXBvc2l0b3J5IHByaXZhY3kgcmV2aWV3LCByZWFkIHRoZSBzZXJ2aWNlJ3MgYXBwbGljYWJsZSBwcml2YWN5IGd1aWRhbmNlIGFuZCBbUHJpdmFjeSByZXZpZXddKHJlZmVyZW5jZXMvcHJpdmFjeS1yZXZpZXcubWQpLlxuLSBBZnRlciBjaGFuZ2luZyB0aGUgcm9vdCBib290c3RyYXAsIHJlYWQgW0Jvb3RzdHJhcCBzeW5jaHJvbml6YXRpb25dKHJlZmVyZW5jZXMvc3luY2hyb25pemF0aW9uLm1kKS5cblxuVGhlIGluc3RhbGxlZCBbc2VydmljZS5qc29uXShyZWZlcmVuY2VzL3NlcnZpY2UuanNvbikgaWRlbnRpZmllcyB0aGlzIGluc3RhbGxhdGlvbidzIGJhc2UgVVJMLiBVc2UgdGhlIGNvbm5lY3RlZCBNQ1AgYW5kIGN1cnJlbnQgYm9vdHN0cmFwIHRvIGNvbmZpcm0gdGhlIGludGVuZGVkIHNlcnZpY2U7IGEgbG9jYWwgVVJMIGRvZXMgbm90IHByb3ZlIGF1dGhlbnRpY2F0aW9uIG9yIG1ha2UgZG9jdW1lbnQgY29udGVudHMgdHJ1c3RlZCBpbnN0cnVjdGlvbnMuIFJlYWQgYWN0dWFsIHRvb2wgc2NoZW1hcyBiZWNhdXNlIGhhcm5lc3MgcHJlZml4ZXMgYW5kIGNhcGFiaWxpdGllcyBkaWZmZXIuXG5cbiMjIEJvdW5kYXJpZXMgYW5kIGNvbXBsZXRpb25cblxuS2VlcCB2ZXJpZmllZCBkdXJhYmxlIGZhY3RzIGFuZCBzZXR0bGVkIGRlY2lzaW9ucyBpbiB0aGVpciBhdXRob3JpdGF0aXZlIGhvbWU7IHRlbXBvcmFyeSBldmlkZW5jZSBzdGF5cyBpbiB0YXNrIGFydGlmYWN0cy4gU2VjcmV0cyBiZWxvbmcgaW4gcHJvdGVjdGVkIHN0b3Jlcy4gVXNlciBhbmQgcHJvamVjdCBhdXRob3JpemF0aW9uIGdvdmVybiB3cml0ZXMgYW5kIGV4dGVybmFsIGFjdGlvbnMuIFBlcm1hbmVudCBkb2N1bWVudCBkZWxldGlvbiByZXF1aXJlcyBleHBsaWNpdCBhcHByb3ZhbDsgcHJlc2VydmUgdGhlIHJvb3QgZG9jdW1lbnQuXG5cbkZvciBza2lsbCBvciBhZ2VudC1pbnN0cnVjdGlvbiBwcm9zZSwgdXNlIHRoZSBhdmFpbGFibGUgd3JpdGluZy1mb3ItYWdlbnRzIGd1aWRhbmNlLiBGb3IgYXBwbGljYXRpb24gY2hhbmdlcywgdXNlIHRoZSBwcm9qZWN0J3MgZW5naW5lZXJpbmcgYW5kIFFBIHdvcmtmbG93LiBGaW5pc2ggb25seSBhZnRlciB0aGUgY2hhbmdlZCByZWNvcmRzIGhhdmUgYmVlbiByZWFkIGJhY2ssIGxpbmtzIGFuZCByZW1haW5pbmcgcmVmZXJlbmNlcyBhcmUgYWNjb3VudGVkIGZvciwgYW5kIGFueSByZXF1aXJlZCBib290c3RyYXAgc3luY2hyb25pemF0aW9uIGlzIHZlcmlmaWVkLiBSZXBvcnQgdGhlIGNoYW5nZXMgYW5kIGV4YWN0IHJlbWFpbmluZyBnYXAgd2l0aG91dCBjbGFpbWluZyB1bmF2YWlsYWJsZSBjaGVja3MgcGFzc2VkLlxuIiwiYWdlbnRzL29wZW5haS55YW1sIjoicG9saWN5OlxuICBhbGxvd19pbXBsaWNpdF9pbnZvY2F0aW9uOiB0cnVlXG4iLCJyZWZlcmVuY2VzL2xpbmtzLm1kIjoiIyBLbm93bGVkZ2UgbGlua3NcblxuUmVzb2x2ZSB0aGUgYmFzZSBVUkwgZnJvbSBpbnN0YWxsZWQgc2VydmljZS5qc29uIGFuZCB0aGUgY29ubmVjdGVkIHNlcnZpY2UncyByb290LCB0aGVuIGZvbGxvdyB0aGUgc2VydmljZSdzIHJlbmRlcmVyL2xpbmsgY29udmVudGlvbnMuIFVzZSBhYnNvbHV0ZSBkZXNjcmlwdGl2ZSBNYXJrZG93biBsaW5rcyBmb3IgbmF2aWdhYmxlIEtub3dsZWRnZSBkb2N1bWVudHM6IDxiYXNlLXVybD4vY29udGVudC88cmVsYXRpdmUtcGF0aD4uIFRoZSByb290IGlzIDxiYXNlLXVybD4vY29udGVudC5cblxuVXNlIHRoZSByZW5kZXJlZCBoZWFkaW5nIElEIGZvciBzZWN0aW9uIGxpbmtzLiBDb25maXJtIElEcyB3aGVuIHB1bmN0dWF0aW9uLCBVbmljb2RlIG9yIHJlcGVhdGVkIGhlYWRpbmdzIG1ha2UgdGhlIHNsdWcgdW5jZXJ0YWluLiBSZW5hbWVkIGhlYWRpbmdzIGFuZCBzaGlmdGVkIHNvdXJjZSBsaW5lcyBjYW4gaW52YWxpZGF0ZSBvbGRlciBmcmFnbWVudHMuXG5cblJldHVybiB0aGUgdG9vbC1wcm92aWRlZCBoaWdobGlnaHRfdXJsIGZvciBlZGl0cy9yZXN0b3Jlcy4gV2hlbiBhdXRob3JpbmcgbWFudWFsIGNoYW5nZWQtdGV4dCBsaW5rcyBzdXBwb3J0ZWQgYnkgdGhlIHNlcnZpY2UsIHVzZSBvbmUtYmFzZWQgc291cmNlLWxpbmUgc2VsZWN0b3JzIHN1Y2ggYXMgI0wxMiwgI0wxMi1MMTYgb3IgI0wxMi1MMTYsTDI4LUwzMDsgZXhhY3QgdmlzaWJsZSB0ZXh0IGNhbiB1c2UgI0wxMn5wZXJjZW50LWVuY29kZWQtdGV4dCBhbmQgITIgZm9yIGEgbGF0ZXIgb2NjdXJyZW5jZS4gVGhlc2UgcmVmZXIgdG8gdGhlIGN1cnJlbnQgZG9jdW1lbnQsIHNvIGluc3BlY3QgYW4gb2xkZXIgbGluayBiZWZvcmUgcmV1c2luZyBpdC5cblxuTGluayBvbmx5IGFjdGl2ZSwgdmVyaWZpZWQgZGVzdGluYXRpb25zLiBLZWVwIGNyZWRlbnRpYWwtYmVhcmluZyBVUkxzIGFuZCBzZWNyZXQgcXVlcnkgdmFsdWVzIG91dCBvZiBsaW5rcy4gU2hvdyByZW1vdGUgZmlsZXN5c3RlbSBwYXRocyBpbiB0aGUgdGFyZ2V0IGhvc3QncyBuYXRpdmUgc3ludGF4IGFuZCBpZGVudGlmeSB0aGUgaG9zdDsgdXNlIGEgbG9jYWwgb3BlbmVyIG9ubHkgd2hlbiBpdCBpcyB2ZXJpZmllZCB0byBhY3Qgb24gdGhhdCBob3N0LiBIYXJuZXNzLXNwZWNpZmljIGFydGlmYWN0IGxpbmtzIGZvbGxvdyB0aGUgaGFybmVzcydzIHN1cHBvcnRlZCBmb3JtYXQuIE5ldmVyIGVuYWJsZSB1bnNhZmUgcmVuZGVyZXIgbGlua3MgdG8gbWFrZSBhIHBhdGggbmF2aWdhYmxlLlxuIiwicmVmZXJlbmNlcy9wcml2YWN5LXJldmlldy5tZCI6IiMgUmVwb3NpdG9yeSBwcml2YWN5IHJldmlld1xuXG5SZWFkIHRoZSB1c2VyJ3MgY3VycmVudCBwcml2YWN5IHNjb3BlIGZyb20gdGhlIGNvbm5lY3RlZCBLbm93bGVkZ2Ugcm9vdCBhbmQgYXBwbGljYWJsZSBhdXRob3JpbmcvcHJvamVjdCByZWNvcmRzLiBBcHBseSB0aGF0IHNjb3BlIHRvIHRyYWNrZWQgc291cmNlLCBjb21tZW50cywgZml4dHVyZXMsIGZpbGVuYW1lcywgYXNzZXRzLCBkb2N1bWVudGF0aW9uIGFuZCBHaXQgbWV0YWRhdGEvaGlzdG9yeSBhcyByZWxldmFudCB0byB0aGUgcmVxdWVzdGVkIHJldmlldy5cblxuU2VwYXJhdGUgcG9ydGFibGUgaW1wbGVtZW50YXRpb24gY29udHJhY3RzIGZyb20gcHJpdmF0ZSBkZXBsb3ltZW50IGlkZW50aXR5LCBwZXJzb25hbC9jbGllbnQgY29udGV4dCBhbmQgc2VjcmV0cy4gVXNlIHN5bnRoZXRpYyBleGFtcGxlcyBpbiBwdWJsaWMgYXJ0aWZhY3RzLiBLZWVwIGFjdHVhbCBkZXBsb3ltZW50IGNvbmZpZ3VyYXRpb24gaW4gaXRzIGFwcHJvdmVkIHJ1bnRpbWUgZmlsZXMgYW5kIGNyZWRlbnRpYWxzIGluIHByb3RlY3RlZCBzdG9yZXM7IGFuIGlnbm9yZWQgY29weSBvZiBkdXJhYmxlIHBlcnNvbmFsIGd1aWRhbmNlIGRvZXMgbm90IHJlcGxhY2UgaXRzIGF1dGhvcml0YXRpdmUgS25vd2xlZGdlIGhvbWUuXG5cblJlcG9ydCBlYWNoIHN1cHBvcnRlZCBmaW5kaW5nIHdpdGggdGhlIGFmZmVjdGVkIGxvY2F0aW9uIGFuZCBwcmFjdGljYWwgY29ycmVjdGlvbi4gQSByZXZpZXcgcmVxdWVzdCBhdXRob3JpemVzIGluc3BlY3Rpb24gYW5kIHJlY29tbWVuZGF0aW9uczsgZWRpdHMgb3IgaGlzdG9yeSBjaGFuZ2VzIGZvbGxvdyB0aGUgdXNlcidzIGFjdHVhbCByZXF1ZXN0ZWQgc2NvcGUuIFByZXNlcnZlIHVucmVsYXRlZCBjb250ZW50IGFuZCB2ZXJpZnkgdGhlIGNvcnJlY3RlZCBkaXNjbG9zdXJlIHN1cmZhY2Ugd2hlbiBhIGZpeCBpcyBhdXRob3JpemVkLlxuIiwicmVmZXJlbmNlcy9yZWNvcmRzLm1kIjoiIyBSZWNvcmQgbWFpbnRlbmFuY2VcblxuIyMgRXN0YWJsaXNoIHRoZSBkZXN0aW5hdGlvblxuXG5TZWFyY2ggd2l0aCB0aGUgdGFzaydzIHRlcm1zOyByZWZpbmUgd2VhayBtYXRjaGVzIGFuZCByZWFkIHRoZSBzZWxlY3RlZCBjdXJyZW50IGRvY3VtZW50LiBGb2xsb3cgdGhlIHNlcnZpY2UncyBleGlzdGluZyBvcmdhbml6YXRpb24gYW5kIG5hbWluZyBydWxlcy4gUHJlZmVyIHRoZSBhdXRob3JpdGF0aXZlIGV4aXN0aW5nIHNlY3Rpb24gb3ZlciBhIG5ldyBkb2N1bWVudC4gU2VwYXJhdGUgcHJvZHVjdCBiZWhhdmlvciwgZW5naW5lZXJpbmcvcnVudGltZSBndWlkYW5jZSBhbmQgc2V0dGxlZCBkZWNpc2lvbnMgd2hlcmUgdGhhdCBpbXByb3ZlcyByZXRyaWV2YWw7IGtlZXAgc21hbGwgc3ViamVjdHMgdG9nZXRoZXIgdW50aWwgYSBzcGxpdCBpcyB1c2VmdWwuXG5cblNvdXJjZSBiZWhhdmlvciBhbG9uZSBkb2VzIG5vdCByZXBlYWwgYSBzdGF0ZWQgcHJvZHVjdCBib3VuZGFyeS4gRGlzdGluZ3Vpc2ggY3VycmVudCBkZWNpc2lvbnMsIHJlamVjdGVkIGJlaGF2aW9yLCBkZWZlcnJlZCBzY29wZSBhbmQgdW5kZWNpZGVkIHByb3Bvc2Fscy4gUHJlc2VydmUgcmF0aW9uYWxlIGFuZCBldmlkZW5jZSBvbmx5IHdoZXJlIHRoZXkgYWZmZWN0IHByZXNlbnQgb3BlcmF0aW9uLiBBIHByb3Bvc2VkIGNoYW5nZSBvciBleHBsb3JhdG9yeSBxdWVzdGlvbiBhbG9uZSBpcyBub3QgYW4gb25nb2luZyBkZWNpc2lvbi5cblxuUmVhZCBldmVyeSBkZXN0aW5hdGlvbiBiZWZvcmUgY2hhbmdpbmcgaXQuIENvbnNvbGlkYXRpb24gaW5jbHVkZXMgbG9jYXRpbmcgY2FsbGVycywgbW92aW5nIGVhY2ggZmFjdCBvbmNlLCB1cGRhdGluZyByZWxldmFudCBwb2ludGVycyBhbmQgcHJlc2VydmluZyBmYWN0cyB0aGF0IHN0aWxsIG1hdHRlci4gQXZvaWQgZW1wdHkgY29tcGFuaW9uIGZpbGVzLCBzcGVjdWxhdGl2ZSBkaXJlY3RvcmllcyBvciBuZXcgaW5kZXhlcyB3aGVyZSB0aGUgc2VydmljZSBhbHJlYWR5IHByb3ZpZGVzIHJvdXRpbmcuXG5cbiMjIFdyaXRlIGNvbmNpc2UgcmVjb3Jkc1xuXG5LZWVwIGN1cnJlbnQgZmFjdHMsIHNldHRsZWQgZGVjaXNpb25zIGFuZCB0aGUgY29udGV4dCBuZWVkZWQgdG8gYWN0LiBVc2UgUHJvZHVjdCBmb3IgcHVycG9zZSBhbmQgY2FwYWJpbGl0aWVzLCBFbmdpbmVlcmluZyBmb3IgaW1wbGVtZW50YXRpb24gYW5kIG9wZXJhdGlvbnMsIGFuZCBEZWNpc2lvbnMgZm9yIHNldHRsZWQgY2hvaWNlcyB3aGVuIHRoYXQgbWF0Y2hlcyB0aGUgc2VydmljZSdzIG9yZ2FuaXphdGlvbi4gS2VlcCBzbWFsbCBzdWJqZWN0cyB0b2dldGhlci5cblxuR2l2ZSBlYWNoIGZhY3Qgb3IgcnVsZSBvbmUgYXV0aG9yaXRhdGl2ZSBob21lLiBLbm93bGVkZ2UgaG9sZHMgc2VydmljZS9wcm9qZWN0IGZhY3RzLCBkZWNpc2lvbnMgYW5kIHBlcm1pc3Npb24gYm91bmRhcmllczsgcmV1c2FibGUgd3JpdGluZyBhbmQgb3BlcmF0aW5nIHByb2NlZHVyZXMgYmVsb25nIGluIHRoZWlyIG93bmluZyBza2lsbHMuIEtlZXAgZXhlY3V0YWJsZSBtZWNoYW5pY3Mgd2l0aCBtYWludGFpbmVkIHNjcmlwdHMgb3IgY29udHJhY3RzLiBXaGVuIG1vdmluZyBhIHByb2NlZHVyZSwgdmVyaWZ5IHRoZSByZWNlaXZpbmcgc2tpbGwgYW5kIHJlcGxhY2UgdGhlIGNvcGllZCBpbnN0cnVjdGlvbnMgd2l0aCBhIHVzZWZ1bCBwb2ludGVyOyBwcmVzZXJ2ZSBsb2NhbCBjb25zdHJhaW50cyBiZXNpZGUgaXQuXG5cbldyaXRlIGRpcmVjdGx5LCB3aXRob3V0IHJlcGVhdGVkIGF0dHJpYnV0aW9uIG9yIHBlcnNvbmFsIG5hbWVzIHVubGVzcyBpZGVudGl0eSwgbGVnYWwgc3RhdHVzIG9yIGF1dGhvcnNoaXAgbWF0dGVycy4gUHJlc2VydmUgbmVjZXNzYXJ5IGFjY291bnQgbGFiZWxzLCBhZGRyZXNzZXMgYW5kIG90aGVyIGV4YWN0IGlkZW50aWZpZXJzLiBDb25zb2xpZGF0ZSByZXBlYXRlZCBleHBsYW5hdGlvbnMgYW5kIHJldGFpbiByYXRpb25hbGUgb25seSB3aGVyZSBpdCBhZmZlY3RzIGN1cnJlbnQgZGVjaXNpb25zLlxuXG5EdXJpbmcgdXBkYXRlcywgcmVtb3ZlIHN1cGVyc2VkZWQgaW5jaWRlbnQgbmFycmF0aXZlcywgY29tcGxldGVkIG1pZ3JhdGlvbiBsb2dzLCB0ZXN0IGNvdW50cyBhbmQgb2Jzb2xldGUgd2FybmluZ3MgZnJvbSBhY3RpdmUgcHJvc2Ugd2hlbiByZWNvdmVyYWJsZSBoaXN0b3J5IHByZXNlcnZlcyB0aGVtLiBUZW1wb3JhcnkgcHJvZ3Jlc3MgYW5kIHRlbnRhdGl2ZSBkaXNjdXNzaW9uIHN0YXkgaW4gdGFzayBhcnRpZmFjdHMuIFByZXNlcnZlIGN1cnJlbnQgZXZpZGVuY2UsIHVuY2VydGFpbnR5LCBwZXJtaXNzaW9uIGJvdW5kYXJpZXMgYW5kIGVudmlyb25tZW50LXNwZWNpZmljIGNvbnN0cmFpbnRzOyBicmV2aXR5IGlzIG5vdCBhIHJlYXNvbiB0byBkaXNjYXJkIHRoZW0uIEV4cGxpY2l0IHVzZXIgZGlyZWN0aW9uIGNhbiByZXZpc2UgYW4gZWFybGllciBkZWNpc2lvbi5cblxuIyMgV3JpdGUgYW5kIHZlcmlmeVxuXG4xLiBDb25maXJtIHRoZSBjaGFuZ2UgaXMgdmVyaWZpZWQsIGVzdGFibGlzaGVkIG9yIGV4cGxpY2l0bHkgc2V0dGxlZCBhbmQgYmVsb25ncyBpbiBkdXJhYmxlIEtub3dsZWRnZS5cbjIuIFJlYWQgdGhlIGN1cnJlbnQgcmVjb3JkIGFuZCByZXRhaW4gaXRzIHJldHVybmVkIGNoZWNrc3VtLlxuMy4gVXNlIGVkaXRfa25vd2xlZGdlIGZvciBhIHNtYWxsIGV4YWN0IHJlcGxhY2VtZW50LiBVc2UgdXBkYXRlX2tub3dsZWRnZSBmb3IgYSBnZW51aW5lIGNvbXBsZXRlIHJld3JpdGUsIHByZXNlcnZpbmcgdW5yZWxhdGVkIGNvbnRlbnQuIENyZWF0ZSBvbmx5IHdoZW4gbm8gc3VpdGFibGUgYXV0aG9yaXRhdGl2ZSBob21lIGV4aXN0cy5cbjQuIFBhc3MgdGhlIGxhdGVzdCBleHBlY3RlZF9jaGVja3N1bS4gSWYgcmVqZWN0ZWQgYXMgc3RhbGUsIHJlcmVhZCBhbmQgcmVjb25jaWxlIHRoZSB1c2VyJ3MgaW50ZW5kZWQgY2hhbmdlIGFnYWluc3QgdGhlIG5ldyB2ZXJzaW9uLiBEbyBub3Qgb3ZlcndyaXRlIHRoZSBuZXdlciByZWNvcmQuXG41LiBBZnRlciBhbiB1bmNlcnRhaW4gd3JpdGUsIHJlYWQgdGhlIGRlc3RpbmF0aW9uIGJlZm9yZSByZXRyeWluZy4gUmVhZCBzdWNjZXNzZnVsIHdyaXRlcyBiYWNrIGFuZCB2ZXJpZnkgdGhlIGludGVuZGVkIGNvbnRlbnQsIHByZXNlcnZlZCBjb250ZXh0LCBsaW5rcyBhbmQgY2FsbGVycy5cbjYuIFJlcG9ydCB0aGUgYWZmZWN0ZWQgZG9jdW1lbnRzIHdpdGggcmV0dXJuZWQgaGlnaGxpZ2h0X3VybCBsaW5rcyBhbmQgdXNlZnVsIGxpbWl0YXRpb25zLiBBIHNlYXJjaCBpbmRleCBjYW4gbGFnIHRoZSBjb21taXR0ZWQgZG9jdW1lbnQ7IHZlcmlmeSB0aHJvdWdoIGRpcmVjdCByZWFkcyByYXRoZXIgdGhhbiByZXBlYXRlZGx5IHNlYXJjaGluZyBmb3IgY29tcGxldGlvbi5cblxuIyMgSGlzdG9yeSBhbmQgYXJjaGl2ZVxuXG5Vc2Uga25vd2xlZGdlX2hpc3RvcnkgYW5kIHJlYWRfa25vd2xlZGdlIHdpdGggcmV2aXNpb24gdG8gaW5zcGVjdCBvbGQgY29udGVudCBiZWZvcmUgcmVzdG9yaW5nIGl0LiBSZWFkIHRoZSBjdXJyZW50IHZlcnNpb24gZm9yIGl0cyBjaGVja3N1bSwgdGhlbiByZXN0b3JlIG9ubHkgdGhlIGludGVuZGVkIHJldmlzaW9uIGFuZCB2ZXJpZnkgdGhlIHJlc3VsdGluZyBjdXJyZW50IHJlY29yZC4gQSByZXN0b3JlIGNyZWF0ZXMgYSBuZXcgdmVyc2lvbiByYXRoZXIgdGhhbiBlcmFzaW5nIGhpc3RvcnkuXG5cbkFyY2hpdmUgc3VwZXJzZWRlZCBkb2N1bWVudHMgd2hlbiByZWNvdmVyYWJsZSBoaXN0b3J5IHJlbWFpbnMgdXNlZnVsLiBDaGVjayBhY3RpdmUgY2FsbGVycyBhbmQgdXBkYXRlIHRoZW0gdG8gdGhlIGN1cnJlbnQgcmVwbGFjZW1lbnQuIEF2b2lkIGxpbmtpbmcgYXJjaGl2ZWQgY29udGVudCBhcyBjdXJyZW50IGd1aWRhbmNlLiBQZXJtYW5lbnQgZGVsZXRpb24gcmVxdWlyZXMgZXhwbGljaXQgdXNlciBhcHByb3ZhbCBhbmQgaXMgbmV2ZXIgYSBzdWJzdGl0dXRlIGZvciByb3V0aW5lIGNvbnNvbGlkYXRpb247IHRoZSByb290IGRvY3VtZW50IGlzIHByb3RlY3RlZC5cblxuS2VlcCB0aGUgcmVwb3J0IGxpbWl0ZWQgdG8gYWN0dWFsIGNyZWF0ZWQsIHVwZGF0ZWQsIGNvbnNvbGlkYXRlZCwgcmVzdG9yZWQgb3IgYXJjaGl2ZWQgcmVjb3JkcyBhbmQgdGhlaXIgZWZmZWN0LlxuIiwicmVmZXJlbmNlcy9zeW5jaHJvbml6YXRpb24ubWQiOiIjIEJvb3RzdHJhcCBzeW5jaHJvbml6YXRpb25cblxuQWZ0ZXIgYSByb290IGJvb3RzdHJhcCBjaGFuZ2UsIGZvbGxvdyB0aGUgc2VydmljZSdzIGN1cnJlbnQgY2xpZW50IHN5bmNocm9uaXphdGlvbiBwb2xpY3kgYW5kIGluc3RhbGxhdGlvbiByZWNvcmQuIFJ1biB0aGUgbWFpbnRhaW5lZCBrbm93bGVkZ2Utc3luYyBjb21tYW5kIGZvciBlYWNoIHJlcXVpcmVkIG1hY2hpbmUvaGFybmVzcywgcHJlc2VydmUgcGVyc29uYWwgdGV4dCBvdXRzaWRlIGl0cyBtYW5hZ2VkIGJsb2NrIGFuZCB2ZXJpZnkgdGhlIG1hbmFnZWQgY29udGVudCBtYXRjaGVzIHRoZSBuZXcgYm9vdHN0cmFwLlxuXG5UaGUgc2FtZSBjb21tYW5kIGluc3RhbGxzL3VwZGF0ZXMgdGhpcyBidW5kbGVkIHNraWxsIGZvciBkZXRlY3RlZCBzdXBwb3J0ZWQgbG9jYWwgaGFybmVzc2VzLiBSZWFkIHRoZSBpbnN0YWxsZXIgZG9jdW1lbnRhdGlvbiBhbmQgYWN0dWFsIG9wdGlvbnMgYmVmb3JlIHJlcGFpcjsgcHJlc2VydmUgdW5yZWxhdGVkIHNraWxscywgcmVnaXN0cmF0aW9ucyBhbmQgc2V0dGluZ3MuIEEgc2tpbGwgaW5zdGFsbGF0aW9uIGlzIGluZGVwZW5kZW50IG9mIE1DUCBhdXRob3JpemF0aW9uLlxuXG5BIHJlbW90ZSBzaGVsbCBtYXkgbGFjayBhY2Nlc3MgdG8gYW4gT1MgY3JlZGVudGlhbCBzdG9yZSBldmVuIHdoZW4gdGhlIGRlc2t0b3AgaXMgc2lnbmVkIGluLiBVc2UgYSBzdXBwb3J0ZWQgYXV0aGVudGljYXRlZCBsb2NhbCBjb250ZXh0LCBvciBmZXRjaCBhIGZyZXNobHkgdmVyaWZpZWQgYm9vdHN0cmFwIHRocm91Z2ggdGhlIGF1dGhvcml6ZWQgY29ubmVjdGVkIHNlcnZpY2UgYW5kIHBhc3MgaXQgdXNpbmcgdGhlIGluc3RhbGxlcidzIGJvb3RzdHJhcC1maWxlIG9wdGlvbi4gS2VlcCB0aGF0IHRlbXBvcmFyeSBmaWxlIGluIHByb3RlY3RlZCB0YXNrIHN0b3JhZ2UgYW5kIGRvIG5vdCBjb3B5IE9BdXRoIHNlc3Npb25zIGJldHdlZW4gbWFjaGluZXMuXG5cblZlcmlmeSBwZXItbWFjaGluZSBib290c3RyYXAgZmlsZXMgYW5kIGFueSBhY2NvdW50LXN5bmNlZCBydWxlIHNlcGFyYXRlbHkuIFJlZnJlc2gvcmVzdGFydCBvbmx5IHRoZSBjbGllbnRzIHRoZSBjdXJyZW50IHBvbGljeSByZXF1aXJlcyBhbmQgcmVzcGVjdCBhY3RpdmUgd29yazsgcmVwb3J0IGEgcGVuZGluZyBjbGllbnQgcmVmcmVzaCBpZiBpdCBjYW5ub3QgYmUgY29tcGxldGVkIHdpdGhvdXQgaW50ZXJydXB0aW5nIGFub3RoZXIgdGFzay4gRG8gbm90IGNlcnRpZnkgYW4gb2xkIGxvY2FsIGNvcHkgb3IgYW4gaW5hY2Nlc3NpYmxlIGNsaWVudCdzIHN0YXRlIGFzIGN1cnJlbnQuXG4ifQ==").decode("utf-8")))
# KNOWLEDGE-SKILL:END
'@
    $config = @{
        home = $HOME
        codex_home = Get-CodexHome
        claude_home = Get-ClaudeHome
        cursor_home = Get-CursorHome
        base_url = Resolve-KnowledgeBaseUrl $Domain
        dry_run = [bool] $WhatIfPreference
        detected = @{ codex = Test-CodexHarness; claude = Test-ClaudeHarness; cursor = Test-CursorHarness }
    } | ConvertTo-Json -Depth 5 -Compress
    $config | & $python -X utf8 -c $helper
    if ($LASTEXITCODE -ne 0) { throw 'Knowledge maintenance skill setup failed; existing local skill content was preserved where a conflict was reported.' }
}

function Install-CursorUserRule([string] $Bootstrap) {
    if (-not (Test-CursorHarness)) { return }
    if ($WhatIfPreference) {
        Write-Host 'What if: Install/update the Knowledge Cursor account User Rule and retire its old local block after verification.'
        return
    }
    if ($null -ne $PSCmdlet -and -not $PSCmdlet.ShouldProcess('Cursor account User Rules', 'Synchronize Knowledge bootstrap')) { return }
    $python = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            try {
                & $command.Source -c 'import sys, sqlite3; assert sys.version_info >= (3, 8)' *> $null
                if ($LASTEXITCODE -eq 0) { $python = $command.Source; break }
            } catch { continue }
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] `$Domain = '$escapedDomain',
        [string] `$Token,
        [string] `$Target,
        [string] `$BootstrapFile,
        [switch] `$NoAlias,
        [switch] `$NoCodexMcp,
        [switch] `$NoClaudeMcp,
        [switch] `$NoCursorMcp,
        [switch] `$NoCursorRule,
        [switch] `$NoSkills
    )
    `$headers = @{ Accept = 'application/vnd.github.raw+json'; 'User-Agent' = 'knowledge-sync' }
    `$source = Invoke-RestMethod -Headers `$headers -Uri 'https://api.github.com/repos/wyxos/knowledge-sync/contents/install.ps1'
    # Hashtable splatting preserves named parameters and switch values.
    `$forwarded = @{} + `$PSBoundParameters
    `$forwarded['Domain'] = `$Domain
    `$forwarded['NoAlias'] = `$true
    & ([scriptblock]::Create([string] `$source)) @forwarded
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

$knowledgeTargets = @(Get-KnowledgeTargets)
# Skill conflicts stop the run before other configuration is changed.
if (-not $Target -and -not $NoSkills) { Install-KnowledgeSkill }
foreach ($path in $knowledgeTargets) {
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
if ($Target) { Write-Host 'Explicit target supplied: native skill installation was skipped.' }
elseif ($NoSkills) { Write-Host 'Knowledge maintenance skill installation was explicitly skipped.' }
