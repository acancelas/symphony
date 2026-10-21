#!/usr/bin/env python3
"""No-model canary probe of installed AppServer permission profiles.

Uses an empty temporary CODEX_HOME and no real credentials. Never changes global
configuration, sets up a Windows sandbox, replaces binaries, or relaxes guards.
A passing command sandbox is only one prerequisite, not broker certification.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


def probe(executable, scratch=None):
    report = {"brokerCertified": False, "modelInvoked": False,
              "realCredentialsUsed": False, "globalConfigModified": False}
    parent = Path(scratch or tempfile.gettempdir()).resolve()
    if not parent.is_dir():
        raise ValueError("scratch directory must already exist")
    with tempfile.TemporaryDirectory(prefix="bos-governance-canary-", dir=parent) as temporary:
        base = Path(temporary).resolve()
        if base.parent != parent:
            raise ValueError("generated scratch path escaped its intended parent")
        workspace, outside, home = (base / p for p in ("workspace", "outside", "codex-home"))
        for directory in (workspace, outside, home):
            directory.mkdir()
        allowed = workspace / "allowed.txt"
        denied = outside / "host-canary.txt"
        forbidden_write = workspace / "forbidden-write.txt"
        allowed.write_text("allowed fixture", encoding="utf-8")
        denied.write_text("synthetic host secret", encoding="utf-8")
        # No sandbox_mode/--sandbox/legacy config may override this profile.
        config = '''default_permissions = "bos-review"
approval_policy = "never"
[permissions.bos-review.filesystem]
":root" = "deny"
":minimal" = "read"
[permissions.bos-review.filesystem.":workspace_roots"]
"." = "read"
".env" = "deny"
"*.env" = "deny"
".aws" = "deny"
".ssh" = "deny"
[permissions.bos-review.network]
enabled = false
[shell_environment_policy]
inherit = "none"
'''
        (home / "config.toml").write_text(config, encoding="utf-8")
        environment = {"PATH": os.defpath, "HOME": str(home), "USERPROFILE": str(home),
                       "CODEX_HOME": str(home), "LANG": "C.UTF-8",
                       "BOS_SYNTHETIC_PARENT_SECRET": "synthetic parent-only secret"}
        for name in ("SYSTEMROOT", "WINDIR", "TEMP", "TMP"):
            if name in os.environ:
                environment[name] = os.environ[name]
        version = subprocess.run([executable, "--version"], env=environment,
                                 capture_output=True, text=True, timeout=10)
        report["version"] = version.stdout.strip()
        popen_options = {"cwd": workspace, "env": environment, "stdin": subprocess.PIPE,
                         "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
                         "text": True, "encoding": "utf-8", "errors": "replace"}
        if os.name != "nt":
            popen_options["start_new_session"] = True
        process = subprocess.Popen([executable, "app-server"], **popen_options)
        messages, stderr = queue.Queue(), []
        def read_stdout():
            for line in process.stdout:
                try:
                    messages.put(json.loads(line))
                except json.JSONDecodeError:
                    pass
        def read_stderr():
            for line in process.stderr:
                # Isolated process; bounded diagnostics never include real secrets.
                if len(stderr) < 40:
                    stderr.append(line.strip())
        readers = [threading.Thread(target=read_stdout), threading.Thread(target=read_stderr)]
        for reader in readers:
            reader.start()
        def send(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
        def receive(identifier, timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if process.poll() is not None and messages.empty():
                    raise RuntimeError("app_server_exited_before_response")
                try:
                    value = messages.get(timeout=min(.2, max(.01, deadline-time.monotonic())))
                    if value.get("id") == identifier:
                        return value
                except queue.Empty:
                    pass
            raise RuntimeError("bounded_app_server_timeout")
        try:
            send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "bos-governance-canary", "version": "1"}, "capabilities": {"experimentalApi": True}}})
            receive(1)
            send({"method": "initialized", "params": {}})
            send({"id": 2, "method": "config/read", "params": {"includeLayers": False}})
            configured = receive(2)
            effective = configured.get("result", {}).get("config", {})
            report["profileSelected"] = effective.get("default_permissions") == "bos-review"
            report["legacySandboxOverride"] = bool(effective.get("sandbox_mode"))
            if not report["profileSelected"] or report["legacySandboxOverride"]:
                report["blockedReason"] = "isolated_profile_not_effective"
            else:
                code = """import json, os
from pathlib import Path
result = {}
for key, path in [('allowedRead', %r), ('outsideRead', %r)]:
    try:
        Path(path).read_text()
        result[key] = True
    except OSError:
        result[key] = False
try:
    Path(%r).write_text('forbidden')
    result['workspaceWrite'] = True
except OSError:
    result['workspaceWrite'] = False
result['parentSecretVisible'] = 'BOS_SYNTHETIC_PARENT_SECRET' in os.environ
print(json.dumps(result))
""" % (str(allowed), str(denied), str(forbidden_write))
                send({"id": 3, "method": "command/exec", "params": {"command": [sys.executable, "-c", code], "cwd": str(workspace), "permissionProfile": "bos-review", "timeoutMs": 10000}})
                executed = receive(3)
                result = executed.get("result", {})
                report["commandExit"] = result.get("exitCode")
                if result.get("exitCode") == 0:
                    try:
                        checks = json.loads(result.get("stdout", "").strip())
                        report["canaries"] = checks
                        report["commandIsolationPassed"] = checks == {"allowedRead": True, "outsideRead": False, "workspaceWrite": False, "parentSecretVisible": False}
                    except json.JSONDecodeError:
                        report["blockedReason"] = "unreadable_canary_result"
                else:
                    report["blockedReason"] = "native_profile_execution_failed"
                    report["commandError"] = (executed.get("error") or result.get("stderr", ""))
        except (OSError, RuntimeError) as error:
            report["blockedReason"] = str(error)
        finally:
            if process.poll() is None:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True, timeout=5)
                else:
                    os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if os.name == "nt":
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            for reader in readers:
                reader.join(timeout=2)
            report["probeProcessReaped"] = process.poll() is not None
            report["canaryFilesUnchanged"] = denied.read_text(encoding="utf-8") == "synthetic host secret" and not forbidden_write.exists()
            report["diagnostics"] = stderr[-8:]
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--scratch", help="existing task-owned scratch directory outside platform temp roots")
    args = parser.parse_args()
    if not args.codex:
        parser.error("installed codex executable is required")
    result = probe(str(Path(args.codex).resolve()), args.scratch)
    print(json.dumps(result, indent=2))
    # No live broker/M2M capability is ever certified by this no-model probe.
    sys.exit(0 if result.get("commandIsolationPassed") else 2)

