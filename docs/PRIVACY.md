# Privacy and data flow

HarnessMate is designed as a local companion around a separately installed Harness runtime. “Local” does not mean that all conversation content stays on the Mac: prompts, selected extracts, approved attachments, and tool results can be sent by Harness to whichever model provider the user configures.

This document describes the companion layer. The upstream Harness runtime, model providers, npm registry, linked websites, and macOS have their own behavior and policies.

## Data stored on the Mac

The app uses this private application-support area:

```text
~/Library/Application Support/DeepSeek Harness/
├── dsh-home/                     app-specific Harness profile
├── Artifacts/
│   ├── Inbox/                    managed copies of imported files
│   ├── Appshots/<id>/            confirmed preview, context, and metadata
│   ├── Renders/                  immutable PDF page renders
│   └── Exports/                  destination for separately authorized outputs
├── app-bridge-selection.json     exact attached-app identity
└── drafts/<id>/SKILL.md          review-only Computer Use recording drafts
```

On first setup, the companion can copy existing `~/.dsh/.credentials.yaml` and `~/.dsh/settings.yaml` into its app-specific `dsh-home` only when the destination files do not already exist. Those copies are set to owner-only mode (`0600`). Existing sessions and project history are not copied by this installer.

Files routed through the managed-file path are copied into the private `Artifacts` root. A verified pure-image batch may instead remain on the upstream image-composer path and is not duplicated into this store. The original file is not edited. The artifact helper may create deterministic PDF-page PNGs only under `Renders`; it does not overwrite the imported source.

The repository and public bug reports must never contain any of the local files above.

## Files, PDFs, Office documents, and images

Dragging or selecting a file is an explicit user action. Documents, mixed batches, and images that cannot use a verified native image route become private managed copies and can appear as removable cards in the active conversation draft. A verified pure-image batch can remain on the upstream composer path instead. The app does not press **Send** automatically.

PDF/Office/Markdown/code support is not the same as silently uploading an entire source file. The local artifact helper can list, inspect, search, extract bounded text, perform opt-in local OCR, or render a selected PDF page. Extracted/redacted text or an explicitly routed attachment may then enter the Harness conversation and be sent to the configured provider.

Pure image batches use the exact current provider/model capability route. Unknown, loading, expired, mixed, or text-only routes fail closed to managed local handling. Video and audio are not currently shipped as direct conversation upload paths.

Removing a card removes the managed reference from the draft lifecycle, but the managed file copy remains in the research-file library. It is not a secure-erasure guarantee for that copy or for text that was already sent, copied, recorded in local session history, backed up by macOS, or received by a model provider.

## Appshot

Appshot is a one-time capture of the exact frontmost focused window, not continuous monitoring.

The app temporarily hides itself, captures the selected window, runs local Accessibility/Vision OCR, masks likely secrets in text and pixels, and presents a preview. Nothing is persisted until the user confirms. The default confirmed image is the locally redacted version. Preserving original pixels for a vision-capable route requires a separate explicit toggle and confirmation.

Confirmed Appshots are stored under `Artifacts/Appshots`. Copying an image to the clipboard or sending an approved image to a model is a separate user/workflow action. No redaction system is perfect; inspect every preview before sharing it.

## Computer Use

Computer Use is off until the user attaches one exact running process and grants the relevant macOS permissions.

- **Accessibility** allows reading the focused UI hierarchy and performing actions such as click, type, key, scroll, value change, selection, and drag.
- **Screen Recording** allows in-memory capture of the attached app’s focused window for Vision OCR.

The bridge binds control to the selected bundle identifier, process identifier, process launch time, focused window, and fresh state snapshot. It blocks known password managers, Keychain/login/security surfaces, secure fields, and common credential patterns, and fails closed while the Mac is locked. These defenses reduce risk but cannot guarantee that every sensitive custom application or novel secret format will be recognized.

Computer Use screenshots are used in memory and are not written to disk by the bridge. Redacted Accessibility/OCR text is returned as a tool result and can remain in local Harness session history or be sent to the configured model provider. Recording mode stores only a review draft under `drafts`; it omits typed contents and never installs or enables that draft automatically.

The current control bridge is semantic Accessibility/OCR automation. It is not equivalent to a general vision model that receives and understands the raw screen.

## Permissions

macOS owns the Accessibility and Screen Recording permission databases. The app can show status, open the relevant System Settings pane, or trigger Apple’s permission prompt after a user action; it cannot silently grant itself access.

Permissions are sensitive to the app’s signing identity and path. Rebuilding, re-signing, or replacing the app may require the user to remove an older System Settings entry and grant access again. Grant only the permissions needed, and revoke them in **System Settings → Privacy & Security** when no longer required.

## Network activity

The native companion starts a local Harness service on a loopback address and displays it in `WKWebView`. Loopback limits network exposure but is not, by itself, authentication or proof that every local process is trusted.

The companion’s local file/OCR helpers do not implement their own cloud upload service. Network requests can still occur through:

- the separately installed upstream Harness runtime;
- the user’s configured DeepSeek, Kimi, or other model provider;
- npm/runtime installation and update checks;
- links the user opens in the embedded or external browser.

Review the provider, selected model, and attachment preview before sending sensitive material. Provider retention, training, regional processing, and deletion terms are outside this project’s control.

## Deleting local data

The current source preview does not include an in-app per-artifact deletion control. Quit the app, back up anything needed, and remove individual items from the `Artifacts` directory with Finder if desired. To remove all companion-local state, delete:

```text
~/Library/Application Support/DeepSeek Harness/
```

This does not delete the separate global `~/.dsh` profile, provider-side conversation data, macOS backups, clipboard history, or files exported elsewhere. Remove Accessibility and Screen Recording entries separately in System Settings.

## Privacy reports

For a suspected privacy or security vulnerability, follow [SECURITY.md](../SECURITY.md) and do not post private content publicly.
