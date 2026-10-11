import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("knowledge_skill", ROOT / "knowledge_skill.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
FILES = {"SKILL.md": "---\nname: knowledge-maintenance\ndescription: Maintain records.\n---\n\nCafé — 知识\n",
         "references/records.md": "Read the destination, preserve facts.\n"}


class SkillTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.config = dict(home=str(self.root), codex_home=str(self.root / "codex-custom"),
                           claude_home=str(self.root / "claude-custom"), cursor_home=str(self.root / "cursor-custom"),
                           base_url="https://knowledge.example.test", detected=dict(codex=True, claude=True, cursor=True))
        self.shared = self.root / ".agents/skills/knowledge-maintenance"
        self.claude = self.root / "claude-custom/skills/knowledge-maintenance"

    def install(self, files=FILES):
        return module.install_skill(self.config, files)

    def snapshot(self, root):
        return {path.relative_to(root).as_posix(): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in root.rglob("*") if path.is_file()}

    def test_install_update_idempotency_domain_binding_and_custom_roots(self):
        self.assertEqual(self.install(), [self.shared, self.claude])
        self.assertFalse((self.root / "codex-custom/skills").exists())
        self.assertFalse((self.root / "cursor-custom/skills").exists())
        for target in (self.shared, self.claude):
            self.assertEqual((target / "SKILL.md").read_text(encoding="utf-8"), FILES["SKILL.md"])
            service = json.loads((target / "references/service.json").read_text())
            self.assertEqual(service["mcp_url"], "https://knowledge.example.test/mcp/knowledge")
        before = self.snapshot(self.root)
        self.install()
        self.assertEqual(self.snapshot(self.root), before)
        updated = {"SKILL.md": FILES["SKILL.md"] + "New version.\n", "references/added.md": "New reference.\n"}
        self.install(updated)
        self.assertFalse((self.shared / "references/records.md").exists())
        self.assertEqual((self.shared / "references/added.md").read_text(), "New reference.\n")
        self.config["base_url"] = "https://other.example.test"
        self.install(updated)
        self.assertEqual(json.loads((self.shared / "references/service.json").read_text())["base_url"],
                         "https://other.example.test")

    def test_local_edits_missing_files_and_extra_files_block_all_targets(self):
        for mutation in ("edit", "remove", "extra", "directory", "binding"):
            with self.subTest(mutation=mutation):
                self.install()
                if mutation == "edit":
                    (self.claude / "SKILL.md").write_text("Personal edits")
                elif mutation == "remove":
                    (self.claude / "references/records.md").unlink()
                elif mutation == "extra":
                    (self.claude / "personal.md").write_text("Keep this")
                elif mutation == "directory":
                    (self.claude / "personal-directory").mkdir()
                else:
                    (self.claude / "references/service.json").write_text("{}")
                before = self.snapshot(self.root)
                with self.assertRaisesRegex(RuntimeError, "local edits"):
                    self.install(dict(FILES, **{"SKILL.md": "New"}))
                self.assertEqual(self.snapshot(self.root), before)
                shutil.rmtree(self.shared)
                shutil.rmtree(self.claude)

    def test_unmanaged_and_invalid_manifest_conflicts_are_preserved(self):
        self.claude.mkdir(parents=True)
        (self.claude / "SKILL.md").write_text("Personal guidance")
        with self.assertRaisesRegex(RuntimeError, "Unmanaged"):
            self.install()
        self.assertFalse(self.shared.exists())
        for manifest in ("{", "null", '{"owner":"another"}', '{"owner":"wyxos/knowledge-sync","schema":1,"files":[]}'):
            (self.claude / module.MANIFEST).write_text(manifest)
            with self.assertRaisesRegex(RuntimeError, "manifest"):
                self.install()
            self.assertEqual((self.claude / "SKILL.md").read_text(), "Personal guidance")

    def test_alternate_legacy_copy_is_reported_without_duplicates(self):
        legacy = self.root / "codex-custom/skills/knowledge-maintenance"
        legacy.mkdir(parents=True)
        (legacy / "SKILL.md").write_text("Old personal copy")
        with self.assertRaisesRegex(RuntimeError, "Another Knowledge skill"):
            self.install()
        self.assertFalse(self.shared.exists())

    def test_nested_same_name_skill_is_reported_without_duplicates(self):
        existing = self.root / "cursor-custom/skills/category/custom-directory"
        existing.mkdir(parents=True)
        (existing / "SKILL.md").write_text(FILES["SKILL.md"], encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Another Knowledge skill"):
            self.install()
        self.assertFalse(self.shared.exists())

    @unittest.skipUnless(sys.platform == "win32", "Windows junction semantics")
    def test_windows_junction_skill_roots_are_shared_and_leaf_junctions_blocked(self):
        self.shared.parent.mkdir(parents=True)
        self.claude.parent.parent.mkdir()
        def junction(link, target):
            # Arguments are data; no interpolated shell command or cmd deletion.
            fixture_script = self.root / "junction.ps1"
            fixture_script.write_text('param([string] $LinkPath, [string] $TargetPath)\n$ErrorActionPreference = "Stop"\nNew-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null\n')
            result = subprocess.run(["pwsh", "-NoProfile", "-File", str(fixture_script),
                str(link), str(target)], capture_output=True, text=True)
            if result.returncode and "Access is denied" in result.stderr:
                self.skipTest("Native junction creation denied by the sandbox.")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        junction(self.claude.parent, self.shared.parent)
        self.assertEqual(self.install(), [self.shared])
        self.assertEqual((self.claude / "SKILL.md").read_text(encoding="utf-8"), FILES["SKILL.md"])
        self.claude.parent.rmdir()  # Removes only the junction, never its target.
        self.claude.parent.mkdir()
        junction(self.claude, self.shared)
        with self.assertRaisesRegex(RuntimeError, "link"):
            self.install()
        self.claude.rmdir()
        alias = self.shared.parent / "different-alias"
        junction(alias, self.shared)
        with self.assertRaisesRegex(RuntimeError, "Another Knowledge skill"):
            self.install()
        alias.rmdir()

    def test_unrelated_invalid_encoding_does_not_block_setup(self):
        unrelated = self.root / ".agents/skills/unrelated"
        unrelated.mkdir(parents=True)
        (unrelated / "SKILL.md").write_bytes(b"\xff unrelated")
        self.install()
        self.assertEqual((unrelated / "SKILL.md").read_bytes(), b"\xff unrelated")

    def symlink(self, source, target):
        try:
            source.symlink_to(target, target_is_directory=target.is_dir())
        except OSError as error:
            self.skipTest("Native symlink creation unavailable: " + str(error))

    def test_leaf_link_and_linked_payload_file_are_preserved(self):
        outside = self.root / "private-source"
        outside.mkdir()
        (outside / "SKILL.md").write_text("Private source")
        self.shared.parent.mkdir(parents=True)
        self.symlink(self.shared, outside)
        with self.assertRaisesRegex(RuntimeError, "link"):
            self.install()
        self.assertEqual((outside / "SKILL.md").read_text(), "Private source")
        self.shared.unlink()
        self.install()
        (self.shared / "references/records.md").unlink()
        self.symlink(self.shared / "references/records.md", outside / "SKILL.md")
        with self.assertRaisesRegex(RuntimeError, "link"):
            self.install()

    def test_shared_native_skill_root_link_is_deduplicated(self):
        self.shared.parent.mkdir(parents=True)
        claude_root = self.claude.parent
        claude_root.parent.mkdir()
        self.symlink(claude_root, self.shared.parent)
        self.assertEqual(self.install(), [self.shared])
        self.assertEqual((self.claude / "SKILL.md").read_text(encoding="utf-8"), FILES["SKILL.md"])
        self.install()

    def test_linked_same_name_skill_alias_is_reported(self):
        outside = self.root / "personal-source"
        outside.mkdir()
        (outside / "SKILL.md").write_text(FILES["SKILL.md"], encoding="utf-8")
        self.shared.parent.mkdir(parents=True)
        self.symlink(self.shared.parent / "different-alias", outside)
        with self.assertRaisesRegex(RuntimeError, "Another Knowledge skill"):
            self.install()
        self.assertFalse(self.shared.exists())

    def test_dry_run_and_unsupported_harness_never_create_skill_directories(self):
        self.config["dry_run"] = True
        self.install()
        self.assertEqual(list(self.root.iterdir()), [])
        self.config["detected"] = {}
        with self.assertRaisesRegex(RuntimeError, "No supported"):
            self.install()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_payload_traversal_reserved_paths_and_credential_urls_rejected(self):
        for name in ("../private.md", "/private.md", "C:/private.md", "foo\\private.md", "references/service.json", module.MANIFEST):
            with self.assertRaisesRegex(RuntimeError, "unsafe"):
                self.install(dict(FILES, **{name: "No"}))
        self.config["base_url"] = "https://user:secret@knowledge.example.test"
        with self.assertRaisesRegex(RuntimeError, "without credentials"):
            self.install()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_failed_directory_swap_restores_previous_install(self):
        self.install()
        before = self.snapshot(self.root)
        rename = Path.rename
        def fail_staging(path, destination):
            if path.name.startswith(".knowledge-sync-stage-"):
                raise OSError("Fixture swap failure")
            return rename(path, destination)
        with patch.object(Path, "rename", fail_staging):
            with self.assertRaisesRegex(OSError, "swap failure"):
                self.install(dict(FILES, **{"SKILL.md": "Updated"}))
        self.assertEqual(self.snapshot(self.root), before)
        self.assertFalse(any(path.name.startswith(".knowledge-sync-") for path in self.shared.parent.iterdir()))

    def test_failed_swap_and_rollback_keeps_recoverable_previous_install(self):
        self.install()
        original = self.snapshot(self.shared)
        rename = Path.rename
        def fail_both(path, destination):
            if path.name.startswith((".knowledge-sync-stage-", ".knowledge-sync-backup-")):
                raise OSError("Fixture swap/rollback failure")
            return rename(path, destination)
        with patch.object(Path, "rename", fail_both):
            with self.assertRaisesRegex(RuntimeError, "previous installation is preserved") as raised:
                self.install(dict(FILES, **{"SKILL.md": "Updated"}))
        backups = list(self.shared.parent.glob(".knowledge-sync-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertIn(str(backups[0]), str(raised.exception))
        self.assertEqual(self.snapshot(backups[0]), original)
        backups[0].rename(self.shared)

    def test_installers_embed_current_payload_and_helper(self):
        subprocess.run([sys.executable, str(ROOT / "tools/embed_knowledge_skill.py"), "--check"], check=True)


class StandaloneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.env = dict(os.environ, HOME=str(self.root), USERPROFILE=str(self.root),
                        CODEX_HOME=str(self.root / "codex-custom"), CLAUDE_CONFIG_DIR=str(self.root / "claude-custom"),
                        CURSOR_HOME=str(self.root / "cursor-custom"), CURSOR_USER_DATA_DIR=str(self.root / "cursor-data"))
        for name in ("codex-custom", "claude-custom", "cursor-custom"):
            (self.root / name).mkdir()
        self.bootstrap = self.root / "bootstrap.md"
        self.bootstrap.write_text("# Synthetic bootstrap\n", encoding="utf-8")
        self.shared = self.root / ".agents/skills/knowledge-maintenance"

    def command(self):
        if sys.platform == "win32":
            # Verify the child resolves its own fixture home before invoking the
            # installer. Tests must never install into the real Windows profile.
            result = subprocess.run(["pwsh", "-NoProfile", "-Command", "$HOME"], env=self.env, capture_output=True, text=True)
            self.assertEqual(Path(result.stdout.strip()), self.root)
            source = ROOT / "install.ps1"
            downloaded = self.root / "downloaded.ps1"
            shutil.copyfile(source, downloaded)
            return ["pwsh", "-NoProfile", "-File", str(downloaded), "-BootstrapFile", str(self.bootstrap),
                    "-Domain", "knowledge.example.test", "-NoAlias", "-NoCodexMcp", "-NoClaudeMcp", "-NoCursorMcp", "-NoCursorRule"]
        downloaded = self.root / "downloaded.sh"
        shutil.copyfile(ROOT / "install.sh", downloaded)
        return ["bash", str(downloaded), "--bootstrap-file", str(self.bootstrap), "--domain", "knowledge.example.test",
                "--no-alias", "--no-codex-mcp", "--no-claude-mcp", "--no-cursor-mcp", "--no-cursor-rule"]

    def run_installer(self, command, extra=(), success=True, stdin=None):
        result = subprocess.run(command + list(extra), input=stdin, env=self.env, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_downloaded_install_preview_idempotency_and_conflict(self):
        command = self.command()
        preview = "-WhatIf" if sys.platform == "win32" else "--dry-run"
        self.run_installer(command, [preview])
        self.assertFalse(self.shared.exists())
        self.run_installer(command)
        expected = (ROOT / "skills/knowledge-maintenance/SKILL.md").read_text(encoding="utf-8")
        self.assertEqual((self.shared / "SKILL.md").read_text(encoding="utf-8"), expected)
        first = (self.shared / module.MANIFEST).stat().st_mtime_ns
        self.run_installer(command)
        self.assertEqual((self.shared / module.MANIFEST).stat().st_mtime_ns, first)
        (self.shared / "SKILL.md").write_text("Preserve personal edits")
        self.bootstrap.write_text("# Changed bootstrap")
        result = self.run_installer(command, success=False)
        self.assertIn("local edits", result.stdout + result.stderr)
        self.assertEqual((self.root / "codex-custom/AGENTS.md").read_text().count("Changed bootstrap"), 0)
        self.assertEqual((self.shared / "SKILL.md").read_text(), "Preserve personal edits")
        skip = "-NoSkills" if sys.platform == "win32" else "--no-skills"
        self.run_installer(command, [skip])
        self.assertIn("Changed bootstrap", (self.root / "codex-custom/AGENTS.md").read_text())

    def test_explicit_target_skips_skills(self):
        command = self.command()
        target = "-Target" if sys.platform == "win32" else "--target"
        self.run_installer(command, [target, str(self.root / "custom.md")])
        self.assertFalse(self.shared.exists())
        self.assertFalse((self.root / "claude-custom/skills").exists())

    @unittest.skipUnless(sys.platform == "win32", "Native PowerShell persistent command")
    def test_persisted_powershell_command_forwards_named_flags_and_preview(self):
        command = self.command()  # Check child fixture home before using it.
        self.run_installer(["pwsh", "-NoProfile", "-File", str(ROOT / "tests/fixtures/powershell_alias.ps1"),
                            str(ROOT / "install.ps1"), str(self.root)])

    def test_piped_installer_is_standalone(self):
        if sys.platform == "win32":
            self.command()  # Check fixture home before running piped code.
            source = (ROOT / "install.ps1").read_text(encoding="utf-8")
            for variable in ("NoAlias", "NoCodexMcp", "NoClaudeMcp", "NoCursorMcp", "NoCursorRule"):
                source = source.replace("[switch] $" + variable, "[switch] $" + variable + " = $true")
            source = source.replace("[string] $BootstrapFile,", "[string] $BootstrapFile = '" + str(self.bootstrap).replace("'", "''") + "',")
            self.run_installer(["pwsh", "-NoProfile", "-Command", "$input | Out-String | Invoke-Expression"], stdin=source)
        else:
            command = self.command()
            self.run_installer(["bash", "-s", "--"] + command[2:], stdin=(ROOT / "install.sh").read_text(encoding="utf-8"))
        self.assertTrue((self.shared / "SKILL.md").is_file())


if __name__ == "__main__":
    unittest.main()
