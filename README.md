# DeepSeek Harness Desktop

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> · English
</p>

<p align="center"><strong>A focused macOS companion for DeepSeek Harness — built for research files, deliberate Mac context, and optional remote compute.</strong></p>

> [!IMPORTANT]
> **Unofficial community project.** It is not affiliated with, maintained by, sponsored by, or endorsed by DeepSeek. This repository is a source preview; it does not ship a notarized public app.

<p align="center">
  <a href="https://github.com/tengqi159/deepseek-harness-desktop/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/tengqi159/deepseek-harness-desktop/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Source Preview 1.7.1" src="https://img.shields.io/badge/source_preview-1.7.1-f59e0b">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M%20series-111827?logo=apple">
  <img alt="Upstream dsh 0.1.1-rc.2" src="https://img.shields.io/badge/upstream_dsh-0.1.1--rc.2-334155">
</p>

## What changed in 1.7.1 (build 19)

This source preview moves the compatibility lock to upstream `@deepseek-ai/dsh@0.1.1-rc.2`. It keeps the upstream persistent-Bash prompt fix and adds an exact, fail-closed Vision route rather than labeling every DeepSeek model as multimodal.

- **Flash Vision images stay images.** When the live provider/model is exactly `deepseek-official` / `deepseek-v4-flash-vision-exp`, a PNG/JPEG/image clipboard paste is handed to the upstream composer. You see its thumbnail attachment, and the adapter serializes the transient request as an image block—not a `[DeepSeek Harness managed attachment …]` line.
- **Other routes remain honest.** `deepseek-v4-flash`, `deepseek-v4-pro`, unknown models, PDFs, non-images, mixed batches, and over-limit images remain managed locally. OCR is never an automatic substitute for raw vision; it is an explicit local-tool fallback.
- **Existing settings are migrated narrowly.** Harness settings override the bundled catalog, so launch repairs only the exact Vision model's `inputModalities` record, keeps all other user model settings intact, and saves one owner-only pre-migration backup.
- **Upgrade-safe integrations.** The managed Web profile, attachment client, capability menu, and MCP bridges are tested against rc.2. The app checks the upstream launcher, persistent-shell fix, and DeepSeek image serializer before it launches.

### Real Vision smoke test

<p align="center">
  <img src="docs/images/vision-smoke-1.7.1.jpg" alt="DeepSeek Harness showing a thumbnail image attachment and a visual description from the exact Flash Vision route" width="838">
</p>

The screenshot uses a synthetic app icon and a one-line demo prompt. It shows the desired contract: the composer and conversation retain a thumbnail, while the model describes visual structure rather than receiving a managed-file reference sentence.

## What 1.6.9 stabilized

This source preview focuses on making the everyday attachment path dependable rather than adding another layer of complexity.

- **Image drops no longer borrow a model route from another conversation.** A delayed capability update from an old conversation can no longer send an image from an active DeepSeek conversation into the wrong upstream path and produce the misleading “current model does not support images” message.
- **Images can be dragged or pasted into a DeepSeek conversation.** Text-only or unknown routes fall back to a session-bound managed attachment instead of being rejected by the upstream image composer. Ordinary text paste remains ordinary text paste.
- **Removed attachments stay removed.** The attachment lifecycle now survives delayed acknowledgements, reloads, and a new blank conversation without restoring a discarded PDF, image, or Markdown card over your draft.
- **No accidental page reload while an attachment is arriving.** The native wrapper now treats equivalent local URLs as the same page, so a harmless trailing slash or client-side route change does not wipe the in-page attachment state.
- **A quieter toolbar.** File/library/Appshot/app-context actions live under one **Context & Attachments** menu. Dragging or pasting into the chat remains the direct way to add material to the current conversation.

## What it adds around upstream Harness

