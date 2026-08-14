# WKWebView file-drop QA

Run:

```sh
./scripts/test_webview_file_drop.sh
```

The fixture compiles the production `ArtifactStore.swift` and
`HarnessWebView.swift` directly, creates a real `NSHostingView`/`WKWebView`, and
drives its AppKit drag-destination methods with an in-memory `NSDraggingInfo`.
All source files are created under a disposable temporary directory. The runner
also executes `test_native_attachments_plugin.mjs`, whose behavioral assertions
cover FIFO retry, drop-time session routing, acknowledgement ordering, and
non-duplicating replay.

Automated coverage:

- before any model route is published, a valid PNG takes the native path
  (fail closed);
- a DeepSeek route, a `null` route, and an unknown model route each keep a
  valid PNG on the native path;
- the model-route test travels through the production JavaScript
  `CustomEvent` relay, `WKScriptMessageHandler`, and the representable's
  capability closure rather than mutating the web view policy directly;
- only the fixture's verified Kimi route enables upstream image handling:
  decodable PNG, JPG, WebP, and GIF files, including one four-image batch,
  stay out of the native callback path;
- under that verified route, twenty images may pass upstream, while a
  twenty-one-image batch takes the native path;
- an extension-only fake PNG and a decodable PNG larger than 5 MiB both take
  the native path instead of being sent directly to the model;
- a non-file text pasteboard stays out of the native callback path;
- PDF, source code, and a mixed image/PDF batch take the native path even while
  the verified Kimi route is active;
- native `entered -> updated -> prepare -> perform -> conclude` produces one
  ordered callback, keeps the drop-time session, and clears the overlay;
- native `entered -> exited` clears the overlay without importing anything;
- a test-process-only Objective-C runtime probe proves pass-through calls
  `WKWebView.perform/conclude` exactly once, while native drops call neither;
- source-contract checks guard the native conclude-before-super branch and the
  FIFO, session-addressing, and replay handshake across Swift and the Web
  plugin.

Remaining manual boundary:

The test invokes the real `DropAwareWKWebView`, but it does not own AppKit's
private drag manager and cannot make WebKit synthesize a browser DOM `drop`
event for a fabricated `NSDraggingInfo`. Therefore final release acceptance
still needs one Finder-to-installed-app pass:

1. Select a DeepSeek text-only route, drag one valid PNG, and confirm exactly
   one native research-file card and no official Harness thumbnail.
2. Select a registry-verified Kimi image-capable route, wait for the route to
   settle, drag one valid PNG, and confirm exactly one official Harness
   thumbnail and no native research-file card.
3. While Kimi is active, drag an extension-only fake PNG and a PNG larger than
   5 MiB; confirm each becomes one native card and neither is sent directly.
4. While Kimi is active, drag one PDF, then PNG + PDF together; confirm the PDF
   and the whole mixed batch use native cards with no official image thumbnail.
5. Switch to an unknown model (or reload so the route is temporarily `null`),
   then immediately drag a valid PNG and confirm it uses the native path.
6. Repeat after entering/exiting without dropping and verify neither overlay is
   left visible.

This distinction is intentional: the automated result proves production policy
and native lifecycle dispatch, while the Finder check proves WebKit's private
superclass path generates the expected DOM event exactly once.
