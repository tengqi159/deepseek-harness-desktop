#!/usr/bin/python3
"""Safe, repeatable end-to-end QA for DeepSeekAppBridge.

The test creates two disposable AppKit app bundles in a temporary directory and
points the bridge at a temporary selection file. It never reads the production
selection, DeepSeek credentials, or another user application.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Iterable


PRIMARY_BUNDLE_ID = "com.tengqi.deepseek-bridge-fixture.primary"
DECOY_BUNDLE_ID = "com.tengqi.deepseek-bridge-fixture.decoy"
SECRET_SENTINEL = "fixture-secret-must-be-redacted-4729"
SYNTHETIC_SECRET_PROBE = "sk-" + "fixtureredactiontoken4729abcd"
OCR_SENTINEL = "OCR SAFETY CHECK 4729"
REQUIRED_TOOLS = {
    "ping",
    "permission_status",
    "list_apps",
    "get_app_state",
    "activate_app",
    "click_element",
    "click_point",
    "set_value",
    "type_text",
    "press_key",
    "scroll",
    "drag",
    "perform_secondary_action",
    "select_text",
    "wait_for_state",
    "recording_start",
    "recording_status",
    "recording_stop",
}

WATCHDOG_DSH_CODE = r"""
# deepseek-watchdog-dummy-dsh
import json
import os
import subprocess
import sys

helper = subprocess.Popen(
    [sys.argv[1]],
    stdin=subprocess.PIPE,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=os.environ.copy(),
)
payload = {
    "wrapper_pid": int(os.environ["DSH_APP_BRIDGE_PARENT_PID"]),
    "dsh_pid": os.getpid(),
    "helper_pid": helper.pid,
}
temporary = sys.argv[2] + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, sys.argv[2])
helper.wait()
"""

WATCHDOG_WRAPPER_CODE = r"""
# deepseek-watchdog-dummy-wrapper
import os
import subprocess
import sys

