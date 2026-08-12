# Local agent voice setup

One-command setup for local agent voice on macOS Apple Silicon:

- `agent-voice` on `127.0.0.1:8880` as a login LaunchAgent.
- Qwen3-TTS VoiceDesign through MLX-Audio with the `questline_deadpan` voice.
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

The first run downloads several gigabytes and can take a while. At the end you
should hear:

> Agent voice is installed. Qwen three T T S is running locally, and Claude
> Code is ready to speak progress summaries.

Useful options:

```bash
./setup.sh --dry-run
./setup.sh --no-play
```

`--no-play` still synthesizes and validates a real WAV; it only suppresses
speaker playback.

## Installed state

| Path or endpoint | Purpose |
| --- | --- |
| `~/.agent-voice` | App, pinned source, logs, model cache, and backups |
| `~/.local/bin/agent-speak` | Best-effort helper used by agents |
| `~/.local/bin/agent-voice-summary` | Strict synthesis/playback helper |
| `http://127.0.0.1:8880` | Local agent-voice server |
| `~/.claude/CLAUDE.md` | Managed voice timing instructions |
| `~/.claude/settings.json` | Narrow permission for `agent-speak` |

Existing Claude files are preserved outside a marked managed block. Before
editing them, setup writes copies under `~/.agent-voice/backups/setup-*`.
The upstream agent-voice installer also backs up the installed app and shims.

To use a different spoken identity prefix:

```bash
AGENT_VOICE_CLAUDE_SPEAKER="My agent here." ./setup.sh
```

## Server configuration

`setup.sh` verifies a pinned agent-voice checkout and delegates runtime setup
to that checkout's installer. The installed server is configured as follows:

1. Application files and an isolated Python environment are installed under
   `~/.agent-voice/app`. MLX-Audio and the rest of the locked Python runtime are
   installed with `uv`.
2. Command shims are written to `~/.local/bin` for `agent-voice`,
   `agent-speak`, and `agent-voice-summary`.
3. A macOS LaunchAgent named `com.keegoid.agent-voice` starts Uvicorn with
   `agent_voice.server:app`, bound only to `127.0.0.1:8880`.
4. The LaunchAgent sets `HF_HOME` to
   `~/.agent-voice/model-cache/huggingface`, keeping model data within the
   managed state directory. It runs at login, restarts if it exits, and writes
   logs under `~/.agent-voice/logs`.
5. Setup downloads the pinned Qwen3-TTS snapshot into that cache, verifies its
   content-addressed blobs, and confirms the health response reports the
   expected model and `questline_deadpan` voice.
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
```

The setup pins:

- agent-voice commit `a9a80699323c4376a745f717772130efdf1f3c06`,
  including the repaired Qwen sampler.
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
