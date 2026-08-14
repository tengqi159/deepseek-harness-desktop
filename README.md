# DeepSeek Harness for macOS — the native layer upstream doesn't ship

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> · English
</p>

<p align="center"><strong>Upstream DeepSeek Harness plans, codes, and calls tools. This companion gives it hands on your Mac — drag in your research files, capture one window safely, and attach exactly one app for Computer Use.</strong></p>

<p align="center">
  <img src="docs/images/hero-files.png" alt="Dropping research files into DeepSeek Harness for macOS" width="920">
</p>

<p align="center"><sub>Sanitized product demo based on the real interface. No user files, accounts, or API keys.</sub></p>

<p align="center">
  <a href="https://github.com/tengqi159/deepseek-harness-macos/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/tengqi159/deepseek-harness-macos/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Source Preview" src="https://img.shields.io/badge/status-source_preview-f59e0b">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">
</p>

## Why this project exists

Upstream Harness is already a strong agent runtime: planning, coding, tools, subagents, workflows. But on a Mac it stops at the browser tab — while your actual work lives in Finder, Preview, and other apps. The paper is in Finder, the result plot is in Preview, and the interface you need help with is in another app.

This companion is the native layer that closes that gap. It does not fork or rewrite upstream — it hosts the verified runtime and adds what a Mac-native agent needs:

- **Research files by drag-and-drop** — PDFs, Office, Markdown, code, data, images, and mixed batches become managed, removable cards in the conversation. Originals stay untouched.
- **A local artifact workbench that tells the truth** — bounded text extraction, page-referenced PDF search, selected-page rendering, and opt-in local OCR. What the model actually saw is never oversold.
- **Appshot** (`⌘⇧⌥2`) — one-shot capture of the exact frontmost window, secrets masked locally in text and pixels, preview before anything is saved. A reviewable snapshot, not screen sharing.
- **Bounded macOS Computer Use** — attach one exact running app; Accessibility semantics plus optional in-memory OCR drive clicks, typing, scrolling, and waits, locked to the process lifetime and a fresh window snapshot.
- **Capability routing that fails closed** — images only go through native routes when the exact provider and model verifiably support them; unknown, expired, or text-only routes fall back to managed references instead of pretending.
- **A verified upstream** — the companion accepts only the pinned, digest-checked `@deepseek-ai/dsh` runtime; unknown builds are refused.

> [!NOTE]
> **Unofficial source preview.** This is an independent community project, not affiliated with or endorsed by DeepSeek. We publish source, not an Apple-notarized binary — [Distribution](docs/DISTRIBUTION.md) spells out exactly what blocks a public download and what we verify before shipping one. Build locally and review the permissions you enable.

## What changes in everyday work

### “Compare these papers—and tell me which page supports the answer.”

Drag PDFs, Markdown, source code, Office files, images, or a mixed batch from Finder. They become removable draft cards tied to that conversation, while the originals stay untouched.

PDFs and Office files are managed locally. A tool can extract bounded text, search a PDF with page references, or render selected pages when the task needs it. That is different from claiming the selected model natively understood the raw document — and we say so out loud.

A pure image batch keeps the upstream image route only when the exact provider and model are verified as image-capable. Unknown or text-only routes fall back to managed references instead of pretending the model saw pixels.

Detailed limits and file-safety rules: [Artifact Bridge](integration/ARTIFACT_BRIDGE.md) and [Privacy](docs/PRIVACY.md).

### “Show the agent this window, but not my whole desktop or a password beside it.”

Appshot (`⌘⇧⌥2`) captures the exact frontmost window once, masks likely secrets locally in both text and pixels, and gives you a preview. Nothing is saved until you confirm, and sending the result to a model remains an explicit action.

Appshot is a reviewable snapshot—not continuous screen sharing.

### “Look at this app and help me—but stop before anything consequential.”

Attach one exact running Mac app. Harness can use Accessibility semantics and optional local OCR for that app's focused window, then perform bounded clicks, typing, scrolling, selection, or waits.

The attachment is locked to the process, its lifetime, and a fresh window snapshot. Known login, Keychain, password-manager, secure-field, and system-security surfaces are blocked; likely secrets are redacted. These defenses cannot recognize every custom sensitive interface.

For sending, publishing, purchasing, deleting, installing, or changing permissions, the bundled safety instructions tell the agent to stop and ask for immediate, explicit confirmation. Computer Use screenshots stay in memory and are not sent as image blocks; bounded Accessibility/OCR **text** may enter model context and local session history.

<p align="center">
  <img src="docs/images/app-control.png" alt="Attaching one Mac app for bounded Computer Use" width="920">
</p>

<p align="center"><sub>Sanitized product demo based on the real interface. No user files, accounts, or API keys.</sub></p>

This is useful semantic/OCR-assisted control. It is **not Codex-style end-to-end visual computer control**, and some custom-drawn interfaces will not work.

## Models and tools that tell the truth

The routing pipeline states what it can and cannot see, and fails closed when it is unsure:

