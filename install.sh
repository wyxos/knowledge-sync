#!/usr/bin/env bash
set -euo pipefail

domain="knowledge.test"
token="${KNOWLEDGE_MCP_TOKEN:-}"
target=""
bootstrap_file=""
dry_run=0
install_alias=1
install_codex_mcp=1
install_claude_mcp=1
install_cursor_mcp=1
install_cursor_rule=1
install_skills=1
start_marker='<!-- KNOWLEDGE-MCP:BEGIN -->'
end_marker='<!-- KNOWLEDGE-MCP:END -->'

codex_home() { printf '%s' "${CODEX_HOME:-${HOME}/.codex}"; }
claude_home() { printf '%s' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"; }
claude_config() {
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then printf '%s/.claude.json' "$CLAUDE_CONFIG_DIR"
  else printf '%s/.claude.json' "$HOME"; fi
}
cursor_home() { printf '%s' "${CURSOR_HOME:-${HOME}/.cursor}"; }

codex_detected() {
  command -v codex >/dev/null 2>&1 || [[ -d "$(codex_home)" ]]
}

claude_detected() {
  command -v claude >/dev/null 2>&1 || [[ -d "$(claude_home)" ]] || [[ -f "$(claude_config)" ]]
}

cursor_detected() {
  local user_data="${CURSOR_USER_DATA_DIR:-}"
  if [[ -z "$user_data" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then user_data="$HOME/Library/Application Support/Cursor"
    else user_data="${XDG_CONFIG_HOME:-$HOME/.config}/Cursor"; fi
  fi
  command -v agent >/dev/null 2>&1 \
    || command -v cursor-agent >/dev/null 2>&1 \
    || command -v cursor >/dev/null 2>&1 \
    || [[ -d "$(cursor_home)" ]] \
    || [[ -d "$user_data" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) domain="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --bootstrap-file) bootstrap_file="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --no-alias) install_alias=0; shift ;;
    --no-codex-mcp) install_codex_mcp=0; shift ;;
    --no-claude-mcp) install_claude_mcp=0; shift ;;
    --no-cursor-mcp) install_cursor_mcp=0; shift ;;
    --no-cursor-rule) install_cursor_rule=0; shift ;;
    --no-skills) install_skills=0; shift ;;
    -h|--help)
      printf '%s\n' 'Usage: install.sh [--domain knowledge.test] [--token TOKEN] [--target PATH] [--bootstrap-file FILE] [--dry-run] [--no-alias] [--no-codex-mcp] [--no-claude-mcp] [--no-cursor-mcp] [--no-cursor-rule] [--no-skills]'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

install_knowledge_skill() {
  local python_bin="" candidate helper has_codex=false has_claude=false has_cursor=false
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  if [[ -z "$python_bin" ]]; then
    echo 'Python 3.8+ is required for Knowledge skill setup. Install Python, or use --no-skills to skip it explicitly.' >&2
    return 1
  fi
  codex_detected && has_codex=true
  claude_detected && has_claude=true
  cursor_detected && has_cursor=true
  # Generated from knowledge_skill.py and skills/knowledge-maintenance.
  helper="$(cat <<'KNOWLEDGE_SKILL_PY'
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
KNOWLEDGE_SKILL_PY
)"
  "$python_bin" -c 'import json,sys; print(json.dumps(dict(home=sys.argv[1], codex_home=sys.argv[2], claude_home=sys.argv[3], cursor_home=sys.argv[4], base_url=sys.argv[5], dry_run=sys.argv[6]=="1", detected=dict(codex=sys.argv[7]=="true", claude=sys.argv[8]=="true", cursor=sys.argv[9]=="true"))))' \
    "$HOME" "$(codex_home)" "$(claude_home)" "$(cursor_home)" "$(resolve_base_url "$domain")" "$dry_run" "$has_codex" "$has_claude" "$has_cursor" \
    | "$python_bin" -X utf8 -c "$helper"
}

