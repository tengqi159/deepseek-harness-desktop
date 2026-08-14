#!/usr/bin/env python3

import datetime as dt
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "app"
BIN = PACKAGE / ".build" / "debug" / "DeepSeekSSHBridge"


FAKE_SSH = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

root = Path(os.environ["DSH_SSH_FIXTURE_ROOT"])
hostname = Path(os.environ["DSH_SSH_FIXTURE_HOSTNAME_FILE"]).read_text().strip()
args = sys.argv[1:]

def remote_path(value):
    if ":" in value and not value.startswith("/"):
        value = value.split(":", 1)[1]
    return root / value.lstrip("/")

def job_id(command):
    match = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", command)
    if not match:
        print("missing job id", file=sys.stderr); sys.exit(2)
    return match.group(0)

if "-G" in args:
    print(f"hostname {hostname}")
    print("user fixture-user")
    print("port 2222")
    print("batchmode yes")
    sys.exit(0)

command = args[-1]
payload = sys.stdin.buffer.read()
required_endpoint_args = ["HostName=fixture.internal", "User=fixture-user", "-p", "2222"]
if not all(value in args for value in required_endpoint_args):
    print("selected endpoint was not pinned", file=sys.stderr)
    sys.exit(2)

if "HARNESS_SSH_OK" in command:
    print("HARNESS_SSH_OK")
elif "printf 'os='" in command:
    print("os=Linux fixture 1.0")
    print("hostname=fixture-host")
    print("workspace=/srv/project")
    print("workspace_exists=true")
    print("disk_kb_total=1000000")
    print("disk_kb_available=800000")
    print("python=Python 3.12.1")
    print("setsid=true")
    print("nvidia_smi=true")
    print("0, Fixture GPU, 24576, 20000, 3")
elif "HARNESS_FIXTURE_HANG" in command or b"HARNESS_FIXTURE_HANG" in payload:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    subprocess.Popen(
        [sys.executable, "-c",
         "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"],
        stdout=sys.stdout, stderr=sys.stderr,
    )
    while True: time.sleep(1)
elif "exec /bin/sh -s" in command:
    workspace = root / "srv" / "project"
    workspace.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(["/bin/sh"], input=payload, cwd=workspace, capture_output=True)
    sys.stdout.buffer.write(completed.stdout)
    sys.stderr.buffer.write(completed.stderr)
    sys.exit(completed.returncode)
elif "/command.sh" in command and "cat >" in command:
    required = ['workspace_fd="/proc/$$/fd/9"', 'test ! -L', 'test -O', "permissions"]
    if not all(value in command for value in required):
        print("unsafe remote job directory creation", file=sys.stderr); sys.exit(2)
    target = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command) / "command.sh"
    target.parent.mkdir(parents=True, exist_ok=False)
    target.write_bytes(payload)
elif "/launcher.sh" in command and "cat >" in command:
    if 'job_fd="/proc/$$/fd/8"' not in command or "test ! -L" not in command:
        print("unsafe remote launcher access", file=sys.stderr); sys.exit(2)
    target = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command) / "launcher.sh"
    target.write_bytes(payload); target.chmod(0o700)
elif "/display_name" in command and "cat >" in command:
    target = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command) / "display_name"
    target.write_bytes(payload)
elif "nohup setsid" in command:
    if "process_start_time" not in command or "process_group" not in command:
        print("missing persistent process identity", file=sys.stderr); sys.exit(2)
    directory = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command)
    (directory / "state").write_text("running\n")
    (directory / "pid").write_text("4242\n")
    (directory / "process_group").write_text("4242\n")
    (directory / "process_start_time").write_text("987654\n")
    (directory / "stdout.log").write_text("epoch 1 loss=0.5\napi_key=fixture-secret-value-12345\n")
    (directory / "stderr.log").write_text("")
    print("4242")
elif "find" in command and ".harnessmate/jobs" in command:
    jobs = root / "srv" / "project" / ".harnessmate" / "jobs"
    if jobs.exists():
        for item in sorted(jobs.iterdir()):
            if item.is_dir(): print(item.name)
elif "printf 'state='" in command:
    directory = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command)
    if not directory.exists(): sys.exit(1)
    print("state=" + (directory / "state").read_text().strip())
    print("pid=" + (directory / "pid").read_text().strip())
    print("exit_code=")
    print("alive=true")
    print("display_name=" + (directory / "display_name").read_text().strip())
elif "tail -c" in command and ".log" in command:
    stream_match = re.search(r'log_path="\$job_fd/(stdout|stderr)\.log"', command)
    target = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command) / f"{stream_match.group(1)}.log"
    sys.stdout.buffer.write(target.read_bytes())
