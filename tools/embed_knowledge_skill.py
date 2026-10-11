"""Embed the public generic skill and helper in standalone installers.

No private service URLs or personal skills are fetched or packaged here.
"""
import base64
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
skill = root / "skills/knowledge-maintenance"
files = {}
for path in sorted(skill.rglob("*")):
    if path.is_symlink():
        raise SystemExit(f"Refusing to embed a linked payload file: {path}")
    if path.is_file():
        files[path.relative_to(skill).as_posix()] = path.read_text(encoding="utf-8")
if "SKILL.md" not in files:
    raise SystemExit("Missing skills/knowledge-maintenance/SKILL.md")
if "references/service.json" in files or ".knowledge-sync.json" in files:
    raise SystemExit("Runtime service metadata and ownership manifests must not be committed.")
payload = base64.b64encode(json.dumps(files, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")).encode("utf-8")).decode("ascii")
source = (root / "knowledge_skill.py").read_text(encoding="utf-8").rstrip()
embedded = source + '\n\nimport base64\nmain(json.loads(base64.b64decode("' + payload + '").decode("utf-8")))\n'
start, end = "# KNOWLEDGE-SKILL:BEGIN\n", "# KNOWLEDGE-SKILL:END"
for name in ("install.ps1", "install.sh"):
    path = root / name
    text = path.read_text(encoding="utf-8")
    before, old = text.split(start)
    _, after = old.split(end)
    expected = before + start + embedded + end + after
    if "--check" in sys.argv:
        if text != expected:
            raise SystemExit(f"{name}: run python tools/embed_knowledge_skill.py")
    else:
        with path.open("w", encoding="utf-8", newline="\n") as output:
            output.write(expected)
