# GROK_TOOLS.md — Grok Build Tool Reference for Lutheran Radio

**Purpose**: This file exists to make Grok's capabilities **implicitly known** when working on the Lutheran Radio iOS codebase.

If you are Grok and you can read this file, **you have tools**. Never respond with "I don't have any tools", "I cannot edit files", or "I cannot run commands". Use the tools below via function calls in the exact format provided by the live session system prompt.

This file is committed alongside `CODING_AGENT.md`. It supplements (but does not replace) the permanent system prompt in `CODING_AGENT.md`. All agents working on this project — especially Grok in build/coding sessions — should read both.

**Authority when names diverge:** The live session system prompt's tool list and schemas win. This file documents project workflow and the **usual** Grok Build coding surface. If a tool is missing from the session, do not invent it; use the closest available tool.

## Current tool names (prefer these)

Older drafts of this file used legacy aliases. Prefer the live names below; treat the left column as obsolete synonyms only.

| Legacy alias (do not prefer) | Prefer |
|------------------------------|--------|
| `bash` | `run_terminal_command` |
| `edit_file` | `search_replace` |
| `write_file` | `write` |
| `file_path` on read | `target_file` (on `read_file`) |
| `browse_page` | `open_page` / `web_fetch` (whichever the session exposes) |

Timeouts on `run_terminal_command` are typically **milliseconds**, not seconds. Long `xcodebuild test` runs often need several minutes — raise `timeout`, or use `background: true` and fetch output later. Quiet stretches of 5–15 minutes can still be real work; do not cancel or restart early (see `CODING_AGENT.md` test patience).

## Core Coding Tools (Primary for iOS/Swift Work)

These are the tools you will use 95%+ of the time on this project.

### `run_terminal_command` — Execute Shell Commands
Run any command in the environment's shell (typically zsh or bash on macOS with full Xcode toolchain access).

**Use cases on this project**:
- Run the exact **Agent Verification Commands** from `README.md`
- `xcodebuild clean build`, `xcodebuild test` (prefer sequential `build-for-testing`, then `test-without-building`)
- `git status`, `git diff`, `git log --oneline -10` (only commit when the user asks)
- `find . -name "*.swift" -path "./Core/*" | head -30`
- `swift --version`, `xcrun --show-sdk-path`, `plutil`, `security`, `codesign`, etc.
- Any Apple developer tooling available on the host machine
- Discovery: `xcrun simctl list devices available` before assuming a simulator name

**Parameters** (typical; session schema is authoritative):
- `command` (string, required): The shell command to execute. Prefer single-line or `&&`-chained. Use proper quoting.
- `timeout` (integer, optional): **Milliseconds** before a still-running command may be cancelled so the agent can continue (session default applies if omitted).
- `background` (boolean, optional): Run in background (returns a task id immediately for long builds/tests).
- `description` (string): Short why for logs / UX.

**Example — Verify security model + live SSL pins (copy-paste ready)**:
```bash
dig +short +dnssec TXT securitymodels.siikkari.net
dig +short +dnssec TXT securitymodels.lutheranradio.eu
dig +short +dnssec TXT securitymodels.lutheranradio.sk
openssl s_client -connect livestream.siikkari.net:443 -servername livestream.siikkari.net < /dev/null 2>/dev/null \
  | openssl x509 -outform DER | openssl dgst -sha256
```

Primary (`securitymodels.siikkari.net`) serves the live allow-list. Secondary/backup mirror it for transient-only fallback. Leaf DER SHA-256 for `*.siikkari.net` must match `pinnedSiikkariLeafFingerprintDigest` / `pinnedFingerprintDigests` in `SecurityConfiguration` (see README "Current Security Snapshot" and "Media Apex Cutover").

**Example — Clean build (canonical gate from CODING_AGENT.md — bleeding-edge for agents)**:
```bash
xcrun simctl list devices available
xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator27.0 \
  -destination 'platform=iOS Simulator,OS=27.0,name=iPhone 17 Pro' clean build-for-testing
# Look for: ** TEST BUILD SUCCEEDED **

xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator27.0 \
  -destination 'platform=iOS Simulator,OS=27.0,name=iPhone 17 Pro' test-without-building
# Look for: ** TEST SUCCEEDED **
```

