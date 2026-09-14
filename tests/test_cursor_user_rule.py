import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cursor_user_rule", ROOT / "cursor_user_rule.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeAPI:
    def __init__(self, rules=None):
        self.rules = copy.deepcopy(rules or [])
        self.writes = []
        self.confirm = True

    def __call__(self, method, payload):
        if method == "KnowledgeBaseList":
            return {"success": True, "allResults": copy.deepcopy(self.rules)}
        self.writes.append((method, payload))
        if method == "KnowledgeBaseAdd":
            if self.confirm:
                self.rules.append({"id": "created", **payload})
            return {"success": True, "id": "created"}
        if self.confirm:
            next(r for r in self.rules if r["id"] == payload["id"]).update(payload)
        return {"success": True}


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.legacy = self.root / "knowledge-mcp.mdc"
        self.backups = self.root / "backups"

    def sync(self, api, bootstrap="# Bootstrap\n\nCafé — 知识"):
        module.sync_rule(bootstrap, api, self.legacy, self.backups)

    def test_create_update_and_reinstall_preserve_personal_rules(self):
        personal = {"id": "personal", "title": "My preference", "knowledge": "Keep this."}
        api = FakeAPI([personal])
        self.sync(api)
        self.sync(api)
        self.assertEqual(len(api.writes), 1)
        api.rules[1]["knowledge"] = "Before\n" + api.rules[1]["knowledge"] + "After\n"
        self.sync(api, "# New bootstrap")
        self.assertEqual(api.rules[0], personal)
        self.assertTrue(api.rules[1]["knowledge"].startswith("Before\n"))
        self.assertTrue(api.rules[1]["knowledge"].endswith("After\n"))
        self.assertEqual(len(list(self.backups.glob("account-rule-*.json"))), 1)

    def test_verified_migration_backs_up_only_generated_file(self):
        old = module.FRONTMATTER + "\n\n" + module.make_block("Old") + "\n"
        self.legacy.write_text(old, encoding="utf-8")
        self.sync(FakeAPI())
        self.assertFalse(self.legacy.exists())
        self.assertEqual(next(self.backups.glob("local-rule-*.mdc")).read_text(encoding="utf-8"), old)

    def test_migration_keeps_personal_content_active(self):
        before, after = "---\nalwaysApply: true\n---\nPersonal before\n", "\nPersonal after\n"
        self.legacy.write_text(before + module.make_block("Old") + after, encoding="utf-8")
        self.sync(FakeAPI())
        self.assertEqual(self.legacy.read_text(encoding="utf-8"), before + after)

    def test_unverified_save_keeps_legacy(self):
        old = module.make_block("Old")
        self.legacy.write_text(old, encoding="utf-8")
        api = FakeAPI()
        api.confirm = False
        with self.assertRaisesRegex(RuntimeError, "read-back"):
            self.sync(api)
        self.assertEqual(self.legacy.read_text(encoding="utf-8"), old)

    def test_conflicts_and_invalid_rules_never_write(self):
        rule = {"id": "one", "title": module.TITLE, "knowledge": module.make_block("Old")}
        cases = [
            [rule, {**rule, "id": "two"}],
            [{**rule, "knowledge": "Personal"}],
            [{**rule, "knowledge": module.START}],
            [{**rule, "isGenerated": True}],
            [{**rule, "knowledge": module.END + module.START}],
            [dict(rule, id=str(i)) for i in range(100)],
        ]
        for rules in cases:
            api = FakeAPI(rules)
            with self.assertRaises(RuntimeError):
                self.sync(api)
            self.assertEqual(api.writes, [])

    def test_empty_and_reserved_bootstrap_never_write(self):
        for bootstrap in (" ", module.START, module.END):
            api = FakeAPI()
            with self.assertRaises(RuntimeError):
                self.sync(api, bootstrap)
            self.assertEqual(api.writes, [])

    def test_missing_sign_in_does_not_create_database(self):
        with patch.object(module, "cursor_data_dir", return_value=self.root):
            with self.assertRaisesRegex(RuntimeError, "sign in"):
                module.access_token()
        self.assertFalse((self.root / "User").exists())

    def test_platform_paths_and_override(self):
        cases = [("win32", {"APPDATA": str(self.root)}, self.root / "Cursor"),
                 ("darwin", {}, Path.home() / "Library/Application Support/Cursor"),
                 ("linux", {"XDG_CONFIG_HOME": str(self.root)}, self.root / "Cursor")]
        for platform, env, expected in cases:
            env.update({"HOME": str(Path.home()), "USERPROFILE": str(Path.home())})
            with patch.object(sys, "platform", platform), patch.dict(os.environ, env, clear=True):
                self.assertEqual(module.cursor_data_dir(), expected)
        with patch.dict(os.environ, {"CURSOR_USER_DATA_DIR": str(self.root)}):
            self.assertEqual(module.cursor_data_dir(), self.root)

    def test_token_database_read_only_and_redirects_refused(self):
        database = self.root / "User/globalStorage/state.vscdb"
        database.parent.mkdir(parents=True)
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
            connection.execute("INSERT INTO ItemTable VALUES (?, ?)", ("cursorAuth/accessToken", "fixture-only"))
        connection.close()
        before = database.read_bytes()
        with patch.object(module, "cursor_data_dir", return_value=self.root):
            self.assertEqual(module.access_token(), "fixture-only")
        self.assertEqual(database.read_bytes(), before)
        self.assertIsNone(module.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.org"))

    def test_installers_embed_current_source(self):
        subprocess.run([sys.executable, str(ROOT / "tools/embed_cursor_rule.py"), "--check"], check=True)


class InstallerTests(unittest.TestCase):
    def test_default_install_reinstall_update_and_dry_run(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cursor = root / "cursor"
            legacy = cursor / "rules/knowledge-mcp.mdc"
            legacy.parent.mkdir(parents=True)
            legacy.write_text(module.FRONTMATTER + "\n\n" + module.make_block("Old"), encoding="utf-8")
            codex = root / "codex"
            codex.mkdir()
            database = root / "data/User/globalStorage/state.vscdb"
            database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                connection.execute("INSERT INTO ItemTable VALUES (?, ?)", ("cursorAuth/accessToken", "test-only"))
            connection.close()
            fixture = root / "account.json"
            personal = {"id": "personal", "title": "Personal", "knowledge": "Preserve"}
            fixture.write_text(json.dumps([personal]), encoding="utf-8")
            # Patch transport in the Python child; the real SQLite lookup, JSON
            # payload, installer embedding and rule reconciliation all run.
            shutil.copyfile(ROOT / "tests/fixtures/cursor_sitecustomize.py", root / "sitecustomize.py")
            env = dict(os.environ, PYTHONPATH=str(root), CURSOR_TEST_ACCOUNT=str(fixture),
                       CURSOR_USER_DATA_DIR=str(root / "data"), CURSOR_HOME=str(cursor),
                       CODEX_HOME=str(codex), HOME=str(root), USERPROFILE=str(root))
            bootstrap = root / "bootstrap.md"
            bootstrap.write_text("# Café — 知识", encoding="utf-8")
            if sys.platform == "win32":
                command = ["pwsh", "-NoProfile", "-File", str(ROOT / "install.ps1"),
                           "-BootstrapFile", str(bootstrap), "-NoAlias", "-NoCodexMcp"]
                preview = "-WhatIf"
            else:
                command = ["bash", str(ROOT / "install.sh"), "--bootstrap-file", str(bootstrap),
                           "--no-alias", "--no-codex-mcp"]
                preview = "--dry-run"

            def run(extra=()):
                result = subprocess.run(command + list(extra), env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            run([preview])
            self.assertTrue(legacy.exists())
            self.assertEqual(json.loads(fixture.read_text()), [personal])
            run()
            self.assertFalse(legacy.exists())
            first = fixture.read_bytes()
            run()
            self.assertEqual(fixture.read_bytes(), first)
            bootstrap.write_text("# Updated 知识", encoding="utf-8")
            run()
            rules = json.loads(fixture.read_text())
            self.assertEqual(rules[0], personal)
            self.assertEqual(len(rules), 2)
            self.assertIn("# Updated 知识", rules[1]["knowledge"])
            self.assertEqual(json.loads((cursor / "mcp.json").read_text())["mcpServers"]["knowledge"]["url"],
                             "https://knowledge.test/mcp/knowledge")


if __name__ == "__main__":
    unittest.main()