| When you need to… | Desktop companion behavior |
| --- | --- |
| Read a paper, inspect code, or work through a dataset | Drag PDFs, Office files, Markdown, source, data, and images into a conversation. They become removable, session-bound managed references; originals are never edited. |
| Pull a useful detail from a document | Let the model call bounded local Artifact tools for PDF search/page extraction, Office text extraction, and safe text reading. The app does not pretend a model has read a file merely because it was imported. |
| Capture a single window | Use **Appshot** (`⌘⇧⌥2`) for a one-time local capture with OCR/redaction and a preview before saving. |
| Ask for help inside another Mac app | Explicitly attach one running app. Accessibility/OCR actions are limited to that app, its current window, and a fresh snapshot. |
| Run a research task on a Linux server | Select one SSH host and workspace, then use the scoped remote-compute bridge. Inspection tools may be selected by a model; commands, jobs, cancellation, and transfers require immediate confirmation. |

### Images: clear routing, not a false promise

Dropping an image is supported. That does **not** automatically mean the selected model receives raw pixels:

- `deepseek-v4-flash-vision-exp` receives a direct image block only when the live host route matches that exact ID.
- The base Flash and Pro routes keep images as managed local context; the workflow may use local extraction/OCR tools on demand.
- Unknown, changing, mixed, or expired routes fail closed to the managed-file path.

This keeps file handling useful without claiming that DeepSeek saw an image it was never sent.

## How it fits together

<p align="center">
  <img src="docs/images/architecture.svg" alt="Diagram showing the native desktop companion managing local files, macOS permissions, and an optional SSH bridge around upstream DeepSeek Harness" width="860">
</p>

The native layer owns the local file boundary, macOS permissions, one-shot Appshots, exact-app attachment, and optional SSH selection. Upstream Harness continues to own conversations, model selection, provider adapters, and its normal tool framework.

> The architecture diagram and the Vision smoke test use only isolated demo data. Personal documents, chats, credentials, and live app context are never published as repository screenshots.

## Important boundaries

- **Source preview only.** No Developer ID–signed or Apple-notarized binary is published. Build and review it locally.
- **Apple Silicon / macOS 14+.** Intel support is not claimed.
- **Computer Use is scoped, not universal.** You must attach an exact app first. Known password, login, Keychain, and security surfaces are blocked, but no heuristic recognizes every custom sensitive interface.
- **SSH is deliberately narrow.** It uses your existing system OpenSSH/public-key setup; passwords, MFA prompts, interactive TTY, jump hosts, forwarding, and automatic host-key acceptance are out of scope. A workspace is routing scope, not a server-side sandbox.
- **No video or audio upload.** This project does not turn the pinned DeepSeek route into a general visual-model service.

## Build from source

Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools with Swift 5.10+, Node.js 22, and the pinned upstream runtime.

```bash
npm install -g @deepseek-ai/dsh@0.1.1-rc.2 --registry=https://registry.npmjs.org
git clone https://github.com/tengqi159/deepseek-harness-desktop.git
cd deepseek-harness-desktop
./scripts/build_and_run.sh package
```

The default package is ad-hoc signed for local development. It is not a distributable, trusted public binary. The companion verifies the expected upstream `dsh` version and executable digest; an unknown runtime is refused.

## Validation in this source preview

The current source tree passes a Release build and deterministic local regression suites for:

- native attachment lifecycle and session binding;
- real `WKWebView` drag/drop and clipboard routing;
- Artifact Bridge (17 checks), Appshot (26 checks), and a disposable Computer Use fixture (37 checks);
- Remote Host selection and an isolated fake-SSH bridge (29 checks across 11 tools, with **zero real server connections**).

These results are local engineering evidence, not a promise that every Mac, provider, or server configuration will behave identically.

## Documentation

[Privacy](docs/PRIVACY.md) · [Security](SECURITY.md) · [Distribution](docs/DISTRIBUTION.md) · [Artifact Bridge](integration/ARTIFACT_BRIDGE.md) · [SSH remote compute](docs/SSH_REMOTE_COMPUTE.md) · [Computer Use testing](app/APP_BRIDGE_TESTING.md) · [Contributing](CONTRIBUTING.md)

## License

MIT. Read [NOTICE](NOTICE.md) for upstream attribution and trademark boundaries.
