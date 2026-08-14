<div align="center">

# HarnessMate

#### The Mac companion for DeepSeek Harness

**DeepSeek Harness thinks hard. On your Mac, though, it has no hands. HarnessMate gives it a pair — to hold your papers, look at one window, operate one app — always on your terms.**

[简体中文](README.zh-CN.md) · English

<img alt="CI" src="https://github.com/tengqi159/harness-mate/actions/workflows/ci.yml/badge.svg">
<img alt="Source Preview" src="https://img.shields.io/badge/status-source_preview-f59e0b">
<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">

<img src="docs/images/hero-files.png" alt="Dropping research files into HarnessMate" width="920">

<sub>Sanitized product demo based on the real interface. No user files, accounts, or API keys.</sub>

</div>

## ✨ Why HarnessMate exists

Every Harness session started the same way for us: the agent had ideas, but the paper it needed was sitting in Finder, the chart it should read was open in Preview, and the app it was supposed to drive was one window over. So we copied paths, took screenshots by hand, and described interfaces in words. It got old fast. HarnessMate is the layer that fixes this — it runs the verified upstream runtime and adds the parts a Mac-native agent needs:

<table align="center">
<tr>
<td align="center" width="33%"><b>📁 Research files, dropped</b><br>PDF, Office, Markdown, code, data, images — drag them in, they become cards. Originals stay exactly where you left them.</td>
<td align="center" width="33%"><b>🧾 Local artifact workbench</b><br>Extract, search with page numbers, render pages, OCR. It says what it did — never “the model read the whole thing.”</td>
<td align="center" width="33%"><b>📸 Appshot <code>⌘⇧⌥2</code></b><br>Captures the frontmost window only, masks secrets before you preview — and hides itself first, so no screenshot of the screenshot.</td>
</tr>
<tr>
<td align="center" width="33%"><b>🖱️ Bounded Computer Use</b><br>One app, your pick. Accessibility + in-memory OCR, locked to that process, and it stops to ask before anything consequential.</td>
<td align="center" width="33%"><b>🧭 Routing that fails closed</b><br>Images go to the model only when that model truly sees images. Otherwise the pipeline quietly does something honest instead.</td>
<td align="center" width="33%"><b>🔒 Verified upstream</b><br>One pinned runtime, digest-checked. Unknown builds don't even start.</td>
</tr>
</table>

> [!IMPORTANT]
> **Unofficial source preview.** HarnessMate is an independent community project — not DeepSeek, and not endorsed by them. We publish source, not a notarized binary; [Distribution](docs/DISTRIBUTION.md) spells out exactly what has to happen before a public download exists. Build it locally, read the permissions you enable — you know your Mac better than we do.

## 💬 Three things that stop being annoying

### “Compare these papers—and tell me which page supports the answer.”

Drag PDFs, Markdown, source code, Office files, images, or a mixed batch from Finder. They become removable draft cards tied to that conversation, while the originals stay untouched.

PDFs and Office files stay local, in a managed corner of your disk. When a task needs it, a tool extracts bounded text, searches a PDF with page numbers, or renders the pages the task actually uses. Notice the wording there: none of that is “the model understood your file.” We say what happened, and nothing more.

Images get the same treatment. A pure image batch keeps the native image route only when that exact provider and model verifiably see images; anything uncertain falls back to managed references. No quiet pretending.

Rules and limits: [Artifact Bridge](integration/ARTIFACT_BRIDGE.md) and [Privacy](docs/PRIVACY.md).

### “Show the agent this window, but not my whole desktop or a password beside it.”

Appshot (`⌘⇧⌥2`) grabs the frontmost window once, masks likely secrets in text and pixels, then shows you a preview. Nothing is saved until you confirm, and nothing reaches a model until you say so.

Small detail we're genuinely proud of: the app hides its own window first, so your capture never contains a picture of the tool taking the picture.

Appshot is a reviewable snapshot—not continuous screen sharing.

### “Look at this app and help me—but stop before anything consequential.”

Attach one running app — the exact one you pick. HarnessMate reads its Accessibility tree, OCRs the window in memory when needed, and performs bounded clicks, typing, scrolling, selection, or waits.

The binding is to that process, for its lifetime, against a fresh window snapshot — not “click around the whole desktop.” Login screens, Keychain, password managers, secure fields, system security surfaces: blocked. Likely secrets: redacted. Custom-drawn apps can still smuggle something past these defenses, so give the preview a second look yourself.

Before anything consequential — sending, publishing, buying, deleting, installing, changing permissions — the bundled safety rules make the agent stop and ask you, every time. Computer Use screenshots never leave memory as image blocks; the bounded Accessibility/OCR **text** may enter model context and local session history.

<p align="center">
  <img src="docs/images/app-control.png" alt="Attaching one Mac app for bounded Computer Use" width="920">
</p>

<p align="center"><sub>Sanitized product demo based on the real interface. No user files, accounts, or API keys.</sub></p>

