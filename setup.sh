#!/usr/bin/env bash
# Install the verified local agent-voice stack on macOS Apple Silicon.

set -Eeuo pipefail

readonly AGENT_VOICE_REPO_URL="https://github.com/keegoid/agent-voice.git"
readonly AGENT_VOICE_COMMIT="1dcb3ad0f940b6d4fc3831dedf366335e6fc9dd4"
readonly AGENT_VOICE_TREE_SHA256="2165078f78db8f83dd6916f075715de19f0ff66b7dbeda649c80a864079d638b"
readonly QWEN_MODEL_ID="mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
readonly QWEN_MODEL_REVISION="7d3824abff87e49756bb0f83fb5411de75d160c4"
readonly VOICE_SERVER_URL="http://127.0.0.1:8880"
readonly CLAUDE_BLOCK_BEGIN="<!-- agent-voice-setup:claude-begin -->"
readonly CLAUDE_BLOCK_END="<!-- agent-voice-setup:claude-end -->"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AGENT_VOICE_HOME:-$HOME/.agent-voice}"
SOURCE_DIR="$STATE_DIR/sources/${AGENT_VOICE_COMMIT:0:12}"
NO_SERVICE_PATCH="$SCRIPT_DIR/patches/agent-voice-no-service.patch"
AGENT_VOICE_OVERLAY="$SCRIPT_DIR/overlays"
SESSION_HELPER_SOURCE="$SCRIPT_DIR/scripts/agent-voice-session"
BACKUP_ID="setup-$(date '+%Y%m%d%H%M%S')-$$"
BACKUP_DIR="$STATE_DIR/backups/$BACKUP_ID"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_INSTRUCTIONS="$CLAUDE_DIR/CLAUDE.md"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
LOCAL_BIN="$HOME/.local/bin"
AGENT_SPEAK="$LOCAL_BIN/agent-speak"
AGENT_VOICE_SUMMARY="$LOCAL_BIN/agent-voice-summary"
AGENT_VOICE_SESSION="$LOCAL_BIN/agent-voice-session"
AGENT_VOICE_SESSION_BIN="$STATE_DIR/bin/agent-voice-session"
LAUNCHD_LABEL="com.keegoid.agent-voice"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
DRY_RUN=0
PLAY_TEST=1
SERVICE_MODE="launchd"
FOREGROUND_SERVICE_STARTED=0
TEMP_ROOT=""

usage() {
  cat <<'USAGE'
Usage: ./setup.sh [options]

Options:
  --service-mode MODE  Server lifecycle: launchd (default), session, or foreground.
  --dry-run           Print the planned operations without changing the laptop.
  --no-play           Generate and validate the test WAV without playing it.
  -h, --help          Show this help.

Use session mode when launchd is unavailable. Claude Code will start a
restart-capable supervisor from an asynchronous SessionStart hook. Foreground
mode installs the same supervisor but requires `agent-voice-session run` in a
terminal whenever voice is wanted.
USAGE
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'setup: %s\n' "$*" >&2
  exit 1
}

would() {
  printf 'dry-run:'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    would "$@"
  else
    "$@"
  fi
}

file_mode() {
  local target="$1"
  local mode=""

  if [[ -x /usr/bin/stat ]]; then
    mode="$(/usr/bin/stat -f '%Lp' "$target" 2>/dev/null)" || mode=""
  fi
  if [[ -z "$mode" ]]; then
    mode="$(stat -c '%a' "$target" 2>/dev/null)" || mode=""
  fi
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] ||
    die "could not determine file mode for $target"
  printf '%s\n' "$mode"
}

cleanup() {
  if [[ "$FOREGROUND_SERVICE_STARTED" -eq 1 && -x "$AGENT_VOICE_SESSION" ]]; then
    "$AGENT_VOICE_SESSION" stop >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf -- "$TEMP_ROOT"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service-mode)
        [[ $# -ge 2 ]] || die "missing value for --service-mode"
        SERVICE_MODE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --no-play)
        PLAY_TEST=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown option: $1"
        ;;
    esac
  done
  case "$SERVICE_MODE" in
    launchd|session|foreground) ;;
    *) die "invalid service mode: $SERVICE_MODE (expected launchd, session, or foreground)" ;;
  esac
}

