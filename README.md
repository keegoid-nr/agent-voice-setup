# Local agent voice setup

One-command setup for local agent voice on macOS Apple Silicon:

- `agent-voice` on `127.0.0.1:8880`, managed by launchd, a Claude-started
  session supervisor, or a foreground terminal.
- Qwen3-TTS VoiceDesign through MLX-Audio with `chesapeake_balanced` as the
  general default and `cool_street_deadpan` retained for Fig cues.
- Claude Code progress cues timed like Codex: start, important boundary, and
  closing handoff.
- A final audible synthesis test that loads Qwen and validates the generated
  WAV. A health response alone is not accepted as proof.

The TTS path is
`Claude Code -> agent-speak -> agent-voice -> MLX-Audio -> Qwen3-TTS`.

## Requirements

- macOS on Apple Silicon.
- [Homebrew](https://brew.sh/) already installed.
- A logged-in desktop session, internet access, and roughly 8 GB of free disk
  space. The pinned Qwen model is about 4.2 GB before runtime dependencies and
  caches.

Homebrew is a deliberate prerequisite so executable downloads are installed
through its checksum-verifying package flow. Agent-voice is pinned by commit
and a second tree checksum, while every Qwen model blob is verified against its
content-addressed Git or SHA-256 digest. Setup never executes a `curl | sh`
pipeline, keeping it usable on managed work laptops.

## Run

```bash
chmod +x setup.sh
./setup.sh
```

On a managed Mac where `launchctl bootstrap` is unavailable:

```bash
./setup.sh --service-mode session
```

Session mode adds an asynchronous Claude Code `SessionStart` hook. Opening or
resuming Claude starts a detached supervisor, and the supervisor restarts the
voice server if it exits or the TTS watchdog terminates a wedged process. It
does not require administrator access or launchd. After a reboot, voice becomes
available when Claude Code starts.

If background processes are also restricted, use foreground mode:

```bash
./setup.sh --service-mode foreground
~/.local/bin/agent-voice-session run
```

Keep that terminal open while using voice. Setup temporarily starts the same
supervisor for its real synthesis test, then stops it.

The first run downloads several gigabytes and can take a while. At the end you
should hear:

> Agent voice is installed. Qwen three T T S is running locally, and Claude
> Code is ready to speak progress summaries.

Useful options:

```bash
./setup.sh --dry-run
./setup.sh --no-play
./setup.sh --service-mode session
./setup.sh --service-mode foreground
```

`--no-play` still synthesizes and validates a real WAV; it only suppresses
speaker playback.

## Installed state

| Path or endpoint | Purpose |
| --- | --- |
| `~/.agent-voice` | App, pinned source, logs, model cache, and backups |
| `~/.local/bin/agent-speak` | Best-effort helper used by agents |
| `~/.local/bin/agent-voice-summary` | Strict synthesis/playback helper |
| `~/.local/bin/agent-voice-session` | Non-launchd supervisor controls |
| `http://127.0.0.1:8880` | Local agent-voice server |
| `~/.claude/CLAUDE.md` | Managed voice timing instructions |
| `~/.claude/settings.json` | `agent-speak` permission and optional session hook |

Existing Claude files are preserved outside a marked managed block. Before
editing them, setup writes copies under `~/.agent-voice/backups/setup-*`.
The upstream agent-voice installer also backs up the installed app and shims.

To use a different spoken identity prefix:

```bash
AGENT_VOICE_CLAUDE_SPEAKER="My agent here." ./setup.sh
```

## Server configuration

`setup.sh` verifies a pinned agent-voice checkout, applies the tracked
two-voice `chesapeake_balanced`/`cool_street_deadpan` catalog overlay, and
delegates runtime setup to
that temporary verified source. The installed server is configured as follows:

1. Application files and an isolated Python environment are installed under
   `~/.agent-voice/app`. MLX-Audio and the rest of the locked Python runtime are
   installed with `uv`.
2. Command shims are written to `~/.local/bin` for `agent-voice`,
   `agent-speak`, and `agent-voice-summary`.
3. Uvicorn starts `agent_voice.server:app`, bound only to `127.0.0.1:8880`.
   In the default `launchd` mode, a LaunchAgent named
   `com.keegoid.agent-voice` owns that process. In `session` and `foreground`
   modes, setup applies the tracked `patches/agent-voice-no-service.patch` to a
   temporary copy of the verified source so the upstream installer does not
   write or bootstrap a LaunchAgent. The verified stored source remains
   unchanged.
4. Every lifecycle mode sets `HF_HOME` to
   `~/.agent-voice/model-cache/huggingface`, keeping model data within the
   managed state directory, and writes logs under `~/.agent-voice/logs`.
   Launchd starts at login. The session supervisor starts from Claude's
   asynchronous `SessionStart` hook. Foreground mode starts only when
   `agent-voice-session run` is active. Both supervisors restart the server if
   it exits.
5. Setup downloads the pinned Qwen3-TTS snapshot into that cache, verifies its
   content-addressed blobs, and confirms the health response reports the
   expected model and exactly the two supported voices.
6. The final test calls the real speech endpoint, optionally plays the result,
   and validates that the response is a plausible WAV rather than accepting a
   health response as proof of synthesis.

The service is loopback-only. It is not exposed to the local network.

## Verification and operations

```bash
curl -fsS http://127.0.0.1:8880/v1/health | jq .
~/.local/bin/agent-voice status
~/.local/bin/agent-voice logs
~/.local/bin/agent-voice restart
~/.local/bin/agent-voice mute
~/.local/bin/agent-voice unmute
~/.local/bin/agent-speak "Claude Code here. This is a manual voice test."
~/.local/bin/agent-voice-session status
~/.local/bin/agent-voice-session restart
~/.local/bin/agent-voice-session logs
```

The `agent-voice-session` commands apply to `session` and `foreground` modes.
Rerunning setup with a different service mode stops the managed session
supervisor, unloads a prior voice LaunchAgent when accessible, and removes only
the setup-managed Claude hook. Unrelated Claude hooks are preserved.

The setup pins:

- agent-voice commit `a9a80699323c4376a745f717772130efdf1f3c06`,
  including the repaired Qwen sampler, plus the tracked cool-street voice
  overlay in `overlays/agent_voice/voices.py`.
- Qwen model revision `7d3824abff87e49756bb0f83fb5411de75d160c4`.

The Hugging Face cache is content-addressed. Setup recalculates every snapshot
blob's Git or SHA-256 digest before the model is loaded.

## Rollback

List voice backups or remove the managed runtime with:

```bash
~/.local/bin/agent-voice restore --list
~/.local/bin/agent-voice uninstall
```

Restore the desired `CLAUDE.md` and `settings.json` copies from the reported
`~/.agent-voice/backups/setup-*` directory if you want to remove the Claude
integration as well.

## License

Apache-2.0. See [LICENSE](LICENSE).
