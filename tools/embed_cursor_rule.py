"""Keep the two standalone installers in sync with the reviewable Python source."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
source = (root / "cursor_user_rule.py").read_text(encoding="utf-8").rstrip()
start = "# CURSOR-USER-RULE:BEGIN\n"
end = "# CURSOR-USER-RULE:END"
for name in ("install.ps1", "install.sh"):
    path = root / name
    text = path.read_text(encoding="utf-8")
    before, embedded = text.split(start)
    old, after = embedded.split(end)
    expected = before + start + source + "\n" + end + after
    if "--check" in sys.argv:
        if text != expected:
            raise SystemExit(f"{name}: run python tools/embed_cursor_rule.py")
    else:
        with path.open("w", encoding="utf-8", newline="\n") as output:
            output.write(expected)
