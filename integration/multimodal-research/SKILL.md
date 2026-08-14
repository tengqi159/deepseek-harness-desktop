---
name: multimodal-research
description: Route research files, PDFs, images, Appshots and video honestly according to the selected model's verified input capabilities.
---

# Multimodal research routing

Use the `mcp__artifacts__*` tools for files placed in the native Research Files workbench. Never guess a local path outside that managed workbench.

## Capability boundary

- DeepSeek's rc.6 official route is text-only. For PDFs, images and Appshots, use bounded local extraction, PDF rendering metadata, Accessibility text or local OCR. Do not claim the raw image was seen.
- The built-in `moonshotai-cn` and `moonshotai` pi-ai routes can accept text and image message blocks when the selected Kimi model declares image input.
- The current Harness composer and MCP projection do not deliver video blocks. A video file must be handled by an explicit controlled video-upload tool; if that tool is unavailable, say so.
- Kimi file extraction returns text. It is not page-layout or chart understanding. For layout-sensitive PDF work, inspect rendered pages and cite page numbers.
- No Kimi audio/transcription capability is verified. Request a separate ASR workflow for audio.

## Research workflow

Files dragged into the macOS conversation window arrive as exact managed
`Inbox/<uuid>/<filename>` attachment references. Use those paths for the current
request and keep each result associated with its filename; never substitute a
different recently imported file.

1. Call `mcp__artifacts__list_files` before assuming which file the user means.
   Skip the broad listing when the current message already supplies an exact
   managed attachment path; inspect that path directly instead.
2. Inspect metadata and size before reading.
3. For PDF facts, use page-bounded extraction/search and report page numbers.
4. For scanned or layout-sensitive pages, render only the required pages. Explain whether the conclusion came from extracted text, local OCR, or direct vision.
5. For Appshots, read `context.md` first. The screenshot remains local unless its metadata explicitly says the user approved it for a vision model.
6. Never upload a file, image or video to a provider merely because the provider supports it. Obtain immediate user confirmation for external upload and state the destination.
7. Do not overwrite imported source files. Write generated or revised artifacts under the managed Exports directory.

The model capability registry bundled with the desktop app is the product truth source. `unknown` is not unlimited and must be treated as unsupported until re-verified.