install_codex_mcp_server() {
  local mcp_url="$1" existing_json existing_url existing_type
  if ! command -v codex >/dev/null 2>&1; then
    echo 'Warning: Codex CLI was not found; skipped Knowledge MCP registration.' >&2
    return
  fi

  if existing_json="$(codex mcp get knowledge --json 2>/dev/null)"; then
    existing_url="$(jq -r '.transport.url // ""' <<<"$existing_json")"
    existing_type="$(jq -r '.transport.type // ""' <<<"$existing_json")"
    if [[ "$existing_type" != streamable_http || "${existing_url%/}" != "${mcp_url%/}" ]]; then
      echo "Codex already has an MCP server named [knowledge] configured for [$existing_url]. Refusing to replace it with [$mcp_url]." >&2
      exit 1
    fi
    echo "Knowledge MCP is already registered in Codex at [$existing_url]."
    return
  fi

  if [[ "$dry_run" == 1 ]]; then
    echo "Would register Knowledge MCP in Codex at [$mcp_url]."
    return
  fi

  codex mcp add knowledge --url "$mcp_url"
  echo 'Knowledge MCP registered in Codex. Codex completes OAuth authentication during registration when the server requires it.'
}

install_claude_mcp_server() {
  local mcp_url="$1" config python_bin candidate
  claude_detected || return 0
  config="$(claude_config)"
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json, pathlib, tempfile' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  if [[ -z "${python_bin:-}" ]]; then
    echo 'Python 3 is required to register Claude Knowledge MCP. Install Python, or use --no-claude-mcp to skip it explicitly.' >&2
    return 1
  fi

  KNOWLEDGE_SYNC_MCP_URL="$mcp_url" KNOWLEDGE_SYNC_DRY_RUN="$dry_run" "$python_bin" - "$config" <<'PY'
import json, os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
url = os.environ["KNOWLEDGE_SYNC_MCP_URL"]
if path.exists() and path.stat().st_size:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except ValueError as error:
        raise SystemExit(f"Claude config at [{path}] is not valid JSON.") from error
else:
    data = {}
if not isinstance(data, dict):
    raise SystemExit(f"Claude config at [{path}] is not a JSON object.")
servers = data.setdefault("mcpServers", {})
if servers is None:
    servers = {}
    data["mcpServers"] = servers
if not isinstance(servers, dict):
    raise SystemExit(f"Claude mcpServers in [{path}] is not a JSON object.")
if "knowledge" in servers:
    existing = servers["knowledge"]
    existing_url = existing.get("url", "") if isinstance(existing, dict) else ""
    if (not isinstance(existing, dict) or existing.get("type") not in ("http", "streamable-http")
            or existing.get("command") or not isinstance(existing_url, str)
            or existing_url.rstrip("/") != url.rstrip("/")):
        raise SystemExit(f"Claude already has an MCP server named [knowledge] configured for [{existing_url}]. Refusing to replace it with [{url}].")
    print(f"Knowledge MCP is already registered in Claude at [{existing_url}].")
    raise SystemExit(0)
if os.environ["KNOWLEDGE_SYNC_DRY_RUN"] == "1":
    print(f"Would register Knowledge MCP in Claude at [{url}].")
    raise SystemExit(0)
servers["knowledge"] = {"type": "http", "url": url}
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".knowledge-mcp-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(data, output, ensure_ascii=False, indent=2)
        output.write("\n")
    if path.exists():
        os.chmod(temporary, path.stat().st_mode & 0o777)
    else:
        os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("Knowledge MCP registered in Claude. Run: claude mcp login knowledge")
PY
}

