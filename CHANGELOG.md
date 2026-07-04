# Changelog

All notable changes to Jarvis are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **Apple Dictation with the local provider**: three compounding bugs made Apple STT appear deaf. The AEC voice-processing unit (enabled for barge-in) feeds a multichannel format (7 ch on MacBook mic arrays) that `SFSpeechRecognizer` fails on — buffers are now downmixed to mono channel 0 before recognition, AEC is only enabled while barge-in is on, and the benign "No speech detected" (1110) recognizer error no longer tears down hands-free mode (it is equivalent to silence).
- **Hands-free survival**: an empty capture window (echo bleed, noise, a cough) no longer silently kills the conversation; echo-tainted mic state is cleared when a reply finishes so the silence watcher can't commit a garbage turn; and a resume scheduled right before Mute/Stop can no longer re-open the microphone afterwards.
- **Mute/Stop with the local provider**: the mute toggle and hotkey now hard-stop local capture (previously they only signaled the unused web runtime, leaving the mic hot behind a muted-looking UI), and the Stop button cuts the reply being spoken while keeping the conversation armed.
- **STT engine hot-switch**: web-runtime state events (connected=false heartbeats) no longer clobber the local pipeline's voice state, which made engine switches conclude nothing was listening and never re-arm capture.
- **Deferred send reliability**: the native input server remembers the typed-but-unsent brief per agent; on "envíalo" it verifies the brief is still in the agent's box and re-pastes it when missing before pressing Enter (a blind delivery could previously send an empty box), and an unverified delivery is now reported honestly instead of claimed as written.
- **Local agent history**: conversation history now preserves tool-call rounds — storing only the final sentences taught the small model the in-context pattern "claim the delegation without calling the tool", which broke second delegations.
- **Warmup robustness**: overlapping warm-up runs are serialized, and waiting for the Parakeet server bails out after ~3 s when the server is unreachable instead of burning the full 40 s timeout.

### Added
- **Premium TTS voices (local provider)**: the reply voice now picks the highest-quality installed voice (Premium > Enhanced > compact) instead of always using the robotic compact tier, and reacts live when the user downloads a new voice in System Settings (e.g. Marisol Premium). Siri voices are not exposed to third-party apps by macOS.
- **Local pipeline diagnostics**: `logs/local-voice.log` records every capture transition (engine, input format, commit/empty reason, recognition errors), and the sidecar logs each local-agent turn (transcript preview, tool calls made, delegation outcome) and every tool invocation with truncated args/result.

### Changed
- **Control Center redesign**: the console is now two zones — compact voice controls on the left, and a full-height **Live Activity** feed that merges the transcript, backend events, notifications, and approvals chronologically (auto-scrolls to the latest entry). Agent status shrank to a thin strip of colored dots (click to hear status), pending approvals surface as an inline actionable banner, an active task shows as a slim row with its Stop button, and the standalone Current Task / Approvals / Agents / Transcript cards are gone. Header actions degrade gracefully on narrow windows instead of overflowing.
- Code health: the triplicated activate-and-wait-frontmost loop and the duplicated WAV header builder were extracted into shared helpers; `parakeet-server.py` imports `queue` normally.

### Changed
- **Delegation flow (all providers)**: briefs are the assistant's interpretation of the user's intent (never a transcript), they are typed into the agent's **current** chat (new chat only on request), and they are **not sent** until the user confirms — a new `send_agent_prompt` tool presses Enter, and the progress monitor starts at the actual send.

