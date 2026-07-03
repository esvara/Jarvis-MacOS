# Changelog

All notable changes to Jarvis are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