This is semantic/OCR-assisted control, not Codex-style vision. Some custom-drawn interfaces won't cooperate. We'd rather be boring about that than oversell it.

### “Will Harness use this by itself, or do I have to summon it?”

The composer now has a compact, color-coded capability menu instead of another wall of plugin names. It reads the current session's command, Skill, and companion-plugin catalogs every time it opens, then says what each item actually means:

- **Model may auto-select** — the model can choose the Skill when the task matches; it is available, not guaranteed to run.
- **After import / After attach** — the bridge is running, but a file or one exact Mac app must be supplied first.
- **Manual** — commands such as plan, goal, export, and permission only run when you choose them.
- **Running / Loading / Disabled** — live startup state, kept separate from the invocation label.

Selecting a command or Skill only writes its shortcut into the draft. It never presses **Send**. Low-level host placeholders and duplicate disabled entries stay out of this everyday menu; the full technical inventory remains available in Harness Settings.

## 🧭 An honest note on what the model sees

Plenty of agent tools quietly imply the model saw an image it didn't. We don't. Three rules, no exceptions:

| # | Rule | In practice |
| --- | --- | --- |
| 1 | **Trust the registry, not vibes** | Routing follows the verified capability table, nothing else. The DeepSeek rc.6 route is text-only, full stop — local extraction and OCR are never rebranded as “native vision.” A Kimi route keeps image blocks only when that exact model declares image input. |
| 2 | **When in doubt, do less** | Unknown, loading, mismatched, expired — all fall back to managed files. Getting this wrong once costs more trust than the feature was worth. |
| 3 | **Don't promise what isn't there** | Video upload and audio transcription aren't shipped, so we don't list them. Plugin Health shows what started at launch — not a forever warranty — and no tool call is guaranteed just because a model registered it. |

Provider keys live in **Harness Settings → Models**. Never in this repository, never in the capability registry.

## 🤝 Who does what

| Experience | Where it comes from |
| --- | --- |
| Conversations, workspaces, model settings, commands, plans, goals, subagents, workflows, and jobs | Upstream `@deepseek-ai/dsh` |
| Provider adapters, including supported Kimi routes, plus the Skill / MCP framework | Upstream `@deepseek-ai/dsh` |
| Native app window, toolbar, app lifecycle, and no required browser tab | This companion |
| Finder file drop, managed research files, PDF / Office helpers, and removable draft cards | This companion |
| Appshot, exact-app attachment, bounded Computer Use, capability routing, plugin health, and the color-coded capability menu | This companion |

HarnessMate hosts and extends the verified upstream client. We don't replace it, and we won't pretend to be it.

## 🛠️ Quick start from source

Current targets: companion **1.5.0 (build 7)**, upstream **`@deepseek-ai/dsh@0.1.0-rc.6`**, macOS **14+**, and Apple Silicon. Intel is not yet validated.

Requirements: Xcode Command Line Tools with Swift 5.10+, Node.js 22, and npm.

```bash
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
dsh --version
git clone https://github.com/tengqi159/harness-mate.git
cd harness-mate
./scripts/build_and_run.sh package
```

Why pin the runtime? Upstream previews change plugin slots and UI often enough that “works with rc.6” is a promise we can actually keep, while “works with whatever you installed” is a gamble. So `dsh --version` must report `0.1.0-rc.6`, and the companion verifies the executable digest and refuses unknown builds.

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

## 🗺️ Status: why there's no .dmg yet

No downloadable binary yet — on purpose. An unsigned, unnotarized build just gets blocked by Gatekeeper on someone else's Mac; shipping one would be a trap, not a release. The full checklist lives in [Distribution](docs/DISTRIBUTION.md), and we'll publish the day every box is checked.

| Today — source preview | Next on the roadmap |
| --- | --- |
| No notarized `.dmg`, `.zip`, or generally downloadable app release | Developer ID signing and Apple notarization |
| Apple Silicon on macOS 14+ tested; Intel not claimed | Clean-Mac Gatekeeper validation |
| Only the verified upstream rc.6 runtime and digest are accepted | Broader architecture qualification |
| Main interface is upstream web UI inside `WKWebView`, not a full SwiftUI rewrite | |
| No general video upload, audio transcription, automatic permission granting, guaranteed tool invocation, or Codex-equivalent visual control | |

## 🧪 Build confidence

CI compiles and runs deterministic checks, and the repository ships fixture-based suites for the artifact bridge, Appshot, native file drop, the real `WKWebView` drop lifecycle, and disposable-window Computer Use. Full artifact tests need [`uv`](https://docs.astral.sh/uv/); real OCR, permissions, and window actions still have to be verified by a human on a logged-in Mac — automation can't grant itself Accessibility, and honestly, it shouldn't.

```bash
swift build --package-path app -c release
./scripts/test_artifact_bridge.sh
./scripts/test_appshot_qa.sh
./scripts/test_capability_catalog.sh
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

If HarnessMate ever saves you an afternoon, open an issue and say so — that's the entire marketing budget.
