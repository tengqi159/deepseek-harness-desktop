#!/usr/bin/env python3
"""Generated-fixture end-to-end QA for DeepSeekArtifactBridge.

The test compiles the standalone Swift entry point without changing Package.swift,
creates a disposable managed Artifacts tree, and communicates only over MCP JSONL.
It never reads the production Artifacts directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Any

from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - wrapper installs Pillow with ReportLab
    Image = ImageDraw = ImageFont = None  # type: ignore[assignment]


REQUIRED_TOOLS = {
    "ping",
    "list_files",
    "inspect_file",
    "prepare_input",
    "read_text",
    "pdf_info",
    "pdf_extract",
    "pdf_search",
    "pdf_render_page",
    "office_extract_text",
}
SECRET = "sk-" + "artifactfixturetoken7391abcd"
SEARCH_SENTINEL = "PAGE TWO RESEARCH EVIDENCE 7391"
OCR_SENTINEL = "OCR FALLBACK 7391"
DOCX_PRIVATE_SENTINELS = {"COMMENT PRIVATE 7391", "SPOOFED NAMESPACE 7391"}
HIDDEN_OFFICE_SENTINELS = {"HIDDEN XLSX 7391", "HIDDEN PPTX 7391"}


class QAError(RuntimeError):
    pass


class Reporter:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def pass_step(self, name: str, detail: str = "") -> None:
        self.passed += 1
        print(f"PASS  {name}" + (f" - {detail}" if detail else ""))

    def fail_step(self, name: str, detail: str) -> None:
        self.failed += 1
        print(f"FAIL  {name} - {detail}")

    def summary(self) -> int:
        print()
        print(f"RESULT pass={self.passed} fail={self.failed}")
        return 1 if self.failed else 0


def ensure(condition: bool, message: str) -> None:
    if not condition:
        raise QAError(message)


class BridgeClient:
    def __init__(self, executable: Path, artifact_root: Path, capability_registry: Path) -> None:
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in {"HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"}
        }
        environment["DSH_ARTIFACT_BRIDGE_ROOT"] = str(artifact_root)
        environment["DSH_MODEL_CAPABILITY_REGISTRY"] = str(capability_registry)
        self.process = subprocess.Popen(
            [str(executable)],
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        if self.process.stdin is None or self.process.stdout is None:
            raise QAError("Unable to open artifact bridge JSONL streams")
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.next_id = 1

    def request(self, method: str, params: dict[str, Any] | None = None, timeout: float = 30.0) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise QAError(
                    f"Artifact bridge exited with {self.process.returncode}: {self.stderr_text()}"
                )
            events = self.selector.select(max(0.0, deadline - time.monotonic()))
            if not events:
                break
            line = self.process.stdout.readline()
            if not line:
                continue
            try:
                response = json.loads(line)
            except json.JSONDecodeError as error:
                raise QAError(f"Artifact bridge emitted invalid JSON: {line!r}: {error}") from error
            if response.get("id") == request_id:
                return response
        raise QAError(f"Timed out waiting for {method}")

    def tool(self, name: str, arguments: dict[str, Any] | None = None) -> tuple[dict[str, Any], bool]:
        response = self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=35.0)
        ensure("error" not in response, f"JSON-RPC error for {name}: {response.get('error')}")
        result = response.get("result")
        ensure(isinstance(result, dict), f"{name} returned no MCP result")
        payload = result.get("structuredContent")
        ensure(isinstance(payload, dict), f"{name} returned no structuredContent")
        return payload, bool(result.get("isError"))

    def oversized_line_is_rejected(self, byte_count: int = 70_000, timeout: float = 5.0) -> bool:
        self.process.stdin.write("x" * byte_count + "\n")
        self.process.stdin.flush()
        events = self.selector.select(timeout)
        if not events:
            raise QAError("Timed out waiting for oversized JSONL rejection")
        response = json.loads(self.process.stdout.readline())
        return response.get("error", {}).get("code") == -32600

    def close(self) -> None:
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=3)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        finally:
            self.selector.close()

    def stderr_text(self) -> str:
        if self.process.stderr is None or self.process.poll() is None:
            return ""
        return self.process.stderr.read().strip()


def create_pdf(path: Path, image_path: Path) -> None:
    if Image is None or ImageDraw is None:
        raise QAError("Pillow is required for the OCR-only PDF fixture")

    image = Image.new("RGB", (1800, 600), "white")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 92)
    except OSError:
        font = ImageFont.load_default()
    draw.text((90, 220), OCR_SENTINEL, fill="black", font=font)
    image.save(image_path, format="PNG")

    pdf = canvas.Canvas(str(path), pagesize=letter, pageCompression=1)
    width, height = letter
    pdf.setTitle("Artifact Bridge Generated Fixture")
    pdf.setAuthor("Local QA")
    pdf.setFont("Helvetica-Bold", 22)
    pdf.drawString(72, height - 80, "Artifact Bridge PDF Fixture")
    pdf.setFont("Helvetica", 12)
    pdf.drawString(72, height - 120, "This page validates PDFKit extraction and render fidelity.")
    pdf.drawString(72, height - 145, f"Sensitive token must disappear: {SECRET}")
    pdf.rect(70, height - 240, 470, 70, stroke=1, fill=0)
    pdf.drawString(86, height - 205, "A bordered visual block should be sharp and fully visible.")
    pdf.drawString(72, 48, "Page 1 of 3")
    pdf.showPage()

    pdf.setFont("Helvetica-Bold", 18)
    pdf.drawString(72, height - 80, "Research Evidence")
    pdf.setFont("Helvetica", 12)
    pdf.drawString(72, height - 120, SEARCH_SENTINEL)
    pdf.drawString(72, height - 145, "The search result must cite this exact second page.")
    pdf.drawString(72, 48, "Page 2 of 3")
    pdf.showPage()

    pdf.drawImage(str(image_path), 60, height / 2 - 100, width=492, height=164, preserveAspectRatio=True)
    pdf.showPage()
    pdf.save()


def content_types(main_content_type: str, main_part: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/{main_part}" ContentType="{main_content_type}"/>
</Types>"""