install_cursor_user_rule() {
  cursor_detected || return 0
  if [[ "$dry_run" == 1 ]]; then
    echo 'Would install/update the Knowledge Cursor account User Rule and retire its old local block after verification.'
    return
  fi
  local python_bin='' candidate helper
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys, sqlite3; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  if [[ -z "$python_bin" ]]; then
    echo 'Python 3.8+ is required to install the Cursor User Rule. Install Python, or use --no-cursor-rule to skip it explicitly.' >&2
    return 1
  fi
  # Generated from cursor_user_rule.py by tools/embed_cursor_rule.py.
  helper="$(cat <<'CURSOR_RULE_PY'
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
CURSOR_RULE_PY
)"
  printf '%s' "$bootstrap" | "$python_bin" -c 'import json, sys; print(json.dumps({"bootstrap": sys.stdin.read(), "cursor_home": sys.argv[1]}))' "$(cursor_home)" | "$python_bin" -c "$helper"
}

install_cursor_mcp_server() {
  local mcp_url="$1" config python_bin candidate
  if ! cursor_detected; then
    return
  fi
  config="$(cursor_home)/mcp.json"

  if [[ "$dry_run" == 1 ]]; then
    echo "Would register Knowledge MCP in Cursor at [$mcp_url]."
    return
  fi

  python_bin=""
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json, os, pathlib, sys' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  if [[ -z "$python_bin" ]]; then
    echo 'Warning: python3 was not found; skipped Cursor Knowledge MCP registration.' >&2
    return
  fi

  KNOWLEDGE_SYNC_MCP_URL="$mcp_url" "$python_bin" - "$config" <<'PY'
import json, os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
url = os.environ["KNOWLEDGE_SYNC_MCP_URL"]
if path.exists() and path.stat().st_size:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"Cursor MCP config at [{path}] is not valid JSON.") from error
else:
    data = {}
if not isinstance(data, dict):
    raise SystemExit(f"Cursor MCP config at [{path}] is not a JSON object.")
servers = data.setdefault("mcpServers", {})
if servers is None:
    servers = {}
    data["mcpServers"] = servers
if not isinstance(servers, dict):
    raise SystemExit(f"Cursor MCP mcpServers in [{path}] is not a JSON object.")
existing = servers.get("knowledge")
if existing is not None:
    existing_url = existing.get("url", "") if isinstance(existing, dict) else ""
    if not isinstance(existing, dict) or not isinstance(existing_url, str) or existing.get("command") or existing_url.rstrip("/") != url.rstrip("/"):
        raise SystemExit(
            f"Cursor already has an MCP server named [knowledge] configured for [{existing_url}]. Refusing to replace it with [{url}]."
        )
    print(f"Knowledge MCP is already registered in Cursor at [{existing_url}].")
    raise SystemExit(0)
servers["knowledge"] = {"url": url}
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".knowledge-mcp-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(json.dumps(data, indent=2) + "\n")
    if path.exists():
        os.chmod(temporary, path.stat().st_mode & 0o777)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("Knowledge MCP registered in Cursor. Authenticate it in Cursor or run: agent mcp login knowledge")
PY
}

