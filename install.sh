#!/usr/bin/env bash
set -euo pipefail

domain="knowledge.test"
token="${KNOWLEDGE_MCP_TOKEN:-}"
target=""
bootstrap_file=""
dry_run=0
install_alias=1
install_codex_mcp=1
install_cursor_mcp=1
install_cursor_rule=1
start_marker='<!-- KNOWLEDGE-MCP:BEGIN -->'
end_marker='<!-- KNOWLEDGE-MCP:END -->'

codex_home() { printf '%s' "${CODEX_HOME:-${HOME}/.codex}"; }
cursor_home() { printf '%s' "${CURSOR_HOME:-${HOME}/.cursor}"; }

codex_detected() {
  command -v codex >/dev/null 2>&1 || [[ -d "$(codex_home)" ]]
}

cursor_detected() {
  local user_data="${CURSOR_USER_DATA_DIR:-}"
  if [[ -z "$user_data" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then user_data="$HOME/Library/Application Support/Cursor"
    else user_data="${XDG_CONFIG_HOME:-$HOME/.config}/Cursor"; fi
  fi
  command -v agent >/dev/null 2>&1 \
    || command -v cursor-agent >/dev/null 2>&1 \
    || command -v cursor >/dev/null 2>&1 \
    || [[ -d "$(cursor_home)" ]] \
    || [[ -d "$user_data" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) domain="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --bootstrap-file) bootstrap_file="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --no-alias) install_alias=0; shift ;;
    --no-codex-mcp) install_codex_mcp=0; shift ;;
    --no-cursor-mcp) install_cursor_mcp=0; shift ;;
    --no-cursor-rule) install_cursor_rule=0; shift ;;
    -h|--help)
      printf '%s\n' 'Usage: install.sh [--domain knowledge.test] [--token TOKEN] [--target PATH] [--bootstrap-file FILE] [--dry-run] [--no-alias] [--no-codex-mcp] [--no-cursor-mcp] [--no-cursor-rule]'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

install_codex_mcp_server() {
  local mcp_url="$1" existing_json existing_url existing_type
  if ! command -v codex >/dev/null 2>&1; then
    echo 'Warning: Codex CLI was not found; skipped Knowledge MCP registration.' >&2
    return
  fi

  if existing_json="$(codex mcp get knowledge --json 2>/dev/null)"; then
    existing_url="$(jq -r '.transport.url // ""' <<<"$existing_json")"
    existing_type="$(jq -r '.transport.type // ""' <<<"$existing_json")"
    if [[ "$existing_type" != streamable_http || "${existing_url%/}" != "${mcp_url%/}" ]]; then
      echo "Codex already has an MCP server named [knowledge] configured for [$existing_url]. Refusing to replace it with [$mcp_url]." >&2
      exit 1
    fi
    echo "Knowledge MCP is already registered in Codex at [$existing_url]."
    return
  fi

  if [[ "$dry_run" == 1 ]]; then
    echo "Would register Knowledge MCP in Codex at [$mcp_url]."
    return
  fi

  codex mcp add knowledge --url "$mcp_url"
  echo 'Knowledge MCP registered in Codex. Codex completes OAuth authentication during registration when the server requires it.'
}