Substitute destination from discovery when the canonical device is unavailable. Mechanical warning-only work may use the lighter gates in `CODING_AGENT.md` (full `test-without-building` remains mandatory).

**Best practice**: After any edit that affects runtime behavior, security, or user-visible chrome, always run the relevant build/test gate and include output in your reasoning. Report **Security impact** / **Build status** / **Localization needed** per `CODING_AGENT.md`.

### `read_file` — Read File Contents
Read any file in the working directory (and often absolute paths). Supports large files via offset/limit. Prefer this over shell `cat`/`head` for source and docs.

**Critical on this project**:
- Always follow the **Layered permanent sources** reading order from `CODING_AGENT.md` for security work.
- Read `Core/Core.docc/Articles/Security-Invariants.md`, `Core/Core.docc/Articles/Architecture.md`, and implementation files before proposing security changes.
- Before touching DNS, certs, or the security model: confirm sources under `Core/` (`SecurityConfiguration`, `SecurityModelValidator`, `CertificateValidator`, `CertificateFingerprint`).
- Use for Swift files, `.xcstrings`, `Info.plist`, entitlements, DocC, permanent `docs/`, etc.
- Widget / LA / home chrome: read the permanent docs under `docs/` (mechanism names only; never cite untracked living briefs in product code).

**Parameters** (typical):
- `target_file` (string, required)
- `offset` (integer, optional): Line number to start from (1-based)
- `limit` (integer, optional): Max lines to return

**Example**: Read `Core/Configuration/SecurityConfiguration.swift` with a modest `limit` when only policy constants are needed.

### `search_replace` — Precise In-Place Edit (Preferred for modifications)
The primary tool for changing existing code. Performs exact string replacement.

**Rules for this project** (from `CODING_AGENT.md`):
- **Always** read the file (or relevant section) first.
- Plan the change, then perform the minimal correct edit.
- Match exact text (including indentation); keep replacements unique or use `replace_all` intentionally.
- After edit, re-read the changed section when non-trivial + run build gates.
- Every edit touching security, `unsafe`, Sendable, or single-source-of-truth must improve documentation and add/update `// SAFETY:` / `// SECURITY:` comments.
- Never weaken certificate pinning or DNS validation.

**Parameters** (typical):
- `file_path` (string)
- `old_string` (string): Exact text to replace (must be unique unless `replace_all=true`)
- `new_string` (string): Replacement text
- `replace_all` (boolean, optional, default false)

**Example** (surgical fix): replace a hard-coded model string with `SecurityConfiguration.current.expectedSecurityModel` inside `Core/` only after reading the surrounding SSOT.

### `write` — Write or Overwrite Entire File
Use **only** for brand new files or complete rewrites where `search_replace` is impractical. Prefer `search_replace` for almost everything.

**Parameters** (typical):
- `file_path`
- `content` (string): Full new content of the file

### `grep` — Search file contents (ripgrep)
Prefer over shell `rg`/`grep` for codebase search.

**Use on this project**:
- Locate SSOT call sites (`homeWidgetLiveChrome`, `emit(`, `refreshIfNeeded`, `pinnedFingerprintDigests`, …)
- Find emission / stamp / Provider resolution sites before editing
- Audit force-unwraps or bare `@preconcurrency import` on touched paths

**Parameters** (typical): `pattern` (required), `path`, `glob`, `type`, context flags (`-A` / `-B` / `-C`).

### `list_dir` — List directory contents
Prefer over `ls` when exploring structure. Session ignore rules may hide gitignored paths.

### `todo_write` — Multi-step task board
Use for 3+ step work so progress stays visible. Skip for trivial single-file fixes.

## Secondary / Supporting Tools