def create_docx(
    path: Path,
    *,
    dtd: bool = False,
    traversal: bool = False,
    bomb: bool = False,
    glob_name: bool = False,
    tracked_deletion: bool = False,
) -> None:
    document = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
{'<!DOCTYPE x [<!ENTITY boom "unsafe">]>' if dtd else ''}
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>DOCX fixture paragraph 7391</w:t></w:r></w:p>
    {'<w:moveFrom><w:r><w:t>TRACKED DELETION 7391</w:t></w:r></w:moveFrom>' if tracked_deletion else ''}
    <evil:t xmlns:evil="urn:untrusted-prefix">SPOOFED NAMESPACE 7391</evil:t>
  </w:body>
</w:document>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            content_types(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
                "word/document.xml",
            ),
        )
        archive.writestr("word/document.xml", document)
        archive.writestr(
            "word/comments.xml",
            "<w:comments xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:comment><w:p><w:r><w:t>COMMENT PRIVATE 7391</w:t></w:r></w:p></w:comment></w:comments>",
        )
        if traversal:
            archive.writestr("../escape.xml", "not allowed")
        if bomb:
            archive.writestr("word/header1.xml", "A" * (9 * 1024 * 1024))
        if glob_name:
            archive.writestr("word/header[1].xml", "<w:hdr xmlns:w=\"urn:test\"><w:t>unsafe glob</w:t></w:hdr>")


def create_xlsx(path: Path) -> None:
    workbook = """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Fixture" sheetId="1" r:id="rId1"/>
    <sheet name="Private" sheetId="2" state="hidden" r:id="rId2"/>
  </sheets>
</workbook>"""
    relationships = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
</Relationships>"""
    shared = """<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">
  <si><t>XLSX shared text 7391</t></si>
