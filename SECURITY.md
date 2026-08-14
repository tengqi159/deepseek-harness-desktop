# Security policy

HarnessMate can read user-selected files, connect to one explicitly selected SSH workspace, and—only after the user grants macOS permissions—inspect or control one attached application. Security and privacy regressions are therefore treated as release-blocking issues.

## Supported versions

This repository is currently a developer/source preview. Security fixes target the latest commit on `main`; older snapshots and locally built binaries are not guaranteed to receive fixes.

No public binary is currently supported. In particular, any locally produced, self-signed, ad-hoc-signed, or unnotarized `.app`/`.zip` is a development artifact rather than an official release.

## Report a vulnerability privately

Use GitHub’s **Security** tab and choose **Report a vulnerability** when private vulnerability reporting is available. Please do not put secrets, exploit details, private documents, screenshots, or personal data in a public issue.

If private reporting is unavailable, open a minimal public issue asking the maintainer to enable a private contact channel. Do not include the vulnerability details in that issue.

Useful reports include:

- affected commit or version;
- exact macOS version and Mac architecture;
- whether Accessibility or Screen Recording was enabled;
- a minimal reproduction using disposable data and apps;
- expected and observed permission, process, window, or file boundary;
- whether any information left the Mac.

Remove API keys, credentials, tokens, private file contents, and personal identifiers before attaching logs.

## High-priority areas

Please report suspected issues involving:

- control of an application, process, or window that was not explicitly attached;
- reuse of stale process, window, or snapshot identity;
- interaction with password managers, secure fields, login, Keychain, or authentication surfaces;
- unredacted credentials in OCR, Accessibility text, logs, previews, or session context;
- files escaping the managed `Artifacts` directory through traversal, links, archives, or races;
- source files being modified or overwritten;
- an Appshot being saved, copied, or routed without the documented confirmation;
- permissions being requested or changed without a clear user action;
- command injection, unsafe helper discovery, or a bypass of the pinned runtime check.
- an SSH action reaching a host, user, port, or workspace other than the current explicit selection;
- SSH path traversal, symbolic-link races, unbounded downloads, stale job identity, or cancellation of the wrong process;
- SSH passwords, private-key material, agent protocol data, server addresses, commands, or logs leaking into the repository or public reports;
- a consequential remote action being described as natively approved when it was only model-confirmed.

## Security boundaries

- macOS Accessibility and Screen Recording permissions are controlled by macOS. The app can explain or request them, but it cannot silently grant them.
- Computer Use is bound to the exact selected process lifetime and focused window. A fresh state snapshot is required for actions.
- Screen pixels used for Computer Use OCR stay in memory; locally redacted text may enter the Harness conversation and can then be sent to the configured model provider.
- User-imported files and confirmed Appshots are local managed copies. Extraction results or approved attachments may enter model context when a workflow uses them.
- SSH Remote Compute uses the system OpenSSH client, an expiring exact host/workspace selection, and bounded tool results. It does not store passwords or private-key contents. Commands, logs, paths, server facts, and transferred files can leave one machine and enter model/session context.
- Remote confirmation fields and the bundled Skill are model-workflow controls, not an unforgeable native approval token. The upstream Full-access shell can invoke SSH directly, so the specialized bridge is not an account or network sandbox.
- Remote job identity and workspace validation assume a cooperative Linux host with `/proc` and standard GNU tools. They do not defend against a compromised remote kernel, SSH server, or account.
- Model/provider accounts, network transport, and upstream Harness behavior remain governed by their own software and terms.

See [Privacy](docs/PRIVACY.md) for the data-flow description and [Distribution](docs/DISTRIBUTION.md) for signing and notarization boundaries.
