#!/usr/bin/env bash
set -euo pipefail
test_root="$PWD/.tmp/cursor-review-bash"
mkdir -p "$test_root/cursor" "$test_root/codex"
export CURSOR_HOME="$test_root/cursor" CODEX_HOME="$test_root/codex"
printf '# Bootstrap\n' > "$test_root/bootstrap.md"
config="$CURSOR_HOME/mcp.json"
for invalid in '[]' 'null' 'false' '{"mcpServers":[]}' '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/mcp/knowledge","command":"local-server"}}}' '{"mcpServers":{"knowledge":{"url":"https://knowledge.test/MCP/knowledge"}}}'; do
  printf '%s\n' "$invalid" > "$config"
  if bash ./install.sh --bootstrap-file "$test_root/bootstrap.md" --target "$test_root/AGENTS.md" --no-alias --no-codex-mcp; then
    echo 'Expected invalid Cursor configuration to fail' >&2
    exit 1
  fi
  [[ "$(cat "$config")" == "$invalid" ]]
done
printf '%s\n' '{"mcpServers":{"other":{"command":"example","env":{"PRESERVE":"yes"}}},"custom":{"preserve":true}}' > "$config"
bash ./install.sh --bootstrap-file "$test_root/bootstrap.md" --no-alias --no-codex-mcp
python3 - "$config" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    data = json.load(file)
assert data['mcpServers']['other']['env']['PRESERVE'] == 'yes'
assert data['custom']['preserve'] is True
PY
cp "$config" "$test_root/before.json"
bash ./install.sh --bootstrap-file "$test_root/bootstrap.md" --no-alias --no-codex-mcp --dry-run
cmp "$config" "$test_root/before.json"
echo 'Cursor Bash regression checks passed.'