environment = os.environ.copy()
environment["DSH_APP_BRIDGE_PARENT_PID"] = str(os.getpid())
dsh = subprocess.Popen(
    [sys.executable, "-c", sys.argv[3], sys.argv[1], sys.argv[2]],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=environment,
)
dsh.wait()
"""


class QAError(RuntimeError):
    pass


class Reporter:
    def __init__(self) -> None:
        self.passed = 0
        self.skipped = 0
        self.failed = 0

    def passed_step(self, name: str, detail: str = "") -> None:
        self.passed += 1
        suffix = f" — {detail}" if detail else ""
        print(f"PASS  {name}{suffix}")

    def skipped_step(self, name: str, detail: str) -> None:
        self.skipped += 1
        print(f"SKIP  {name} — {detail}")

    def failed_step(self, name: str, detail: str) -> None:
        self.failed += 1
        print(f"FAIL  {name} — {detail}")

    def summary(self) -> int:
        print()
        print(f"RESULT pass={self.passed} skip={self.skipped} fail={self.failed}")
        return 1 if self.failed else 0


class BridgeClient:
    def __init__(self, executable: Path, selection_file: Path, cwd: Path) -> None:
        environment = os.environ.copy()
        environment["DSH_APP_BRIDGE_SELECTION_FILE"] = str(selection_file)
        self.process = subprocess.Popen(
            [str(executable)],
            cwd=str(cwd),
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        if self.process.stdin is None or self.process.stdout is None:
            raise QAError("Unable to open bridge JSONL streams")
        self._selector = selectors.DefaultSelector()
        self._selector.register(self.process.stdout, selectors.EVENT_READ)
        self._next_id = 1

    def request(self, method: str, params: dict[str, Any] | None = None, timeout: float = 12.0) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise QAError(f"Bridge exited unexpectedly with status {self.process.returncode}: {self.stderr_text()}")
            events = self._selector.select(max(0.0, deadline - time.monotonic()))
            if not events:
                break
            line = self.process.stdout.readline()
            if not line:
                continue
            try:
                response = json.loads(line)
            except json.JSONDecodeError as error:
                raise QAError(f"Bridge emitted invalid JSON: {line!r}: {error}") from error
            if response.get("id") == request_id:
                return response
        raise QAError(f"Timed out waiting for bridge method {method}")

    def notification(self, method: str, params: dict[str, Any] | None = None) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)

    def tool(self, name: str, arguments: dict[str, Any] | None = None) -> tuple[dict[str, Any], bool]:
        timeout = 12.0
        if name == "get_app_state" and (arguments or {}).get("include_ocr"):
            timeout = 30.0
        elif name in {"drag", "wait_for_state"}:
            timeout = 20.0
        response = self.request(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
            timeout=timeout,
        )
        if "error" in response:
            raise QAError(f"JSON-RPC error for tool {name}: {response['error']}")
        result = response.get("result")
        if not isinstance(result, dict):
            raise QAError(f"Tool {name} returned no result object")
        payload = result.get("structuredContent")
        if not isinstance(payload, dict):
            raise QAError(f"Tool {name} returned no structuredContent object")
        return payload, bool(result.get("isError"))

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
            self._selector.close()

    def stderr_text(self) -> str:
        if self.process.stderr is None or self.process.poll() is None:
            return ""
        return self.process.stderr.read().strip()

    def _write(self, message: dict[str, Any]) -> None:
        if self.process.stdin is None:
            raise QAError("Bridge stdin is unavailable")
        self.process.stdin.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
        self.process.stdin.flush()


class FixtureProcess:
    def __init__(self, launcher: subprocess.Popen[str], log_handle: Any) -> None:
        self.launcher = launcher
        self.log_handle = log_handle
        self.app_pid: int | None = None

    @property
    def pid(self) -> int:
        if self.app_pid is None:
            raise QAError("Fixture app PID is not available yet")
        return self.app_pid

    def bind_state(self, state: dict[str, Any]) -> None:
        pid = int(state.get("pid", 0))
        ensure(pid > 1, f"Fixture reported invalid PID {pid}")
        self.app_pid = pid


def ensure(condition: bool, message: str) -> None:
    if not condition:
        raise QAError(message)


def create_fixture_bundle(root: Path, fixture_binary: Path, display_name: str, bundle_id: str) -> tuple[Path, Path]:
    app_path = root / f"{display_name}.app"
    contents = app_path / "Contents"
    macos = contents / "MacOS"
    macos.mkdir(parents=True)
    executable = macos / "DeepSeekBridgeFixture"
    shutil.copy2(fixture_binary, executable)
    executable.chmod(0o755)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": display_name,
        "CFBundleExecutable": executable.name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": display_name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=True)
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app_path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    return app_path, executable


def launch_fixture(executable: Path, role: str, state_file: Path, ready_file: Path, log_file: Path) -> FixtureProcess:
    log_handle = log_file.open("w", encoding="utf-8")
    app_path = executable.parents[2]
    launcher = subprocess.Popen(
        [
            "/usr/bin/open",
            "-n",
            "-W",
            str(app_path),
            "--args",
            "--role",
            role,
            "--state-file",
            str(state_file),
            "--ready-file",
            str(ready_file),
        ],
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return FixtureProcess(launcher, log_handle)


def stop_fixture(process: FixtureProcess) -> None:
    if process.app_pid is not None and process_exists(process.app_pid):
        command = process_command(process.app_pid)
        if "DeepSeekBridgeFixture" in command:
            try:
                os.kill(process.app_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and process_exists(process.app_pid):
                time.sleep(0.05)
            if process_exists(process.app_pid) and "DeepSeekBridgeFixture" in process_command(process.app_pid):
                try:
                    os.kill(process.app_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    if process.launcher.poll() is None:
        try:
            process.launcher.terminate()
            process.launcher.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            process.launcher.kill()
            process.launcher.wait(timeout=2.0)
    process.log_handle.close()


def process_exists(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False


def process_parent(pid: int) -> int | None:
    result = subprocess.run(
        ["/bin/ps", "-o", "ppid=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def process_command(pid: int) -> str:
    result = subprocess.run(
        ["/bin/ps", "-o", "command=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def stop_synthetic_process(pid: int, expected_token: str) -> None:
    if not process_exists(pid) or expected_token not in process_command(pid):
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline and process_exists(pid):
        time.sleep(0.05)
    if process_exists(pid) and expected_token in process_command(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def test_parent_death_watchdog(helper: Path, temp_root: Path, reporter: Reporter) -> None:
    state_file = temp_root / "watchdog-state.json"
    log_file = (temp_root / "watchdog-wrapper.log").open("w", encoding="utf-8")
    wrapper = subprocess.Popen(
        [
            sys.executable,
            "-c",
            WATCHDOG_WRAPPER_CODE,
            str(helper),
            str(state_file),
            WATCHDOG_DSH_CODE,
        ],
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        text=True,
    )
    state: dict[str, Any] = {}
    try:
        state = wait_for_state(
            state_file,
            lambda value: all(int(value.get(key, 0)) > 1 for key in ("wrapper_pid", "dsh_pid", "helper_pid")),
            timeout=8.0,
        )
        wrapper_pid = int(state["wrapper_pid"])
        dsh_pid = int(state["dsh_pid"])
        helper_pid = int(state["helper_pid"])
        ensure(wrapper_pid == wrapper.pid, "Synthetic watchdog chain recorded the wrong wrapper PID")
        ensure(process_parent(dsh_pid) == wrapper_pid, "Dummy dsh is not a direct child of the synthetic wrapper")
        ensure(process_parent(helper_pid) == dsh_pid, "Bridge helper is not a direct child of dummy dsh")
        ensure("deepseek-watchdog-dummy-dsh" in process_command(dsh_pid), "Unexpected process occupied dummy dsh PID")
        ensure(helper.name in process_command(helper_pid), "Unexpected process occupied bridge helper PID")

        wrapper.terminate()
        wrapper.wait(timeout=3.0)
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline and (process_exists(dsh_pid) or process_exists(helper_pid)):
            time.sleep(0.10)
        ensure(not process_exists(dsh_pid), "Dummy dsh survived wrapper parent death")
        ensure(not process_exists(helper_pid), "Bridge helper survived wrapper parent death")
        reporter.passed_step("Parent-death watchdog", "wrapper death terminated dummy dsh and bridge helper")
    finally:
        if wrapper.poll() is None:
            wrapper.terminate()
            try:
                wrapper.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                wrapper.kill()
                wrapper.wait(timeout=2.0)
        if state:
            stop_synthetic_process(int(state.get("helper_pid", 0)), helper.name)
            stop_synthetic_process(int(state.get("dsh_pid", 0)), "deepseek-watchdog-dummy-dsh")
        log_file.close()


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def wait_for_state(path: Path, predicate: Callable[[dict[str, Any]], bool], timeout: float = 8.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    latest: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        latest = read_json(path)
        if latest is not None and predicate(latest):
            return latest
        time.sleep(0.08)
    raise QAError(f"Timed out waiting for fixture state {path.name}; latest={latest}")


def isolation_signature(state: dict[str, Any]) -> dict[str, Any]:
    """Return only state that an action routed to the wrong fixture could change."""
    return {
        "click_count": int(state.get("click_count", 0)),
        "input_value": str(state.get("input_value", "")),
        "key_event_count": int(state.get("key_event_count", 0)),
        "scroll_event_count": int(state.get("scroll_event_count", 0)),
        "scroll_origin_y": float(state.get("scroll_origin_y", 0.0)),
        "secondary_action_count": int(state.get("secondary_action_count", 0)),
        "scheduled_wait_count": int(state.get("scheduled_wait_count", 0)),
        "slider_action_count": int(state.get("slider_action_count", 0)),
        "slider_value": float(state.get("slider_value", 0.0)),
    }


def wait_for_quiet_isolation_baseline(
    paths: dict[str, Path], *, quiet_period: float = 0.5, timeout: float = 4.0
) -> dict[str, dict[str, Any]]:
    """Wait out launch-time input/momentum before binding the isolation assertion.

    Each disposable app briefly activates itself while starting. Real user input can
    therefore reach a fixture before the bridge chooses and activates its exact PID.
    Isolation is about changes after that binding, so compare against a quiet baseline
    instead of assuming every launch-time event counter must be zero.
    """
    deadline = time.monotonic() + timeout
    stable_since: float | None = None
    previous: dict[str, dict[str, Any]] | None = None
    while time.monotonic() < deadline:
        current: dict[str, dict[str, Any]] = {}
        for name, path in paths.items():
            state = read_json(path)
            if state is None:
                break
            current[name] = isolation_signature(state)
        if len(current) != len(paths):
            stable_since = None
            previous = None
            time.sleep(0.05)
            continue
        now = time.monotonic()
        if current == previous:
            stable_since = stable_since or now
            if now - stable_since >= quiet_period:
                return current
        else:
            previous = current
            stable_since = now
        time.sleep(0.05)
    raise QAError(f"Fixture isolation state did not become quiet before testing; latest={previous}")


def write_production_selection(path: Path, app: dict[str, Any]) -> None:
    payload = {
        "bundleIdentifier": app["bundle_identifier"],
        "displayName": app["name"],
        "processIdentifier": app["pid"],
        "processLaunchTime": app["process_launch_time"],
        "updatedAt": "fixture-test",
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


def flatten_tree(root: dict[str, Any]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    stack = [root]
    while stack:
        node = stack.pop()
        output.append(node)
        children = node.get("children")
        if isinstance(children, list):
            stack.extend(child for child in reversed(children) if isinstance(child, dict))
    return output


def find_node(nodes: Iterable[dict[str, Any]], *, identifier: str | None = None, title: str | None = None, role: str | None = None) -> dict[str, Any]:
    for node in nodes:
        if identifier is not None and node.get("identifier") != identifier:
            continue
        if title is not None and node.get("title") != title:
            continue
        if role is not None and node.get("role") != role:
            continue
        return node
    criteria = {"identifier": identifier, "title": title, "role": role}
    raise QAError(f"Unable to find Accessibility node matching {criteria}")


def error_text(payload: dict[str, Any]) -> str:
    return str(payload.get("error", ""))


def remove_test_recording_draft(directory: Path | None, recording_id: str | None) -> None:
    if directory is None or recording_id is None or directory.name != recording_id:
        return
    allowed = (Path.home() / "Library" / "Application Support" / "DeepSeek Harness" / "drafts").resolve()
    try:
        directory.resolve().relative_to(allowed)
    except (OSError, ValueError):
        return
    if directory.is_dir() and (directory / "SKILL.md").is_file():
        shutil.rmtree(directory)


def wait_for_listed_app(client: BridgeClient, bundle_id: str, timeout: float = 8.0) -> dict[str, Any]:
    return wait_for_listed_apps(client, bundle_id, count=1, timeout=timeout)[0]


def wait_for_listed_apps(
    client: BridgeClient, bundle_id: str, count: int, timeout: float = 8.0
) -> list[dict[str, Any]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        payload, is_error = client.tool("list_apps")
        if not is_error:
            matches = [
                app
                for app in payload.get("apps", [])
                if isinstance(app, dict) and app.get("bundle_identifier") == bundle_id
            ]
            if len(matches) >= count:
                return matches
        time.sleep(0.12)
    raise QAError(f"Expected {count} fixture app instance(s) for {bundle_id} in list_apps")


def run(args: argparse.Namespace, temp_root: Path, reporter: Reporter) -> None:
    bundles = temp_root / "bundles"
    bundles.mkdir()
    _, primary_executable = create_fixture_bundle(
        bundles, args.fixture, "DeepSeek Bridge QA Primary", PRIMARY_BUNDLE_ID
    )
    _, decoy_executable = create_fixture_bundle(
        bundles, args.fixture, "DeepSeek Bridge QA Decoy", DECOY_BUNDLE_ID
    )
    reporter.passed_step("Disposable fixture bundles", "ad-hoc signed in a temporary directory")

    primary_state = temp_root / "primary-state.json"
    sibling_state = temp_root / "sibling-state.json"
    decoy_state = temp_root / "decoy-state.json"
    primary = launch_fixture(
        primary_executable,
        "primary",
        primary_state,
        temp_root / "primary-ready",
        temp_root / "primary.log",
    )
    sibling = launch_fixture(
        primary_executable,
        "sibling",
        sibling_state,
        temp_root / "sibling-ready",
        temp_root / "sibling.log",
    )
    decoy = launch_fixture(
        decoy_executable,
        "decoy",
        decoy_state,
        temp_root / "decoy-ready",
        temp_root / "decoy.log",
    )
    client: BridgeClient | None = None
    selection_file = temp_root / "selection.json"
    draft_directory: Path | None = None
    draft_recording_id: str | None = None
    try:
        primary_initial = wait_for_state(
            primary_state,
            lambda value: value.get("ready") is True and value.get("bundle_identifier") == PRIMARY_BUNDLE_ID,
        )
        decoy_initial = wait_for_state(
            decoy_state,
            lambda value: value.get("ready") is True and value.get("bundle_identifier") == DECOY_BUNDLE_ID,
        )
        sibling_initial = wait_for_state(
            sibling_state,
            lambda value: value.get("ready") is True and value.get("bundle_identifier") == PRIMARY_BUNDLE_ID,
        )
        primary.bind_state(primary_initial)
        sibling.bind_state(sibling_initial)
        decoy.bind_state(decoy_initial)
        ensure(primary_initial.get("input_value") == "PRIMARY-INITIAL", "Primary fixture initialized incorrectly")
        ensure(sibling_initial.get("input_value") == "SIBLING-INITIAL", "Same-bundle sibling initialized incorrectly")
        ensure(decoy_initial.get("input_value") == "DECOY-INITIAL", "Decoy fixture initialized incorrectly")
        reporter.passed_step("Fixture launch", "primary, same-bundle sibling, and cross-bundle decoy are ready")

        release_override = temp_root / "release-selection-override-must-be-ignored.json"
        release_client = BridgeClient(args.release_bridge, release_override, temp_root)
        try:
            release_permissions, release_permission_error = release_client.tool("permission_status")
            ensure(not release_permission_error, "Release helper permission_status failed")
            ensure(
                release_permissions.get("selection_file") != str(release_override),
                "Release helper accepted DSH_APP_BRIDGE_SELECTION_FILE and could bypass the production attachment",
            )
            reporter.passed_step("Release selection isolation", "test-only selection override ignored outside DEBUG")
        finally:
            release_client.close()

        test_parent_death_watchdog(args.release_bridge, temp_root, reporter)

        client = BridgeClient(args.bridge, selection_file, temp_root)
        initialized = client.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "deepseek-bridge-e2e", "version": "1.0"},
            },
        )
        result = initialized.get("result", {})
        ensure(result.get("protocolVersion") == "2025-06-18", "initialize negotiated the wrong protocol")
        ensure(result.get("serverInfo", {}).get("name") == "deepseek-app-bridge", "initialize serverInfo mismatch")
        client.notification("notifications/initialized")
        reporter.passed_step("MCP initialize", "2025-06-18")

        listed = client.request("tools/list")
        tool_defs = listed.get("result", {}).get("tools", [])
        names = {tool.get("name") for tool in tool_defs if isinstance(tool, dict)}
        ensure(REQUIRED_TOOLS.issubset(names), f"tools/list missing {sorted(REQUIRED_TOOLS - names)}")
        by_name = {tool.get("name"): tool for tool in tool_defs if isinstance(tool, dict)}
        click_required = set(by_name["click_element"]["inputSchema"].get("required", []))
        click_point_required = set(by_name["click_point"]["inputSchema"].get("required", []))
        set_required = set(by_name["set_value"]["inputSchema"].get("required", []))
        type_required = set(by_name["type_text"]["inputSchema"].get("required", []))
        key_required = set(by_name["press_key"]["inputSchema"].get("required", []))
        scroll_required = set(by_name["scroll"]["inputSchema"].get("required", []))
        drag_required = set(by_name["drag"]["inputSchema"].get("required", []))
        secondary_required = set(by_name["perform_secondary_action"]["inputSchema"].get("required", []))
        select_required = set(by_name["select_text"]["inputSchema"].get("required", []))
        wait_required = set(by_name["wait_for_state"]["inputSchema"].get("required", []))
        recording_start_required = set(by_name["recording_start"]["inputSchema"].get("required", []))
        recording_stop_required = set(by_name["recording_stop"]["inputSchema"].get("required", []))
        ensure({"element_id", "snapshot_id"}.issubset(click_required), "click_element schema must require snapshot_id")
        ensure({"snapshot_id", "x", "y"}.issubset(click_point_required), "click_point schema must bind an OCR snapshot")
        ensure({"element_id", "snapshot_id", "value"}.issubset(set_required), "set_value schema must require snapshot_id")
        ensure({"element_id", "snapshot_id", "text"}.issubset(type_required), "type_text schema must bind one element and snapshot")
        ensure({"snapshot_id", "key"}.issubset(key_required), "press_key schema must bind one snapshot")
        ensure({"element_id", "snapshot_id", "delta_y"}.issubset(scroll_required), "scroll schema must bind one element and snapshot")
        ensure({"snapshot_id"}.issubset(drag_required), "drag schema must bind one snapshot")
        ensure({"element_id", "snapshot_id"}.issubset(secondary_required), "secondary action schema must bind one element and snapshot")
        ensure({"element_id", "snapshot_id", "start", "length"}.issubset(select_required), "select_text schema must bind a range, element, and snapshot")
        ensure(
            {"element_id", "snapshot_id", "attribute", "operator", "expected"}.issubset(wait_required),
            "wait_for_state schema must bind a condition, element, and snapshot",
        )
        ensure({"snapshot_id"}.issubset(recording_start_required), "recording_start schema must bind one snapshot")
        ensure({"snapshot_id"}.issubset(recording_stop_required), "recording_stop schema must bind one snapshot")
        ensure(not by_name["recording_status"]["inputSchema"].get("required"), "recording_status must remain read-only and argument-free")
        reporter.passed_step("MCP tools/list", f"{len(names)} tools; Computer Use 2.0 snapshot binding required")

        protocol_ping = client.request("ping")
        ensure(protocol_ping.get("result") == {}, "Protocol ping result was not empty")
        tool_ping, ping_error = client.tool("ping")
        ensure(not ping_error and tool_ping.get("ok") is True, "Tool ping failed")
        reporter.passed_step("MCP ping", "protocol method and bridge tool")

        permissions, permission_error = client.tool("permission_status")
        ensure(not permission_error and permissions.get("prompts_requested") is False, "permission_status was unsafe or failed")
        ensure(permissions.get("selection_file") == str(selection_file), "Selection override was not isolated")
        reporter.passed_step("Permission preflight", "read-only; prompts_requested=false")

        primary_apps = wait_for_listed_apps(client, PRIMARY_BUNDLE_ID, count=2)
        primary_by_pid = {int(app["pid"]): app for app in primary_apps}
        ensure(primary.pid in primary_by_pid and sibling.pid in primary_by_pid, "list_apps missed a same-bundle instance")
        primary_app = primary_by_pid[primary.pid]
        decoy_app = wait_for_listed_app(client, DECOY_BUNDLE_ID)
        reporter.passed_step("MCP list_apps", "two same-bundle instances and a decoy resolved")

        access = bool(permissions.get("permissions", {}).get("accessibility"))
        event_posting = bool(permissions.get("permissions", {}).get("event_posting"))
        interactive = bool(permissions.get("interactive_session", {}).get("control_allowed"))
        if not access or not interactive:
            reason = f"accessibility={access}, interactive_session={interactive}; no permission was requested"
            reporter.skipped_step("Strict selection and AX actions", reason)
            reporter.skipped_step("Keyboard and scroll actions", reason)
            reporter.skipped_step("In-memory OCR", reason)
            return

        no_selection, no_selection_error = client.tool("get_app_state")
        ensure(no_selection_error and "No attached-app selection exists" in error_text(no_selection), "Missing selection did not fail closed")
        reporter.passed_step("Strict selection: missing file", "failed closed")

        selection_file.write_text(json.dumps({"pid": primary_app["pid"]}) + "\n", encoding="utf-8")
        selection_file.chmod(0o600)
        missing_bundle, missing_bundle_error = client.tool("get_app_state")
        ensure(missing_bundle_error and "must include bundle_identifier" in error_text(missing_bundle), "PID-only selection was accepted")
        reporter.passed_step("Strict selection: PID only", "rejected")

        legacy_selection = {
            "bundleIdentifier": primary_app["bundle_identifier"],
            "displayName": primary_app["name"],
            "processIdentifier": primary_app["pid"],
            "updatedAt": "fixture-test",
        }
        selection_file.write_text(json.dumps(legacy_selection) + "\n", encoding="utf-8")
        selection_file.chmod(0o600)
        missing_lifetime, missing_lifetime_error = client.tool("get_app_state")
        ensure(
            missing_lifetime_error and "lacks processLaunchTime" in error_text(missing_lifetime),
            "Selection without process lifetime was accepted",
        )
        reporter.passed_step("Strict selection: missing launch time", "legacy PID-only lifetime rejected")

        sensitive_selection = {
            "bundleIdentifier": "com.apple.passwords",
            "displayName": "Passwords",
            "processIdentifier": primary.pid,
            "processLaunchTime": primary_app["process_launch_time"],
            "updatedAt": "fixture-test",
        }
        selection_file.write_text(json.dumps(sensitive_selection) + "\n", encoding="utf-8")
        selection_file.chmod(0o600)
        sensitive_bundle, sensitive_bundle_error = client.tool("get_app_state")
        ensure(sensitive_bundle_error and "blocked from Computer Use" in error_text(sensitive_bundle), "Sensitive bundle selection was not denied")
        reporter.passed_step("Sensitive bundle denylist", "password surface rejected before resolution")

        write_production_selection(selection_file, primary_app)
        production_selection = json.loads(selection_file.read_text(encoding="utf-8"))
        ensure(production_selection.get("processIdentifier") == primary.pid, "Production-format selection did not pin the chosen PID")
        ensure(
            production_selection.get("processLaunchTime") == primary_app["process_launch_time"],
            "Production-format selection did not pin the process lifetime",
        )
        mismatched_lifetime = dict(production_selection)
        mismatched_lifetime["processLaunchTime"] = float(primary_app["process_launch_time"]) + 1_000.0
        selection_file.write_text(json.dumps(mismatched_lifetime) + "\n", encoding="utf-8")
        selection_file.chmod(0o600)
        lifetime_mismatch, lifetime_mismatch_error = client.tool("get_app_state")
        ensure(lifetime_mismatch_error and "not running" in error_text(lifetime_mismatch), "Mismatched process lifetime was accepted")
        write_production_selection(selection_file, primary_app)
        reporter.passed_step("Exact process lifetime", "launch-time mismatch failed closed")
        override, override_error = client.tool("get_app_state", {"bundle_identifier": DECOY_BUNDLE_ID})
        ensure(override_error and "Target rejected" in error_text(override), "Explicit MCP target bypassed the attached bundle")
        untouched = read_json(decoy_state) or {}
        ensure(untouched.get("click_count") == 0 and untouched.get("input_value") == "DECOY-INITIAL", "Decoy fixture was modified")
        reporter.passed_step("Strict selection: explicit override", "decoy rejected and untouched")

        limited, limited_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 1})
        ensure(not limited_error and limited.get("element_count") == 1, "max_elements=1 was not enforced")
        ensure(limited.get("truncated") is True, "Bounded AX result did not report truncation")
        reporter.passed_step("AX output bounds", "max_elements=1 and truncated=true")

        oversized, oversized_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 800})
        ensure(oversized_error and "256 KiB" in error_text(oversized), "Oversized tool payload did not fail at the 256 KiB cap")
        reporter.passed_step("MCP payload cap", "oversized AX output rejected locally at 256 KiB")

        state_payload, state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not state_error and state_payload.get("ok") is True, f"get_app_state failed: {error_text(state_payload)}")
        ensure(state_payload.get("target", {}).get("bundle_identifier") == PRIMARY_BUNDLE_ID, "AX target mismatch")
        selected_pid = int(state_payload.get("target", {}).get("pid", 0))
        instance_states: dict[int, tuple[Path, str]] = {
            primary.pid: (primary_state, "PRIMARY-INITIAL"),
            sibling.pid: (sibling_state, "SIBLING-INITIAL"),
        }
        ensure(selected_pid in instance_states, f"Exact-process selection resolved unexpected PID {selected_pid}")
        selected_state, selected_initial_value = instance_states[selected_pid]
        selected_process = primary if selected_pid == primary.pid else sibling
        peer_pid = sibling.pid if selected_pid == primary.pid else primary.pid
        peer_state, peer_initial_value = instance_states[peer_pid]
        reporter.passed_step(
            "Production exact-process selection",
            f"resolved exact selected instance pid={selected_pid} while same-bundle sibling stayed separate",
        )

        activation, activation_error = client.tool("activate_app")
        ensure(not activation_error and activation.get("action") == "activate_app", f"activate_app failed: {error_text(activation)}")
        ensure(
            int(activation.get("target", {}).get("pid", 0)) == selected_pid,
            "activate_app did not preserve the exact selected process",
        )
        reporter.passed_step("App activation", f"exact attached fixture pid={selected_pid}")

        # Every disposable fixture activates itself during launch and places its scroll
        # view under the current pointer. A real trackpad event can therefore increment a
        # peer's counter before the bridge has bound and activated the selected PID. Wait
        # for that launch-time input to settle, then make all isolation assertions relative
        # to this exact-target baseline.
        isolation_baseline = wait_for_quiet_isolation_baseline(
            {"same-bundle peer": peer_state, "cross-bundle decoy": decoy_state}
        )
        ensure(
            isolation_baseline["same-bundle peer"]["input_value"] == peer_initial_value,
            "Same-bundle peer input changed before the exact-target isolation baseline",
        )
        ensure(
            isolation_baseline["cross-bundle decoy"]["input_value"] == "DECOY-INITIAL",
            "Cross-bundle decoy input changed before the exact-target isolation baseline",
        )
        reporter.passed_step(
            "Target-isolation baseline",
            "quiet after exact PID activation; subsequent peer/decoy mutation must remain zero",
        )

        state_payload, state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not state_error, f"AX refresh after activation failed: {error_text(state_payload)}")
        ensure(
            int(state_payload.get("target", {}).get("pid", 0)) == selected_pid,
            "AX refresh after activation changed the exact selected process",
        )
        root = state_payload.get("root")
        ensure(isinstance(root, dict), "AX root missing")
        nodes = flatten_tree(root)
        ensure(state_payload.get("scope") == "focused_window", f"Unexpected AX scope {state_payload.get('scope')}")
        ensure(root.get("role") == "AXWindow", "Focused AX root is not a window")
        serialized_tree = json.dumps(root, ensure_ascii=False)
        ensure("SECONDARY QA WINDOW" not in serialized_tree, "Secondary window leaked into the focused-window AX scope")
        ensure(SECRET_SENTINEL not in serialized_tree, "Secure field plaintext leaked into AX output")
        ensure(SYNTHETIC_SECRET_PROBE not in serialized_tree, "Synthetic API-key pattern leaked into AX output")
        ensure("<redacted secret>" in serialized_tree, "Common secret pattern was not visibly redacted")
        input_node = find_node(nodes, identifier="fixture.input")
        secure_node = find_node(nodes, identifier="fixture.secure")
        button_node = find_node(nodes, identifier="fixture.button")
        ensure(secure_node.get("value") == "<redacted sensitive field>", "Secure field was not explicitly redacted")
        snapshot_id = str(state_payload["snapshot_id"])
        reporter.passed_step("AX get_app_state", f"{len(nodes)} focused-window elements; secondary window excluded; secrets redacted")

        missing_snapshot, missing_snapshot_error = client.tool(
            "set_value", {"element_id": input_node["element_id"], "value": "MUST-NOT-APPLY"}
        )
        ensure(missing_snapshot_error and "snapshot_id is required" in error_text(missing_snapshot), "Missing snapshot_id was accepted")
        stale_snapshot, stale_snapshot_error = client.tool(
            "set_value",
            {"element_id": input_node["element_id"], "snapshot_id": "stale-snapshot", "value": "MUST-NOT-APPLY"},
        )
        ensure(stale_snapshot_error and "stale" in error_text(stale_snapshot), "Stale snapshot_id was accepted")
        ensure((read_json(selected_state) or {}).get("input_value") == selected_initial_value, "Snapshot negative tests changed input")
        reporter.passed_step("Snapshot binding", "missing and stale IDs rejected without mutation")

        write_production_selection(selection_file, decoy_app)
        changed_selection, changed_selection_error = client.tool(
            "click_element", {"element_id": button_node["element_id"], "snapshot_id": snapshot_id}
        )
        ensure(changed_selection_error and "attachment changed" in error_text(changed_selection), "Changed attachment did not invalidate snapshot")
        ensure((read_json(selected_state) or {}).get("click_count") == 0, "Button clicked after attachment changed")
        write_production_selection(selection_file, primary_app)
        reporter.passed_step("Snapshot target reauthorization", "attachment change rejected without click")

        state_payload, state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not state_error, f"AX refresh failed: {error_text(state_payload)}")
        nodes = flatten_tree(state_payload["root"])
        snapshot_id = str(state_payload["snapshot_id"])
        input_node = find_node(nodes, identifier="fixture.input")
        secure_node = find_node(nodes, identifier="fixture.secure")
        secure_set, secure_set_error = client.tool(
            "set_value",
            {"element_id": secure_node["element_id"], "snapshot_id": snapshot_id, "value": "MUST-NOT-APPLY"},
        )
        ensure(secure_set_error and "refuses secure" in error_text(secure_set), "Secure field set_value was not refused")

        secure_select, secure_select_error = client.tool(
            "select_text",
            {
                "element_id": secure_node["element_id"],
                "snapshot_id": snapshot_id,
                "start": 0,
                "length": 1,
            },
        )
        ensure(secure_select_error and "refuses secure" in error_text(secure_select), "Secure field select_text was not refused")

        sensitive_set, sensitive_set_error = client.tool(
            "set_value",
            {"element_id": input_node["element_id"], "snapshot_id": snapshot_id, "value": SYNTHETIC_SECRET_PROBE},
        )
        ensure(sensitive_set_error and "looks like a credential" in error_text(sensitive_set), "Secret-pattern set_value was not refused")
        ensure((read_json(selected_state) or {}).get("input_value") == selected_initial_value, "Rejected secret-pattern set_value changed input")

        set_payload, set_error = client.tool(
            "set_value",
            {"element_id": input_node["element_id"], "snapshot_id": snapshot_id, "value": "SET-VALUE-4729"},
        )
        ensure(not set_error and set_payload.get("snapshot_invalidated") is True, f"set_value failed: {error_text(set_payload)}")
        wait_for_state(selected_state, lambda value: value.get("input_value") == "SET-VALUE-4729")
        reuse_payload, reuse_error = client.tool(
            "set_value",
            {"element_id": input_node["element_id"], "snapshot_id": snapshot_id, "value": "MUST-NOT-APPLY"},
        )
        ensure(reuse_error and "No current snapshot" in error_text(reuse_payload), "Consumed snapshot remained actionable")
        reporter.passed_step("AX set_value", "editable value changed; secure and consumed snapshots refused")

        state_payload, state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not state_error, f"AX refresh before click failed: {error_text(state_payload)}")
        nodes = flatten_tree(state_payload["root"])
        refreshed_input = find_node(nodes, identifier="fixture.input")
        ensure(refreshed_input.get("value") == "SET-VALUE-4729", "AX refresh did not expose set_value result")
        button_node = find_node(nodes, identifier="fixture.button")
        click_payload, click_error = client.tool(
            "click_element",
            {"element_id": button_node["element_id"], "snapshot_id": state_payload["snapshot_id"]},
        )
        ensure(not click_error and click_payload.get("snapshot_invalidated") is True, f"click failed: {error_text(click_payload)}")
        wait_for_state(selected_state, lambda value: value.get("click_count") == 1)
        reporter.passed_step("AX click_element", "button action observed exactly once")

        recording_state, recording_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not recording_state_error, f"AX refresh before recording failed: {error_text(recording_state)}")
        recording_nodes = flatten_tree(recording_state["root"])
        recording_input = find_node(recording_nodes, identifier="fixture.input")
        recording_start, recording_start_error = client.tool(
            "recording_start",
            {"snapshot_id": recording_state["snapshot_id"], "name": "Fixture semantic workflow"},
        )
        ensure(not recording_start_error and recording_start.get("active") is True, f"recording_start failed: {error_text(recording_start)}")
        draft_recording_id = str(recording_start["recording_id"])
        recorded_input_value = "RECORDED-INPUT-CONTENT-4729"
        recorded_set, recorded_set_error = client.tool(
            "set_value",
            {
                "element_id": recording_input["element_id"],
                "snapshot_id": recording_state["snapshot_id"],
                "value": recorded_input_value,
            },
        )
        ensure(not recorded_set_error, f"recorded set_value failed: {error_text(recorded_set)}")
        wait_for_state(selected_state, lambda value: value.get("input_value") == recorded_input_value)
        pending_status, pending_status_error = client.tool("recording_status")
        ensure(
            not pending_status_error
            and pending_status.get("pending_verification") is True
            and pending_status.get("verified_step_count") == 0,
            f"recording did not hold an unverified action pending: {pending_status}",
        )
        premature_stop, premature_stop_error = client.tool(
            "recording_stop", {"snapshot_id": recording_state["snapshot_id"]}
        )
        ensure(
            premature_stop_error and "No current snapshot" in error_text(premature_stop),
            "recording_stop accepted an action before a fresh exact-target snapshot",
        )

        recording_verify, recording_verify_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not recording_verify_error, f"recording verification snapshot failed: {error_text(recording_verify)}")
        verified_status, verified_status_error = client.tool("recording_status")
        ensure(
            not verified_status_error
            and verified_status.get("pending_verification") is False
            and verified_status.get("verified_step_count") == 1,
            f"fresh snapshot did not verify exactly one recorded action: {verified_status}",
        )

        recording_verify_nodes = flatten_tree(recording_verify["root"])
        select_input = find_node(recording_verify_nodes, identifier="fixture.input")
        select_payload, select_error = client.tool(
            "select_text",
            {
                "element_id": select_input["element_id"],
                "snapshot_id": recording_verify["snapshot_id"],
                "start": 2,
                "length": 8,
            },
        )
        ensure(not select_error and select_payload.get("action") == "select_text", f"select_text failed: {error_text(select_payload)}")
        wait_for_state(
            selected_state,
            lambda value: int(value.get("selection_start", -1)) == 2 and int(value.get("selection_length", -1)) == 8,
        )
        select_verify, select_verify_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not select_verify_error, f"select_text verification snapshot failed: {error_text(select_verify)}")
        two_step_status, two_step_status_error = client.tool("recording_status")
        ensure(
            not two_step_status_error
            and two_step_status.get("verified_step_count") == 2
            and two_step_status.get("pending_verification") is False,
            f"recording did not verify set_value and select_text: {two_step_status}",
        )
        recording_stop, recording_stop_error = client.tool(
            "recording_stop", {"snapshot_id": select_verify["snapshot_id"]}
        )
        ensure(not recording_stop_error and recording_stop.get("installed") is False, f"recording_stop failed: {error_text(recording_stop)}")
        draft_path = Path(str(recording_stop.get("draft_path", ""))).expanduser()
        draft_directory = draft_path.parent
        allowed_drafts = (Path.home() / "Library" / "Application Support" / "DeepSeek Harness" / "drafts").resolve()
        try:
            draft_path.resolve().relative_to(allowed_drafts)
        except (OSError, ValueError) as error:
            raise QAError(f"Recording draft escaped Application Support/drafts: {draft_path}") from error
        ensure(draft_path.name == "SKILL.md" and draft_directory.name == draft_recording_id, "Recording draft used an unexpected path")
        draft_text = draft_path.read_text(encoding="utf-8")
        ensure(draft_path.stat().st_mode & 0o777 == 0o600, "Recording draft is not mode 0600")
        ensure(draft_directory.stat().st_mode & 0o777 == 0o700, "Recording draft directory is not mode 0700")
        ensure("name: recorded-macos-workflow-" in draft_text, "Draft SKILL.md lacks valid skill metadata")
        ensure("Draft only" in draft_text and "not installed" in draft_text, "Draft does not clearly state its review-only status")
        ensure("fixture.input" in draft_text and "select_text" in draft_text, "Draft omitted verified semantic locators/actions")
        ensure("<VALUE_TO_ENTER>" in draft_text, "Draft did not replace entered content with a placeholder")
        ensure(recorded_input_value not in draft_text, "Draft retained user-entered content")
        ensure(SECRET_SENTINEL not in draft_text and SYNTHETIC_SECRET_PROBE not in draft_text, "Draft leaked a fixture secret")
        ensure("obtain the user's immediate confirmation" in draft_text, "Draft omitted consequential-action confirmation policy")
        remove_test_recording_draft(draft_directory, draft_recording_id)
        draft_directory = None
        draft_recording_id = None
        reporter.passed_step(
            "Semantic recording draft",
            "2 refreshed-state-verified steps; private input omitted; review-only SKILL.md created mode 0600 then removed",
        )

        secondary_state, secondary_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not secondary_state_error, f"AX refresh before secondary action failed: {error_text(secondary_state)}")
        secondary_node = find_node(flatten_tree(secondary_state["root"]), identifier="fixture.secondary-action")
        ensure("AXShowMenu" in secondary_node.get("actions", []), f"Fixture secondary element lacks AXShowMenu: {secondary_node}")
        secondary_before = int((read_json(selected_state) or {}).get("secondary_action_count", 0))
        secondary_payload, secondary_error = client.tool(
            "perform_secondary_action",
            {"element_id": secondary_node["element_id"], "snapshot_id": secondary_state["snapshot_id"]},
        )
        ensure(not secondary_error and secondary_payload.get("ax_action") == "AXShowMenu", f"secondary action failed: {error_text(secondary_payload)}")
        wait_for_state(
            selected_state,
            lambda value: int(value.get("secondary_action_count", 0)) > secondary_before,
        )
        reporter.passed_step("perform_secondary_action", "semantic AXShowMenu observed without a right-click fallback")

        schedule_state, schedule_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not schedule_state_error, f"AX refresh before wait scheduling failed: {error_text(schedule_state)}")
        schedule_node = find_node(flatten_tree(schedule_state["root"]), identifier="fixture.schedule-wait")
        scheduled_before = int((read_json(selected_state) or {}).get("scheduled_wait_count", 0))
        schedule_payload, schedule_error = client.tool(
            "click_element",
            {"element_id": schedule_node["element_id"], "snapshot_id": schedule_state["snapshot_id"]},
        )
        ensure(not schedule_error, f"Unable to schedule wait state: {error_text(schedule_payload)}")
        wait_for_state(selected_state, lambda value: int(value.get("scheduled_wait_count", 0)) > scheduled_before)
        wait_snapshot, wait_snapshot_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
        ensure(not wait_snapshot_error, f"AX refresh before wait_for_state failed: {error_text(wait_snapshot)}")
        wait_node = find_node(flatten_tree(wait_snapshot["root"]), identifier="fixture.wait-state")
        wait_payload, wait_error = client.tool(
            "wait_for_state",
            {
                "element_id": wait_node["element_id"],
                "snapshot_id": wait_snapshot["snapshot_id"],
                "attribute": "value",
                "operator": "equals",
                "expected": "WAIT-READY",
                "timeout_ms": 5000,
                "poll_interval_ms": 80,
            },
        )
        ensure(not wait_error and wait_payload.get("matched") is True, f"wait_for_state failed: {error_text(wait_payload)}")
        ensure((read_json(selected_state) or {}).get("wait_value") == "WAIT-READY", "Fixture did not reach WAIT-READY")
        reporter.passed_step("wait_for_state", "polled a safe AXValue while continuously reauthorizing the exact focused target")

        selected_scroll_window_number: int | None = None
        if not event_posting:
            reporter.skipped_step("Keyboard, drag, and scroll actions", "event_posting=false; no permission was requested")
        else:
            drag_before_state = read_json(selected_state) or {}
            drag_before_count = int(drag_before_state.get("slider_action_count", 0))
            drag_state, drag_state_error = client.tool("get_app_state", {"max_depth": 4, "max_elements": 400})
            ensure(not drag_state_error, f"AX refresh before drag failed: {error_text(drag_state)}")
            drag_nodes = flatten_tree(drag_state["root"])
            slider_node = find_node(drag_nodes, identifier="fixture.drag-slider")
            drag_target_node = find_node(drag_nodes, identifier="fixture.drag-target")
            ambiguous_drag, ambiguous_drag_error = client.tool(
                "drag",
                {
                    "snapshot_id": drag_state["snapshot_id"],
                    "source_element_id": slider_node["element_id"],
                    "source_x": 0.5,
                    "source_y": 0.5,
                    "destination_element_id": drag_target_node["element_id"],
                },
            )
            ensure(
                ambiguous_drag_error and "exactly one source" in error_text(ambiguous_drag),
                "drag accepted an ambiguous element-plus-coordinate source",
            )
            drag_payload, drag_error = client.tool(
                "drag",
                {
                    "snapshot_id": drag_state["snapshot_id"],
                    "source_element_id": slider_node["element_id"],
                    "destination_element_id": drag_target_node["element_id"],
                    "duration_ms": 420,
                },
            )
            ensure(not drag_error and drag_payload.get("action") == "drag", f"semantic drag failed: {error_text(drag_payload)}")
            dragged = wait_for_state(
                selected_state,
                lambda value: int(value.get("slider_action_count", 0)) > drag_before_count
                and float(value.get("slider_value", 0.0)) >= 85.0,
            )
            ensure(float(dragged.get("slider_value", 0.0)) >= 85.0, f"Semantic drag did not move slider toward target: {dragged}")
            reporter.passed_step("drag element-to-element", "real slider value moved using two focused-window semantic anchors")

            before_type = wait_for_state(selected_state, lambda value: value.get("click_count") == 1)
            action_state, action_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
            ensure(not action_state_error, f"AX refresh before type_text failed: {error_text(action_state)}")
            action_nodes = flatten_tree(action_state["root"])
            action_input = find_node(action_nodes, identifier="fixture.input")
            action_value = str(action_input.get("value", ""))
            action_utf16_length = len(action_value.encode("utf-16-le")) // 2
            cursor_payload, cursor_error = client.tool(
                "select_text",
                {
                    "element_id": action_input["element_id"],
                    "snapshot_id": action_state["snapshot_id"],
                    "start": action_utf16_length,
                    "length": 0,
                },
            )
            ensure(not cursor_error, f"Unable to place type_text caret safely: {error_text(cursor_payload)}")
            wait_for_state(
                selected_state,
                lambda value: int(value.get("selection_start", -1)) == action_utf16_length
                and int(value.get("selection_length", -1)) == 0,
            )
            action_state, action_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
            ensure(not action_state_error, f"AX refresh after caret placement failed: {error_text(action_state)}")
            action_input = find_node(flatten_tree(action_state["root"]), identifier="fixture.input")
            rejected_type, rejected_type_error = client.tool(
                "type_text",
                {
                    "element_id": action_input["element_id"],
                    "snapshot_id": action_state["snapshot_id"],
                    "text": SYNTHETIC_SECRET_PROBE,
                },
            )
            ensure(rejected_type_error and "looks like a credential" in error_text(rejected_type), "Secret-pattern type_text was not refused")
            type_payload, type_error = client.tool(
                "type_text",
                {
                    "element_id": action_input["element_id"],
                    "snapshot_id": action_state["snapshot_id"],
                    "text": " TYPE-TEXT-4729",
                },
            )
            ensure(not type_error and type_payload.get("action") == "type_text", f"type_text failed: {error_text(type_payload)}")
            typed = wait_for_state(
                selected_state,
                lambda value: str(value.get("input_value", "")).endswith(" TYPE-TEXT-4729"),
            )
            ensure(typed.get("key_event_count", 0) > before_type.get("key_event_count", 0), "Fixture saw no Unicode key event")
            reporter.passed_step("type_text", "Unicode text reached the focused fixture field")

            key_before = int(typed.get("key_event_count", 0))
            key_state, key_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
            ensure(not key_state_error, f"AX refresh before press_key failed: {error_text(key_state)}")
            key_payload, key_error = client.tool(
                "press_key", {"snapshot_id": key_state["snapshot_id"], "key": "f6"}
            )
            ensure(not key_error and key_payload.get("action") == "press_key", f"press_key failed: {error_text(key_payload)}")
            keyed = wait_for_state(selected_state, lambda value: int(value.get("key_event_count", 0)) > key_before)
            ensure(keyed.get("last_key_code") == 97, f"Fixture received unexpected F6 keycode {keyed.get('last_key_code')}")
            reporter.passed_step("press_key", "targeted F6 event observed")

            scroll_before = int(keyed.get("scroll_event_count", 0))
            scroll_origin_before = float(keyed.get("scroll_origin_y", 0.0))
            scroll_state, scroll_state_error = client.tool("get_app_state", {"max_depth": 12, "max_elements": 220})
            ensure(not scroll_state_error, f"AX refresh before scroll failed: {error_text(scroll_state)}")
            scroll_nodes = flatten_tree(scroll_state["root"])
            scroll_node = find_node(scroll_nodes, identifier="fixture.scroll")
            scroll_payload, scroll_error = client.tool(
                "scroll",
                {
                    "element_id": scroll_node["element_id"],
                    "snapshot_id": scroll_state["snapshot_id"],
                    "delta_y": -37,
                    "delta_x": 5,
                    "unit": "pixel",
                },
            )
            ensure(not scroll_error and scroll_payload.get("action") == "scroll", f"scroll failed: {error_text(scroll_payload)}")
            scrolled = wait_for_state(
                selected_state,
                lambda value: int(value.get("scroll_event_count", 0)) > scroll_before
                and abs(float(value.get("scroll_origin_y", 0.0)) - scroll_origin_before) > 0.1,
            )
            ensure(
                abs(float(scrolled.get("last_scroll_delta_y", 0.0)) - (-37.0)) <= 0.01,
                f"Fixture received the wrong vertical scroll delta: {scrolled.get('last_scroll_delta_y')}",
            )
            ensure(
                abs(float(scrolled.get("last_scroll_delta_x", 0.0)) - 5.0) <= 0.01,
                f"Fixture received the wrong horizontal scroll delta: {scrolled.get('last_scroll_delta_x')}",
            )
            selected_scroll_window_number = int(scrolled.get("last_scroll_window_number", 0))
            ensure(selected_scroll_window_number > 0, "Fixture did not record the target window for the scroll event")
            reporter.passed_step(
                "scroll",
                f"exact delta (-37, 5) moved selected window {selected_scroll_window_number}",
            )

        ocr_payload, ocr_error = client.tool(
            "get_app_state", {"max_depth": 12, "max_elements": 220, "include_ocr": True}
        )
        ensure(not ocr_error, f"OCR get_app_state failed: {error_text(ocr_payload)}")
        ocr = ocr_payload.get("ocr", {})
        (temp_root / "first-ocr-payload.json").write_text(
            json.dumps(ocr_payload, ensure_ascii=False, indent=2, sort_keys=True),
            encoding="utf-8",
        )
        if ocr.get("performed") is True:
            ensure(ocr.get("image_in_memory_only") is True and ocr.get("image_persisted") is False, "OCR persistence safeguards missing")
            ensure(OCR_SENTINEL in str(ocr.get("text", "")), "OCR did not read the large primary-window sentinel")
            ensure("SECONDARY QA WINDOW" not in str(ocr.get("text", "")), "OCR selected the smaller secondary window")
            ensure(SYNTHETIC_SECRET_PROBE not in str(ocr.get("text", "")), "Synthetic API-key pattern leaked through OCR")
            if selected_scroll_window_number is not None:
                ensure(
                    int(ocr.get("window", {}).get("window_id", 0)) == selected_scroll_window_number,
                    "Scroll event window did not match the exact OCR-captured selected window",
                )
            reporter.passed_step("In-memory OCR", f"{ocr.get('line_count', 0)} lines from the focused attached window")

            if event_posting:
                coordinate_nodes = flatten_tree(ocr_payload["root"])
                coordinate_slider = find_node(coordinate_nodes, identifier="fixture.drag-slider")
                slider_frame = coordinate_slider.get("frame", {})
                window_frame = ocr.get("window", {}).get("frame", {})
                coordinate_before_state = read_json(selected_state) or {}
                coordinate_before_count = int(coordinate_before_state.get("slider_action_count", 0))
                coordinate_before_value = float(coordinate_before_state.get("slider_value", 100.0))
                slider_margin = min(12.0, max(4.0, float(slider_frame["width"]) * 0.04))
                usable_width = float(slider_frame["width"]) - 2.0 * slider_margin
                start_screen_x = (
                    float(slider_frame["x"])
                    + slider_margin
                    + usable_width * max(0.0, min(1.0, coordinate_before_value / 100.0))
                )
                destination_screen_x = (
                    float(slider_frame["x"]) + slider_margin
                    if coordinate_before_value >= 50.0
                    else float(slider_frame["x"]) + float(slider_frame["width"]) - slider_margin
                )
                screen_y = float(slider_frame["y"]) + float(slider_frame["height"]) / 2.0
                source_x = (start_screen_x - float(window_frame["x"])) / float(window_frame["width"])
                source_y = (screen_y - float(window_frame["y"])) / float(window_frame["height"])
                destination_x = (destination_screen_x - float(window_frame["x"])) / float(window_frame["width"])
                destination_y = source_y
                ensure(
                    all(0.0 <= value <= 1.0 for value in (source_x, source_y, destination_x, destination_y)),
                    "AX slider coordinates did not map inside the OCR-captured window",
                )
                coordinate_drag, coordinate_drag_error = client.tool(
                    "drag",
                    {
                        "snapshot_id": ocr_payload["snapshot_id"],
                        "source_x": source_x,
                        "source_y": source_y,
                        "destination_x": destination_x,
                        "destination_y": destination_y,
                        "duration_ms": 420,
                    },
                )
                ensure(
                    not coordinate_drag_error and coordinate_drag.get("source") == "normalized_point",
                    f"coordinate drag failed: {error_text(coordinate_drag)}",
                )
                coordinate_dragged = wait_for_state(
                    selected_state,
                    lambda value: int(value.get("slider_action_count", 0)) > coordinate_before_count
                    and abs(float(value.get("slider_value", coordinate_before_value)) - coordinate_before_value) >= 40.0,
                )
                reporter.passed_step(
                    "drag coordinate-to-coordinate",
                    f"OCR-window-bound real slider moved {coordinate_before_value:.1f} -> {float(coordinate_dragged.get('slider_value', 0.0)):.1f}",
                )

                ocr_payload, ocr_error = client.tool(
                    "get_app_state", {"max_depth": 12, "max_elements": 220, "include_ocr": True}
                )
                ensure(not ocr_error, f"OCR refresh after coordinate drag failed: {error_text(ocr_payload)}")
                ocr = ocr_payload.get("ocr", {})
                ensure(ocr.get("performed") is True, "OCR became unavailable after a coordinate drag")
                (temp_root / "last-ocr-payload.json").write_text(
                    json.dumps(ocr_payload, ensure_ascii=False, indent=2, sort_keys=True),
                    encoding="utf-8",
                )

            button_observation = next(
                (
                    observation
                    for observation in ocr.get("observations", [])
                    if isinstance(observation, dict)
                    and "fixture button" in str(observation.get("text", "")).lower()
                    and isinstance(observation.get("center_top_left_normalized"), dict)
                ),
                None,
            )
            if button_observation is None:
                reporter.skipped_step("click_point", "OCR did not produce a reliable Fixture Button center")
            else:
                center = button_observation["center_top_left_normalized"]
                ocr_window_frame = ocr.get("window", {}).get("frame", {})
                ocr_nodes = flatten_tree(ocr_payload["root"])
                ocr_button = find_node(ocr_nodes, identifier="fixture.button")
                button_frame = ocr_button.get("frame", {})
                screen_point = {
                    "x": float(ocr_window_frame["x"]) + float(center["x"]) * float(ocr_window_frame["width"]),
                    "y": float(ocr_window_frame["y"]) + float(center["y"]) * float(ocr_window_frame["height"]),
                }
                ensure(
                    float(button_frame["x"]) <= screen_point["x"] <= float(button_frame["x"]) + float(button_frame["width"])
                    and float(button_frame["y"]) <= screen_point["y"] <= float(button_frame["y"]) + float(button_frame["height"]),
                    f"OCR button center maps outside AX button frame: center={center}, screen={screen_point}, frame={button_frame}",
                )
                point_payload, point_error = client.tool(
                    "click_point",
                    {"snapshot_id": ocr_payload["snapshot_id"], "x": center["x"], "y": center["y"]},
                )
                ensure(not point_error and point_payload.get("action") == "click_point", f"click_point failed: {error_text(point_payload)}")
                try:
                    wait_for_state(selected_state, lambda value: value.get("click_count") == 2)
                except QAError as error:
                    raise QAError(
                        f"click_point returned success but did not activate button; center={center}, "
                        f"screen={screen_point}, frame={button_frame}; {error}"
                    ) from error
                reporter.passed_step("click_point", "OCR-derived center activated the fixture button")
        else:
            reason = str(ocr.get("reason", "unknown"))
            ensure(ocr.get("prompts_requested") is False and ocr.get("image_in_memory_only") is True, "OCR skip did not fail safely")
            reporter.skipped_step("In-memory OCR", f"{reason}; no permission was requested")
            reporter.skipped_step("click_point", "no OCR-captured window snapshot")

        final_decoy = read_json(decoy_state) or {}
        final_peer = read_json(peer_state) or {}
        final_decoy_signature = isolation_signature(final_decoy)
        final_peer_signature = isolation_signature(final_peer)
        ensure(
            final_decoy_signature == isolation_baseline["cross-bundle decoy"],
            "Cross-bundle decoy changed after exact-target binding: "
            f"baseline={isolation_baseline['cross-bundle decoy']} final={final_decoy_signature}",
        )
        ensure(
            final_peer_signature == isolation_baseline["same-bundle peer"],
            "Same-bundle peer changed after exact-target binding: "
            f"baseline={isolation_baseline['same-bundle peer']} final={final_peer_signature}",
        )
        reporter.passed_step(
            "Target isolation",
            "peer/decoy post-baseline action deltas stayed zero, including scroll count and origin",
        )

        stop_fixture(selected_process)
        dead_target_confirmed = False
        dead_target_detail = ""
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            dead_target, dead_target_error = client.tool("get_app_state")
            dead_target_detail = error_text(dead_target)
            if not dead_target_error:
                resolved_pid = int(dead_target.get("target", {}).get("pid", 0))
                ensure(resolved_pid != peer_pid, "Terminated selected PID fell back to a same-bundle sibling")
            elif "not running" in dead_target_detail:
                dead_target_confirmed = True
                break
            time.sleep(0.12)
        ensure(dead_target_confirmed, f"Terminated selected PID was not reported as unavailable: {dead_target_detail}")
        ensure((read_json(peer_state) or {}).get("input_value") == peer_initial_value, "Sibling changed after selected PID terminated")
        reporter.passed_step("Exact process binding", "terminated selected PID did not fall back to sibling")
    finally:
        if client is not None:
            client.close()
        remove_test_recording_draft(draft_directory, draft_recording_id)
        stop_fixture(decoy)
        stop_fixture(sibling)
        stop_fixture(primary)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", required=True, type=Path, help="Path to the DeepSeekAppBridge executable")
    parser.add_argument(
        "--release-bridge",
        required=True,
        type=Path,
        help="Path to a release DeepSeekAppBridge executable; its selection override must be disabled",
    )
    parser.add_argument("--fixture", required=True, type=Path, help="Path to the DeepSeekBridgeFixture executable")
    parser.add_argument("--keep-temp", action="store_true", help="Keep the disposable test directory for debugging")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.bridge = args.bridge.expanduser().resolve()
    args.release_bridge = args.release_bridge.expanduser().resolve()
    args.fixture = args.fixture.expanduser().resolve()
    if not args.bridge.is_file() or not os.access(args.bridge, os.X_OK):
        print(f"Bridge executable is missing or not executable: {args.bridge}", file=sys.stderr)
        return 2
    if not args.fixture.is_file() or not os.access(args.fixture, os.X_OK):
        print(f"Fixture executable is missing or not executable: {args.fixture}", file=sys.stderr)
        return 2
    if not args.release_bridge.is_file() or not os.access(args.release_bridge, os.X_OK):
        print(f"Release bridge executable is missing or not executable: {args.release_bridge}", file=sys.stderr)
        return 2

    temp_root = Path(tempfile.mkdtemp(prefix="deepseek-app-bridge-e2e-"))
    reporter = Reporter()
    try:
        run(args, temp_root, reporter)
    except Exception as error:
        reporter.failed_step("Unexpected test failure", str(error))
        print(f"Diagnostic directory: {temp_root}", file=sys.stderr)
        args.keep_temp = True
    finally:
        if args.keep_temp:
            print(f"Kept disposable test directory: {temp_root}")
        else:
            shutil.rmtree(temp_root, ignore_errors=True)
    return reporter.summary()


if __name__ == "__main__":
    raise SystemExit(main())
