#!/usr/bin/env bash
set -euo pipefail

test_root="$PWD/.tmp/keychain-review"
mkdir -p "$test_root/bin" "$test_root/home" "$test_root/codex"

cat > "$test_root/bin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
cat > "$test_root/bin/security" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == find-generic-password ]]; then exit "${MOCK_KEYCHAIN_STATUS:-36}"; fi
if [[ "$1" == add-generic-password ]]; then exit 36; fi
exit 1
SH
cat > "$test_root/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$MOCK_NETWORK_LOG"
exit 1
SH
cat > "$test_root/bin/jq" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -nc ]]; then printf '{"access_token":"test-token"}\n'; exit 0; fi
if [[ "$1" == -er ]]; then printf 'test-token\n'; exit 0; fi
if [[ "$1" == -r ]]; then printf '3600\n'; exit 0; fi
exit 1
SH
for name in openssl python3; do
  cat > "$test_root/bin/$name" <<'SH'
#!/usr/bin/env bash
exit 1
SH
done
chmod +x "$test_root/bin/"*

export PATH="$test_root/bin:$PATH" HOME="$test_root/home" CODEX_HOME="$test_root/codex" USER=example
export MOCK_NETWORK_LOG="$test_root/network.log"

: > "$MOCK_NETWORK_LOG"
export MOCK_KEYCHAIN_STATUS=36
if bash ./install.sh --domain knowledge.test --no-alias --no-codex-mcp --no-claude-mcp --no-cursor-mcp --no-cursor-rule > "$test_root/output" 2>&1; then
  echo 'Expected an inaccessible Keychain entry to fail.' >&2
  exit 1
fi
grep -q 'cannot read its macOS Keychain session' "$test_root/output"
! grep -q 'Opening the browser' "$test_root/output"
[[ ! -s "$MOCK_NETWORK_LOG" ]]

export MOCK_KEYCHAIN_STATUS=44 # errSecItemNotFound: first-time OAuth may proceed
if bash ./install.sh --domain knowledge.test --no-alias --no-codex-mcp --no-claude-mcp --no-cursor-mcp --no-cursor-rule > "$test_root/output" 2>&1; then
  echo 'Expected mocked network failure after a missing Keychain entry.' >&2
  exit 1
fi
[[ -s "$MOCK_NETWORK_LOG" ]]
! grep -q 'cannot read its macOS Keychain session' "$test_root/output"

# Load a complete file: sourcing process substitution can close the pipe before
# awk finishes writing on macOS. A separate command also checks extraction errors.
awk '/^(save_credentials|save_token_response)\(\) \{$/{copy=1} copy{print} copy && /^}$/ {copy=0}' install.sh > "$test_root/credential-functions.sh"
source "$test_root/credential-functions.sh"
if save_token_response knowledge.test '{"access_token":"test-token"}' client-id '' endpoint resource > "$test_root/token-output" 2> "$test_root/save-error"; then
  echo 'Expected a Keychain save failure to prevent token use.' >&2
  exit 1
fi
grep -q 'could not save its OAuth session' "$test_root/save-error"
[[ ! -s "$test_root/token-output" ]]

echo 'Mac Keychain regression checks passed.'
