#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
SESSION_HELPER="$REPO_ROOT/scripts/agent-voice-session"
NO_SERVICE_PATCH="$REPO_ROOT/patches/agent-voice-no-service.patch"
AGENT_VOICE_OVERLAY="$REPO_ROOT/overlays"

bash -n "$SETUP" "$SESSION_HELPER"
help_output="$("$SETUP" --help)"
grep -Fq -- '--voice NAME' <<<"$help_output"
git apply --stat "$NO_SERVICE_PATCH" >/dev/null
grep -Fq '"cool_street_deadpan": _COOL_STREET_DEADPAN' \
  "$AGENT_VOICE_OVERLAY/agent_voice/voices.py"
grep -Fq '"chesapeake_balanced": _CHESAPEAKE_BALANCED' \
  "$AGENT_VOICE_OVERLAY/agent_voice/voices.py"
grep -Fq '"chesapeake_balanced_female": _CHESAPEAKE_BALANCED_FEMALE' \
  "$AGENT_VOICE_OVERLAY/agent_voice/voices.py"
CHESAPEAKE_DESIGN="A warm adult male British baritone, friendly and steady, not too formal, like someone who's right there with you. Clear, reassuring, but never stiff." \
CHESAPEAKE_FEMALE_DESIGN="A warm adult female British contralto, friendly and steady, not too formal, like someone who's right there with you. Clear, reassuring, but never stiff." \
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$AGENT_VOICE_OVERLAY" python3 -c '
import os

from agent_voice.voices import VOICE_DESIGNS

assert VOICE_DESIGNS["chesapeake_balanced"] == os.environ["CHESAPEAKE_DESIGN"]
assert VOICE_DESIGNS["chesapeake_balanced_female"] == os.environ["CHESAPEAKE_FEMALE_DESIGN"]
'
[[ "$(grep -Ec '^    "[a-z_]+": _[A-Z_]+,$' "$AGENT_VOICE_OVERLAY/agent_voice/voices.py")" -eq 3 ]]

SETUP_PATH="$SETUP" bash <<'TEST'
set -euo pipefail
source "$SETUP_PATH"

SELECTED_VOICE=""
select_setup_voice >/dev/null
[[ "$SELECTED_VOICE" == "chesapeake_balanced" ]]

for choice_and_voice in \
  ':chesapeake_balanced' \
  '1:chesapeake_balanced' \
  '2:chesapeake_balanced_female' \
  '3:cool_street_deadpan'
do
  choice="${choice_and_voice%%:*}"
  expected="${choice_and_voice#*:}"
  SELECTED_VOICE=""
  set_selected_voice_from_choice "$choice"
  [[ "$SELECTED_VOICE" == "$expected" ]]
done

for voice in chesapeake_balanced chesapeake_balanced_female cool_street_deadpan; do
  SELECTED_VOICE="$voice"
  select_setup_voice >/dev/null
  [[ "$SELECTED_VOICE" == "$voice" ]]
done

if (set_selected_voice_from_choice 4 >/dev/null 2>&1); then
  echo "invalid menu choice unexpectedly accepted" >&2
  exit 1
fi

if (SELECTED_VOICE="not_a_voice"; select_setup_voice >/dev/null 2>&1); then
  echo "invalid voice unexpectedly accepted" >&2
  exit 1
fi
TEST

test_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-voice-setup-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/home/.claude" "$test_root/tmp" "$test_root/fake-bin"
printf 'existing instructions\n' >"$test_root/home/.claude/CLAUDE.md"
chmod 640 "$test_root/home/.claude/CLAUDE.md"
printf '%s\n' '{"permissions":{"allow":["Read"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"existing-session-hook"}]}]},"custom":true}' >"$test_root/home/.claude/settings.json"

cat >"$test_root/fake-bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
[[ -s "$HOME/.agent-voice/run/session-supervisor.pid" ]]
FAKE_CURL
chmod 755 "$test_root/fake-bin/curl"

cat >"$test_root/fake-bin/stat" <<'FAKE_STAT'
#!/usr/bin/env bash
echo "PATH-shadowed stat must not replace macOS /usr/bin/stat" >&2
exit 97
FAKE_STAT
chmod 755 "$test_root/fake-bin/stat"

HOME="$test_root/home" TMPDIR="$test_root/tmp" SETUP_PATH="$SETUP" \
  PATH="$test_root/fake-bin:$PATH" \
  FAKE_BIN="$test_root/fake-bin" bash <<'TEST'
set -euo pipefail
source "$SETUP_PATH"
TEMP_ROOT="$(mktemp -d "$TMPDIR/functions.XXXXXX")"
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
SERVICE_MODE="session"
SELECTED_VOICE="chesapeake_balanced"

write_claude_instructions
configure_claude_permission
configure_claude_session_hook
first_instructions_hash="$(shasum -a 256 "$CLAUDE_INSTRUCTIONS" | awk '{print $1}')"
first_settings_hash="$(shasum -a 256 "$CLAUDE_SETTINGS" | awk '{print $1}')"
write_claude_instructions
configure_claude_permission
configure_claude_session_hook
second_instructions_hash="$(shasum -a 256 "$CLAUDE_INSTRUCTIONS" | awk '{print $1}')"
second_settings_hash="$(shasum -a 256 "$CLAUDE_SETTINGS" | awk '{print $1}')"

