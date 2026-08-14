# DeepSeek Artifact Bridge

`DeepSeekArtifactBridge` is an additive MCP JSONL helper for the native artifact workbench. It does not patch or import upstream `dsh` code.

## Managed layout

Release builds always use:

```text
~/Library/Application Support/DeepSeek Harness/Artifacts/
├── Inbox/
├── Appshots/<id>/
│   ├── preview.png
│   ├── context.md
│   └── metadata.json
├── Renders/
└── Exports/
```

The native app owns imports into `Inbox/` and confirmed Appshot files. The helper reads regular files under the managed root and writes only immutable PDF page PNGs under `Renders/`. It never overwrites an imported source. `list_files` is recursive by default and omits hidden items plus `metadata.json` unless explicitly requested.

`DSH_ARTIFACT_BRIDGE_ROOT` is accepted only when compiled with `-D DEBUG`; Release builds ignore it.

## Build and App integration

The helper is declared as the `DeepSeekArtifactBridge` SwiftPM executable product, copied into the App's `Contents/Helpers/`, and registered as the `artifacts` stdio MCP server through `DSH_ARTIFACT_BRIDGE_BIN`. A normal package build includes it:

```sh
swift build --package-path app --product DeepSeekArtifactBridge
```

For isolated development, it can also be built directly:

```sh
swiftc app/Sources/DeepSeekArtifactBridge/main.swift \
  -o DeepSeekArtifactBridge \
  -framework AppKit \
  -framework PDFKit \
  -framework Vision \
  -framework CryptoKit
```

It supports MCP `initialize`, `ping`, `tools/list`, and `tools/call`. The packaged App uses an absolute helper path and fails startup closed if the registered executable is unavailable.

## Tools

- `ping`
- `list_files`
- `inspect_file`
- `prepare_input`
- `read_text`
- `pdf_info`
- `pdf_extract`
- `pdf_search`
- `pdf_render_page`
- `office_extract_text`

Text, PDF text, OCR text, and Office text are bounded and locally redacted before becoming model context. Returned document text is explicitly marked untrusted. OCR is opt-in and its raster remains in a resource-limited worker process.

Call `prepare_input(relative_path, provider, model)` before routing images, PDFs, audio, or video. It reads the bundled capability registry and returns one of `direct_multimodal`, `local_extract`, `render_pages_for_vision`, `controlled_video_upload_required`, or `unsupported`. It never transmits data. Direct image routing still requires an immediate user confirmation and a native composer attachment; video requires a separate controlled upload tool. A text-only model may use local OCR only as an explicit local extraction choice and must not be described as native vision.

Rendered PNGs intentionally preserve the selected source page's pixels; they are local artifacts, are not returned as MCP image blocks, and are never uploaded automatically. A later vision/upload workflow must preview the render and obtain the user's explicit approval.

## Security model

- Every input is a relative managed path; absolute paths, dot traversal, URL-like paths, symlinks, hardlinks, cross-device paths, and changing files fail closed.
- Direct file reads use component-by-component `openat(..., O_NOFOLLOW)` plus pre/post `fstat` validation. Recursive listing uses `fdopendir`, `fstatat(..., AT_SYMLINK_NOFOLLOW)`, and directory FDs instead of path-based traversal.
- Render directories and PNGs are created exclusively with `mkdirat`/`openat` from the validated root FD. Failed writes use `unlinkat` on the same parent FD; a pre-existing render is reused only if it is a single-link regular file whose bytes exactly match the deterministic output.
- PDFKit, Vision, ZIP, and XML work runs in a CPU/memory/file-limited child worker with a wall-clock timeout.
- Office documents must be bounded non-encrypted OOXML ZIPs. A binary central-directory/local-header check rejects ZIP64, multi-disk, duplicate/conflicting names, traversal, unsafe ratios, overlapping data, macros, ActiveX, embedded objects, and external-link parts.
- Selected OOXML members stream from the in-memory archive through `/usr/bin/bsdtar -xO`; the archive is never unpacked to disk. XML DTD/entity declarations and oversized/deep trees are rejected.
- Office XML matching is namespace-aware. Word comments are excluded, while documents containing deletion/move-from revision markers fail closed to avoid exposing deleted text. XLSX worksheets and PPTX slides are selected only through validated internal relationships, and hidden sheets/slides are omitted.
- PDF extraction is limited to 500-page documents and 25 pages per request. OCR requires explicit opt-in. Page rendering is capped at 4 megapixels.
- MCP JSONL input is read with a bounded streaming reader. Requests, responses, worker output, extracted text, entry counts, file sizes, and final tool payloads all have hard bounds.

## QA

Run the generated-fixture E2E suite:

```sh
scripts/test_artifact_bridge.sh
```

The suite compiles both DEBUG and Release variants, generates PDF/DOCX/XLSX/PPTX fixtures, exercises all MCP tools and capability routes, verifies text redaction and exact page references, renders a PDF page, and runs Vision OCR. Adversarial checks reject absolute/traversal paths, source symlinks/hardlinks, render-directory symlink swaps, pre-existing render hardlinks, DTD/entity declarations, ZIP glob names, and compressed-size attacks. The final rendered PNG must also be opened and visually inspected before release.
