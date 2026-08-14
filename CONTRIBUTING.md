# Contributing

Thank you for helping improve this unofficial macOS companion for DeepSeek Harness. Small, focused pull requests with observable tests are easiest to review.

## Before starting

- Read [SECURITY.md](SECURITY.md) before working on permissions, Computer Use, Appshots, file parsing, helper discovery, or signing.
- Use only disposable test files and test applications. Never commit API keys, credentials, local Harness state, personal screenshots, or signing certificates.
- Keep upstream `@deepseek-ai/dsh` unmodified. Integration belongs in this wrapper, its bundled helpers, Skills, or the versioned client/plugin layer.
- Preserve fail-closed behavior for unknown model capabilities, stale process/window identity, unsupported file types, and unavailable permissions.

For material feature or architecture changes, open an issue first so the security and compatibility boundary can be agreed before implementation.

## Development environment

The current preview targets macOS 14 or later and is tested on Apple Silicon (`arm64`). The public source has not yet been qualified as a universal binary.

You will need:

- Xcode Command Line Tools with Swift 5.10 or later;
- Node.js 22 for the attachment-client test and the separately installed Harness runtime;
- `@deepseek-ai/dsh@0.1.0-rc.6` when launching the full app;
- `uv`, or Python with ReportLab and Pillow, for the artifact generated-fixture test.

## Build and test

From the repository root:

```sh
swift build --package-path app -c release
node scripts/test_native_attachments_plugin.mjs
scripts/test_native_file_drop.sh
scripts/test_artifact_bridge.sh
```

The hosted CI intentionally avoids tests that depend on a logged-in WindowServer session or macOS TCC permissions. Before changing Computer Use, Appshot, or live `WKWebView` behavior, also run the relevant local suites on a disposable fixture:

```sh
scripts/test_app_bridge_e2e.sh
scripts/test_appshot_qa.sh
scripts/test_webview_file_drop.sh
```

Those suites do not grant permissions. A permission-dependent step may be reported as skipped when the launching process lacks Accessibility or Screen Recording access. A tool’s success message is not enough: verify the expected UI or file state on the intended fixture.

## Pull request checklist

- [ ] The change is narrowly scoped and the user-visible behavior is documented.
- [ ] No secret, credential, personal file, local state, log, app bundle, ZIP, or signing material is included.
- [ ] Source files selected by users are never overwritten.
- [ ] New permissions or data flows are explained in `docs/PRIVACY.md`.
- [ ] Signing, architecture, or packaging changes are explained in `docs/DISTRIBUTION.md`.
- [ ] Automated tests cover the behavior, and macOS UI/TCC behavior has fixture-based local evidence where applicable.
- [ ] Claims distinguish implemented behavior from planned, conditional, or unsupported behavior.
- [ ] The project is still described as unofficial and independent.

## Style and commits

- Prefer platform APIs and small, explicit bridges over broad automation privileges.
- Keep user-facing text clear about what stays local and what can reach a model provider.
- Do not weaken size, path, redaction, timeout, snapshot, or confirmation limits merely to make a test pass.
- Use descriptive commits and avoid mixing formatting-only changes with functional changes.

By contributing, you agree that your contribution is licensed under the repository’s [MIT License](LICENSE).
