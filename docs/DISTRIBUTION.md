# Distribution, signing, and release status

## Current status: source preview

This repository currently publishes source code, not a generally installable Mac binary.

The local app used during development is built for Apple Silicon (`arm64`), requires macOS 14 or later, and launches the separately installed, exactly pinned `@deepseek-ai/dsh@0.1.0-rc.6` runtime. Node.js and the upstream CLI are not embedded in the app bundle.

The current development app is not signed with an Apple-issued Developer ID and has not been notarized by Apple. Gatekeeper can therefore reject it on another Mac. For that reason, the existing local ZIP is deliberately excluded from this repository and must not be attached to a public “stable” release.

Ad-hoc or local self-signing can make development and local permission testing repeatable on one Mac. It does not make a build suitable for public distribution, does not create an Apple trust chain, and does not replace notarization.

## Building from source

Prerequisites:

- macOS 14 or later;
- Apple Silicon for the currently tested configuration;
- Xcode Command Line Tools with Swift 5.10 or later;
- Node.js 22;
- the exact compatible upstream runtime:

```sh
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
```

Build and package locally from the repository root:

```sh
./scripts/build_and_run.sh package
```

The default source-preview build uses ad-hoc signing suitable only for local development. `DSH_LOCAL_SIGNING=1` is an explicit opt-in that creates a self-signed identity in the helper-owned `DeepSeekHarnessMacCompanionLocalSigning-v1.keychain-db` and adds that keychain to the user's search list. The helper rejects path overrides and will manage an existing keychain only when its fixed ownership marker matches. This persistent identity can reduce repeated TCC entries during development, but it changes keychain state and is not suitable for distribution. Signing material, keychains, app bundles, and ZIPs are ignored by Git.

Before relying on a local build, run the regression suites documented in [CONTRIBUTING.md](../CONTRIBUTING.md) and verify the actual intended app/window/file state. macOS permissions are associated with code identity and the responsible process chain; a passing Terminal-launched fixture does not prove that an independently launched app has the same permissions.

## Requirements for a public binary release

A downloadable release is not ready until all of the following are complete:

1. Build from a clean, tagged commit in a controlled environment.
2. Declare the supported architecture accurately; build and test a universal binary before claiming Intel support.
3. Embed or clearly install/verify every runtime dependency. Do not imply that the current source preview bundles Node.js or `dsh`.
4. Sign every nested executable and the final app with a valid **Developer ID Application** certificate and the hardened runtime, using secure timestamps where required.
5. Verify the final bundle with strict code-signing checks before archiving it.
6. Submit the exact distributable archive to Apple’s notary service, wait for acceptance, and staple the notarization ticket to the app.
7. Verify Gatekeeper assessment and launch behavior on a clean Mac that has never seen a development build.
8. Re-run file, Appshot, Computer Use, lifecycle, update, and permission acceptance tests against the exact release artifact.
9. Publish a checksum and release notes that state the wrapper version, pinned upstream version, macOS minimum, architecture, permissions, privacy boundary, and known limitations.

Hosted CI in this repository is a source-build and non-TCC regression gate. It is not a notarization pipeline and must not be used as evidence that an app ZIP is trusted by Gatekeeper.

## Upstream compatibility and updates

The companion does not modify the global upstream npm package. Compatibility is deliberately locked to the exact `dsh` version that passed integration testing. A new upstream preview may change plugin slots, configuration, UI structure, or attachment behavior, so updating the global package and updating this wrapper are separate operations.

Do not relax the version check merely to start against an untested release. Update the lock only after source build, helper, client-slot, file lifecycle, local UI, permissions, and end-to-end compatibility tests pass.

## Release naming

The native wrapper and upstream runtime have independent versions. Release notes should always show both, for example:

```text
Companion: 1.4.1-source-preview
Compatible upstream: @deepseek-ai/dsh 0.1.0-rc.6
```

Never label a source preview or an unnotarized development archive as a stable macOS release.