require_platform() {
  [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] ||
    die "this installer supports macOS on Apple Silicon only"

  command -v brew >/dev/null || die \
    "Homebrew is required. Install it from https://brew.sh, then rerun setup.sh."
  for command_name in git curl shasum awk; do
    command -v "$command_name" >/dev/null || die "$command_name is required"
  done
}

ensure_formula() {
  local formula="$1"
  if brew list --formula "$formula" >/dev/null 2>&1; then
    say "Homebrew formula already installed: $formula"
    return 0
  fi
  run brew install "$formula"
}

install_dependencies() {
  say "Installing checksummed Homebrew dependencies"
  ensure_formula uv
  ensure_formula jq
  ensure_formula ffmpeg
}

verify_agent_voice_source() {
  local source="$1"
  local actual_commit actual_tree
  actual_commit="$(git -C "$source" rev-parse HEAD)"
  [[ "$actual_commit" == "$AGENT_VOICE_COMMIT" ]] ||
    die "agent-voice commit mismatch: expected $AGENT_VOICE_COMMIT, got $actual_commit"

  actual_tree="$(git -C "$source" ls-tree -r HEAD | shasum -a 256 | awk '{print $1}')"
  [[ "$actual_tree" == "$AGENT_VOICE_TREE_SHA256" ]] ||
    die "agent-voice tree checksum mismatch: expected $AGENT_VOICE_TREE_SHA256, got $actual_tree"
}

clone_agent_voice() {
  local clone_parent staged_source

  if [[ -d "$SOURCE_DIR/.git" ]]; then
    say "Verifying existing pinned agent-voice clone"
    verify_agent_voice_source "$SOURCE_DIR"
    return 0
  fi
  [[ ! -e "$SOURCE_DIR" ]] || die "source path exists but is not a git clone: $SOURCE_DIR"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    would git clone "$AGENT_VOICE_REPO_URL" "$SOURCE_DIR"
    would git -C "$SOURCE_DIR" checkout --detach "$AGENT_VOICE_COMMIT"
    would verify-agent-voice-tree "$AGENT_VOICE_TREE_SHA256"
    return 0
  fi

  clone_parent="$(dirname "$SOURCE_DIR")"
  mkdir -p "$clone_parent"
  staged_source="$TEMP_ROOT/agent-voice"
  git clone --no-checkout "$AGENT_VOICE_REPO_URL" "$staged_source"
  git -C "$staged_source" checkout --detach "$AGENT_VOICE_COMMIT"
  verify_agent_voice_source "$staged_source"
  mv "$staged_source" "$SOURCE_DIR"
  say "Cloned verified agent-voice commit $AGENT_VOICE_COMMIT"
}

is_managed_session_helper() {
  local helper="$1"
  grep -Fq '# agent-voice-setup-session-supervisor' "$helper" 2>/dev/null
}

stop_managed_session_supervisor() {
  if [[ -x "$AGENT_VOICE_SESSION" ]] && is_managed_session_helper "$AGENT_VOICE_SESSION"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      would "$AGENT_VOICE_SESSION" stop
    else
      "$AGENT_VOICE_SESSION" stop >/dev/null 2>&1 || true
    fi
  fi
}

remove_managed_session_helper() {
  if [[ -e "$AGENT_VOICE_SESSION" ]] && is_managed_session_helper "$AGENT_VOICE_SESSION"; then
    backup_path "$AGENT_VOICE_SESSION"
    run rm -f -- "$AGENT_VOICE_SESSION"
  fi
}

disable_launchd_for_fallback() {
  local domain
  domain="gui/$(id -u)"

  if command -v launchctl >/dev/null 2>&1 && \
    launchctl print "$domain/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      would launchctl bootout "$domain/$LAUNCHD_LABEL"
    else
      launchctl bootout "$domain/$LAUNCHD_LABEL" ||
        die "could not stop the existing $LAUNCHD_LABEL service"
    fi
  fi
  if [[ -e "$LAUNCHD_PLIST" ]]; then
    backup_path "$LAUNCHD_PLIST"
    run rm -f -- "$LAUNCHD_PLIST"
  fi
}

prepare_service_transition() {
  case "$SERVICE_MODE" in
    launchd)
      stop_managed_session_supervisor
      remove_managed_session_helper
      ;;
    session|foreground)
      stop_managed_session_supervisor
      disable_launchd_for_fallback
      ;;
  esac
}

