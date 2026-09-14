"""Offline transport fixture, copied to a temporary PYTHONPATH by tests only."""
import io
import json
import os
from pathlib import Path
import urllib.request


class OfflineCursor:
    def open(self, request, timeout):
        prefix = "https://api2.cursor.sh/aiserver.v1.AiService/"
        if not request.full_url.startswith(prefix):
            raise AssertionError("Unexpected network request in offline installer test")
        if request.get_header("Authorization") != "Bearer test-only":
            raise AssertionError("Installer did not use the isolated Cursor sign-in")
        path = Path(os.environ["CURSOR_TEST_ACCOUNT"])
        rules = json.loads(path.read_text(encoding="utf-8"))
        payload = json.loads(request.data)
        method = request.full_url[len(prefix):]
        if method == "KnowledgeBaseList":
            result = {"success": True, "allResults": rules}
        elif method == "KnowledgeBaseAdd":
            rules.append(dict(payload, id="new"))
            result = {"success": True, "id": "new"}
        elif method == "KnowledgeBaseUpdate":
            next(r for r in rules if r["id"] == payload["id"]).update(payload)
            result = {"success": True}
        else:
            raise AssertionError("Unexpected operation")
        if method != "KnowledgeBaseList":
            path.write_text(json.dumps(rules), encoding="utf-8")
        return io.BytesIO(json.dumps(result).encode())


urllib.request.build_opener = lambda *args: OfflineCursor()
