#!/usr/bin/env bash
set -euo pipefail

domain="knowledge.test"
token="${KNOWLEDGE_MCP_TOKEN:-}"
target="${CODEX_HOME:-${HOME}/.codex}/AGENTS.md"
bootstrap_file=""
dry_run=0
start_marker='<!-- KNOWLEDGE-MCP:BEGIN -->'
end_marker='<!-- KNOWLEDGE-MCP:END -->'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) domain="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --bootstrap-file) bootstrap_file="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help)
      printf '%s\n' 'Usage: install.sh [--domain knowledge.test] [--token TOKEN] [--target PATH]'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

resolve_base_url() {
  local value="${1%/}"
  if [[ "$value" =~ ^https?:// ]]; then printf '%s' "$value"
  elif [[ "$value" == *.test ]]; then printf 'http://%s' "$value"
  else printf 'https://%s' "$value"
  fi
}

mcp_post() {
  local payload="$1"
  local curl_headers=(
    -H 'Accept: application/json, text/event-stream'
    -H 'Content-Type: application/json'
    -H "Authorization: Bearer ${token}"
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
  if [[ -z "$token" ]]; then read -r -s -p 'Knowledge MCP access token: ' token < /dev/tty; echo > /dev/tty; fi

  mcp_url="$(resolve_base_url "$domain")/mcp/knowledge"
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
if [[ -f "$target" ]] && cmp -s "$target" "$output_file"; then rm -f "$output_file"; echo "Knowledge bootstrap is already current in [$target]."; exit 0; fi
if [[ "$dry_run" == 1 ]]; then cat "$output_file"; rm -f "$output_file"; exit 0; fi
mv -f "$output_file" "$target"
echo "Knowledge bootstrap installed in [$target]."
