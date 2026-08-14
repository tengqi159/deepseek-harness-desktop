# Changelog

All notable user-visible changes to this project will be documented here.

This project is an unofficial companion and versions its native wrapper independently from the upstream DeepSeek Harness runtime.

## [Unreleased]

### Planned release work

- Apple Developer ID signing and Apple notarization for a public downloadable app.
- Clean-machine installation and Gatekeeper acceptance testing.
- Broader architecture qualification beyond the currently tested Apple Silicon build.

## [1.4.1-source-preview] - 2026-08-14

### Added

- Native SwiftUI/AppKit shell for the separately installed DeepSeek Harness `0.1.0-rc.6` runtime.
- Managed drag-and-drop cards for PDF, Office, Markdown, source, data, image, and mixed file batches, with removal/reload reconciliation.
- Local artifact workbench with bounded PDF/OOXML inspection, search, extraction, OCR, and PDF-page rendering.
- One-shot Appshot capture with local text/pixel redaction and an explicit preview/confirmation boundary.
- Permission-scoped macOS Computer Use bridge using Accessibility plus optional in-memory ScreenCaptureKit/Vision OCR.
- Exact-process-lifetime, focused-window, and fresh-snapshot checks for UI actions.
- Model capability registry and fail-closed image/file routing for text-only, unknown, or expired routes.
- Plugin health view and bundled research/artifact/Computer Use Skills.
- Fixture-based regression suites for the app bridge, artifact bridge, Appshot, native attachments, and `WKWebView` drag-and-drop.

### Security and privacy

- Local managed artifact root with traversal, symbolic-link, hard-link, archive, size, and changing-input defenses.
- Sensitive-app and secure-field blocks, bounded local redaction, and Mac-locked fail-closed behavior.
- Imported sources are copied rather than edited; actions and uploads remain user- or model-workflow initiated within the documented confirmation boundaries.

### Distribution status

- Source preview only.
- The current local `.app` is Apple Silicon (`arm64`), requires macOS 14 or later, and depends on a separately installed pinned `dsh` runtime.
- No app ZIP is published with this preview: current development builds are not signed with an Apple Developer ID and are not notarized by Apple.

[Unreleased]: https://github.com/tengqi159/harness-mate/compare/v1.4.1-source-preview...HEAD
[1.4.1-source-preview]: https://github.com/tengqi159/harness-mate/releases/tag/v1.4.1-source-preview