install_cursor_user_rule() {
  cursor_detected || return 0
  if [[ "$dry_run" == 1 ]]; then
    echo 'Would install/update the Knowledge Cursor account User Rule and retire its old local block after verification.'
    return
  fi
  local python_bin='' candidate helper
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys, sqlite3; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  if [[ -z "$python_bin" ]]; then
    echo 'Python 3.8+ is required to install the Cursor User Rule. Install Python, or use --no-cursor-rule to skip it explicitly.' >&2
    return 1
  fi
  # Generated from cursor_user_rule.py by tools/embed_cursor_rule.py.
  helper="$(cat <<'CURSOR_RULE_PY'
# CURSOR-USER-RULE:BEGIN
"""Cursor account User Rule installer, embedded in both standalone installers.

Uses the same internal Connect API as Cursor desktop (verified with 3.20.17).
Reads its existing sign-in from SQLite without changing Cursor's database.
Run tools/embed_cursor_rule.py after editing this file.
"""

import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

START = "<!-- KNOWLEDGE-MCP:BEGIN -->"
END = "<!-- KNOWLEDGE-MCP:END -->"
TITLE = "Knowledge MCP bootstrap"
FRONTMATTER = "---\ndescription: Knowledge MCP bootstrap\nalwaysApply: true\n---"
API = "https://api2.cursor.sh/aiserver.v1.AiService/"


def managed_span(text):
    if START not in text and END not in text:
        return None
    if text.count(START) != 1 or text.count(END) != 1:
        raise RuntimeError("Knowledge rule contains invalid managed markers; left unchanged.")
    start, end = text.index(START), text.index(END)
    if end < start:
        raise RuntimeError("Knowledge rule contains reversed managed markers; left unchanged.")
    return start, end + len(END)


def make_block(bootstrap):
    if not bootstrap.strip() or START in bootstrap or END in bootstrap:
        raise RuntimeError("Bootstrap must be nonempty and contain no reserved markers.")
    return (START + "\n<!-- Generated from Knowledge MCP. Changes inside this block will be replaced. -->\n\n"
            + bootstrap.strip() + "\n" + END)


def cursor_data_dir():
    override = os.environ.get("CURSOR_USER_DATA_DIR")
    if override:
        return Path(override).expanduser()
    if sys.platform == "win32":
        return Path(os.environ["APPDATA"]) / "Cursor"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/Cursor"
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "Cursor"


def access_token():
    database = cursor_data_dir() / "User/globalStorage/state.vscdb"
    if not database.is_file():
        raise RuntimeError("Open Cursor desktop and sign in, then rerun knowledge-sync. "
                           "For a custom --user-data-dir, set CURSOR_USER_DATA_DIR. "
                           "To skip the account rule, use -NoCursorRule / --no-cursor-rule.")
    try:
        connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            row = connection.execute("SELECT value FROM ItemTable WHERE key=?",
                                     ("cursorAuth/accessToken",)).fetchone()
        finally:
            connection.close()
    except sqlite3.Error:
        raise RuntimeError("Could not read Cursor's sign-in. Open Cursor and retry.") from None
    if not row or not isinstance(row[0], str) or not row[0].strip():
        raise RuntimeError("Sign in to Cursor desktop, then rerun knowledge-sync.")
    return row[0]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class CursorAPI:
    def __init__(self, token):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def __call__(self, method, payload):
        if method not in ("KnowledgeBaseList", "KnowledgeBaseAdd", "KnowledgeBaseUpdate"):
            raise RuntimeError("Unsupported Cursor operation.")
        request = urllib.request.Request(API + method, data=json.dumps(payload).encode("utf-8"),
                                         headers={"Authorization": "Bearer " + self.token,
                                                  "Content-Type": "application/json",
                                                  "Connect-Protocol-Version": "1"})
        try:
            with self.opener.open(request, timeout=30) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise RuntimeError("Cursor rejected its saved sign-in. Open Cursor, sign in again, and rerun.") from None
            raise RuntimeError(f"Cursor User Rule API returned HTTP {error.code}; setup is incomplete. "
                               "This internal API may have changed. Rerun to check before retrying a write.") from None
        except (urllib.error.URLError, TimeoutError, ValueError, OSError):
            raise RuntimeError("Cursor User Rule request failed; setup could not be verified. "
                               "Rerun to check the existing rule before retrying a write.") from None
        if not isinstance(result, dict) or result.get("success") is not True:
            raise RuntimeError("Cursor did not confirm the User Rule operation; setup is incomplete.")
        return result


def list_rules(api):
    result = api("KnowledgeBaseList", {"limit": 100})
    rules = result.get("allResults", [])
    if not isinstance(rules, list) or len(rules) >= 100:
        raise RuntimeError("Cursor returned an invalid or possibly incomplete rule list; refusing to write.")
    for rule in rules:
        if (not isinstance(rule, dict) or not isinstance(rule.get("id"), str) or not rule["id"]
                or not isinstance(rule.get("knowledge", ""), str)
                or not isinstance(rule.get("title", ""), str)):
            raise RuntimeError("Cursor returned an invalid rule; refusing to write.")
    return rules


def backup(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        os.chmod(path, 0o600)
        output.write(text)


def retire_local_rule(path, backup_dir):
    if not path.is_file():
        return
    existing = path.read_text(encoding="utf-8-sig")
    span = managed_span(existing)
    if span is None:
        return
    remaining = existing[:span[0]] + existing[span[1]:]
    # Keep personal content active. Only retire a file containing our block and
    # our exact generated frontmatter, or our block alone.
    generated_only = remaining.strip() in ("", FRONTMATTER)
    saved = backup_dir / ("local-rule-" + uuid.uuid4().hex + ".mdc")
    backup(saved, existing)
    if generated_only:
        path.unlink()
    else:
        fd, temporary = tempfile.mkstemp(prefix=".knowledge-rule-", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(remaining)
            os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(f"Retired the local Knowledge block; personal content preserved. Backup: [{saved}]")


def sync_rule(bootstrap, api, legacy_path, backup_dir):
    block = make_block(bootstrap)
    rules = list_rules(api)
    matches = [r for r in rules if START in r.get("knowledge", "") or END in r.get("knowledge", "")]
    if len(matches) > 1:
        raise RuntimeError("Multiple managed Cursor rules found; resolve duplicates in Cursor Settings before retrying.")
    if not matches and any(r.get("title") == TITLE for r in rules):
        raise RuntimeError("An unmanaged Cursor rule has the Knowledge title; refusing to overwrite it.")
    # Validate the old file before any account write or cleanup.
    if legacy_path.is_file():
        managed_span(legacy_path.read_text(encoding="utf-8-sig"))
    if matches:
        rule = matches[0]
        if rule.get("isGenerated"):
            raise RuntimeError("The managed block belongs to a generated memory; refusing to change it.")
        existing = rule["knowledge"]
        start, end = managed_span(existing)
        desired = existing[:start] + block + existing[end:]
        rule_id = rule["id"]
        if desired != existing:
            backup(backup_dir / ("account-rule-" + uuid.uuid4().hex + ".json"),
                   json.dumps(rule, ensure_ascii=False, indent=2) + "\n")
            api("KnowledgeBaseUpdate", {"id": rule_id, "title": rule.get("title", TITLE), "knowledge": desired})
    else:
        desired = block + "\n"
        result = api("KnowledgeBaseAdd", {"title": TITLE, "knowledge": desired})
        rule_id = result.get("id")
        if not isinstance(rule_id, str) or not rule_id:
            raise RuntimeError("Cursor did not return a rule ID. Rerun to check whether it was saved.")
    # A read-back must confirm exactly one managed rule before retiring the old
    # local block. No automatic retry of potentially successful writes.
    verified = list_rules(api)
    matches = [r for r in verified if START in r.get("knowledge", "") or END in r.get("knowledge", "")]
    if len(matches) != 1 or matches[0]["id"] != rule_id or matches[0].get("knowledge") != desired:
        raise RuntimeError("Cursor User Rule read-back did not match. Local rule retained; rerun to check.")
    retire_local_rule(legacy_path, backup_dir)
    print("Knowledge bootstrap verified in Cursor's account User Rules. Restart Cursor to refresh its cached rules.")


def main():
    options = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
    bootstrap = options["bootstrap"]
    make_block(bootstrap)
    if options.get("dry_run"):
        print("Would install/update the Knowledge Cursor account User Rule and retire its old local block after verification.")
        return
    legacy = Path(options["cursor_home"]).expanduser() / "rules/knowledge-mcp.mdc"
    sync_rule(bootstrap, CursorAPI(access_token()), legacy,
              Path.home() / ".knowledge-sync/cursor-rule-backups")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print("Cursor User Rule setup failed: " + str(error), file=sys.stderr)
        sys.exit(1)
# CURSOR-USER-RULE:END
CURSOR_RULE_PY
)"
  printf '%s' "$bootstrap" | "$python_bin" -c 'import json, sys; print(json.dumps({"bootstrap": sys.stdin.read(), "cursor_home": sys.argv[1]}))' "$(cursor_home)" | "$python_bin" -c "$helper"
}

install_cursor_mcp_server() {
  local mcp_url="$1" config python_bin candidate
  if ! cursor_detected; then
    return
  fi
  config="$(cursor_home)/mcp.json"

  if [[ "$dry_run" == 1 ]]; then
    echo "Would register Knowledge MCP in Cursor at [$mcp_url]."
    return
  fi

  python_bin=""
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json, os, pathlib, sys' >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done
  if [[ -z "$python_bin" ]]; then
    echo 'Warning: python3 was not found; skipped Cursor Knowledge MCP registration.' >&2
    return
  fi

  KNOWLEDGE_SYNC_MCP_URL="$mcp_url" "$python_bin" - "$config" <<'PY'
import json, os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
url = os.environ["KNOWLEDGE_SYNC_MCP_URL"]
if path.exists() and path.stat().st_size:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"Cursor MCP config at [{path}] is not valid JSON.") from error
else:
    data = {}
if not isinstance(data, dict):
    raise SystemExit(f"Cursor MCP config at [{path}] is not a JSON object.")
servers = data.setdefault("mcpServers", {})
if servers is None:
    servers = {}
    data["mcpServers"] = servers
if not isinstance(servers, dict):
    raise SystemExit(f"Cursor MCP mcpServers in [{path}] is not a JSON object.")
existing = servers.get("knowledge")
if existing is not None:
    existing_url = existing.get("url", "") if isinstance(existing, dict) else ""
    if not isinstance(existing, dict) or not isinstance(existing_url, str) or existing.get("command") or existing_url.rstrip("/") != url.rstrip("/"):
        raise SystemExit(
            f"Cursor already has an MCP server named [knowledge] configured for [{existing_url}]. Refusing to replace it with [{url}]."
        )
    print(f"Knowledge MCP is already registered in Cursor at [{existing_url}].")
    raise SystemExit(0)
servers["knowledge"] = {"url": url}
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".knowledge-mcp-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(json.dumps(data, indent=2) + "\n")
    if path.exists():
        os.chmod(temporary, path.stat().st_mode & 0o777)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("Knowledge MCP registered in Cursor. Authenticate it in Cursor or run: agent mcp login knowledge")
PY
}

