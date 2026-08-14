<div align="center">

# HarnessMate

#### The Mac companion for DeepSeek Harness

**Upstream DeepSeek Harness plans, codes, and calls tools. This companion gives it hands on your Mac — drag in your research files, capture one window safely, attach exactly one app for Computer Use.**

[简体中文](README.zh-CN.md) · English

<img alt="CI" src="https://github.com/tengqi159/harness-mate/actions/workflows/ci.yml/badge.svg">
<img alt="Source Preview" src="https://img.shields.io/badge/status-source_preview-f59e0b">
<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">

<img src="docs/images/hero-files.png" alt="Dropping research files into HarnessMate" width="920">

<sub>Sanitized product demo based on the real interface. No user files, accounts, or API keys.</sub>

</div>

## ✨ Why this project exists

Upstream Harness is already a strong agent runtime: planning, coding, tools, subagents, workflows. But on a Mac it stops at the browser tab — while your actual work lives in Finder, Preview, and other apps. The paper is in Finder, the result plot is in Preview, and the interface you need help with is in another app.

This companion is the native layer that closes that gap. It does not fork or rewrite upstream — it hosts the verified runtime and adds what a Mac-native agent needs:

<table align="center">
<tr>
<td align="center" width="33%"><b>📁 Research files, dropped</b><br>PDF, Office, Markdown, code, data, images, and mixed batches become managed, removable cards. Originals stay untouched.</td>
<td align="center" width="33%"><b>🧾 Local artifact workbench</b><br>Bounded extraction, page-referenced PDF search, page rendering, opt-in OCR. What the model saw is never oversold.</td>
<td align="center" width="33%"><b>📸 Appshot <code>⌘⇧⌥2</code></b><br>One-shot capture of the exact frontmost window, secrets masked in text and pixels, preview before save. A snapshot, not screen sharing.</td>
</tr>
<tr>
<td align="center" width="33%"><b>🖱️ Bounded Computer Use</b><br>Attach one exact app; Accessibility + in-memory OCR drive bounded actions, locked to the process lifetime and a fresh window snapshot.</td>
<td align="center" width="33%"><b>🧭 Routing that fails closed</b><br>Native images only for verified provider/model pairs; unknown routes fall back to managed references — no pretending.</td>
<td align="center" width="33%"><b>🔒 Verified upstream</b><br>Only the pinned, digest-checked runtime is accepted; unknown builds are refused.</td>
</tr>
</table>

> [!IMPORTANT]
> **Unofficial source preview.** This is an independent community project, not affiliated with or endorsed by DeepSeek. We publish source, not an Apple-notarized binary — [Distribution](docs/DISTRIBUTION.md) spells out exactly what blocks a public download and what we verify before shipping one. Build locally and review the permissions you enable.

## 💬 What changes in everyday work

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

## 🧭 Models and tools that tell the truth

Three rules govern how content reaches a model:

| # | Rule | In practice |
| --- | --- | --- |
| 1 | **Capability first** | Routing follows the verified capability registry, nothing else. The DeepSeek rc.6 route is text-only: local extraction or OCR never becomes “native vision.” A Kimi route keeps native image blocks only when the selected model explicitly declares image input. |
| 2 | **Fail closed** | Unknown, loading, mismatched, or expired records never guess upward — they fall back to managed files. When unsure, the pipeline does less, not more. |
| 3 | **No fake promises** | Video upload and audio transcription are not shipped. Plugin Health reports startup discovery — not permanent availability — and the model may or may not invoke a registered tool. |

Provider keys are configured in **Harness Settings → Models**. They are not stored in this repository or in the model capability registry.

## 🤝 What this companion contributes