prepare_install_source() {
  local patched_source="$TEMP_ROOT/agent-voice-install"
  local source_archive="$TEMP_ROOT/agent-voice-source.tar"
  local relative rendered original_mode

  [[ -f "$AGENT_VOICE_OVERLAY/agent_voice/voices.py" ]] ||
    die "missing agent-voice overlay: $AGENT_VOICE_OVERLAY"
  [[ -f "$NO_SERVICE_PATCH" ]] || die "missing no-service patch: $NO_SERVICE_PATCH"
  git -C "$SOURCE_DIR" archive --format=tar HEAD -o "$source_archive"
  mkdir -p "$patched_source"
  tar -xf "$source_archive" -C "$patched_source"
  cp -R "$AGENT_VOICE_OVERLAY/." "$patched_source/"
  for relative in \
    agent_voice/hermes_config.py \
    agent_voice/server.py \
    scripts/agent-speak \
    scripts/agent-voice-summary
  do
    original_mode="$(file_mode "$patched_source/$relative")" || return 1
    rendered="$(mktemp "$TEMP_ROOT/voice-default.XXXXXX")"
    sed 's/questline_deadpan/chesapeake_balanced/g' \
      "$patched_source/$relative" >"$rendered"
    chmod "$original_mode" "$rendered" || return 1
    mv "$rendered" "$patched_source/$relative"
  done
  if [[ "$SERVICE_MODE" != "launchd" ]]; then
    git -C "$patched_source" apply --unidiff-zero --check "$NO_SERVICE_PATCH" ||
      die "the no-service patch no longer matches the pinned agent-voice installer"
    git -C "$patched_source" apply --unidiff-zero "$NO_SERVICE_PATCH"
  fi
  printf '%s\n' "$patched_source"
}

install_agent_voice() {
  local install_source="$SOURCE_DIR"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    would apply-voice-overlay "$AGENT_VOICE_OVERLAY"
    if [[ "$SERVICE_MODE" == "launchd" ]]; then
      would patched-agent-voice-install --source-dir verified-source --no-codex-config
    else
      would apply-no-service-patch "$NO_SERVICE_PATCH"
      would patched-agent-voice-install --source-dir verified-source --no-codex-config --no-service
    fi
    return 0
  fi

  [[ -x "$SOURCE_DIR/install.sh" ]] || die "verified source is missing executable install.sh"
  install_source="$(prepare_install_source)"
  if [[ "$SERVICE_MODE" == "launchd" ]]; then
    "$install_source/install.sh" --source-dir "$install_source" --no-codex-config
  else
    "$install_source/install.sh" --source-dir "$install_source" --no-codex-config --no-service
  fi
}

install_session_helper() {
  local rendered

  [[ "$SERVICE_MODE" != "launchd" ]] || return 0
  [[ -f "$SESSION_HELPER_SOURCE" ]] || die "missing session helper: $SESSION_HELPER_SOURCE"
  backup_path "$AGENT_VOICE_SESSION"
  backup_path "$AGENT_VOICE_SESSION_BIN"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    would install-session-supervisor "$AGENT_VOICE_SESSION_BIN" "$AGENT_VOICE_SESSION"
    return 0
  fi

  mkdir -p "$STATE_DIR/bin" "$LOCAL_BIN"
  cp "$SESSION_HELPER_SOURCE" "$AGENT_VOICE_SESSION_BIN"
  chmod 755 "$AGENT_VOICE_SESSION_BIN"
  rendered="$(mktemp "$TEMP_ROOT/agent-voice-session-shim.XXXXXX")"
  cat >"$rendered" <<EOF
#!/usr/bin/env bash
# agent-voice-setup-session-supervisor
export AGENT_VOICE_HOME="\${AGENT_VOICE_HOME:-$STATE_DIR}"
exec "$AGENT_VOICE_SESSION_BIN" "\$@"
EOF
  mv "$rendered" "$AGENT_VOICE_SESSION"
  chmod 755 "$AGENT_VOICE_SESSION"
}

