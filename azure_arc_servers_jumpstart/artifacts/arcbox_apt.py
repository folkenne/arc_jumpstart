#!/usr/bin/env python3
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


BUDGET = 1800
VENDOR_SHA256 = "a41c8b0626e41aac6c51a9c01a0c35e87cedc77bdd38155a416b1a49bf1e9101"
LOCKS = {
    "/var/lib/dpkg/lock-frontend": "frontend",
    "/var/lib/dpkg/lock": "dpkg",
    "/var/lib/apt/lists/lock": "lists",
    "/var/cache/apt/archives/lock": "archives",
}
SCOPED_ERROR = re.compile(
    rb"(?m)^(?:E: Could not get lock |dpkg: error: (?:dpkg (?:frontend|database) lock|database lock))([^\r\n]{0,512})"
)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def held_locks():
    keys = {}
    for path, label in LOCKS.items():
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue
        keys[(os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)] = label
    with open("/proc/locks", encoding="ascii") as source:
        for line in source:
            parts = line.split()
            if len(parts) < 8 or parts[1] not in ("POSIX", "FLOCK", "OFDLCK"):
                continue
            major, minor, inode = parts[5].split(":")
            label = keys.get((int(major, 16), int(minor, 16), int(inode)))
            if label:
                pid = int(parts[4])
                yield label, pid if pid > 0 else None


class LockWait:
    def __init__(self, directory, clock=time.monotonic, sleep=time.sleep, observe=held_locks):
        self.directory = Path(directory)
        self.state_path = self.directory / "wait-state.json"
        self.clock, self.sleep, self.observe = clock, sleep, observe
        try:
            self.state = json.loads(self.state_path.read_text(encoding="ascii"))
        except FileNotFoundError:
            self.state = {}

    def save(self):
        pending = self.state_path.with_suffix(".pending")
        pending.write_text(json.dumps(self.state), encoding="ascii")
        pending.replace(self.state_path)

    def log(self, result, elapsed, locks):
        with (self.directory / "apt-wait.jsonl").open("a", encoding="ascii") as log:
            print(json.dumps({"at": utc(), "stage": "apt-lock-wait", "state": result,
                              "occurrence": self.state["count"], "elapsedSeconds": int(elapsed),
                              "locks": [{"name": label, "pid": pid} for label, pid in locks]}), file=log)

    def wait(self, contended=False, native=None):
        locks = list(self.observe())
        if not (locks or contended):
            return True
        begin = self.clock()
        if not self.state:
            self.state = {"deadline": begin + BUDGET, "start": utc(), "waited": 0.0, "count": 0}
        self.state["count"] += 1
        self.state.update(result="waiting", end=utc(), native=native)
        self.save()
        self.log("waiting", 0, locks)
        next_progress = begin + 60
        # A conflicting invocation may already have released its lock by the first probe.
        if contended and not locks:
            self.sleep(min(1, max(0, self.state["deadline"] - begin)))
        while True:
            now = self.clock()
            elapsed = now - begin
            if now >= self.state["deadline"] or not locks:
                result = "timeout" if now >= self.state["deadline"] else "released"
                self.state.update(result=result, end=utc(), waited=self.state["waited"] + elapsed)
                self.save()
                self.log(result, elapsed, locks)
                return result == "released"
            if now >= next_progress:
                self.log("waiting", elapsed, locks)
                next_progress = now + 60
            self.sleep(min(5, self.state["deadline"] - now))
            locks = list(self.observe())


def lock_error(output):
    for match in SCOPED_ERROR.finditer(output):
        detail = match[1]
        if any(detail.startswith(p.encode() + terminator) for p in LOCKS for terminator in (b".", b" ", b":")):
            return True
        if detail.startswith(b" was locked by another process with pid "):
            return True
    return False


def run_package_command(wait, args):
    command = ["sudo", *args]
    tool = next(i for i, arg in enumerate(command) if arg in ("apt", "apt-get", "dpkg"))
    if command[tool] != "dpkg":
        command[tool + 1:tool + 1] = ["-o", "DPkg::Lock::Timeout=0"]
    command.insert(tool, "LC_ALL=C")
    if not wait.wait():
        return 124
    while True:
        tail = b""
        with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT) as proc:
            while chunk := proc.stdout.read1(8192):
                tail = (tail + chunk)[-65536:]
                sys.stdout.buffer.write(chunk)
            code = proc.wait()
        if code:
            try:
                with (wait.directory / "first-package-error.log").open("xb") as first:
                    first.write(f"{utc()} {command[tool + 1]} exit={code}\n".encode("ascii") + tail)
            except FileExistsError:
                pass
            except OSError:
                print("ArcBox could not retain the first package error.", file=sys.stderr)
        if code not in (2, 100) or not lock_error(tail):
            return code if 0 <= code <= 255 else 128 - code
        if not wait.wait(contended=True, native=code):
            return 124


def prepare(vendor, directory):
    path = Path(vendor)
    if path.stat().st_size > 200000:
        raise ValueError("vendor exceeds reviewed size")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != VENDOR_SHA256:
        raise ValueError("vendor digest not reviewed")
    source = data.decode("utf-8")
    # Replace the vendor's five-minute gate and route its APT entry points through the same budget.
    source, gates = re.subn(r"(?m)^function verify_apt_not_busy \{[\s\S]*?^\}",
                            'function verify_apt_not_busy { arcbox_wait_gate; }', source)
    source, sites = re.subn(
        r"(?m)^([ \t]*)sudo (?=(?:-E )?(?:(?:https_proxy=\$\{proxy\}|DEBIAN_FRONTEND=noninteractive) )*(?:apt(?:-get)? |dpkg -i ))",
        r"\1arcbox_package_command ", source)
    if gates != 1 or sites != 19:
        raise ValueError("unexpected APT entry points")
    prefix = """#!/bin/bash
arcbox_wait_gate() {
    python3 "$ARCBOX_APT_HELPER" wait "$ARCBOX_APT_WORK" || exit "$?"
}
arcbox_package_command() {
    local code=0
    python3 "$ARCBOX_APT_HELPER" command "$ARCBOX_APT_WORK" "$@" || code=$?
    if [ "$code" -eq 124 ] || [ "$code" -eq 125 ]; then exit "$code"; fi
    return "$code"
}
arcbox_wait_gate
"""
    out = Path(directory) / "vendor-candidate.sh"
    out.write_bytes((prefix + source).encode("utf-8"))


def main(argv):
    mode, directory, *args = argv
    if mode == "prepare":
        prepare(args[0], directory)
        return 0
    wait = LockWait(directory)
    if mode == "wait":
        return 0 if wait.wait() else 124
    if mode == "command":
        return run_package_command(wait, args)
    if mode == "emit" and (Path(directory) / "controller-unavailable").is_file():
        print("ArcBoxAptControllerUnavailable")
    if mode == "emit" and wait.state:
        state = wait.state
        capture = Path(directory).name
        print(f"ArcBoxAptWait:v1:{state['start']}:{state['end']}:{int(state['waited'])}:"
              f"{state['count']}:{state['result']}:{state['native'] or 0}:{capture}")
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError):
        if len(sys.argv) >= 3 and sys.argv[1] in ("wait", "command"):
            try:
                (Path(sys.argv[2]) / "controller-unavailable").touch()
            except OSError:
                print("ArcBox could not retain the controller error state.", file=sys.stderr)
        print("ArcBox APT lock controller unavailable or vendor contract not verified.", file=sys.stderr)
        sys.exit(125)