| Experience | Where it comes from |
| --- | --- |
| Conversations, workspaces, model settings, commands, plans, goals, subagents, workflows, and jobs | Upstream `@deepseek-ai/dsh` |
| Provider adapters, including supported Kimi routes, plus the Skill / MCP framework | Upstream `@deepseek-ai/dsh` |
| Native app window, toolbar, app lifecycle, and no required browser tab | This companion |
| Finder file drop, managed research files, PDF / Office helpers, and removable draft cards | This companion |
| Appshot, exact-app attachment, bounded Computer Use, capability routing, and plugin health | This companion |

The companion hosts and extends the verified upstream client; it does not replace or rewrite Harness.

## 🛠️ Quick start from source

Current targets: companion **1.4.1 (build 6)**, upstream **`@deepseek-ai/dsh@0.1.0-rc.6`**, macOS **14+**, and Apple Silicon. Intel is not yet validated.

Requirements: Xcode Command Line Tools with Swift 5.10+, Node.js 22, and npm.

```bash
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
dsh --version
git clone https://github.com/tengqi159/harness-mate.git
cd harness-mate
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

## 🔐 Permission and data boundaries

| Permission / data | What it enables | What it does not do |
| --- | --- | --- |
| Accessibility | Semantic reading and bounded actions in the attached app | Cannot be granted by Harness; does not authorize every app automatically |
| Screen Recording | Appshot and optional focused-window OCR | Does not turn on continuous remote viewing |
| Provider API | Conversations and content you or a workflow sends | Does not make local files private after you choose to send extracted content |
| Managed files | Local research-file workflows under Application Support | Does not modify originals; removing a draft card does not delete the managed copy |

Harness is served on a random loopback port in a non-persistent `WKWebView`. That reduces accidental collisions; it is not a complete authentication or sandbox boundary. Read [Privacy](docs/PRIVACY.md) and [Security](SECURITY.md) before enabling control for sensitive apps.

## 🗺️ Status and roadmap

Being a source preview is a deliberate choice, not an accident: we will not publish a public binary until it earns one.

| Today — source preview | Next on the roadmap |
| --- | --- |
| No notarized `.dmg`, `.zip`, or generally downloadable app release | Developer ID signing and Apple notarization |
| Apple Silicon on macOS 14+ tested; Intel not claimed | Clean-Mac Gatekeeper validation |
| Only the verified upstream rc.6 runtime and digest are accepted | Broader architecture qualification |
| Main interface is upstream web UI inside `WKWebView`, not a full SwiftUI rewrite | |
| No general video upload, audio transcription, automatic permission granting, guaranteed tool invocation, or Codex-equivalent visual control | |

See [Distribution](docs/DISTRIBUTION.md) for the exact checklist a public binary must pass.

## 🧪 Build confidence

CI covers compilation and deterministic checks. The repository also includes artifact, Appshot, native file-drop, real `WKWebView` drop-lifecycle, and disposable-window Computer Use suites. Full artifact tests require [`uv`](https://docs.astral.sh/uv/); real OCR, permissions, and window actions must still be verified locally in a logged-in macOS session.

```bash
swift build --package-path app -c release
./scripts/test_artifact_bridge.sh
./scripts/test_appshot_qa.sh
./scripts/test_native_file_drop.sh
./scripts/test_webview_file_drop.sh
./scripts/test_app_bridge_e2e.sh
```

## 📚 Read the details

<div align="center">

<a href="docs/PRIVACY.md">🔒 Privacy</a> ·
<a href="SECURITY.md">🛡️ Security</a> ·
<a href="docs/DISTRIBUTION.md">📦 Distribution</a> ·
<a href="integration/ARTIFACT_BRIDGE.md">🧾 Artifact Bridge</a> ·
<a href="app/APP_BRIDGE_TESTING.md">🖱️ Computer Use testing</a> ·
<a href="CONTRIBUTING.md">🤝 Contributing</a>

</div>

## ⚖️ License and acknowledgements

This companion source is available under the [MIT License](LICENSE). See [NOTICE](NOTICE.md) for upstream attribution and trademark boundaries. Issues and focused pull requests are welcome; report vulnerabilities privately through [SECURITY.md](SECURITY.md).