elif "/bin/kill -" in command:
    required = ["process_start_time", "process_group", "/proc/$pid/stat", "$stored_pgid"]
    if not all(value in command for value in required):
        print("unsafe cancellation identity check", file=sys.stderr); sys.exit(2)
    directory = root / "srv" / "project" / ".harnessmate" / "jobs" / job_id(command)
    (directory / "state").write_text("cancel_requested\n")
elif "HARNESSMATE_UPLOAD_V1" in command:
    parent_match = re.search(r"parent_candidate='([^']+)'", command)
    name_match = re.search(r"target_name='([^']+)'", command)
    overwrite_match = re.search(r"overwrite=([01])", command)
    size_match = re.search(r"expected_bytes=([0-9]+)", command)
    commit_match = re.search(r"expected_commit='([^']+)'", command)
    if not all([parent_match, name_match, overwrite_match, size_match, commit_match]):
        print("invalid upload stream", file=sys.stderr); sys.exit(2)
    expected_size = int(size_match.group(1))
    expected_trailer = (commit_match.group(1) + "\n").encode()
    if len(payload) != expected_size + len(expected_trailer) or not payload.endswith(expected_trailer):
        print("upload size mismatch", file=sys.stderr); sys.exit(2)
    target = remote_path(parent_match.group(1)) / name_match.group(1)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and overwrite_match.group(1) == "0":
        sys.exit(1)
    target.write_bytes(payload[:expected_size])
    print(f"uploaded_bytes={expected_size}")
elif "HARNESSMATE_DOWNLOAD_V1" in command:
    candidate_match = re.search(r"(?m)^candidate='([^']+)'$", command)
    if not candidate_match:
        print("invalid download stream", file=sys.stderr); sys.exit(2)
    source = remote_path(candidate_match.group(1))
    if not source.is_file():
        print(f"download fixture missing: {source}", file=sys.stderr); sys.exit(1)
    sys.stdout.buffer.write(source.read_bytes())
elif "root=$(realpath" in command:
    sys.exit(0)
elif command.startswith("mv -f --"):
    paths = re.findall(r"'([^']+)'", command)
    shutil.move(remote_path(paths[0]), remote_path(paths[1]))
elif command.startswith("ln --"):
    paths = re.findall(r"'([^']+)'", command)
    source, target = remote_path(paths[0]), remote_path(paths[1])
    if target.exists(): sys.exit(1)
    target.parent.mkdir(parents=True, exist_ok=True)
    os.link(source, target); source.unlink()
elif command.startswith("rm -f --"):
    paths = re.findall(r"'([^']+)'", command)
    if paths: remote_path(paths[0]).unlink(missing_ok=True)
else:
    print("unsupported fixture command", file=sys.stderr)
    print(command, file=sys.stderr)
    sys.exit(2)