write_agents_file() {
  local target="$1"
  local directory existing_file output_file block_file start_count end_count unchanged
  directory="$(dirname "$target")"
  mkdir -p "$directory"
  existing_file="$(mktemp)"
  [[ ! -f "$target" ]] || cp "$target" "$existing_file"
  output_file="$(mktemp "$directory/.knowledge-agents-XXXXXX")"
  block_file="$(mktemp)"
  printf '%s\n%s\n\n%s\n%s\n' "$start_marker" '<!-- Generated from Knowledge MCP. Changes inside this block will be replaced. -->' "$bootstrap" "$end_marker" > "$block_file"

  start_count="$(grep -Fxc "$start_marker" "$existing_file" || true)"
  end_count="$(grep -Fxc "$end_marker" "$existing_file" || true)"
  [[ "$start_count" == "$end_count" && "$start_count" -le 1 ]] || { echo 'Target contains an invalid managed block.' >&2; exit 1; }

  if [[ "$start_count" == 0 ]]; then
    if [[ -s "$existing_file" ]]; then sed -e '${/^$/d;}' "$existing_file" > "$output_file"; printf '\n\n' >> "$output_file"; fi
    cat "$block_file" >> "$output_file"
  else
    awk -v start="$start_marker" -v end="$end_marker" -v block="$block_file" '
      $0 == start { while ((getline line < block) > 0) print line; skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$existing_file" > "$output_file"
  fi

  rm -f "$existing_file" "$block_file"
  unchanged=0
  if [[ -f "$target" ]] && cmp -s "$target" "$output_file"; then unchanged=1; fi
  if [[ "$dry_run" == 1 ]]; then
    if [[ "${#targets[@]}" -gt 1 ]]; then printf -- '--- %s ---\n' "$target"; fi
    cat "$output_file"
    rm -f "$output_file"
    return
  fi
  if [[ "$unchanged" == 1 ]]; then rm -f "$output_file"; echo "Knowledge bootstrap is already current in [$target]."
  else mv -f "$output_file" "$target"; echo "Knowledge bootstrap installed in [$target]."
  fi
}

resolve_base_url() {
  local value="${1%/}"
  if [[ "$value" =~ ^https?:// ]]; then printf '%s' "$value"
  else printf 'https://%s' "$value"
  fi
}

credential_file() {
  local key
  key="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s/.knowledge-sync/oauth-%s.json' "$HOME" "$key"
}

read_credentials() {
  local service="knowledge-sync:$1" file status
  if [[ "$(uname -s)" == Darwin ]] && command -v security >/dev/null; then
    if security find-generic-password -a "$USER" -s "$service" -w 2>/dev/null; then
      return 0
    else
      status=$?
      [[ "$status" == 44 ]] && return 0 # errSecItemNotFound
      echo 'Knowledge Sync cannot read its macOS Keychain session. Run it in a local Mac Terminal, or pass a freshly verified --bootstrap-file when syncing over SSH.' >&2
      return 1
    fi
  elif command -v secret-tool >/dev/null; then
    secret-tool lookup service knowledge-sync domain "$1" 2>/dev/null || true
  else
    file="$(credential_file "$1")"
    [[ ! -f "$file" ]] || cat "$file"
  fi
}

save_credentials() {
  local domain="$1" value="$2" service="knowledge-sync:$1" file
  if [[ "$(uname -s)" == Darwin ]] && command -v security >/dev/null; then
    if ! security add-generic-password -a "$USER" -s "$service" -w "$value" -U >/dev/null; then
      echo 'Knowledge Sync could not save its OAuth session to macOS Keychain. Run it in a local Mac Terminal, or use a freshly verified --bootstrap-file over SSH.' >&2
      return 1
    fi
  elif command -v secret-tool >/dev/null; then
    printf '%s' "$value" | secret-tool store --label='Knowledge Sync OAuth' service knowledge-sync domain "$domain"
  else
    file="$(credential_file "$domain")"
    mkdir -p "$(dirname "$file")"
    (umask 077; printf '%s' "$value" > "$file")
    echo "Warning: OAuth credentials are stored in [$file] with user-only permissions because no system keyring CLI was found." >&2
  fi
}

token_request() {
  local endpoint="$1"; shift
  curl --fail-with-body --silent --show-error -X POST "$endpoint" "$@"
}

save_token_response() {
  local base_url="$1" response="$2" client_id="$3" client_secret="$4" token_endpoint="$5" resource="$6" expires_at
  expires_at="$(( $(date +%s) + $(jq -r '.expires_in // 3600' <<<"$response") ))"
  credentials="$(jq -nc --argjson token "$response" --arg client_id "$client_id" --arg client_secret "$client_secret" \
    --arg token_endpoint "$token_endpoint" --arg resource "$resource" --argjson expires_at "$expires_at" \
    '{access_token:$token.access_token,refresh_token:($token.refresh_token // ""),expires_at:$expires_at,client_id:$client_id,client_secret:$client_secret,token_endpoint:$token_endpoint,resource:$resource}')"
  save_credentials "$base_url" "$credentials" || return 1
  jq -er '.access_token' <<<"$credentials"
}

get_oauth_token() {
  local base_url="$1" stored now refreshed resource_metadata issuer metadata redirect_uri registration
  local verifier challenge state authorize_url token_response client_id client_secret token_endpoint resource
  stored="$(read_credentials "$base_url")" || return 1
  now="$(date +%s)"
  if [[ -n "$stored" ]] && [[ "$(jq -r '.expires_at // 0' <<<"$stored")" -gt $((now + 60)) ]]; then
    jq -er '.access_token' <<<"$stored"
    return
  fi
  if [[ -n "$stored" && -n "$(jq -r '.refresh_token // empty' <<<"$stored")" ]]; then
    token_endpoint="$(jq -r '.token_endpoint' <<<"$stored")"
    client_id="$(jq -r '.client_id' <<<"$stored")"
    client_secret="$(jq -r '.client_secret // empty' <<<"$stored")"
    resource="$(jq -r '.resource' <<<"$stored")"
    refresh_args=(--data-urlencode 'grant_type=refresh_token' --data-urlencode "refresh_token=$(jq -r '.refresh_token' <<<"$stored")" --data-urlencode "client_id=$client_id" --data-urlencode "resource=$resource")
    [[ -z "$client_secret" ]] || refresh_args+=(--data-urlencode "client_secret=$client_secret")
    if refreshed="$(token_request "$token_endpoint" "${refresh_args[@]}" 2>/dev/null)"; then
      save_token_response "$base_url" "$refreshed" "$client_id" "$client_secret" "$token_endpoint" "$resource" || return 1
      return
    fi
    echo 'Saved OAuth session could not be refreshed; signing in again.' >&2
  fi

  resource_metadata="$(curl --fail-with-body --silent --show-error "$base_url/.well-known/oauth-protected-resource/mcp/knowledge")"
  resource="$(jq -er '.resource' <<<"$resource_metadata")"
  issuer="$(jq -er '.authorization_servers[0]' <<<"$resource_metadata")"
  metadata="$(curl --fail-with-body --silent --show-error "${issuer%/}/.well-known/oauth-authorization-server")"
  token_endpoint="$(jq -er '.token_endpoint' <<<"$metadata")"

  oauth_dir="$(mktemp -d)"
  callback_script="$oauth_dir/callback.py"
  cat > "$callback_script" <<'PY'
import http.server, json, pathlib, sys, urllib.parse
directory = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        values = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).items()}
        (directory / "result.json").write_text(json.dumps(values))
        body = b"Authentication complete. You can close this window."
        self.send_response(200); self.send_header("Content-Type", "text/plain"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 300
(directory / "port").write_text(str(server.server_port))
server.handle_request()
PY
  python3 "$callback_script" "$oauth_dir" & callback_pid=$!
  for _ in {1..100}; do [[ -f "$oauth_dir/port" ]] && break; sleep 0.05; done
  [[ -f "$oauth_dir/port" ]] || { kill "$callback_pid" 2>/dev/null || true; echo 'Could not start the OAuth callback listener.' >&2; exit 1; }
  redirect_uri="http://127.0.0.1:$(cat "$oauth_dir/port")/callback"
  registration="$(curl --fail-with-body --silent --show-error -X POST "$(jq -r '.registration_endpoint' <<<"$metadata")" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg redirect "$redirect_uri" '{client_name:"Knowledge Sync",redirect_uris:[$redirect],grant_types:["authorization_code","refresh_token"],response_types:["code"],token_endpoint_auth_method:"client_secret_post",application_type:"native",scope:"mcp:use"}')")"
  client_id="$(jq -er '.client_id' <<<"$registration")"
  client_secret="$(jq -r '.client_secret // empty' <<<"$registration")"
  verifier="$(openssl rand -base64 64 | tr '+/' '-_' | tr -d '=\n')"
  challenge="$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  state="$(openssl rand -hex 24)"
  uri_encode() { jq -rn --arg value "$1" '$value|@uri'; }
  authorize_url="$(jq -r '.authorization_endpoint' <<<"$metadata")?response_type=code&client_id=$(uri_encode "$client_id")&redirect_uri=$(uri_encode "$redirect_uri")&state=$(uri_encode "$state")&code_challenge=$(uri_encode "$challenge")&code_challenge_method=S256&scope=mcp%3Ause&resource=$(uri_encode "$resource")"
  echo 'Opening the browser to authenticate Knowledge Sync...' >&2
  if [[ "$(uname -s)" == Darwin ]]; then open "$authorize_url"
  elif command -v xdg-open >/dev/null; then xdg-open "$authorize_url" >/dev/null 2>&1
  else echo "Open this URL in a browser: $authorize_url" >&2
  fi
  wait "$callback_pid"
  callback="$(cat "$oauth_dir/result.json")"
  rm -rf "$oauth_dir"
  [[ "$(jq -r '.state // empty' <<<"$callback")" == "$state" ]] || { echo 'OAuth state did not match.' >&2; exit 1; }
  code="$(jq -er '.code' <<<"$callback")"
  token_args=(--data-urlencode 'grant_type=authorization_code' --data-urlencode "code=$code" --data-urlencode "redirect_uri=$redirect_uri" --data-urlencode "code_verifier=$verifier" --data-urlencode "client_id=$client_id" --data-urlencode "resource=$resource")
  [[ -z "$client_secret" ]] || token_args+=(--data-urlencode "client_secret=$client_secret")
  token_response="$(token_request "$token_endpoint" "${token_args[@]}")"
  save_token_response "$base_url" "$token_response" "$client_id" "$client_secret" "$token_endpoint" "$resource" || return 1
}

mcp_post() {
  local payload="$1" machine_os
  machine_os="$(uname -s)"
  [[ "$machine_os" != Darwin ]] || machine_os=Mac
  local curl_headers=(
    -H 'Accept: application/json, text/event-stream'
    -H 'Content-Type: application/json'
    -H "Authorization: Bearer ${token}"
    -H "X-Knowledge-Machine: $machine_os - $(hostname -s)"
  )
  [[ -z "$session_id" ]] || curl_headers+=(-H "MCP-Session-Id: ${session_id}")
  [[ -z "$protocol_version" ]] || curl_headers+=(-H "MCP-Protocol-Version: ${protocol_version}")

  curl --fail-with-body --silent --show-error \
    -D "$headers_file" -o "$body_file" \
    "${curl_headers[@]}" \
    --data "$payload" "$mcp_url"
}

json_response() {
  if head -c 1 "$body_file" | grep -q '{'; then cat "$body_file"
  else sed -n 's/^data:[[:space:]]*//p' "$body_file" | tail -n 1
  fi
}

if [[ -n "$bootstrap_file" ]]; then
  bootstrap="$(cat "$bootstrap_file")"
else
  command -v curl >/dev/null || { echo 'curl is required.' >&2; exit 1; }
  command -v jq >/dev/null || { echo 'jq is required.' >&2; exit 1; }
  base_url="$(resolve_base_url "$domain")"
  if [[ -z "$token" ]]; then
    command -v openssl >/dev/null || { echo 'openssl is required for interactive OAuth.' >&2; exit 1; }
    command -v python3 >/dev/null || { echo 'python3 is required for the OAuth callback.' >&2; exit 1; }
    token="$(get_oauth_token "$base_url")" || exit 1
  fi

  mcp_url="$base_url/mcp/knowledge"
  headers_file="$(mktemp)"
  body_file="$(mktemp)"
  trap 'rm -f "$headers_file" "$body_file" "${output_file:-}"' EXIT
  session_id=""
  protocol_version=""

  mcp_post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"knowledge-sync","version":"0.1.0"}}}'
  initialize="$(json_response)"
  protocol_version="$(jq -er '.result.protocolVersion' <<<"$initialize")"
  session_id="$(awk 'BEGIN{IGNORECASE=1} /^MCP-Session-Id:/ {sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$headers_file")"

  mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"bootstrap_context","arguments":{}}}'
  called="$(json_response)"
  [[ "$(jq -r '.result.isError // false' <<<"$called")" != true ]] || { echo 'bootstrap_context returned an MCP tool error.' >&2; exit 1; }
  bootstrap="$(jq -er '[.result.content[] | select(.type == "text") | .text] | join("")' <<<"$called")"
