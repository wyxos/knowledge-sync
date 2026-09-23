#!/usr/bin/env bash
set -euo pipefail

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
python_bin=''
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json' >/dev/null 2>&1; then python_bin="$candidate"; break; fi
done
[[ -n "$python_bin" ]] || { echo 'Python 3 is required for this test.' >&2; exit 1; }
export HOME="$root/home" CODEX_HOME="$root/codex" CLAUDE_CONFIG_DIR="$root/claude"
mkdir -p "$HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
printf '# Bootstrap\n' > "$root/bootstrap.md"
printf '# Personal Claude guidance\n' > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
printf '%s\n' '{"mcpServers":{"other":{"command":"example"}},"custom":{"preserve":true}}' > "$CLAUDE_CONFIG_DIR/.claude.json"

./install.sh --bootstrap-file "$root/bootstrap.md" --no-alias --no-codex-mcp --no-cursor-mcp --no-cursor-rule
grep -q '# Personal Claude guidance' "$CLAUDE_CONFIG_DIR/CLAUDE.md"
grep -q '# Bootstrap' "$CLAUDE_CONFIG_DIR/CLAUDE.md"
"$python_bin" - "$CLAUDE_CONFIG_DIR/.claude.json" <<'PY'
import json, pathlib, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert config["custom"]["preserve"] is True
assert config["mcpServers"]["other"]["command"] == "example"
assert config["mcpServers"]["knowledge"] == {"type": "http", "url": "https://knowledge.test/mcp/knowledge"}
PY
cp "$CLAUDE_CONFIG_DIR/CLAUDE.md" "$root/first.md"
cp "$CLAUDE_CONFIG_DIR/.claude.json" "$root/first.json"
./install.sh --bootstrap-file "$root/bootstrap.md" --no-alias --no-codex-mcp --no-cursor-mcp --no-cursor-rule
cmp "$root/first.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
cmp "$root/first.json" "$CLAUDE_CONFIG_DIR/.claude.json"

printf '# Updated bootstrap\n' > "$root/bootstrap.md"
./install.sh --bootstrap-file "$root/bootstrap.md" --no-alias --no-codex-mcp --no-cursor-mcp --no-cursor-rule --dry-run > "$root/preview.txt"
cmp "$root/first.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
cmp "$root/first.json" "$CLAUDE_CONFIG_DIR/.claude.json"
./install.sh --bootstrap-file "$root/bootstrap.md" --no-alias --no-codex-mcp --no-cursor-mcp --no-cursor-rule
grep -q '# Updated bootstrap' "$CLAUDE_CONFIG_DIR/CLAUDE.md"

for invalid in '[]' 'null' 'false' '{"mcpServers":[]}' '{"mcpServers":{"knowledge":{"type":"http","url":"https://other.example/mcp"}}}' '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/mcp/knowledge"}}}'; do
  printf '%s\n' "$invalid" > "$CLAUDE_CONFIG_DIR/.claude.json"
  if ./install.sh --bootstrap-file "$root/bootstrap.md" --target "$root/target.md" --no-alias --no-codex-mcp --no-cursor-mcp --no-cursor-rule > "$root/output.txt" 2>&1; then
    echo 'Expected invalid Claude config to fail.' >&2
    exit 1
  fi
  [[ "$(cat "$CLAUDE_CONFIG_DIR/.claude.json")" == "$invalid" ]] || { echo 'Invalid Claude config was modified.' >&2; exit 1; }
done
echo 'Claude Bash regression checks passed.'