### Web & Research Tools
- `web_search` — Search the web (useful for Apple Developer docs, Swift 6 concurrency patterns, AVFoundation background audio gotchas, etc.)
- `open_page` / `web_fetch` — Fetch a specific URL (names vary by session; use whichever is listed)
- Image tools (`image_gen`, `image_edit`, …) — Only relevant if working on app icons, onboarding graphics, or marketing assets (see `docs/ios26icon-*.png` and session image skills)

### X / Twitter Tools
Rarely needed unless researching Lutheran radio mentions or community feedback. Use `x_keyword_search`, `x_semantic_search`, etc. if required. Not for security or SSOT decisions.

### Skills (Advanced)
Grok has access to **skills** (bundled capabilities). To use one:
1. `read_file` the skill's `SKILL.md` (typical paths: `~/.grok/skills/<skill>/SKILL.md` or a session-bundled skill root)
2. Follow the instructions in that skill file

**Often relevant on this project** (when installed): `check-work`, `review`, `device-interaction`, `modernize-tests`, `audit-xcode-security-settings`, `swiftui-specialist`, `swiftui-whats-new-27`.

For day-to-day Lutheran Radio coding the default remains disciplined use of `run_terminal_command` + `read_file` / `search_replace` / `grep`.

### Subagents / plan / MCP (when available)
- Explore / plan / general-purpose subagents for large read-only sweeps or parallel work
- If MCP servers are connected, discover tools with the session's MCP search/use path before calling — do not guess schemas. Never use MCP to bypass Core security policy.

### Render Components (Final Response Only)
These are **not** tools for gathering information or editing code. They are used only in your *final* response to the user when the session defines them (e.g. inline citations, generated-image display helpers).

Do **not** call them as ordinary coding tools. Use them only to enhance the final answer when appropriate.

## Environment Notes for Lutheran Radio
- Working directory is the root of this repository.
- Prefer **Xcode 27+** / iOS 27 simulators for agent gates (full MIE/EMTE); human contributors may use stable Xcode 26.x per README. Minimum deployment target is **iOS 26.2**.
- On macOS hosts you have full access to Xcode command-line tools (`xcodebuild`, `xcrun`, `swift`, `agvtool`, etc.).
- Strict Swift 6 + memory safety build settings are enforced project-wide. Clean builds must emit **zero warnings** (unless the PR is scoped to warning cleanup per `CODING_AGENT.md`).
- Security work **must** follow the mandatory reading order and verification commands documented in `README.md` and `CODING_AGENT.md`. Never duplicate DNS/cert logic outside `Core/`.
- Cross-process home/Control paint: privacy-gated App Group ``homeWidgetLiveChrome`` + ``homeWidgetStreamMetadata``; `reloadTimelines` is wake-only. Canonical: `docs/Home-Live-Chrome-App-Group-Mirror-Design.md`, `docs/Widget-Presentation-Dataflow.md`.
- Live Activity language / lock-stretch work: read `docs/Live-Activity-Stacking-and-Media-Surfaces.md` and `docs/Widget-Functionality-Roadmap.md` (ContentState convergence) before changing ensure/recreation policy. Soft language ensure may lag under continuous lock-ineligible; become-active heals; never end the only interactive LA while request is ineligible solely for language lag. Product comments must use mechanism names only (never living prompts or evidence filenames).
- Event path is non-forcing and main-app only; the extension never observes `PlayerEvent`. See `docs/Event-Driven-Refactor-Roadmap.md`.
- After any file modification, you are expected to run the appropriate verification commands and report results.

## Maintenance

This file is the **authoritative project-side description** of how Grok should use tools on the Lutheran Radio codebase.

- Update it when the underlying Grok tool surface changes or when better Xcode / security-specific examples are discovered.
- Prefer **stable tool names + project commands** over hard-coding a function-call XML dialect that will drift.
- Changes should be reviewed for accuracy against the actual function-calling capabilities (live session schemas win on conflict).
- All agents (especially Grok) should treat the combination of `CODING_AGENT.md` + this file as the complete context for tool-using work on this project.

**Remember**: Security invariants > everything else. When in doubt, re-read `CODING_AGENT.md` sections on documentation standards and required rules before touching `Core/` or security-related files.