'''


def iso(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def write_selection(path: Path, *, hostname="fixture.internal", alias="fixture-gpu", expired=False):
    now = dt.datetime.now(dt.timezone.utc)
    selected = now - dt.timedelta(hours=25) if expired else now
    expires = selected + dt.timedelta(hours=24)
    payload = {
        "version": 1,
        "selection_id": str(uuid.uuid4()),
        "selected_at": iso(selected),
        "expires_at": iso(expires),
        "host_alias": alias,
        "resolved_hostname": hostname,
        "resolved_user": "fixture-user",
        "resolved_port": 2222,
        "remote_workspace": "/srv/project",
    }
    path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    path.chmod(0o600)
    return payload


class Bridge:
    def __init__(self, env):
        self.process = subprocess.Popen(
            [str(BIN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=env, bufsize=1,
        )
        self.next_id = 1

    def rpc(self, method, params=None):
        request_id = self.next_id; self.next_id += 1
        request = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None: request["params"] = params
        self.process.stdin.write(json.dumps(request) + "\n"); self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("bridge exited without a response: " + self.process.stderr.read())
        response = json.loads(line)
        assert response.get("id") == request_id, response
        return response

    def tool(self, name, arguments=None):
        return self.rpc("tools/call", {"name": name, "arguments": arguments or {}})

    def raw(self, request):
        self.process.stdin.write(json.dumps(request) + "\n"); self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("bridge exited without a response: " + self.process.stderr.read())
        return json.loads(line)

    def assert_notification_silent(self, request):
        self.process.stdin.write(json.dumps(request) + "\n"); self.process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        assert not selector.select(timeout=0.2), "notification unexpectedly produced a response"
        selector.close()

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        self.process.wait(timeout=5)
        assert self.process.returncode == 0, self.process.stderr.read()


def result_value(response):
    assert "error" not in response, response
    return response["result"]


def tool_value(response):
    value = result_value(response)
    assert value.get("isError") is False, value
    return value["structuredContent"]


def tool_error(response):
    value = result_value(response)
    assert value.get("isError") is True, value
    return value["content"][0]["text"]


def rpc_error(response, code=-32602):
    error = response.get("error")
    assert isinstance(error, dict) and error.get("code") == code, response
    return error.get("message", "")


def main():
    subprocess.run(
        ["swift", "build", "--package-path", str(PACKAGE), "-c", "debug", "--product", "DeepSeekSSHBridge"],
        check=True,
    )
    subprocess.run(
        ["swift", "build", "--package-path", str(PACKAGE), "-c", "release", "--product", "DeepSeekSSHBridge"],
        check=True,
    )
    release_bytes = (PACKAGE / ".build" / "release" / "DeepSeekSSHBridge").read_bytes()
    for debug_marker in [
        b"DSH_SSH_BIN", b"DSH_SSH_SELECTION_FILE", b"DSH_SSH_APP_SUPPORT_ROOT",
        b"DSH_SSH_TEST_TRANSFER_LIMIT", b"DSH_SSH_FIXTURE_ROOT", b"DSH_SCP_BIN",
        b"/usr/bin/scp",
    ]:
        assert debug_marker not in release_bytes, debug_marker

    with tempfile.TemporaryDirectory(prefix="deepseek-ssh-bridge-", dir="/private/tmp") as temp:
        temp = Path(temp)
        fixture_root = temp / "remote"
        app_support = temp / "app-support"
        selection_path = temp / "selection.json"
        hostname_file = temp / "hostname"
        ssh_path = temp / "fake-ssh"
        fixture_root.mkdir(); app_support.mkdir(); (fixture_root / "srv" / "project").mkdir(parents=True)
        hostname_file.write_text("fixture.internal")
        ssh_path.write_text(FAKE_SSH); ssh_path.chmod(0o700)

        env = os.environ.copy()
        env.update({
            "DSH_SSH_BIN": str(ssh_path),
            "DSH_SSH_SELECTION_FILE": str(selection_path),
            "DSH_SSH_APP_SUPPORT_ROOT": str(app_support),
            "DSH_SSH_FIXTURE_ROOT": str(fixture_root),
            "DSH_SSH_FIXTURE_HOSTNAME_FILE": str(hostname_file),
            "DSH_SSH_TEST_TRANSFER_LIMIT": "1024",
        })
        bridge = Bridge(env)
        passes = 1

        initialized = result_value(bridge.rpc("initialize", {"protocolVersion": "2025-06-18"}))
        assert initialized["serverInfo"]["name"] == "deepseek-ssh-bridge"; passes += 1
        tools = result_value(bridge.rpc("tools/list", {}))["tools"]
        assert len(tools) == 11
        assert all(tool["inputSchema"]["additionalProperties"] is False for tool in tools); passes += 1
        invalid_id = bridge.raw({"jsonrpc": "2.0", "id": {"bad": True}, "method": "ping"})
        assert invalid_id["id"] is None and invalid_id["error"]["code"] == -32600; passes += 1
        bridge.assert_notification_silent({"jsonrpc": "1.0", "method": "broken-notification"}); passes += 1
        assert tool_value(bridge.tool("ping"))["ok"] is True; passes += 1
        assert "No SSH server is selected" in tool_error(bridge.tool("connection_status")); passes += 1

        selection = write_selection(selection_path)
        status = tool_value(bridge.tool("connection_status"))
        assert status["connected"] is True and status["host_alias"] == "fixture-gpu"; passes += 1
        probe = tool_value(bridge.tool("inspect_server"))
        assert "Fixture GPU" in probe["probe"] and probe["remote_workspace"] == "/srv/project"; passes += 1

        command = "printf 'api_key=fixture-secret-value-12345\\n'"
        expected = f"Run on fixture-gpu in /srv/project: {command}"
        assert "Immediate user confirmation" in tool_error(bridge.tool("run_command", {"command": command, "confirmed": False, "confirmation_summary": expected})); passes += 1
        run = tool_value(bridge.tool("run_command", {"command": command, "confirmed": True, "confirmation_summary": expected}))
        assert run["exit_code"] == 0 and "fixture-secret" not in run["stdout"] and "[REDACTED]" in run["stdout"]; passes += 1

        numeric_confirmation = bridge.tool("run_command", {
            "command": command, "confirmed": 1, "confirmation_summary": expected,
        })
        assert numeric_confirmation["error"]["code"] == -32602; passes += 1

        hang_command = "HARNESS_FIXTURE_HANG"
        hang_expected = f"Run on fixture-gpu in /srv/project: {hang_command}"
        started = time.monotonic()
        hang_result = tool_value(bridge.tool("run_command", {
            "command": hang_command, "timeout_seconds": 1,
            "confirmed": True, "confirmation_summary": hang_expected,
        }))
        assert hang_result["timed_out"] is True
        assert time.monotonic() - started < 6; passes += 1

        bad = bridge.tool("connection_status", {"unexpected": True})
        assert bad["error"]["code"] == -32602; passes += 1

        job_command = "python3 train.py --epochs 1"
        job_expected = f"Start background job on fixture-gpu in /srv/project: {job_command}"
        job = tool_value(bridge.tool("start_job", {
            "display_name": "fixture training", "command": job_command,
            "confirmed": True, "confirmation_summary": job_expected,
        }))
        job_id = job["job_id"]
        assert re.fullmatch(r"[0-9a-f-]{36}", job_id); passes += 1
        job_dir = fixture_root / "srv" / "project" / ".harnessmate" / "jobs" / job_id
        assert (job_dir / "process_group").read_text().strip() == "4242"
        assert (job_dir / "process_start_time").read_text().strip() == "987654"; passes += 1
        jobs = tool_value(bridge.tool("list_jobs"))["job_ids"]
        assert job_id in jobs; passes += 1
        job_status = tool_value(bridge.tool("job_status", {"job_id": job_id}))
        assert "state=running" in job_status["status"] and "display_name=fixture training" in job_status["status"]; passes += 1
        logs = tool_value(bridge.tool("job_logs", {"job_id": job_id, "stream": "stdout"}))
        assert "epoch 1" in logs["text"] and "fixture-secret" not in logs["text"]; passes += 1
        cancel_expected = f"Cancel remote job {job_id} on fixture-gpu"
        assert "Immediate user confirmation" in tool_error(bridge.tool("cancel_job", {"job_id": job_id, "confirmed": False, "confirmation_summary": cancel_expected})); passes += 1
        cancelled = tool_value(bridge.tool("cancel_job", {"job_id": job_id, "confirmed": True, "confirmation_summary": cancel_expected}))
        assert cancelled["cancel_requested"] is True and cancelled["signal"] == "TERM"; passes += 1

        local = app_support / "Artifacts" / "Inbox" / "fixture" / "dataset.txt"
        local.parent.mkdir(parents=True); local.write_text("training data\n"); local.chmod(0o600)
        upload_expected = "Upload Artifacts/Inbox/fixture/dataset.txt to fixture-gpu:data/dataset.txt"
        uploaded = tool_value(bridge.tool("upload", {
            "local_managed_path": "Artifacts/Inbox/fixture/dataset.txt",
            "remote_relative_path": "data/dataset.txt", "overwrite": False,
            "confirmed": True, "confirmation_summary": upload_expected,
        }))
        assert uploaded["uploaded"] is True
        assert (fixture_root / "srv" / "project" / "data" / "dataset.txt").read_text() == "training data\n"; passes += 1
        assert "may not contain" in rpc_error(bridge.tool("upload", {
            "local_managed_path": "Artifacts/Inbox/fixture/dataset.txt",
            "remote_relative_path": "../escape", "confirmed": True,
            "confirmation_summary": "unused",
        })); passes += 1

        remote_result = fixture_root / "srv" / "project" / "results" / "model.pt"
        remote_result.parent.mkdir(parents=True); remote_result.write_bytes(b"fixture-model")
        download_expected = "Download fixture-gpu:results/model.pt to managed Downloads"
        downloaded = tool_value(bridge.tool("download", {
            "remote_relative_path": "results/model.pt", "confirmed": True,
            "confirmation_summary": download_expected,
        }))
        downloaded_path = app_support / downloaded["managed_relative_path"]
        assert downloaded_path.read_bytes() == b"fixture-model"; passes += 1

        oversized = fixture_root / "srv" / "project" / "results" / "oversized.bin"
        oversized.write_bytes(b"x" * 2048)
        oversized_expected = "Download fixture-gpu:results/oversized.bin to managed Downloads"
        assert "output limit" in tool_error(bridge.tool("download", {
            "remote_relative_path": "results/oversized.bin", "confirmed": True,
            "confirmation_summary": oversized_expected,
        })); passes += 1

        hostname_file.write_text("drifted.internal")
        assert "SSH config changed after selection" in tool_error(bridge.tool("connection_status")); passes += 1
        hostname_file.write_text("fixture.internal")
        write_selection(selection_path, expired=True)
        assert "expired" in tool_error(bridge.tool("connection_status")); passes += 1
        write_selection(selection_path)
        selection_path.chmod(0o644)
        assert "permission validation" in tool_error(bridge.tool("connection_status")); passes += 1
        write_selection(selection_path, alias="fixture:gpu")
        assert "invalid or unexpected schema" in tool_error(bridge.tool("connection_status")); passes += 1

        bridge.close()
        print(f"SSH_BRIDGE_QA_OK pass={passes} tools={len(tools)} real_connections=0")


if __name__ == "__main__":
    main()