### Added
- **Parakeet v3 speech engine (local provider)**: a selectable alternative to Apple Dictation — NVIDIA Parakeet-TDT 0.6B v3 running on MLX behind a tiny resident HTTP server (`scripts/parakeet-server.py`, port 4821, managed by the `com.jarvis.parakeet` LaunchAgent; `scripts/setup-parakeet.sh` creates the venv, using `uv` when the system Python is older than 3.10). ~0.9 GB RAM, ~0.2 s per utterance, best-in-class Spanish accuracy, and no dependency on macOS Dictation. Switch engines from the settings popover ("Speech engine").
- **Hands-free polish (local provider)**: voice barge-in — talk over Jarvis and it stops (echo-cancelled input via voice processing, with a raised threshold while the reply plays); the completion announcement now reads the agent's own answer summary; a rewritten brief REPLACES the pending one instead of appending; and a new `discard_agent_prompt` tool ("olvídalo") clears an unsent brief — available on cloud providers too.
- **Local provider capabilities**: hands-free conversation mode on the mic button (silence auto-commits the turn and listening resumes after the reply; the hotkey remains push-to-talk), current date/time in every turn, `web_search` (DuckDuckGo, no key), and light desktop actions (`quit_app`, `paste_text_into_app`, `click_in_app`, `press_keys`) plus natural delegation phrasing ("dile a Codex…"). Ollama keep-alive documented via LaunchAgent.
- **Local provider upgrades**: replies stream sentence-by-sentence to speech while the model is still generating; what you said and what Jarvis replied now appear in the transcript; a proactive monitor announces when a delegated agent finishes, gets blocked, or needs approval; the settings popover shows live Ollama status (running/model pulled); and the local agent gained open_file, read_app, search_memory, and save_memory tools.
- **Cloud provider upgrades**: Gemini Live sessions resume across reconnects (session-resumption handles survive the ~15-minute connection limit), and Grok/Gemini voices are now selectable in the settings popover (rex, leo, sal… / Charon, Fenrir, Orus…).
- **Local voice provider (v3)**: a fourth provider, "Local (Ollama)", runs the whole voice loop on-device with zero cloud cost — Apple `SFSpeechRecognizer` for on-device speech-to-text (es/en), a local Ollama model (default `qwen3:4b-instruct`, override with `JARVIS_LOCAL_MODEL`) with function calling for the agent loop, and `AVSpeechSynthesizer` for the reply. Push-to-talk only. Tools: delegate to Codex/Claude, agent status, open URL. Requires Ollama running; a clear installation hint is spoken/shown otherwise. Adds the Speech Recognition permission.
- **Multi-provider voice (v2)**: the voice layer now supports three providers, selectable from the settings popover — OpenAI Realtime (default), **Grok** via xAI's Voice Agent API (`wss://api.x.ai/v1/realtime`, same protocol, `rex` voice), and **Gemini Live** via `@google/genai` (`Charon` voice, ephemeral auth tokens, incremental transcription, function calling). Each provider stores its own API key under `secrets/` (mode 600) and mints short-lived client secrets through the sidecar. Screenshot vision (`see_screen`) remains OpenAI-only; all other tools — including delegation to Codex/Claude — work on every provider.
- Request-size limits on both local servers (Swift input server and Node sidecar) — oversized bodies are rejected with a clear error instead of growing memory without bound.
- SHA-256 checksum generated next to the release DMG.
- CI, release, and license badges in the README; issue and pull-request templates.

### Fixed
- The `AIza` (Google API key) pattern in the secret scan silently lost its literal hyphen when ported to `grep -E` (`\-` inside a bracket expression parses as a character range); keys containing hyphens now match again.

### Changed
- Oversized request bodies now return HTTP 413 from the sidecar instead of a generic 500.
- Sidecar shutdown wait is event-driven (termination handler) instead of a polling loop.
- Voice tools now restore the UI phase even when the sidecar request fails, so the interface can't get stuck in "acting"; a failed backend task also clears its task indicator.
- Shell commands run by the backend agent are bounded to a 30 s default / 5 min maximum timeout instead of running unbounded.
- Quitting Jarvis now waits for the sidecar to exit and force-kills it after 2 s, preventing orphan processes from holding port 4818.
- A failure to bind the input-action port (4819) is now reported in the UI instead of failing silently (e.g., when another instance is already running).
- Sensitive-content patterns are shared between the delegation gate and the backend risk policy from a single module, and backend log lines (including error stacks) are redacted before hitting disk.
- Progress announcements migrated from the deprecated `NSSpeechSynthesizer` to `AVSpeechSynthesizer`, with a voice matching the assistant language.
- Monitor narration failures no longer stop the agent monitor; it retries on the next poll.
- The public-repo secret scan now uses `grep` (always present on macOS) and fails loudly if the scan itself cannot run, instead of silently passing when `ripgrep` is missing.
- Accessibility tree traversal for text-input lookup now uses the same depth limits as button lookup, fixing missed chat boxes in deeply nested (Electron) windows.
- Delivery outcome (`verified`/`handoff`) is now returned per request instead of read from shared state, removing a race between concurrent deliveries.
- Spotlight file-search queries escape quotes and backslashes before being interpolated into the `mdfind` predicate.
- Corrupted memory tags in the SQLite store no longer break search/list; they are ignored with a warning.
- Agent-monitor poll failures are logged with their cause.

### Fixed
- `create-release-archive.sh` referenced the pre-rename `Samantha.app` bundle path, breaking DMG creation; the release workflow now also publishes the DMG artifact it actually builds.

## [0.1.4] - 2026-06-12

### Added
- Basic computer-control harness for gpt-realtime-2: `see_screen` (screenshot injected into the Realtime session as an image), `open_url`, `quit_app` (graceful only), `read_app` (Accessibility text from any app), `press_keys` (whitelisted combos), and `scroll`.

## [0.1.0] - 2026-06-11

### Added
- Initial public release: voice meta-controller that delegates work to Codex and Claude through their GUI apps, with delivery verification, proactive monitoring, durable memory, and light desktop actions.