write_agents_file() {
  local target="$1"
  local directory existing_file output_file block_file start_count end_count unchanged
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
  unchanged=0
  if [[ -f "$target" ]] && cmp -s "$target" "$output_file"; then unchanged=1; fi
  if [[ "$dry_run" == 1 ]]; then
    if [[ "${#targets[@]}" -gt 1 ]]; then printf -- '--- %s ---\n' "$target"; fi
    cat "$output_file"
    rm -f "$output_file"
    return
  fi
  if [[ "$unchanged" == 1 ]]; then rm -f "$output_file"; echo "Knowledge bootstrap is already current in [$target]."
  else mv -f "$output_file" "$target"; echo "Knowledge bootstrap installed in [$target]."
  fi
}

resolve_base_url() {
  local value="${1%/}"
  if [[ "$value" =~ ^https?:// ]]; then printf '%s' "$value"
  else printf 'https://%s' "$value"
  fi
}

credential_file() {
  local key
  key="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s/.knowledge-sync/oauth-%s.json' "$HOME" "$key"
}

read_credentials() {
  local service="knowledge-sync:$1" file
  if [[ "$(uname -s)" == Darwin ]] && command -v security >/dev/null; then
    security find-generic-password -a "$USER" -s "$service" -w 2>/dev/null || true
  elif command -v secret-tool >/dev/null; then
    secret-tool lookup service knowledge-sync domain "$1" 2>/dev/null || true
  else
    file="$(credential_file "$1")"
    [[ ! -f "$file" ]] || cat "$file"
  fi
}

save_credentials() {
  local domain="$1" value="$2" service="knowledge-sync:$1" file
  if [[ "$(uname -s)" == Darwin ]] && command -v security >/dev/null; then
    security add-generic-password -a "$USER" -s "$service" -w "$value" -U >/dev/null
  elif command -v secret-tool >/dev/null; then
    printf '%s' "$value" | secret-tool store --label='Knowledge Sync OAuth' service knowledge-sync domain "$domain"
  else
    file="$(credential_file "$domain")"
    mkdir -p "$(dirname "$file")"
    (umask 077; printf '%s' "$value" > "$file")
    echo "Warning: OAuth credentials are stored in [$file] with user-only permissions because no system keyring CLI was found." >&2
  fi
}

token_request() {
  local endpoint="$1"; shift
  curl --fail-with-body --silent --show-error -X POST "$endpoint" "$@"
}

save_token_response() {
  local base_url="$1" response="$2" client_id="$3" client_secret="$4" token_endpoint="$5" resource="$6" expires_at
  expires_at="$(( $(date +%s) + $(jq -r '.expires_in // 3600' <<<"$response") ))"
  credentials="$(jq -nc --argjson token "$response" --arg client_id "$client_id" --arg client_secret "$client_secret" \
    --arg token_endpoint "$token_endpoint" --arg resource "$resource" --argjson expires_at "$expires_at" \
    '{access_token:$token.access_token,refresh_token:($token.refresh_token // ""),expires_at:$expires_at,client_id:$client_id,client_secret:$client_secret,token_endpoint:$token_endpoint,resource:$resource}')"
  save_credentials "$base_url" "$credentials"
  jq -er '.access_token' <<<"$credentials"
}

get_oauth_token() {
  local base_url="$1" stored now refreshed resource_metadata issuer metadata redirect_uri registration
  local verifier challenge state authorize_url token_response client_id client_secret token_endpoint resource
  stored="$(read_credentials "$base_url")"
  now="$(date +%s)"
  if [[ -n "$stored" ]] && [[ "$(jq -r '.expires_at // 0' <<<"$stored")" -gt $((now + 60)) ]]; then
    jq -er '.access_token' <<<"$stored"
    return
  fi
  if [[ -n "$stored" && -n "$(jq -r '.refresh_token // empty' <<<"$stored")" ]]; then
    token_endpoint="$(jq -r '.token_endpoint' <<<"$stored")"
    client_id="$(jq -r '.client_id' <<<"$stored")"
    client_secret="$(jq -r '.client_secret // empty' <<<"$stored")"
    resource="$(jq -r '.resource' <<<"$stored")"
    refresh_args=(--data-urlencode 'grant_type=refresh_token' --data-urlencode "refresh_token=$(jq -r '.refresh_token' <<<"$stored")" --data-urlencode "client_id=$client_id" --data-urlencode "resource=$resource")
    [[ -z "$client_secret" ]] || refresh_args+=(--data-urlencode "client_secret=$client_secret")
    if refreshed="$(token_request "$token_endpoint" "${refresh_args[@]}" 2>/dev/null)"; then
      save_token_response "$base_url" "$refreshed" "$client_id" "$client_secret" "$token_endpoint" "$resource"
      return
    fi
    echo 'Saved OAuth session could not be refreshed; signing in again.' >&2
  fi

  resource_metadata="$(curl --fail-with-body --silent --show-error "$base_url/.well-known/oauth-protected-resource/mcp/knowledge")"
  resource="$(jq -er '.resource' <<<"$resource_metadata")"
  issuer="$(jq -er '.authorization_servers[0]' <<<"$resource_metadata")"
  metadata="$(curl --fail-with-body --silent --show-error "${issuer%/}/.well-known/oauth-authorization-server")"
  token_endpoint="$(jq -er '.token_endpoint' <<<"$metadata")"

  oauth_dir="$(mktemp -d)"
  callback_script="$oauth_dir/callback.py"
  cat > "$callback_script" <<'PY'
import http.server, json, pathlib, sys, urllib.parse
directory = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        values = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).items()}
        (directory / "result.json").write_text(json.dumps(values))
        body = b"Authentication complete. You can close this window."
        self.send_response(200); self.send_header("Content-Type", "text/plain"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 300
(directory / "port").write_text(str(server.server_port))
server.handle_request()
PY
  python3 "$callback_script" "$oauth_dir" & callback_pid=$!
  for _ in {1..100}; do [[ -f "$oauth_dir/port" ]] && break; sleep 0.05; done
  [[ -f "$oauth_dir/port" ]] || { kill "$callback_pid" 2>/dev/null || true; echo 'Could not start the OAuth callback listener.' >&2; exit 1; }
  redirect_uri="http://127.0.0.1:$(cat "$oauth_dir/port")/callback"
  registration="$(curl --fail-with-body --silent --show-error -X POST "$(jq -r '.registration_endpoint' <<<"$metadata")" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg redirect "$redirect_uri" '{client_name:"Knowledge Sync",redirect_uris:[$redirect],grant_types:["authorization_code","refresh_token"],response_types:["code"],token_endpoint_auth_method:"client_secret_post",application_type:"native",scope:"mcp:use"}')")"
  client_id="$(jq -er '.client_id' <<<"$registration")"
  client_secret="$(jq -r '.client_secret // empty' <<<"$registration")"
  verifier="$(openssl rand -base64 64 | tr '+/' '-_' | tr -d '=\n')"
  challenge="$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  state="$(openssl rand -hex 24)"
  uri_encode() { jq -rn --arg value "$1" '$value|@uri'; }
  authorize_url="$(jq -r '.authorization_endpoint' <<<"$metadata")?response_type=code&client_id=$(uri_encode "$client_id")&redirect_uri=$(uri_encode "$redirect_uri")&state=$(uri_encode "$state")&code_challenge=$(uri_encode "$challenge")&code_challenge_method=S256&scope=mcp%3Ause&resource=$(uri_encode "$resource")"
  echo 'Opening the browser to authenticate Knowledge Sync...' >&2
  if [[ "$(uname -s)" == Darwin ]]; then open "$authorize_url"
  elif command -v xdg-open >/dev/null; then xdg-open "$authorize_url" >/dev/null 2>&1
  else echo "Open this URL in a browser: $authorize_url" >&2
  fi
  wait "$callback_pid"
  callback="$(cat "$oauth_dir/result.json")"
  rm -rf "$oauth_dir"
  [[ "$(jq -r '.state // empty' <<<"$callback")" == "$state" ]] || { echo 'OAuth state did not match.' >&2; exit 1; }
  code="$(jq -er '.code' <<<"$callback")"
  token_args=(--data-urlencode 'grant_type=authorization_code' --data-urlencode "code=$code" --data-urlencode "redirect_uri=$redirect_uri" --data-urlencode "code_verifier=$verifier" --data-urlencode "client_id=$client_id" --data-urlencode "resource=$resource")
  [[ -z "$client_secret" ]] || token_args+=(--data-urlencode "client_secret=$client_secret")
  token_response="$(token_request "$token_endpoint" "${token_args[@]}")"
  save_token_response "$base_url" "$token_response" "$client_id" "$client_secret" "$token_endpoint" "$resource"
}

