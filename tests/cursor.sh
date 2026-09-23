#!/usr/bin/env bash
set -euo pipefail
test_root="$PWD/.tmp/cursor-review-bash"
python_bin=''
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json' >/dev/null 2>&1; then python_bin="$candidate"; break; fi
done
[[ -n "$python_bin" ]] || { echo 'Python 3 is required for this test.' >&2; exit 1; }
mkdir -p "$test_root/cursor" "$test_root/codex"
export CURSOR_HOME="$test_root/cursor" CODEX_HOME="$test_root/codex" CLAUDE_CONFIG_DIR="$test_root/claude-not-installed"
printf '# Bootstrap\n' > "$test_root/bootstrap.md"
config="$CURSOR_HOME/mcp.json"
for invalid in '[]' 'null' 'false' '{"mcpServers":[]}' '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/mcp/knowledge","command":"local-server"}}}' '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/MCP/knowledge"}}}'; do
  printf '%s\n' "$invalid" > "$config"
  if bash ./install.sh --bootstrap-file "$test_root/bootstrap.md" --target "$test_root/AGENTS.md" --no-alias --no-codex-mcp --no-claude-mcp --no-cursor-rule; then
    echo 'Expected invalid Cursor configuration to fail' >&2
    exit 1
  fi
  [[ "$(cat "$config")" == "$invalid" ]]
done
printf '%s\n' '{"mcpServers":{"other":{"command":"example","env":{"PRESERVE":"yes"}}},"custom":{"preserve":true}}' > "$config"
bash ./install.sh --bootstrap-file "$test_root/bootstrap.md" --no-alias --no-codex-mcp --no-claude-mcp --no-cursor-rule
"$python_bin" - "$config" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    data = json.load(file)
assert data['mcpServers']['other']['env']['PRESERVE'] == 'yes'
assert data['custom']['preserve'] is True
PY
cp "$config" "$test_root/before.json"
bash ./install.sh --bootstrap-file "$test_root/bootstrap.md" --no-alias --no-codex-mcp --no-claude-mcp --no-cursor-rule --dry-run
cmp "$config" "$test_root/before.json"
echo 'Cursor Bash regression checks passed.'