- The verified DeepSeek rc.6 route is treated as text-only; local extraction or OCR does not become “native vision.”
- An upstream Kimi route may keep native image blocks only when the selected model explicitly declares image input.
- Unknown, loading, mismatched, or expired capability records fail closed to managed files.
- Video upload and audio transcription are not shipped.
- Plugin Health shows startup discovery, not a promise of permanent availability. A model may choose a registered tool automatically, but invocation is never guaranteed.

Provider keys are configured in **Harness Settings → Models**. They are not stored in this repository or in the model capability registry.

## What this companion contributes

| Experience | Where it comes from |
| --- | --- |
| Conversations, workspaces, model settings, commands, plans, goals, subagents, workflows, and jobs | Upstream `@deepseek-ai/dsh` |
| Provider adapters, including supported Kimi routes, plus the Skill / MCP framework | Upstream `@deepseek-ai/dsh` |
| Native app window, toolbar, app lifecycle, and no required browser tab | This companion |
| Finder file drop, managed research files, PDF / Office helpers, and removable draft cards | This companion |
| Appshot, exact-app attachment, bounded Computer Use, capability routing, and plugin health | This companion |

The companion hosts and extends the verified upstream client; it does not replace or rewrite Harness.

## Quick start from source

Current targets: companion **1.4.1 (build 6)**, upstream **`@deepseek-ai/dsh@0.1.0-rc.6`**, macOS **14+**, and Apple Silicon. Intel is not yet validated.

Requirements: Xcode Command Line Tools with Swift 5.10+, Node.js 22, and npm.

```bash
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
dsh --version
git clone https://github.com/tengqi159/deepseek-harness-macos.git
cd deepseek-harness-macos
./scripts/build_and_run.sh package
```

`dsh --version` must report `0.1.0-rc.6`. The companion also checks the verified executable digest and refuses an unknown build.

The package command uses ad-hoc signing and creates `outputs/DeepSeek Harness.zip`; it does not install a certificate or modify your keychain.

```bash
mkdir -p "$HOME/Applications"
ditto -x -k "outputs/DeepSeek Harness.zip" "$HOME/Applications"
open "$HOME/Applications/DeepSeek Harness.app"
```

On first launch, configure a provider in **Settings → Models**. Keep only one installed copy of the app so macOS does not create duplicate permission entries. A signing-identity change may require permission approval again.

> [!NOTE]
> The app uses its own home under `~/Library/Application Support/DeepSeek Harness/` and does not rewrite the global npm package. On first setup, if the app-specific destination does not exist, it may copy existing `~/.dsh` model settings and credentials into that private home with owner-only permissions.

## Permission and data boundaries

| Permission / data | What it enables | What it does not do |
| --- | --- | --- |
| Accessibility | Semantic reading and bounded actions in the attached app | Cannot be granted by Harness; does not authorize every app automatically |
| Screen Recording | Appshot and optional focused-window OCR | Does not turn on continuous remote viewing |
| Provider API | Conversations and content you or a workflow sends | Does not make local files private after you choose to send extracted content |
| Managed files | Local research-file workflows under Application Support | Does not modify originals; removing a draft card does not delete the managed copy |

Harness is served on a random loopback port in a non-persistent `WKWebView`. That reduces accidental collisions; it is not a complete authentication or sandbox boundary. Read [Privacy](docs/PRIVACY.md) and [Security](SECURITY.md) before enabling control for sensitive apps.

## Status and roadmap

Being a source preview is a deliberate choice, not an accident: we will not publish a public binary until it earns one.

- Source preview today: no notarized `.dmg`, `.zip`, or generally downloadable app release.
- Apple Silicon on macOS 14+ is tested; Intel support is not claimed.
- Only the verified upstream rc.6 runtime and digest are accepted.
- The main interface remains upstream web UI inside `WKWebView`, not a full SwiftUI rewrite.
- No general video upload, audio transcription, automatic permission granting, guaranteed tool invocation, or Codex-equivalent visual control.

Next on the roadmap: Developer ID signing and Apple notarization, clean-Mac Gatekeeper validation, and broader architecture qualification. See [Distribution](docs/DISTRIBUTION.md).

## Build confidence

CI covers compilation and deterministic checks. The repository also includes artifact, Appshot, native file-drop, real `WKWebView` drop-lifecycle, and disposable-window Computer Use suites. Full artifact tests require [`uv`](https://docs.astral.sh/uv/); real OCR, permissions, and window actions must still be verified locally in a logged-in macOS session.

```bash
swift build --package-path app -c release
./scripts/test_artifact_bridge.sh
./scripts/test_appshot_qa.sh
./scripts/test_native_file_drop.sh
./scripts/test_webview_file_drop.sh
./scripts/test_app_bridge_e2e.sh
```

## Read the details

[Privacy](docs/PRIVACY.md) · [Security](SECURITY.md) · [Distribution](docs/DISTRIBUTION.md) · [Artifact Bridge](integration/ARTIFACT_BRIDGE.md) · [Computer Use testing](app/APP_BRIDGE_TESTING.md) · [Contributing](CONTRIBUTING.md)

## License and acknowledgements

This companion source is available under the [MIT License](LICENSE). See [NOTICE](NOTICE.md) for upstream attribution and trademark boundaries. Issues and focused pull requests are welcome; report vulnerabilities privately through [SECURITY.md](SECURITY.md).