fi

[[ -n "${bootstrap//[[:space:]]/}" ]] || { echo 'Refusing to install an empty bootstrap.' >&2; exit 1; }
[[ "$bootstrap" != *"$start_marker"* && "$bootstrap" != *"$end_marker"* ]] || { echo 'Bootstrap contains reserved markers.' >&2; exit 1; }

targets=()
if [[ -n "$target" ]]; then
  targets+=("$target")
else
  if codex_detected; then targets+=("$(codex_home)/AGENTS.md"); fi
  if claude_detected; then targets+=("$(claude_home)/CLAUDE.md"); fi
  if [[ "${#targets[@]}" -eq 0 ]] && ! cursor_detected; then
    echo 'No Codex, Claude, or Cursor installation was detected. Install one, set its configuration directory, or pass --target explicitly.' >&2
    exit 1
  fi
fi

# Keep the explicit target separate from iteration: it disables account-rule writes.
# Skill conflicts stop the run before other configuration is changed.
if [[ -z "$target" && "$install_skills" == 1 ]]; then
  install_knowledge_skill
fi
for output_target in ${targets[@]+"${targets[@]}"}; do
  write_agents_file "$output_target"
done

if [[ "$dry_run" != 1 && "$install_alias" == 1 ]]; then
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh) rc_file="$HOME/.zshrc" ;;
    *) rc_file="$HOME/.bashrc" ;;
  esac
  rc_file="${KNOWLEDGE_SYNC_RC:-$rc_file}"
  alias_start='# KNOWLEDGE-SYNC:BEGIN'
  alias_end='# KNOWLEDGE-SYNC:END'
  escaped_domain="${domain//\'/\'\\\'\'}"
  alias_file="$(mktemp)"
  cat > "$alias_file" <<EOF
