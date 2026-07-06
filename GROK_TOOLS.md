# GROK_TOOLS.md — Grok Build Tool Reference for Lutheran Radio

**Purpose**: This file exists to make Grok's capabilities **implicitly known** when working on the Lutheran Radio iOS codebase.

If you are Grok and you can read this file, **you have tools**. Never respond with "I don't have any tools", "I cannot edit files", or "I cannot run commands". Use the tools below via function calls in the exact XML format.

This file is committed alongside `CODING_AGENT.md`. It supplements (but does not replace) the permanent system prompt in `CODING_AGENT.md`. All agents working on this project — especially Grok in build/coding sessions — should read both.

## Core Coding Tools (Primary for iOS/Swift Work)

These are the tools you will use 95%+ of the time on this project.

### `bash` — Execute Shell Commands
Run any command in the environment's shell (typically zsh or bash on macOS with full Xcode toolchain access).

**Use cases on this project**:
- Run the exact **Agent Verification Commands** from `README.md`
- `xcodebuild clean build`, `xcodebuild test`
- `git status`, `git diff`, `git log --oneline -10`
- `find . -name "*.swift" -path "./Core/*" | head -30`
- `swift --version`, `xcrun --show-sdk-path`, `plutil`, `security`, `codesign`, etc.
- Any Apple developer tooling available on the host machine

**Parameters**:
- `command` (string, required): The shell command to execute. Prefer single-line or `&&`-chained. Use proper quoting.
- `timeout` (integer, optional, default 30): Seconds before killing the command.
- `background` (boolean, optional): Run in background (returns PID immediately).
- `maxOutputLength` (integer, optional): Max characters in output.

**Example — Verify security model (copy-paste ready)**:
```xml
call tool bash with command is dig +short +dnssec TXT securitymodels.lutheran.radio
```

**Example — Clean build (canonical gate from CODING_AGENT.md — bleeding-edge for agents)**:
```xml
call tool bash with command is xcrun simctl list devices available && xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator27.0 -destination 'platform=iOS Simulator,OS=27.0,name=iPhone 17 Pro' clean build-for-testing
```

**Best practice**: After any edit, always run the relevant build/test gate and include output in your reasoning.

### `read_file` — Read File Contents
Read any file in the working directory. Supports large files via offset/limit.

**Critical on this project**:
- Always follow the **Layered permanent sources** reading order from `CODING_AGENT.md` for security work.
- Read `Core.md`, `Core/Core.docc/Articles/Security-Invariants.md`, implementation files before proposing changes.
- Use for Swift files, `.xcstrings`, `Info.plist`, entitlements, `Package.swift` (if any), etc.

**Parameters**:
- `file_path` (string, required)
- `offset` (integer, optional): Line number to start from (1-based)
- `limit` (integer, optional): Max lines to return

**Example**:
```xml
call tool read_file with file_path is Core/Configuration/SecurityConfiguration.swift limit is 80
```

### `edit_file` — Precise In-Place Edit (Preferred for modifications)
The primary tool for changing existing code. Performs exact string replacement.

**Rules for this project** (from `CODING_AGENT.md`):
- **Always** read the file (or relevant section) first.
- Plan the change, then perform the minimal correct edit.
- After edit, re-read the changed section + run build gates.
- Every edit touching security, `unsafe`, Sendable, or single-source-of-truth must improve documentation and add/update `// SAFETY:` / `// SECURITY:` comments.
- Never weaken certificate pinning or DNS validation.

**Parameters**:
- `file_path` (string)
- `old_string` (string): Exact text to replace (must be unique unless `replace_all=true`)
- `new_string` (string): Replacement text
- `replace_all` (boolean, optional, default false)
- `show_diff` (boolean, optional, default false)

**Example** (surgical fix):
```xml
call tool edit_file with file_path is Core/Actors/SecurityModelValidator.swift old_string is let expected = "oldmodel" new_string is let expected = SecurityConfiguration.current.expectedSecurityModel
```

### `write_file` — Write or Overwrite Entire File
Use **only** for brand new files or complete rewrites where `edit_file` is impractical. Prefer `edit_file` for almost everything.

**Parameters**:
- `file_path`
- `content` (string): Full new content of the file

## Secondary / Supporting Tools

### Web & Research Tools
- `web_search` — Search the web (useful for Apple Developer docs, Swift 6 concurrency patterns, AVFoundation background audio gotchas, etc.)
- `browse_page` — Fetch and summarize a specific URL with custom instructions (e.g. Apple Tech Notes, Swift forums threads)
- `search_images` / `generate_image` / `edit_image` — Only relevant if working on app icons, onboarding graphics, or marketing assets (see `docs/ios26icon-*.png`)

### X / Twitter Tools
Rarely needed unless researching Lutheran radio mentions or community feedback. Use `x_keyword_search`, `x_semantic_search`, etc. if required.

### Skills (Advanced)
Grok has access to **skills** (bundled capabilities). To use one:
1. `read_file` the skill's `SKILL.md` (usually at `/root/.grok/skills/<skill>/SKILL.md` or similar in the environment)
2. Follow the instructions in that skill file (e.g. `pdf`, `docx`, `ffmpeg` for media tasks, `xlsx` for data work)

For this iOS radio app the most relevant "skill" is usually just disciplined use of `bash` + `read_file`/`edit_file`.

## Render Components (Final Response Only)
These are **not** tools for gathering information or editing code. They are used only in your *final* response to the user:
- `render_inline_citation`
- `render_searched_image`, `render_generated_image`, `render_edited_image`
- `render_file`

Do **not** call them as function calls. Use them to enhance the final answer (e.g. show a generated icon mockup or cite a source).

## Environment Notes for Lutheran Radio
- Working directory is the root of this repository.
- On macOS hosts you have full access to Xcode 26+ command-line tools (`xcodebuild`, `xcrun`, `swift`, `agvtool`, etc.).
- Strict Swift 6 + memory safety build settings are enforced project-wide. Clean builds must emit **zero warnings**.
- Security work **must** follow the mandatory reading order and verification commands documented in `README.md` and `CODING_AGENT.md`.
- After any file modification, you are expected to run the appropriate verification commands and report results.

## Maintenance

This file is the **authoritative description** of the tools available to Grok when working on the Lutheran Radio codebase.

- Update it when the underlying Grok tool surface changes or when better Xcode / security-specific examples are discovered.
- Changes should be reviewed for accuracy against the actual function-calling capabilities.
- All agents (especially Grok) should treat the combination of `CODING_AGENT.md` + this file as the complete context for tool-using work on this project.

**Remember**: Security invariants > everything else. When in doubt, re-read `CODING_AGENT.md` sections on documentation standards and required rules before touching `Core/` or security-related files.
