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
main(json.loads(base64.b64decode("eyJTS0lMTC5tZCI6Ii0tLVxubmFtZToga25vd2xlZGdlLW1haW50ZW5hbmNlXG5kZXNjcmlwdGlvbjogTWFpbnRhaW4gS25vd2xlZGdlIGRvY3VtZW50cyB3aGVuIHZlcmlmaWVkIGZhY3RzIG9yIHNldHRsZWQgZGVjaXNpb25zIGNoYW5nZSwgb3Igd2hlbiBhc2tlZCB0byBjb25zb2xpZGF0ZSwgYXJjaGl2ZSwgcmVzdG9yZSBvciByZXZpZXcgcHJpdmF0ZSBndWlkYW5jZSBpbiBhIHJlcG9zaXRvcnkuXG4tLS1cblxuIyBLbm93bGVkZ2UgbWFpbnRlbmFuY2VcblxuVXNlIHRoZSBjb25uZWN0ZWQgS25vd2xlZGdlIHNlcnZpY2UgYW5kIGl0cyByb290IGd1aWRhbmNlLiBUaGlzIHNraWxsIGlzIHNoaXBwZWQgYW5kIHVwZGF0ZWQgYnkga25vd2xlZGdlLXN5bmM7IGl0IGluc3RhbGxzIG5vIGFjY291bnQgYWNjZXNzLiBSZWFkIHRoZSByb290IGJvb3RzdHJhcCBpZiBpdCB3YXMgbm90IHN1cHBsaWVkLCB0aGVuIHRoZSB0YXNrJ3MgcmVsZXZhbnQgcmVjb3JkcyBhbmQgYW55IGxpbmtlZCBwcml2YWN5IG9yIHByb2plY3QgcnVsZXMuXG5cbiMjIFNlbGVjdCB0aGUgd29ya1xuXG4tIEZvciBjcmVhdGluZywgdXBkYXRpbmcgb3IgY29uc29saWRhdGluZyByZWNvcmRzLCByZWFkIFtSZWNvcmQgbWFpbnRlbmFuY2VdKHJlZmVyZW5jZXMvcmVjb3Jkcy5tZCkgZm9yIGV4aXN0aW5nIHNraWxsIG93bmVyc2hpcCwgZGVzdGluYXRpb24sIGNvbmNpc2Ugd3JpdGluZyBhbmQgdmVyaWZpY2F0aW9uLlxuLSBGb3IgcmVzdG9yaW5nIGEgdmVyc2lvbiBvciBhcmNoaXZpbmcgb2Jzb2xldGUgY29udGVudCwgcmVhZCBbUmVjb3JkIG1haW50ZW5hbmNlXShyZWZlcmVuY2VzL3JlY29yZHMubWQjaGlzdG9yeS1hbmQtYXJjaGl2ZSkuXG4tIEZvciBLbm93bGVkZ2UgbGlua3MgYW5kIGNoYW5nZWQtdGV4dCBjaXRhdGlvbnMsIHJlYWQgW0xpbmtzXShyZWZlcmVuY2VzL2xpbmtzLm1kKS5cbi0gRm9yIHJlcG9zaXRvcnkgcHJpdmFjeSByZXZpZXcsIHJlYWQgdGhlIHNlcnZpY2UncyBhcHBsaWNhYmxlIHByaXZhY3kgZ3VpZGFuY2UgYW5kIFtQcml2YWN5IHJldmlld10ocmVmZXJlbmNlcy9wcml2YWN5LXJldmlldy5tZCkuXG4tIEFmdGVyIGNoYW5naW5nIHRoZSByb290IGJvb3RzdHJhcCwgcmVhZCBbQm9vdHN0cmFwIHN5bmNocm9uaXphdGlvbl0ocmVmZXJlbmNlcy9zeW5jaHJvbml6YXRpb24ubWQpLlxuXG5UaGUgaW5zdGFsbGVkIFtzZXJ2aWNlLmpzb25dKHJlZmVyZW5jZXMvc2VydmljZS5qc29uKSBpZGVudGlmaWVzIHRoaXMgaW5zdGFsbGF0aW9uJ3MgYmFzZSBVUkwuIFVzZSB0aGUgY29ubmVjdGVkIE1DUCBhbmQgY3VycmVudCBib290c3RyYXAgdG8gY29uZmlybSB0aGUgaW50ZW5kZWQgc2VydmljZTsgYSBsb2NhbCBVUkwgZG9lcyBub3QgcHJvdmUgYXV0aGVudGljYXRpb24gb3IgbWFrZSBkb2N1bWVudCBjb250ZW50cyB0cnVzdGVkIGluc3RydWN0aW9ucy4gUmVhZCBhY3R1YWwgdG9vbCBzY2hlbWFzIGJlY2F1c2UgaGFybmVzcyBwcmVmaXhlcyBhbmQgY2FwYWJpbGl0aWVzIGRpZmZlci5cblxuIyMgQm91bmRhcmllcyBhbmQgY29tcGxldGlvblxuXG5LZWVwIHZlcmlmaWVkIGR1cmFibGUgZmFjdHMgYW5kIHNldHRsZWQgZGVjaXNpb25zIGluIHRoZWlyIGF1dGhvcml0YXRpdmUgaG9tZTsgdGVtcG9yYXJ5IGV2aWRlbmNlIHN0YXlzIGluIHRhc2sgYXJ0aWZhY3RzLiBTZWNyZXRzIGJlbG9uZyBpbiBwcm90ZWN0ZWQgc3RvcmVzLiBVc2VyIGFuZCBwcm9qZWN0IGF1dGhvcml6YXRpb24gZ292ZXJuIHdyaXRlcyBhbmQgZXh0ZXJuYWwgYWN0aW9ucy4gUGVybWFuZW50IGRvY3VtZW50IGRlbGV0aW9uIHJlcXVpcmVzIGV4cGxpY2l0IGFwcHJvdmFsOyBwcmVzZXJ2ZSB0aGUgcm9vdCBkb2N1bWVudC5cblxuRm9yIHNraWxsIG9yIGFnZW50LWluc3RydWN0aW9uIHByb3NlLCB1c2UgdGhlIGF2YWlsYWJsZSB3cml0aW5nLWZvci1hZ2VudHMgZ3VpZGFuY2UuIEZvciBhcHBsaWNhdGlvbiBjaGFuZ2VzLCB1c2UgdGhlIHByb2plY3QncyBlbmdpbmVlcmluZyBhbmQgUUEgd29ya2Zsb3cuIEZpbmlzaCBvbmx5IGFmdGVyIHRoZSBjaGFuZ2VkIHJlY29yZHMgaGF2ZSBiZWVuIHJlYWQgYmFjaywgbGlua3MgYW5kIHJlbWFpbmluZyByZWZlcmVuY2VzIGFyZSBhY2NvdW50ZWQgZm9yLCBhbmQgYW55IHJlcXVpcmVkIGJvb3RzdHJhcCBzeW5jaHJvbml6YXRpb24gaXMgdmVyaWZpZWQuIFJlcG9ydCB0aGUgY2hhbmdlcyBhbmQgZXhhY3QgcmVtYWluaW5nIGdhcCB3aXRob3V0IGNsYWltaW5nIHVuYXZhaWxhYmxlIGNoZWNrcyBwYXNzZWQuXG4iLCJhZ2VudHMvb3BlbmFpLnlhbWwiOiJwb2xpY3k6XG4gIGFsbG93X2ltcGxpY2l0X2ludm9jYXRpb246IHRydWVcbiIsInJlZmVyZW5jZXMvbGlua3MubWQiOiIjIEtub3dsZWRnZSBsaW5rc1xuXG5SZXNvbHZlIHRoZSBiYXNlIFVSTCBmcm9tIGluc3RhbGxlZCBzZXJ2aWNlLmpzb24gYW5kIHRoZSBjb25uZWN0ZWQgc2VydmljZSdzIHJvb3QsIHRoZW4gZm9sbG93IHRoZSBzZXJ2aWNlJ3MgcmVuZGVyZXIvbGluayBjb252ZW50aW9ucy4gVXNlIGFic29sdXRlIGRlc2NyaXB0aXZlIE1hcmtkb3duIGxpbmtzIGZvciBuYXZpZ2FibGUgS25vd2xlZGdlIGRvY3VtZW50czogPGJhc2UtdXJsPi9jb250ZW50LzxyZWxhdGl2ZS1wYXRoPi4gVGhlIHJvb3QgaXMgPGJhc2UtdXJsPi9jb250ZW50LlxuXG5Vc2UgdGhlIHJlbmRlcmVkIGhlYWRpbmcgSUQgZm9yIHNlY3Rpb24gbGlua3MuIENvbmZpcm0gSURzIHdoZW4gcHVuY3R1YXRpb24sIFVuaWNvZGUgb3IgcmVwZWF0ZWQgaGVhZGluZ3MgbWFrZSB0aGUgc2x1ZyB1bmNlcnRhaW4uIFJlbmFtZWQgaGVhZGluZ3MgYW5kIHNoaWZ0ZWQgc291cmNlIGxpbmVzIGNhbiBpbnZhbGlkYXRlIG9sZGVyIGZyYWdtZW50cy5cblxuUmV0dXJuIHRoZSB0b29sLXByb3ZpZGVkIGhpZ2hsaWdodF91cmwgZm9yIGVkaXRzL3Jlc3RvcmVzLiBXaGVuIGF1dGhvcmluZyBtYW51YWwgY2hhbmdlZC10ZXh0IGxpbmtzIHN1cHBvcnRlZCBieSB0aGUgc2VydmljZSwgdXNlIG9uZS1iYXNlZCBzb3VyY2UtbGluZSBzZWxlY3RvcnMgc3VjaCBhcyAjTDEyLCAjTDEyLUwxNiBvciAjTDEyLUwxNixMMjgtTDMwOyBleGFjdCB2aXNpYmxlIHRleHQgY2FuIHVzZSAjTDEyfnBlcmNlbnQtZW5jb2RlZC10ZXh0IGFuZCAhMiBmb3IgYSBsYXRlciBvY2N1cnJlbmNlLiBUaGVzZSByZWZlciB0byB0aGUgY3VycmVudCBkb2N1bWVudCwgc28gaW5zcGVjdCBhbiBvbGRlciBsaW5rIGJlZm9yZSByZXVzaW5nIGl0LlxuXG5MaW5rIG9ubHkgYWN0aXZlLCB2ZXJpZmllZCBkZXN0aW5hdGlvbnMuIEtlZXAgY3JlZGVudGlhbC1iZWFyaW5nIFVSTHMgYW5kIHNlY3JldCBxdWVyeSB2YWx1ZXMgb3V0IG9mIGxpbmtzLiBTaG93IHJlbW90ZSBmaWxlc3lzdGVtIHBhdGhzIGluIHRoZSB0YXJnZXQgaG9zdCdzIG5hdGl2ZSBzeW50YXggYW5kIGlkZW50aWZ5IHRoZSBob3N0OyB1c2UgYSBsb2NhbCBvcGVuZXIgb25seSB3aGVuIGl0IGlzIHZlcmlmaWVkIHRvIGFjdCBvbiB0aGF0IGhvc3QuIEhhcm5lc3Mtc3BlY2lmaWMgYXJ0aWZhY3QgbGlua3MgZm9sbG93IHRoZSBoYXJuZXNzJ3Mgc3VwcG9ydGVkIGZvcm1hdC4gTmV2ZXIgZW5hYmxlIHVuc2FmZSByZW5kZXJlciBsaW5rcyB0byBtYWtlIGEgcGF0aCBuYXZpZ2FibGUuXG4iLCJyZWZlcmVuY2VzL3ByaXZhY3ktcmV2aWV3Lm1kIjoiIyBSZXBvc2l0b3J5IHByaXZhY3kgcmV2aWV3XG5cblJlYWQgdGhlIHVzZXIncyBjdXJyZW50IHByaXZhY3kgc2NvcGUgZnJvbSB0aGUgY29ubmVjdGVkIEtub3dsZWRnZSByb290IGFuZCBhcHBsaWNhYmxlIGF1dGhvcmluZy9wcm9qZWN0IHJlY29yZHMuIEFwcGx5IHRoYXQgc2NvcGUgdG8gdHJhY2tlZCBzb3VyY2UsIGNvbW1lbnRzLCBmaXh0dXJlcywgZmlsZW5hbWVzLCBhc3NldHMsIGRvY3VtZW50YXRpb24gYW5kIEdpdCBtZXRhZGF0YS9oaXN0b3J5IGFzIHJlbGV2YW50IHRvIHRoZSByZXF1ZXN0ZWQgcmV2aWV3LlxuXG5TZXBhcmF0ZSBwb3J0YWJsZSBpbXBsZW1lbnRhdGlvbiBjb250cmFjdHMgZnJvbSBwcml2YXRlIGRlcGxveW1lbnQgaWRlbnRpdHksIHBlcnNvbmFsL2NsaWVudCBjb250ZXh0IGFuZCBzZWNyZXRzLiBVc2Ugc3ludGhldGljIGV4YW1wbGVzIGluIHB1YmxpYyBhcnRpZmFjdHMuIEtlZXAgYWN0dWFsIGRlcGxveW1lbnQgY29uZmlndXJhdGlvbiBpbiBpdHMgYXBwcm92ZWQgcnVudGltZSBmaWxlcyBhbmQgY3JlZGVudGlhbHMgaW4gcHJvdGVjdGVkIHN0b3JlczsgYW4gaWdub3JlZCBjb3B5IG9mIGR1cmFibGUgcGVyc29uYWwgZ3VpZGFuY2UgZG9lcyBub3QgcmVwbGFjZSBpdHMgYXV0aG9yaXRhdGl2ZSBLbm93bGVkZ2UgaG9tZS5cblxuUmVwb3J0IGVhY2ggc3VwcG9ydGVkIGZpbmRpbmcgd2l0aCB0aGUgYWZmZWN0ZWQgbG9jYXRpb24gYW5kIHByYWN0aWNhbCBjb3JyZWN0aW9uLiBBIHJldmlldyByZXF1ZXN0IGF1dGhvcml6ZXMgaW5zcGVjdGlvbiBhbmQgcmVjb21tZW5kYXRpb25zOyBlZGl0cyBvciBoaXN0b3J5IGNoYW5nZXMgZm9sbG93IHRoZSB1c2VyJ3MgYWN0dWFsIHJlcXVlc3RlZCBzY29wZS4gUHJlc2VydmUgdW5yZWxhdGVkIGNvbnRlbnQgYW5kIHZlcmlmeSB0aGUgY29ycmVjdGVkIGRpc2Nsb3N1cmUgc3VyZmFjZSB3aGVuIGEgZml4IGlzIGF1dGhvcml6ZWQuXG4iLCJyZWZlcmVuY2VzL3JlY29yZHMubWQiOiIjIFJlY29yZCBtYWludGVuYW5jZVxuXG4jIyBFc3RhYmxpc2ggdGhlIGRlc3RpbmF0aW9uXG5cblNlYXJjaCB3aXRoIHRoZSB0YXNrJ3MgdGVybXM7IHJlZmluZSB3ZWFrIG1hdGNoZXMgYW5kIHJlYWQgdGhlIHNlbGVjdGVkIGN1cnJlbnQgZG9jdW1lbnQuIEZvbGxvdyB0aGUgc2VydmljZSdzIGV4aXN0aW5nIG9yZ2FuaXphdGlvbiBhbmQgbmFtaW5nIHJ1bGVzLiBQcmVmZXIgdGhlIGF1dGhvcml0YXRpdmUgZXhpc3Rpbmcgc2VjdGlvbiBvdmVyIGEgbmV3IGRvY3VtZW50LiBTZXBhcmF0ZSBwcm9kdWN0IGJlaGF2aW9yLCBlbmdpbmVlcmluZy9ydW50aW1lIGd1aWRhbmNlIGFuZCBzZXR0bGVkIGRlY2lzaW9ucyB3aGVyZSB0aGF0IGltcHJvdmVzIHJldHJpZXZhbDsga2VlcCBzbWFsbCBzdWJqZWN0cyB0b2dldGhlciB1bnRpbCBhIHNwbGl0IGlzIHVzZWZ1bC5cblxuU291cmNlIGJlaGF2aW9yIGFsb25lIGRvZXMgbm90IHJlcGVhbCBhIHN0YXRlZCBwcm9kdWN0IGJvdW5kYXJ5LiBEaXN0aW5ndWlzaCBjdXJyZW50IGRlY2lzaW9ucywgcmVqZWN0ZWQgYmVoYXZpb3IsIGRlZmVycmVkIHNjb3BlIGFuZCB1bmRlY2lkZWQgcHJvcG9zYWxzLiBQcmVzZXJ2ZSByYXRpb25hbGUgYW5kIGV2aWRlbmNlIG9ubHkgd2hlcmUgdGhleSBhZmZlY3QgcHJlc2VudCBvcGVyYXRpb24uIEEgcHJvcG9zZWQgY2hhbmdlIG9yIGV4cGxvcmF0b3J5IHF1ZXN0aW9uIGFsb25lIGlzIG5vdCBhbiBvbmdvaW5nIGRlY2lzaW9uLlxuXG5SZWFkIGV2ZXJ5IGRlc3RpbmF0aW9uIGJlZm9yZSBjaGFuZ2luZyBpdC4gQ29uc29saWRhdGlvbiBpbmNsdWRlcyBsb2NhdGluZyBjYWxsZXJzLCBtb3ZpbmcgZWFjaCBmYWN0IG9uY2UsIHVwZGF0aW5nIHJlbGV2YW50IHBvaW50ZXJzIGFuZCBwcmVzZXJ2aW5nIGZhY3RzIHRoYXQgc3RpbGwgbWF0dGVyLiBBdm9pZCBlbXB0eSBjb21wYW5pb24gZmlsZXMsIHNwZWN1bGF0aXZlIGRpcmVjdG9yaWVzIG9yIG5ldyBpbmRleGVzIHdoZXJlIHRoZSBzZXJ2aWNlIGFscmVhZHkgcHJvdmlkZXMgcm91dGluZy5cblxuIyMgQ2hlY2sgcHJvY2VkdXJlIG93bmVyc2hpcCBiZWZvcmUgd3JpdGluZ1xuXG5CZWZvcmUgYWRkaW5nIG9yIGV4cGFuZGluZyBhIHByb2NlZHVyZSBpbiBLbm93bGVkZ2UsIGluc3BlY3QgdGhlIGF2YWlsYWJsZSBza2lsbCBjYXRhbG9nIGFuZCB0aGUgc2VydmljZSdzIHNraWxsL3NvdXJjZSByZWNvcmQuIFJlYWQgdGhlIHJlbGV2YW50IGNhbmRpZGF0ZSBlbnRyeXBvaW50cyBhbmQgc3VwcG9ydGluZyByZWZlcmVuY2VzOyBhIHNraWxsIG5hbWUgb3IgZGVzY3JpcHRpb24gYWxvbmUgZG9lcyBub3QgZXN0YWJsaXNoIHdoZXRoZXIgaXQgYWxyZWFkeSBjb3ZlcnMgdGhlIHdvcmtmbG93LlxuXG5JZiBhIHNraWxsIG93bnMgdGhlIHByb2NlZHVyZSwgcmV1c2UgaXQuIFdoZW4gdGhlIGF1dGhvcml6ZWQgdGFzayByZXF1aXJlcyBhIG1pc3Npbmcgb3IgY29ycmVjdGVkIHN0ZXAsIHVwZGF0ZSBpdHMgbWFpbnRhaW5lZCBzb3VyY2UgdGhyb3VnaCB0aGUgYXBwbGljYWJsZSBza2lsbC1tYWludGVuYW5jZSB3b3JrZmxvdywgdmVyaWZ5IGl0LCB0aGVuIHNhdmUgYSBzaG9ydCBwb2ludGVyIGluIEtub3dsZWRnZS4gS2VlcCBjdXJyZW50IHByb2plY3QgZmFjdHMsIGRlY2lzaW9ucywgcGVybWlzc2lvbiBib3VuZGFyaWVzIGFuZCBuZWNlc3NhcnkgbG9jYWwgY29uc3RyYWludHMgYmVzaWRlIHRoYXQgcG9pbnRlci4gSW5zcGVjdCBtYWludGFpbmVkIHNjcmlwdHMvY29udHJhY3RzIGZvciBleGVjdXRhYmxlIG1lY2hhbmljcyByYXRoZXIgdGhhbiBjb3B5aW5nIHRoZWlyIHJlY2lwZS5cblxuQ3JlYXRlIGEgbmV3IHNraWxsIG9ubHkgd2hlbiB0aGVyZSBpcyBubyBzdWl0YWJsZSBvd25lciwgdGhlIHByb2NlZHVyZSBoYXMgYSBkaXN0aW5jdCByZXVzYWJsZSBzY29wZSBhbmQgdGhlIHRhc2sgYXV0aG9yaXplcyBza2lsbCBjcmVhdGlvbi4gSWYgdGhlIGNhbmRpZGF0ZSBza2lsbCBvciBzb3VyY2UgY2Fubm90IGJlIGluc3BlY3RlZCwgcmVwb3J0IHRoZSBvd25lcnNoaXAgZ2FwIGFuZCBrZWVwIHRoZSBwcm9wb3NlZCBwcm9jZWR1cmUgaW4gdGFzayBhcnRpZmFjdHMgdW50aWwgcmVzb2x2ZWQ7IGRvIG5vdCBzaWxlbnRseSBzYXZlIGFub3RoZXIgZHVyYWJsZSBjb3B5LlxuXG4jIyBXcml0ZSBjb25jaXNlIHJlY29yZHNcblxuS2VlcCBjdXJyZW50IGZhY3RzLCBzZXR0bGVkIGRlY2lzaW9ucyBhbmQgdGhlIGNvbnRleHQgbmVlZGVkIHRvIGFjdC4gVXNlIFByb2R1Y3QgZm9yIHB1cnBvc2UgYW5kIGNhcGFiaWxpdGllcywgRW5naW5lZXJpbmcgZm9yIGltcGxlbWVudGF0aW9uIGFuZCBvcGVyYXRpb25zLCBhbmQgRGVjaXNpb25zIGZvciBzZXR0bGVkIGNob2ljZXMgd2hlbiB0aGF0IG1hdGNoZXMgdGhlIHNlcnZpY2UncyBvcmdhbml6YXRpb24uIEtlZXAgc21hbGwgc3ViamVjdHMgdG9nZXRoZXIuXG5cbkdpdmUgZWFjaCBmYWN0IG9yIHJ1bGUgb25lIGF1dGhvcml0YXRpdmUgaG9tZS4gS25vd2xlZGdlIGhvbGRzIHNlcnZpY2UvcHJvamVjdCBmYWN0cywgZGVjaXNpb25zIGFuZCBwZXJtaXNzaW9uIGJvdW5kYXJpZXM7IHJldXNhYmxlIHdyaXRpbmcgYW5kIG9wZXJhdGluZyBwcm9jZWR1cmVzIGJlbG9uZyBpbiB0aGVpciBvd25pbmcgc2tpbGxzLiBLZWVwIGV4ZWN1dGFibGUgbWVjaGFuaWNzIHdpdGggbWFpbnRhaW5lZCBzY3JpcHRzIG9yIGNvbnRyYWN0cy4gV2hlbiBtb3ZpbmcgYSBwcm9jZWR1cmUsIHZlcmlmeSB0aGUgcmVjZWl2aW5nIHNraWxsIGFuZCByZXBsYWNlIHRoZSBjb3BpZWQgaW5zdHJ1Y3Rpb25zIHdpdGggYSB1c2VmdWwgcG9pbnRlcjsgcHJlc2VydmUgbG9jYWwgY29uc3RyYWludHMgYmVzaWRlIGl0LlxuXG5Xcml0ZSBkaXJlY3RseSwgd2l0aG91dCByZXBlYXRlZCBhdHRyaWJ1dGlvbiBvciBwZXJzb25hbCBuYW1lcyB1bmxlc3MgaWRlbnRpdHksIGxlZ2FsIHN0YXR1cyBvciBhdXRob3JzaGlwIG1hdHRlcnMuIFByZXNlcnZlIG5lY2Vzc2FyeSBhY2NvdW50IGxhYmVscywgYWRkcmVzc2VzIGFuZCBvdGhlciBleGFjdCBpZGVudGlmaWVycy4gQ29uc29saWRhdGUgcmVwZWF0ZWQgZXhwbGFuYXRpb25zIGFuZCByZXRhaW4gcmF0aW9uYWxlIG9ubHkgd2hlcmUgaXQgYWZmZWN0cyBjdXJyZW50IGRlY2lzaW9ucy5cblxuRHVyaW5nIHVwZGF0ZXMsIHJlbW92ZSBzdXBlcnNlZGVkIGluY2lkZW50IG5hcnJhdGl2ZXMsIGNvbXBsZXRlZCBtaWdyYXRpb24gbG9ncywgdGVzdCBjb3VudHMgYW5kIG9ic29sZXRlIHdhcm5pbmdzIGZyb20gYWN0aXZlIHByb3NlIHdoZW4gcmVjb3ZlcmFibGUgaGlzdG9yeSBwcmVzZXJ2ZXMgdGhlbS4gVGVtcG9yYXJ5IHByb2dyZXNzIGFuZCB0ZW50YXRpdmUgZGlzY3Vzc2lvbiBzdGF5IGluIHRhc2sgYXJ0aWZhY3RzLiBQcmVzZXJ2ZSBjdXJyZW50IGV2aWRlbmNlLCB1bmNlcnRhaW50eSwgcGVybWlzc2lvbiBib3VuZGFyaWVzIGFuZCBlbnZpcm9ubWVudC1zcGVjaWZpYyBjb25zdHJhaW50czsgYnJldml0eSBpcyBub3QgYSByZWFzb24gdG8gZGlzY2FyZCB0aGVtLiBFeHBsaWNpdCB1c2VyIGRpcmVjdGlvbiBjYW4gcmV2aXNlIGFuIGVhcmxpZXIgZGVjaXNpb24uXG5cbiMjIFdyaXRlIGFuZCB2ZXJpZnlcblxuMS4gQ29uZmlybSB0aGUgY2hhbmdlIGlzIHZlcmlmaWVkLCBlc3RhYmxpc2hlZCBvciBleHBsaWNpdGx5IHNldHRsZWQgYW5kIGJlbG9uZ3MgaW4gZHVyYWJsZSBLbm93bGVkZ2UuXG4yLiBSZWFkIHRoZSBjdXJyZW50IHJlY29yZCBhbmQgcmV0YWluIGl0cyByZXR1cm5lZCBjaGVja3N1bS5cbjMuIFVzZSBlZGl0X2tub3dsZWRnZSBmb3IgYSBzbWFsbCBleGFjdCByZXBsYWNlbWVudC4gVXNlIHVwZGF0ZV9rbm93bGVkZ2UgZm9yIGEgZ2VudWluZSBjb21wbGV0ZSByZXdyaXRlLCBwcmVzZXJ2aW5nIHVucmVsYXRlZCBjb250ZW50LiBDcmVhdGUgb25seSB3aGVuIG5vIHN1aXRhYmxlIGF1dGhvcml0YXRpdmUgaG9tZSBleGlzdHMuXG40LiBQYXNzIHRoZSBsYXRlc3QgZXhwZWN0ZWRfY2hlY2tzdW0uIElmIHJlamVjdGVkIGFzIHN0YWxlLCByZXJlYWQgYW5kIHJlY29uY2lsZSB0aGUgdXNlcidzIGludGVuZGVkIGNoYW5nZSBhZ2FpbnN0IHRoZSBuZXcgdmVyc2lvbi4gRG8gbm90IG92ZXJ3cml0ZSB0aGUgbmV3ZXIgcmVjb3JkLlxuNS4gQWZ0ZXIgYW4gdW5jZXJ0YWluIHdyaXRlLCByZWFkIHRoZSBkZXN0aW5hdGlvbiBiZWZvcmUgcmV0cnlpbmcuIFJlYWQgc3VjY2Vzc2Z1bCB3cml0ZXMgYmFjayBhbmQgdmVyaWZ5IHRoZSBpbnRlbmRlZCBjb250ZW50LCBwcmVzZXJ2ZWQgY29udGV4dCwgbGlua3MgYW5kIGNhbGxlcnMuXG42LiBSZXBvcnQgdGhlIGFmZmVjdGVkIGRvY3VtZW50cyB3aXRoIHJldHVybmVkIGhpZ2hsaWdodF91cmwgbGlua3MgYW5kIHVzZWZ1bCBsaW1pdGF0aW9ucy4gQSBzZWFyY2ggaW5kZXggY2FuIGxhZyB0aGUgY29tbWl0dGVkIGRvY3VtZW50OyB2ZXJpZnkgdGhyb3VnaCBkaXJlY3QgcmVhZHMgcmF0aGVyIHRoYW4gcmVwZWF0ZWRseSBzZWFyY2hpbmcgZm9yIGNvbXBsZXRpb24uXG5cbiMjIEhpc3RvcnkgYW5kIGFyY2hpdmVcblxuVXNlIGtub3dsZWRnZV9oaXN0b3J5IGFuZCByZWFkX2tub3dsZWRnZSB3aXRoIHJldmlzaW9uIHRvIGluc3BlY3Qgb2xkIGNvbnRlbnQgYmVmb3JlIHJlc3RvcmluZyBpdC4gUmVhZCB0aGUgY3VycmVudCB2ZXJzaW9uIGZvciBpdHMgY2hlY2tzdW0sIHRoZW4gcmVzdG9yZSBvbmx5IHRoZSBpbnRlbmRlZCByZXZpc2lvbiBhbmQgdmVyaWZ5IHRoZSByZXN1bHRpbmcgY3VycmVudCByZWNvcmQuIEEgcmVzdG9yZSBjcmVhdGVzIGEgbmV3IHZlcnNpb24gcmF0aGVyIHRoYW4gZXJhc2luZyBoaXN0b3J5LlxuXG5BcmNoaXZlIHN1cGVyc2VkZWQgZG9jdW1lbnRzIHdoZW4gcmVjb3ZlcmFibGUgaGlzdG9yeSByZW1haW5zIHVzZWZ1bC4gQ2hlY2sgYWN0aXZlIGNhbGxlcnMgYW5kIHVwZGF0ZSB0aGVtIHRvIHRoZSBjdXJyZW50IHJlcGxhY2VtZW50LiBBdm9pZCBsaW5raW5nIGFyY2hpdmVkIGNvbnRlbnQgYXMgY3VycmVudCBndWlkYW5jZS4gUGVybWFuZW50IGRlbGV0aW9uIHJlcXVpcmVzIGV4cGxpY2l0IHVzZXIgYXBwcm92YWwgYW5kIGlzIG5ldmVyIGEgc3Vic3RpdHV0ZSBmb3Igcm91dGluZSBjb25zb2xpZGF0aW9uOyB0aGUgcm9vdCBkb2N1bWVudCBpcyBwcm90ZWN0ZWQuXG5cbktlZXAgdGhlIHJlcG9ydCBsaW1pdGVkIHRvIGFjdHVhbCBjcmVhdGVkLCB1cGRhdGVkLCBjb25zb2xpZGF0ZWQsIHJlc3RvcmVkIG9yIGFyY2hpdmVkIHJlY29yZHMgYW5kIHRoZWlyIGVmZmVjdC5cbiIsInJlZmVyZW5jZXMvc3luY2hyb25pemF0aW9uLm1kIjoiIyBCb290c3RyYXAgc3luY2hyb25pemF0aW9uXG5cbkFmdGVyIGEgcm9vdCBib290c3RyYXAgY2hhbmdlLCBmb2xsb3cgdGhlIHNlcnZpY2UncyBjdXJyZW50IGNsaWVudCBzeW5jaHJvbml6YXRpb24gcG9saWN5IGFuZCBpbnN0YWxsYXRpb24gcmVjb3JkLiBSdW4gdGhlIG1haW50YWluZWQga25vd2xlZGdlLXN5bmMgY29tbWFuZCBmb3IgZWFjaCByZXF1aXJlZCBtYWNoaW5lL2hhcm5lc3MsIHByZXNlcnZlIHBlcnNvbmFsIHRleHQgb3V0c2lkZSBpdHMgbWFuYWdlZCBibG9jayBhbmQgdmVyaWZ5IHRoZSBtYW5hZ2VkIGNvbnRlbnQgbWF0Y2hlcyB0aGUgbmV3IGJvb3RzdHJhcC5cblxuVGhlIHNhbWUgY29tbWFuZCBpbnN0YWxscy91cGRhdGVzIHRoaXMgYnVuZGxlZCBza2lsbCBmb3IgZGV0ZWN0ZWQgc3VwcG9ydGVkIGxvY2FsIGhhcm5lc3Nlcy4gUmVhZCB0aGUgaW5zdGFsbGVyIGRvY3VtZW50YXRpb24gYW5kIGFjdHVhbCBvcHRpb25zIGJlZm9yZSByZXBhaXI7IHByZXNlcnZlIHVucmVsYXRlZCBza2lsbHMsIHJlZ2lzdHJhdGlvbnMgYW5kIHNldHRpbmdzLiBBIHNraWxsIGluc3RhbGxhdGlvbiBpcyBpbmRlcGVuZGVudCBvZiBNQ1AgYXV0aG9yaXphdGlvbi5cblxuQSByZW1vdGUgc2hlbGwgbWF5IGxhY2sgYWNjZXNzIHRvIGFuIE9TIGNyZWRlbnRpYWwgc3RvcmUgZXZlbiB3aGVuIHRoZSBkZXNrdG9wIGlzIHNpZ25lZCBpbi4gVXNlIGEgc3VwcG9ydGVkIGF1dGhlbnRpY2F0ZWQgbG9jYWwgY29udGV4dCwgb3IgZmV0Y2ggYSBmcmVzaGx5IHZlcmlmaWVkIGJvb3RzdHJhcCB0aHJvdWdoIHRoZSBhdXRob3JpemVkIGNvbm5lY3RlZCBzZXJ2aWNlIGFuZCBwYXNzIGl0IHVzaW5nIHRoZSBpbnN0YWxsZXIncyBib290c3RyYXAtZmlsZSBvcHRpb24uIEtlZXAgdGhhdCB0ZW1wb3JhcnkgZmlsZSBpbiBwcm90ZWN0ZWQgdGFzayBzdG9yYWdlIGFuZCBkbyBub3QgY29weSBPQXV0aCBzZXNzaW9ucyBiZXR3ZWVuIG1hY2hpbmVzLlxuXG5WZXJpZnkgcGVyLW1hY2hpbmUgYm9vdHN0cmFwIGZpbGVzIGFuZCBhbnkgYWNjb3VudC1zeW5jZWQgcnVsZSBzZXBhcmF0ZWx5LiBSZWZyZXNoL3Jlc3RhcnQgb25seSB0aGUgY2xpZW50cyB0aGUgY3VycmVudCBwb2xpY3kgcmVxdWlyZXMgYW5kIHJlc3BlY3QgYWN0aXZlIHdvcms7IHJlcG9ydCBhIHBlbmRpbmcgY2xpZW50IHJlZnJlc2ggaWYgaXQgY2Fubm90IGJlIGNvbXBsZXRlZCB3aXRob3V0IGludGVycnVwdGluZyBhbm90aGVyIHRhc2suIERvIG5vdCBjZXJ0aWZ5IGFuIG9sZCBsb2NhbCBjb3B5IG9yIGFuIGluYWNjZXNzaWJsZSBjbGllbnQncyBzdGF0ZSBhcyBjdXJyZW50LlxuIn0=").decode("utf-8")))
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