$alias_start
knowledge-sync() {
  curl -fsSL https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.sh | bash -s -- --domain '$escaped_domain' --no-alias "\$@"
}
$alias_end
EOF
  touch "$rc_file"
  rc_output="$(mktemp)"
  awk -v start="$alias_start" -v end="$alias_end" -v block="$alias_file" '
    $0 == start { while ((getline line < block) > 0) print line; skip=1; found=1; next }
    $0 == end { skip=0; next }
    !skip { print }
    END { if (!found) { print ""; while ((getline line < block) > 0) print line } }
  ' "$rc_file" > "$rc_output"
  mv -f "$rc_output" "$rc_file"
  rm -f "$alias_file"
  echo "Persistent command installed in [$rc_file]. Open a new shell, then run: knowledge-sync"
fi

if [[ "$install_codex_mcp" == 1 ]]; then
  install_codex_mcp_server "$(resolve_base_url "$domain")/mcp/knowledge"
fi

if [[ "$install_claude_mcp" == 1 ]]; then
  install_claude_mcp_server "$(resolve_base_url "$domain")/mcp/knowledge"
fi

if [[ "$install_cursor_mcp" == 1 ]]; then
  install_cursor_mcp_server "$(resolve_base_url "$domain")/mcp/knowledge"
fi

if [[ -z "$target" && "$install_cursor_rule" == 1 ]]; then
  install_cursor_user_rule
fi

if [[ -n "$target" ]]; then
  echo 'Explicit target supplied: native skill installation was skipped.'
elif [[ "$install_skills" == 0 ]]; then
  echo 'Knowledge maintenance skill installation was explicitly skipped.'
fi