download_qwen_model() {
  local python snapshot
  python="$STATE_DIR/app/.venv/bin/python"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    would download-hugging-face-snapshot "$QWEN_MODEL_ID@$QWEN_MODEL_REVISION"
    would verify-hugging-face-blob-checksums "$QWEN_MODEL_REVISION"
    return 0
  fi

  [[ -x "$python" ]] || die "agent-voice Python environment was not installed at $python"
  say "Downloading pinned Qwen3-TTS model revision (about 4.2 GB)"
  snapshot="$(
    HF_HOME="$STATE_DIR/model-cache/huggingface" "$python" - "$QWEN_MODEL_ID" "$QWEN_MODEL_REVISION" <<'PY'
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

model_id, revision = sys.argv[1:]
snapshot = Path(snapshot_download(repo_id=model_id, revision=revision)).resolve()
if snapshot.name != revision:
    raise SystemExit(f"unexpected snapshot revision: {snapshot}")
print(snapshot)
PY
  )"

  verify_hugging_face_snapshot "$python" "$snapshot"
  say "Verified Qwen3-TTS snapshot $QWEN_MODEL_REVISION"
}

verify_hugging_face_snapshot() {
  local python="$1"
  local snapshot="$2"
  "$python" - "$snapshot" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

snapshot = Path(sys.argv[1])
if not snapshot.is_dir():
    raise SystemExit(f"snapshot does not exist: {snapshot}")


def file_digest(path: Path, algorithm: str, git_blob: bool = False) -> str:
    digest = hashlib.new(algorithm)
    if git_blob:
        digest.update(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


checked = 0
for entry in sorted(snapshot.rglob("*")):
    if not entry.is_symlink():
        continue
    blob = entry.resolve(strict=True)
    expected = blob.name
    if re.fullmatch(r"[0-9a-f]{64}", expected):
        actual = file_digest(blob, "sha256")
    elif re.fullmatch(r"[0-9a-f]{40}", expected):
        actual = file_digest(blob, "sha1", git_blob=True)
    else:
        raise SystemExit(f"unrecognized Hugging Face blob name: {blob}")
    if actual != expected:
        raise SystemExit(f"checksum mismatch for {entry}: expected {expected}, got {actual}")
    checked += 1

if checked == 0:
    raise SystemExit(f"no content-addressed model blobs found in {snapshot}")
print(f"Verified {checked} content-addressed Hugging Face blobs")
PY
}

backup_path() {
  local target="$1"
  local relative destination
  [[ -e "$target" ]] || return 0

  if [[ "$target" == "$HOME/"* ]]; then
    relative="home/${target#"$HOME/"}"
  else
    relative="external/${target#/}"
  fi
  destination="$BACKUP_DIR/$relative"
  [[ ! -e "$destination" ]] || return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    would cp -a "$target" "$destination"
    return 0
  fi
  mkdir -p "$(dirname "$destination")"
  cp -a "$target" "$destination"
}

write_claude_instructions() {
  local begin_count=0 end_count=0 stripped rendered helper speaker original_mode
  helper="$AGENT_SPEAK"
  speaker="${AGENT_VOICE_CLAUDE_SPEAKER:-Claude Code here.}"

  if [[ -f "$CLAUDE_INSTRUCTIONS" ]]; then
    begin_count="$(grep -Fxc "$CLAUDE_BLOCK_BEGIN" "$CLAUDE_INSTRUCTIONS" || true)"
    end_count="$(grep -Fxc "$CLAUDE_BLOCK_END" "$CLAUDE_INSTRUCTIONS" || true)"
  fi
  [[ "$begin_count" == "$end_count" && "$begin_count" -le 1 ]] ||
    die "managed Claude voice block markers are unbalanced in $CLAUDE_INSTRUCTIONS"

  backup_path "$CLAUDE_INSTRUCTIONS"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    would update-managed-block "$CLAUDE_INSTRUCTIONS"
    return 0
  fi

  mkdir -p "$CLAUDE_DIR"
  stripped="$(mktemp "$TEMP_ROOT/claude-instructions.XXXXXX")"
  rendered="$(mktemp "$TEMP_ROOT/claude-instructions-rendered.XXXXXX")"
  original_mode="644"
  if [[ -f "$CLAUDE_INSTRUCTIONS" ]]; then
    original_mode="$(file_mode "$CLAUDE_INSTRUCTIONS")" || return 1
    awk -v begin="$CLAUDE_BLOCK_BEGIN" -v end="$CLAUDE_BLOCK_END" '
      $0 == begin { managed = 1; next }
      $0 == end { managed = 0; next }
      !managed { print }
    ' "$CLAUDE_INSTRUCTIONS" >"$stripped"
  fi

  {
    cat "$stripped"
    printf '%s\n' "$CLAUDE_BLOCK_BEGIN"
    cat <<EOF
## Local voice progress protocol

Use \`$helper\` for best-effort spoken progress cues through the local
agent-voice server and the \`cool_street_deadpan\` Qwen3-TTS voice. Voice is
operator telemetry, never the task: if speech is offline, continue working.

Every spoken message must begin with \`$speaker\` so the speaker is clear away
from the screen.

Speak at these moments:

- Before substantive exploration or edits: one sentence with intent and why.
- Before risky, user-visible, long-running, irreversible, external, or expensive
  actions: say the concrete action about to happen.
- Before the final response: give a useful one-to-three-sentence outcome,
  verification, and residual risk or next step.

Keep cues concise and specific. Do not narrate tiny read-only commands. Invoke
the helper directly with one quoted message argument; do not wait for playback
or treat a speech failure as a task failure.
EOF
    printf '%s\n' "$CLAUDE_BLOCK_END"
  } >"$rendered"
  mv "$rendered" "$CLAUDE_INSTRUCTIONS"
  chmod "$original_mode" "$CLAUDE_INSTRUCTIONS" || return 1
}

configure_claude_permission() {
  local rule temp_settings
  rule="Bash($AGENT_SPEAK:*)"
  backup_path "$CLAUDE_SETTINGS"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    would add-json-array-value "$CLAUDE_SETTINGS" permissions.allow "$rule"
    return 0
  fi

  mkdir -p "$CLAUDE_DIR"
  if [[ ! -e "$CLAUDE_SETTINGS" ]]; then
    printf '{}\n' >"$CLAUDE_SETTINGS"
  fi
  jq -e 'type == "object"' "$CLAUDE_SETTINGS" >/dev/null ||
    die "$CLAUDE_SETTINGS is not a valid JSON object"
  temp_settings="$(mktemp "$TEMP_ROOT/claude-settings.XXXXXX")"
  jq --arg rule "$rule" '
    .permissions = (.permissions // {})
    | .permissions.allow = (.permissions.allow // [])
    | if (.permissions.allow | index($rule)) == null
      then .permissions.allow += [$rule]
      else .
      end
  ' "$CLAUDE_SETTINGS" >"$temp_settings"
  mv "$temp_settings" "$CLAUDE_SETTINGS"
  chmod 600 "$CLAUDE_SETTINGS"
}

configure_claude_session_hook() {
  local command temp_settings
  command="\"$AGENT_VOICE_SESSION\" start"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$SERVICE_MODE" == "session" ]]; then
      would add-claude-session-start-hook "$command"
    else
      would remove-claude-session-start-hook "$command"
    fi
    return 0
  fi

  temp_settings="$(mktemp "$TEMP_ROOT/claude-session-hook.XXXXXX")"
  jq --arg command "$command" --arg mode "$SERVICE_MODE" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = (
        [(.hooks.SessionStart // [])[]
          | select(
              ([.hooks[]? | select(.type? == "command") | .command?]
                | index($command)) == null
            )
        ]
      )
    | if $mode == "session"
      then .hooks.SessionStart += [{
        hooks: [{
          type: "command",
          command: $command,
          timeout: 45,
          async: true
        }]
      }]
      else .
      end
  ' "$CLAUDE_SETTINGS" >"$temp_settings" ||
    die "could not merge the SessionStart hook into $CLAUDE_SETTINGS"
  mv "$temp_settings" "$CLAUDE_SETTINGS"
  chmod 600 "$CLAUDE_SETTINGS"
}

configure_claude() {
  say "Configuring Claude Code voice timing, helper permission, and server lifecycle"
  write_claude_instructions
  configure_claude_permission
  configure_claude_session_hook
}

start_selected_service() {
  case "$SERVICE_MODE" in
    launchd)
      return 0
      ;;
    session)
      say "Starting restart-capable user-session voice supervisor"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        would "$AGENT_VOICE_SESSION" start
      else
        "$AGENT_VOICE_SESSION" start
      fi
      ;;
    foreground)
      say "Starting a temporary voice supervisor for the installation test"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        would "$AGENT_VOICE_SESSION" start
      else
        "$AGENT_VOICE_SESSION" start
        FOREGROUND_SERVICE_STARTED=1
      fi
      ;;
  esac
}

stop_temporary_foreground_service() {
  [[ "$SERVICE_MODE" == "foreground" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    would "$AGENT_VOICE_SESSION" stop
    return 0
  fi
  "$AGENT_VOICE_SESSION" stop
  FOREGROUND_SERVICE_STARTED=0
}

wait_for_json_endpoint() {
  local url="$1"
  local timeout_seconds="$2"
  local attempt
  for ((attempt = 0; attempt < timeout_seconds * 2; attempt++)); do
    if curl -fsS --max-time 2 "$url" | jq -e 'type == "object"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

run_voice_test() {
  local wav play_args=() health

  if [[ "$DRY_RUN" -eq 1 ]]; then
    would wait-for-health "$VOICE_SERVER_URL/v1/health"
    would "$AGENT_VOICE_SUMMARY" --voice chesapeake_balanced --output setup-test.wav \
      "Agent voice is installed. Qwen three T T S is running locally."
    would validate-wav setup-test.wav
    return 0
  fi

  wait_for_json_endpoint "$VOICE_SERVER_URL/v1/health" 30 ||
    die "agent-voice did not become reachable at $VOICE_SERVER_URL"
  health="$(curl -fsS --max-time 3 "$VOICE_SERVER_URL/v1/health")"
  jq -e --arg model "$QWEN_MODEL_ID" \
    '.status == "ok" and .muted == false and .tts_model_id == $model and (.voices | sort == ["chesapeake_balanced", "cool_street_deadpan"])' \
    <<<"$health" >/dev/null || die \
    "agent-voice health is unexpected or muted: $health"

  wav="$TEMP_ROOT/agent-voice-setup-test.wav"
  if [[ "$PLAY_TEST" -ne 1 ]]; then
    play_args+=(--no-play)
  fi
  say "Synthesizing a real Qwen3-TTS test clip"
  "$AGENT_VOICE_SUMMARY" \
    --voice chesapeake_balanced \
    --output "$wav" \
    "${play_args[@]}" \
    "Agent voice is installed. Qwen three T T S is running locally, and Claude Code is ready to speak progress summaries."

  "$STATE_DIR/app/.venv/bin/python" - "$wav" <<'PY'
import sys
import wave
from pathlib import Path

path = Path(sys.argv[1])
with wave.open(str(path), "rb") as audio:
    frames = audio.getnframes()
    rate = audio.getframerate()
    channels = audio.getnchannels()
duration = frames / rate if rate else 0
if path.stat().st_size <= 44 or channels < 1 or not 1.0 <= duration <= 45.0:
    raise SystemExit(
        f"invalid test WAV: bytes={path.stat().st_size}, channels={channels}, duration={duration:.2f}s"
    )
print(f"Validated Qwen test WAV: {duration:.2f}s, {channels} channel(s), {path.stat().st_size} bytes")
PY
}

print_summary() {
  say ""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "Dry run passed; no files or services were changed."
    return 0
  fi
  say "Local agent voice setup passed."
  say "Voice server: $VOICE_SERVER_URL"
  say "Model: $QWEN_MODEL_ID@$QWEN_MODEL_REVISION"
  say "Service mode: $SERVICE_MODE"
  case "$SERVICE_MODE" in
    launchd)
      say "Lifecycle: launchd starts at login and restarts the server"
      ;;
    session)
      say "Lifecycle: Claude SessionStart launches $AGENT_VOICE_SESSION start"
      ;;
    foreground)
      say "Lifecycle: run $AGENT_VOICE_SESSION run in a terminal before using voice"
      ;;
  esac
  say "Claude instructions: $CLAUDE_INSTRUCTIONS"
  say "Claude settings: $CLAUDE_SETTINGS"
  say "Backups: $BACKUP_DIR"
}

main() {
  parse_args "$@"
  require_platform
  trap cleanup EXIT
  if [[ "$DRY_RUN" -eq 1 ]]; then
    TEMP_ROOT="${TMPDIR:-/tmp}/agent-voice-setup-dry-run"
  else
    TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-voice-setup.XXXXXX")"
  fi

  install_dependencies
  clone_agent_voice
  prepare_service_transition
  install_agent_voice
  install_session_helper
  download_qwen_model
  configure_claude
  start_selected_service
  run_voice_test
  stop_temporary_foreground_service
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