</sst>"""
    sheet = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></sheetData>
</worksheet>"""
    hidden_sheet = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>HIDDEN XLSX 7391</t></is></c></row></sheetData>
</worksheet>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            content_types(
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
                "xl/workbook.xml",
            ),
        )
        archive.writestr("xl/workbook.xml", workbook)
        archive.writestr("xl/_rels/workbook.xml.rels", relationships)
        archive.writestr("xl/sharedStrings.xml", shared)
        archive.writestr("xl/worksheets/sheet1.xml", sheet)
        archive.writestr("xl/worksheets/sheet2.xml", hidden_sheet)


def create_pptx(path: Path) -> None:
    presentation = """<?xml version="1.0" encoding="UTF-8"?>
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst>
</p:presentation>"""
    relationships = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
</Relationships>"""
    slide = """<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>PPTX slide text 7391</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
</p:sld>"""
    hidden_slide = """<?xml version="1.0" encoding="UTF-8"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" show="0">
  <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>HIDDEN PPTX 7391</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
</p:sld>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            content_types(
                "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
                "ppt/presentation.xml",
            ),
        )
        archive.writestr("ppt/presentation.xml", presentation)
        archive.writestr("ppt/_rels/presentation.xml.rels", relationships)
        archive.writestr("ppt/slides/slide1.xml", slide)
        archive.writestr("ppt/slides/slide2.xml", hidden_slide)


def create_fixtures(root: Path) -> dict[str, Path]:
    inbox = root / "Inbox"
    appshot = root / "Appshots" / "fixture-shot"
    exports = root / "Exports"
    inbox.mkdir(parents=True)
    appshot.mkdir(parents=True)
    exports.mkdir(parents=True)

    (inbox / "notes.md").write_text(
        f"# Managed fixture\n\nThis is readable text.\napi_key={SECRET}\n",
        encoding="utf-8",
    )
    (inbox / ".hidden.txt").write_text("hidden", encoding="utf-8")
    (appshot / "context.md").write_text("Appshot context 7391", encoding="utf-8")
    (appshot / "metadata.json").write_text('{"private":"metadata"}', encoding="utf-8")
    preview = Image.new("RGB", (96, 64), "white")
    preview.save(appshot / "preview.png", format="PNG")
    (inbox / "fake-image.png").write_text("not image bytes", encoding="utf-8")
    (exports / "results.csv").write_text("name,value\nfixture,7391\n", encoding="utf-8")
    (inbox / "clip.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42generated-fixture")
    outside = root.parent / "outside-secret.txt"
    outside.write_text("outside", encoding="utf-8")
    os.symlink(outside, inbox / "outside-link.md")
    hardlink = inbox / "outside-hardlink.md"
    os.link(outside, hardlink)

    pdf = inbox / "fixture.pdf"
    ocr_image = root.parent / "ocr-fixture.png"
    create_pdf(pdf, ocr_image)
    docx = inbox / "fixture.docx"
    xlsx = inbox / "fixture.xlsx"
    pptx = inbox / "fixture.pptx"
    create_docx(docx)
    create_xlsx(xlsx)
    create_pptx(pptx)
    create_docx(inbox / "unsafe-traversal.docx", traversal=True)
    create_docx(inbox / "unsafe-dtd.docx", dtd=True)
    create_docx(inbox / "unsafe-bomb.docx", bomb=True)
    create_docx(inbox / "unsafe-glob.docx", glob_name=True)
    create_docx(inbox / "unsafe-tracked-deletion.docx", tracked_deletion=True)
    return {
        "pdf": pdf,
        "docx": docx,
        "xlsx": xlsx,
        "pptx": pptx,
        "outside": outside,
        "ocr_image": ocr_image,
    }