mcp_post() {
  local payload="$1" machine_os
  machine_os="$(uname -s)"
  [[ "$machine_os" != Darwin ]] || machine_os=Mac
  local curl_headers=(
    -H 'Accept: application/json, text/event-stream'
    -H 'Content-Type: application/json'
    -H "Authorization: Bearer ${token}"
    -H "X-Knowledge-Machine: $machine_os - $(hostname -s)"
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
  base_url="$(resolve_base_url "$domain")"
  if [[ -z "$token" ]]; then
    command -v openssl >/dev/null || { echo 'openssl is required for interactive OAuth.' >&2; exit 1; }
    command -v python3 >/dev/null || { echo 'python3 is required for the OAuth callback.' >&2; exit 1; }
    token="$(get_oauth_token "$base_url")"
  fi

  mcp_url="$base_url/mcp/knowledge"
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

targets=()
if [[ -n "$target" ]]; then
  targets+=("$target")
else
  if codex_detected; then targets+=("$(codex_home)/AGENTS.md"); fi
  if [[ "${#targets[@]}" -eq 0 ]] && ! cursor_detected; then
    echo 'Neither Codex nor Cursor was detected. Install one of them, set CODEX_HOME or CURSOR_HOME, or pass --target explicitly.' >&2
    exit 1
  fi
fi

# Keep the explicit target separate from iteration: it disables account-rule writes.
for output_target in ${targets[@]+"${targets[@]}"}; do
  write_agents_file "$output_target"
done

if [[ "$dry_run" != 1 && "$install_alias" == 1 ]]; then
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh) rc_file="$HOME/.zshrc" ;;
    *) rc_file="$HOME/.bashrc" ;;
  esac
  rc_file="${KNOWLEDGE_SYNC_RC:-$rc_file}"
  alias_start='# KNOWLEDGE-SYNC:BEGIN'
  alias_end='# KNOWLEDGE-SYNC:END'
  escaped_domain="${domain//\'/\'\\\'\'}"
  alias_file="$(mktemp)"
  cat > "$alias_file" <<EOF
