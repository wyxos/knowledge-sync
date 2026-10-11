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
