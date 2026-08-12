#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

bash -n "$SETUP"
"$SETUP" --help >/dev/null

test_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-voice-setup-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/home/.claude" "$test_root/tmp"
printf 'existing instructions\n' >"$test_root/home/.claude/CLAUDE.md"
printf '{"permissions":{"allow":["Read"]},"custom":true}\n' >"$test_root/home/.claude/settings.json"

HOME="$test_root/home" TMPDIR="$test_root/tmp" SETUP_PATH="$SETUP" bash <<'TEST'
set -euo pipefail
source "$SETUP_PATH"
TEMP_ROOT="$(mktemp -d "$TMPDIR/functions.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT

write_claude_instructions
configure_claude_permission
first_instructions_hash="$(shasum -a 256 "$CLAUDE_INSTRUCTIONS" | awk '{print $1}')"
first_settings_hash="$(shasum -a 256 "$CLAUDE_SETTINGS" | awk '{print $1}')"
write_claude_instructions
configure_claude_permission
second_instructions_hash="$(shasum -a 256 "$CLAUDE_INSTRUCTIONS" | awk '{print $1}')"
second_settings_hash="$(shasum -a 256 "$CLAUDE_SETTINGS" | awk '{print $1}')"

[[ "$first_instructions_hash" == "$second_instructions_hash" ]]
[[ "$first_settings_hash" == "$second_settings_hash" ]]

[[ "$(grep -Fxc "$CLAUDE_BLOCK_BEGIN" "$CLAUDE_INSTRUCTIONS")" -eq 1 ]]
[[ "$(grep -Fxc "$CLAUDE_BLOCK_END" "$CLAUDE_INSTRUCTIONS")" -eq 1 ]]
grep -Fq 'existing instructions' "$CLAUDE_INSTRUCTIONS"
grep -Fq 'questline_deadpan' "$CLAUDE_INSTRUCTIONS"
grep -Fq 'Claude Code here.' "$CLAUDE_INSTRUCTIONS"

rule="Bash($AGENT_SPEAK:*)"
jq -e --arg rule "$rule" '
  .custom == true
  and (.permissions.allow | index("Read") != null)
  and ([.permissions.allow[] | select(. == $rule)] | length == 1)
' "$CLAUDE_SETTINGS" >/dev/null

find "$STATE_DIR/backups" -type f -name CLAUDE.md | grep -q .
find "$STATE_DIR/backups" -type f -name settings.json | grep -q .
grep -Fxq 'existing instructions' "$(find "$STATE_DIR/backups" -type f -name CLAUDE.md | head -n 1)"
jq -e '.custom == true and .permissions.allow == ["Read"]' \
  "$(find "$STATE_DIR/backups" -type f -name settings.json | head -n 1)" >/dev/null
TEST

printf 'setup tests passed\n'