def compile_bridge(workspace: Path, output: Path, *, debug: bool) -> None:
    source = workspace / "app/Sources/DeepSeekArtifactBridge/main.swift"
    command = ["swiftc", "-warnings-as-errors"]
    if debug:
        command += ["-D", "DEBUG"]
    else:
        command += ["-O"]
    command += [
        str(source),
        "-o",
        str(output),
        "-framework",
        "AppKit",
        "-framework",
        "PDFKit",
        "-framework",
        "Vision",
        "-framework",
        "CryptoKit",
    ]
    completed = subprocess.run(command, cwd=workspace, text=True, capture_output=True)
    if completed.returncode != 0:
        raise QAError(f"swiftc failed:\n{completed.stdout}\n{completed.stderr}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expect_tool_error(client: BridgeClient, name: str, arguments: dict[str, Any], phrase: str | None = None) -> None:
    payload, is_error = client.tool(name, arguments)
    ensure(is_error, f"{name} unexpectedly accepted unsafe input: {arguments}")
    if phrase:
        ensure(phrase.lower() in str(payload.get("error", "")).lower(), f"{name} error did not mention {phrase}: {payload}")


def run_checks(client: BridgeClient, root: Path, fixtures: dict[str, Path], reporter: Reporter) -> Path:
    response = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})
    ensure(response.get("result", {}).get("serverInfo", {}).get("name") == "deepseek-artifact-bridge", "initialize server identity mismatch")
    reporter.pass_step("MCP initialize")

    ensure(client.oversized_line_is_rejected(), "oversized JSONL input was not rejected")
    recovery = client.request("ping")
    ensure("result" in recovery, "MCP did not recover after an oversized JSONL line")
    reporter.pass_step("bounded streaming JSONL input and recovery")

    tools = client.request("tools/list").get("result", {}).get("tools", [])
    names = {item.get("name") for item in tools if isinstance(item, dict)}
    ensure(names == REQUIRED_TOOLS, f"tool catalog mismatch: {sorted(names)}")
    reporter.pass_step("MCP tool catalog", f"{len(names)} tools")

    ping, is_error = client.tool("ping")
    ensure(not is_error and ping.get("root") == "Artifacts/", f"ping failed: {ping}")
    ensure(ping.get("layout") == ["Inbox/", "Appshots/<id>/", "Renders/", "Exports/"], "managed layout mismatch")
    reporter.pass_step("fixed managed-root contract")

    listing, is_error = client.tool("list_files")
    ensure(not is_error, f"list_files failed: {listing}")
    paths = {item["path"] for item in listing.get("files", [])}
    for expected in {
        "Inbox/notes.md",
        "Inbox/fixture.pdf",
        "Inbox/fixture.docx",
        "Inbox/fixture.xlsx",
        "Inbox/fixture.pptx",
        "Appshots/fixture-shot/context.md",
        "Appshots/fixture-shot/preview.png",
        "Exports/results.csv",
    }:
        ensure(expected in paths, f"recursive list omitted {expected}")
    ensure("Appshots/fixture-shot/metadata.json" not in paths, "metadata.json was not skipped")
    ensure("Inbox/.hidden.txt" not in paths, "hidden file was not skipped")
    ensure("Inbox/outside-link.md" not in paths, "symbolic link was not skipped")
    reporter.pass_step("recursive layout discovery", f"{len(paths)} bounded files")

    text, is_error = client.tool("read_text", {"path": "Inbox/notes.md", "max_chars": 20_000})
    ensure(not is_error and "Managed fixture" in text.get("text", ""), f"read_text failed: {text}")
    ensure(SECRET not in text.get("text", "") and "[REDACTED]" in text.get("text", ""), "read_text did not redact secret")
    ensure(text.get("content_is_untrusted") is True, "read_text omitted untrusted-content marker")
    reporter.pass_step("bounded text read and redaction")

    inspected, is_error = client.tool("inspect_file", {"path": "Inbox/fixture.pdf", "include_sha256": True})
    ensure(not is_error and inspected.get("sha256") == sha256(fixtures["pdf"]), f"inspect_file hash mismatch: {inspected}")
    reporter.pass_step("file inspection and SHA-256")

    direct, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Appshots/fixture-shot/preview.png", "provider": "moonshotai-cn", "model": "kimi-k3"},
    )
    ensure(not is_error and direct.get("routing_mode") == "direct_multimodal", f"image routing failed: {direct}")
    ensure(direct.get("requires_user_confirmation") is True and direct.get("data_sent") is False, "image routing skipped confirmation/no-send boundary")
    ensure(direct.get("mcp_can_transmit_multimodal_block") is False, "MCP incorrectly claimed image transmission")
    flash_vision, is_error = client.tool(
        "prepare_input",
        {
            "relative_path": "Appshots/fixture-shot/preview.png",
            "provider": "deepseek-official",
            "model": "deepseek-v4-flash-vision-exp",
        },
    )
    ensure(
        not is_error and flash_vision.get("routing_mode") == "direct_multimodal",
        f"exact DeepSeek Flash Vision image routing failed: {flash_vision}",
    )
    deepseek_text_image, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Appshots/fixture-shot/preview.png", "provider": "deepseek-official", "model": "deepseek-v4-pro"},
    )
    ensure(
        not is_error and deepseek_text_image.get("routing_mode") == "local_extract",
        f"non-vision DeepSeek image route was incorrectly promoted: {deepseek_text_image}",
    )
    unverified_image, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Inbox/fake-image.png", "provider": "moonshotai-cn", "model": "kimi-k3"},
    )
    ensure(
        not is_error
        and unverified_image.get("routing_mode") == "unsupported"
        and unverified_image.get("content_type_verified") is False,
        f"forged image extension did not fail closed: {unverified_image}",
    )

    local_pdf, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Inbox/fixture.pdf", "provider": "deepseek-official", "model": "deepseek-v4-pro"},
    )
    ensure(not is_error and local_pdf.get("routing_mode") == "local_extract", f"DeepSeek PDF routing failed: {local_pdf}")
    vision_pdf, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Inbox/fixture.pdf", "provider": "moonshotai", "model": "kimi-k3"},
    )
    ensure(not is_error and vision_pdf.get("routing_mode") == "render_pages_for_vision", f"vision PDF routing failed: {vision_pdf}")
    video, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Inbox/clip.mp4", "provider": "moonshotai-cn", "model": "kimi-k3"},
    )
    ensure(not is_error and video.get("routing_mode") == "controlled_video_upload_required", f"video routing failed: {video}")
    unknown, is_error = client.tool(
        "prepare_input",
        {"relative_path": "Inbox/fixture.pdf", "provider": "moonshotai-cn", "model": "unverified-model"},
    )
    ensure(not is_error and unknown.get("routing_mode") == "unsupported", f"unknown model did not fail closed: {unknown}")
    ensure(direct.get("registry_source") == "debug_override", "DEBUG registry override was not used")
    reporter.pass_step("capability-registry exact vision/text/PDF/video routing")

    expect_tool_error(client, "inspect_file", {"path": "/etc/passwd"}, "relative")
    expect_tool_error(client, "read_text", {"path": "../outside-secret.txt"}, "traversal")
    expect_tool_error(client, "read_text", {"path": "Inbox/outside-link.md"})
    expect_tool_error(client, "read_text", {"path": "Inbox/outside-hardlink.md"})
    expect_tool_error(client, "read_text", {"path": "Inbox/notes.md", "unknown": True}, "unknown")
    reporter.pass_step("absolute, traversal, symlink, hardlink, and schema rejection")

    pdf_before = sha256(fixtures["pdf"])
    info, is_error = client.tool("pdf_info", {"path": "Inbox/fixture.pdf"})
    ensure(not is_error and info.get("page_count") == 3, f"pdf_info failed: {info}")
    ensure(len(info.get("page_dimensions", [])) == 3, "pdf_info dimensions missing")
    reporter.pass_step("PDF metadata and page geometry")

    extracted, is_error = client.tool(
        "pdf_extract",
        {"path": "Inbox/fixture.pdf", "start_page": 1, "end_page": 2, "max_chars": 40_000},
    )
    ensure(not is_error and len(extracted.get("pages", [])) == 2, f"pdf_extract failed: {extracted}")
    joined = "\n".join(page.get("text", "") for page in extracted["pages"])
    ensure("Artifact Bridge PDF Fixture" in joined and SEARCH_SENTINEL in joined, "PDF text was not extracted")
    ensure(SECRET not in joined and "[REDACTED]" in joined, "PDF secret was not redacted")
    ensure(extracted.get("content_is_untrusted") is True, "pdf_extract omitted untrusted marker")
    reporter.pass_step("bounded PDF page-range extraction and redaction")

    search, is_error = client.tool("pdf_search", {"path": "Inbox/fixture.pdf", "query": "RESEARCH EVIDENCE 7391"})
    ensure(not is_error and search.get("result_count", 0) >= 1, f"pdf_search failed: {search}")
    ensure(search["results"][0].get("page") == 2, f"pdf_search cited wrong page: {search}")
    ensure(search["results"][0].get("page_reference") == "Inbox/fixture.pdf#page=2", "page reference mismatch")
    reporter.pass_step("PDF search with exact page reference")

    ocr, is_error = client.tool(
        "pdf_extract",
        {"path": "Inbox/fixture.pdf", "start_page": 3, "end_page": 3, "ocr_fallback": True},
    )
    ensure(not is_error and ocr.get("pages", [{}])[0].get("source") == "vision_ocr", f"OCR fallback not used: {ocr}")
    ocr_text = ocr.get("pages", [{}])[0].get("text", "")
    ensure("OCR" in ocr_text and "7391" in ocr_text, f"Vision OCR missed sentinel: {ocr_text!r}")
    reporter.pass_step("explicit in-memory Vision OCR fallback")

    rendered, is_error = client.tool("pdf_render_page", {"path": "Inbox/fixture.pdf", "page": 1, "dpi": 144})
    ensure(not is_error, f"pdf_render_page failed: {rendered}")
    render_relative = rendered.get("render_path")
    ensure(isinstance(render_relative, str) and render_relative.startswith("Renders/") and render_relative.endswith(".png"), "render escaped Renders/")
    render_path = root / render_relative
    ensure(render_path.is_file() and render_path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "rendered PNG is invalid")
    ensure(sha256(fixtures["pdf"]) == pdf_before and rendered.get("source_overwritten") is False, "PDF source changed during render")
    second, second_error = client.tool("pdf_render_page", {"path": "Inbox/fixture.pdf", "page": 1, "dpi": 144})
    ensure(not second_error and second.get("created") is False, "repeat render should reuse immutable existing PNG")

    expected_png = render_path.read_bytes()
    outside_render = root.parent / "outside-render.png"
    outside_render.write_bytes(expected_png)
    render_path.unlink()
    os.link(outside_render, render_path)
    expect_tool_error(client, "pdf_render_page", {"path": "Inbox/fixture.pdf", "page": 1, "dpi": 144})
    ensure(outside_render.read_bytes() == expected_png, "hard-linked outside render was modified")
    render_path.unlink()

    render_directory = render_path.parent
    render_directory.rmdir()
    outside_directory = root.parent / "outside-render-directory"
    outside_directory.mkdir()
    os.symlink(outside_directory, render_directory)
    expect_tool_error(client, "pdf_render_page", {"path": "Inbox/fixture.pdf", "page": 1, "dpi": 144}, "unsafe")
    ensure(not any(outside_directory.iterdir()), "intermediate render symlink escaped the managed root")
    render_directory.unlink()

    recovered, recovered_error = client.tool("pdf_render_page", {"path": "Inbox/fixture.pdf", "page": 1, "dpi": 144})
    ensure(not recovered_error and recovered.get("created") is True, "render did not recover after unsafe path rejection")
    ensure(render_path.read_bytes() == expected_png, "recovered deterministic render changed")
    ensure(recovered.get("automatic_upload") is False, "render tool incorrectly claimed automatic upload")
    ensure(recovered.get("render_contains_unredacted_source_pixels") is True, "render privacy marker missing")
    reporter.pass_step("FD-confined immutable PDF render output", render_relative)

    office_cases = [
        ("fixture.docx", "DOCX fixture paragraph 7391"),
        ("fixture.xlsx", "XLSX shared text 7391"),
        ("fixture.pptx", "PPTX slide text 7391"),
    ]
    for filename, sentinel in office_cases:
        office, is_error = client.tool("office_extract_text", {"path": f"Inbox/{filename}"})
        ensure(not is_error and sentinel in office.get("text", ""), f"Office extraction failed for {filename}: {office}")
        ensure(office.get("archive_extracted_to_disk") is False, f"{filename} claimed disk extraction")
        if filename.endswith(".docx"):
            ensure(not any(private in office.get("text", "") for private in DOCX_PRIVATE_SENTINELS), "DOCX leaked comments, tracked deletion, or spoofed namespace text")
        ensure(not any(private in office.get("text", "") for private in HIDDEN_OFFICE_SENTINELS), f"{filename} leaked hidden Office content")
        ensure(office.get("hidden_sheets_or_slides_included") is False, f"{filename} omitted its hidden-content privacy marker")
    reporter.pass_step("DOCX/XLSX/PPTX bounded read-only extraction")

    expect_tool_error(client, "office_extract_text", {"path": "Inbox/unsafe-traversal.docx"}, "traversal")
    expect_tool_error(client, "office_extract_text", {"path": "Inbox/unsafe-dtd.docx"}, "DTD")
    expect_tool_error(client, "office_extract_text", {"path": "Inbox/unsafe-bomb.docx"}, "limit")
    expect_tool_error(client, "office_extract_text", {"path": "Inbox/unsafe-glob.docx"}, "unsafe")
    expect_tool_error(client, "office_extract_text", {"path": "Inbox/unsafe-tracked-deletion.docx"}, "tracked")
    reporter.pass_step("OOXML traversal, DTD/entity, glob, tracked-deletion, and ZIP-bomb rejection")

    ensure(not (root.parent / "escape.xml").exists(), "unsafe Office entry escaped to disk")
    ensure(sha256(fixtures["docx"]) == sha256(root / "Inbox/fixture.docx"), "DOCX source changed")
    return render_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--root", type=Path, help="Use an explicit empty QA root and keep it for visual inspection")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    workspace = args.workspace.resolve()
    reporter = Reporter()
    temporary: tempfile.TemporaryDirectory[str] | None = None
    client: BridgeClient | None = None
    try:
        if args.root:
            artifact_root = args.root.resolve()
            artifact_root.mkdir(parents=True, exist_ok=True)
            ensure(not any(artifact_root.iterdir()), "--root must be empty")
            artifact_root.chmod(0o700)
            qa_parent = artifact_root.parent
        else:
            temporary = tempfile.TemporaryDirectory(prefix="deepseek-artifact-bridge-qa-")
            qa_parent = Path(temporary.name)
            artifact_root = qa_parent / "Artifacts"
            artifact_root.mkdir(mode=0o700)

        fixtures = create_fixtures(artifact_root)
        debug_binary = qa_parent / "DeepSeekArtifactBridge-debug"
        release_binary = qa_parent / "DeepSeekArtifactBridge-release"
        compile_bridge(workspace, debug_binary, debug=True)
        compile_bridge(workspace, release_binary, debug=False)
        reporter.pass_step("DEBUG and Release standalone compile")

        client = BridgeClient(
            debug_binary,
            artifact_root,
            workspace / "integration/model-capabilities.json",
        )
        render = run_checks(client, artifact_root, fixtures, reporter)
        print(f"VISUAL_RENDER={render}")
        print(f"QA_ROOT={artifact_root}")
    except Exception as error:
        reporter.fail_step("artifact bridge QA", str(error))
    finally:
        if client is not None:
            client.close()
        status = reporter.summary()
        if temporary is not None:
            temporary.cleanup()
        return status


if __name__ == "__main__":
    raise SystemExit(main())