$alias_start
knowledge-sync() {
  curl -fsSL https://raw.githubusercontent.com/wyxos/knowledge-sync/main/install.sh | bash -s -- --domain '$escaped_domain' --no-alias "\$@"
}
$alias_end
EOF
  touch "$rc_file"
  rc_output="$(mktemp)"
  awk -v start="$alias_start" -v end="$alias_end" -v block="$alias_file" '
    $0 == start { while ((getline line < block) > 0) print line; skip=1; found=1; next }
    $0 == end { skip=0; next }
    !skip { print }
    END { if (!found) { print ""; while ((getline line < block) > 0) print line } }
  ' "$rc_file" > "$rc_output"
  mv -f "$rc_output" "$rc_file"
  rm -f "$alias_file"
  echo "Persistent command installed in [$rc_file]. Open a new shell, then run: knowledge-sync"
fi

if [[ "$install_codex_mcp" == 1 ]]; then
  install_codex_mcp_server "$(resolve_base_url "$domain")/mcp/knowledge"
fi

if [[ "$install_cursor_mcp" == 1 ]]; then
  install_cursor_mcp_server "$(resolve_base_url "$domain")/mcp/knowledge"
fi

if [[ -z "$target" && "$install_cursor_rule" == 1 ]]; then
  install_cursor_user_rule
fi