[[ "$first_instructions_hash" == "$second_instructions_hash" ]]
[[ "$first_settings_hash" == "$second_settings_hash" ]]

[[ "$(grep -Fxc "$CLAUDE_BLOCK_BEGIN" "$CLAUDE_INSTRUCTIONS")" -eq 1 ]]
[[ "$(grep -Fxc "$CLAUDE_BLOCK_END" "$CLAUDE_INSTRUCTIONS")" -eq 1 ]]
grep -Fq 'existing instructions' "$CLAUDE_INSTRUCTIONS"
grep -Fq 'chesapeake_balanced' "$CLAUDE_INSTRUCTIONS"
! grep -Fq 'cool_street_deadpan' "$CLAUDE_INSTRUCTIONS"
grep -Fq 'Claude Code here.' "$CLAUDE_INSTRUCTIONS"
[[ "$(/usr/bin/stat -f '%Lp' "$CLAUDE_INSTRUCTIONS")" == "640" ]]

rule="Bash($AGENT_SPEAK:*)"
session_command="\"$AGENT_VOICE_SESSION\" start"
jq -e --arg rule "$rule" --arg command "$session_command" '
  .custom == true
  and (.permissions.allow | index("Read") != null)
  and ([.permissions.allow[] | select(. == $rule)] | length == 1)
  and ([.hooks.SessionStart[].hooks[] | select(.command == "existing-session-hook")] | length == 1)
  and ([.hooks.SessionStart[].hooks[] | select(.command == $command and .async == true)] | length == 1)
' "$CLAUDE_SETTINGS" >/dev/null

SERVICE_MODE="foreground"
configure_claude_session_hook
jq -e --arg command "$session_command" '
  ([.hooks.SessionStart[].hooks[] | select(.command == "existing-session-hook")] | length == 1)
  and ([.hooks.SessionStart[].hooks[] | select(.command == $command)] | length == 0)
' "$CLAUDE_SETTINGS" >/dev/null

find "$STATE_DIR/backups" -type f -name CLAUDE.md | grep -q .
find "$STATE_DIR/backups" -type f -name settings.json | grep -q .
grep -Fxq 'existing instructions' "$(find "$STATE_DIR/backups" -type f -name CLAUDE.md | head -n 1)"
jq -e '.custom == true and .permissions.allow == ["Read"] and .hooks.SessionStart[0].hooks[0].command == "existing-session-hook"' \
  "$(find "$STATE_DIR/backups" -type f -name settings.json | head -n 1)" >/dev/null

mkdir -p "$STATE_DIR/app/.venv/bin" "$STATE_DIR/bin"
mkdir -p "$STATE_DIR/app/agent_voice"
cat >"$STATE_DIR/app/.venv/bin/python" <<'FAKE_VERIFY_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
[[ -d agent_voice ]]
[[ "$1" == "-" ]]
[[ "$2" == "chesapeake_balanced" ]]
grep -Fq 'from agent_voice.hermes_config import DEFAULT_VOICE'
FAKE_VERIFY_PYTHON
chmod 755 "$STATE_DIR/app/.venv/bin/python"
verify_installed_voice_default

cp "$SESSION_HELPER_SOURCE" "$AGENT_VOICE_SESSION_BIN"
chmod 755 "$AGENT_VOICE_SESSION_BIN"
cat >"$STATE_DIR/app/.venv/bin/python" <<'FAKE_PYTHON'
#!/usr/bin/env bash
mkdir -p "$HOME/.agent-voice/run"
printf '%s\n' "$$" >"$HOME/.agent-voice/run/fake-server.pid"
exec /bin/sleep 300
FAKE_PYTHON
chmod 755 "$STATE_DIR/app/.venv/bin/python"

PATH="$FAKE_BIN:$PATH" "$AGENT_VOICE_SESSION_BIN" start >/dev/null
status_output="$(PATH="$FAKE_BIN:$PATH" "$AGENT_VOICE_SESSION_BIN" status)"
grep -Fq 'session supervisor: running' <<<"$status_output"
supervisor_pid="$(cat "$STATE_DIR/run/session-supervisor.pid")"
kill -0 "$supervisor_pid"
for _ in {1..20}; do
  [[ -s "$STATE_DIR/run/fake-server.pid" ]] && break
  sleep 0.1
done
first_server_pid="$(cat "$STATE_DIR/run/fake-server.pid")"
kill "$first_server_pid"
for _ in {1..50}; do
  restarted_server_pid="$(cat "$STATE_DIR/run/fake-server.pid" 2>/dev/null || true)"
  if [[ -n "$restarted_server_pid" && "$restarted_server_pid" != "$first_server_pid" ]] && \
    kill -0 "$restarted_server_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
[[ "$restarted_server_pid" != "$first_server_pid" ]]
kill -0 "$restarted_server_pid"
PATH="$FAKE_BIN:$PATH" "$AGENT_VOICE_SESSION_BIN" stop >/dev/null
! kill -0 "$supervisor_pid" 2>/dev/null
[[ ! -e "$STATE_DIR/run/session-supervisor.pid" ]]
TEST

printf 'setup tests passed\n'
