#!/bin/bash

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    if [[ $- == *i* && -n ${SSH_TTY-} && -t 0 && -t 1 ]]; then
        PS1='\A [\u@\h] \w \$ '
        HISTTIMEFORMAT='%F %T '
        if ! alias ll &>/dev/null; then alias ll='ls -alF'; fi
        /usr/local/bin/arc-status --welcome
    fi
    return 0
fi

if [[ ${1-} == --install-profile && $# == 1 ]]; then
    if [[ $(id -un) != jumpstart || $HOME != /home/jumpstart || ! -O $HOME || -L $HOME ]]; then
        printf '%s\n' 'Expected the jumpstart lab account and its own home directory.' >&2
        exit 1
    fi
    # Append to the file Bash actually reads, after its existing prompt setup.
    profile=$HOME/.profile
    for candidate in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        if [[ -e $candidate || -L $candidate ]]; then profile=$candidate; break; fi
    done
    if [[ -L $profile || ( -e $profile && ( ! -f $profile || ! -O $profile || ! -r $profile ) ) ]]; then
        printf '%s\n' 'The Bash login profile is not a readable, account-owned regular file.' >&2
        exit 1
    fi
    hook='if [ -n "${BASH_VERSION-}" ] && [ -r /usr/local/bin/arc-status ]; then . /usr/local/bin/arc-status; fi # ArcBox lab shell'
    if [[ -f $profile ]]; then
        grep -Fqx -- "$hook" "$profile" && exit 0
        if [[ $? != 1 ]]; then exit 1; fi
    fi
    umask 077
    printf '\n%s\n' "$hook" >> "$profile"
    exit $?
fi

if [[ $# != 0 && ( $# != 1 || $1 != --welcome ) ]]; then
    printf '%s\n' 'Usage: arc-status' >&2
    exit 2
fi

if /usr/bin/timeout --kill-after=1s 3s /usr/bin/python3 -I -B - "$@" 2>/dev/null <<'PY'
import datetime as dt
import json
import os
import pwd
import re
import socket
import subprocess
import sys


def read(args, seconds):
    try:
        result = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            encoding="utf-8", errors="replace", timeout=seconds, env={**os.environ, "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        return None, "local read timed out", None
    except FileNotFoundError:
        return None, "local tool not found", None
    except OSError:
        return None, "local read failed", None
    return result.stdout, None, result.returncode


def utc_heartbeat(value):
    match = re.fullmatch(
        r"(\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)", value
    ) if isinstance(value, str) else None
    if not match:
        return None
    try:
        stamp = dt.datetime.fromisoformat(match[1] + match[2].replace("Z", "+00:00"))
        return stamp.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC") if stamp.year > 1 else None
    except (ValueError, OverflowError):
        return None


def arc_fields():
    pkg, error, code = read(["/usr/bin/dpkg-query", "-W", "-f=${Status}\\n${Version}", "azcmagent"], 0.35)
    package_status, _, version = (pkg or "").partition("\n")
    agent = "/opt/azcmagent/bin/azcmagent"
    present = os.path.isfile(agent)
    package_installed = code == 0 and package_status.endswith(" ok installed")
    if package_installed or present:
        observed = package_installed and re.fullmatch(r"[0-9][0-9A-Za-z.+:~-]{0,79}", version)
        installation = f"Installed · {('v' + version) if observed else 'Version unavailable'}"
    elif code == 1 or (code == 0 and package_status.endswith((" ok not-installed", " ok config-files"))):
        installation = "Not installed"
    else:
        installation = f"Unavailable ({error or 'package status could not be read'})"
    service, error, code = read(
        ["/usr/bin/systemctl", "show", "-p", "LoadState", "-p", "ActiveState", "himdsd.service"], 0.45
    )
    states = dict(line.split("=", 1) for line in (service or "").splitlines() if "=" in line)
    state = states.get("ActiveState")
    if code == 0 and states.get("LoadState") == "not-found":
        service_status = "Service not found"
    elif code == 0 and state in ("active", "inactive", "failed", "activating", "deactivating", "reloading"):
        service_status = {
            "active": "Service running", "inactive": "Service stopped", "failed": "Service failed",
        }.get(state, f"Service {state}")
    else:
        service_status = f"Unavailable ({error or 'service state could not be read'})"
    data, error, code = read([agent, "show", "status", "lastHeartbeat", "--json"], 1.5)
    if error or code != 0:
        reason = error or f"agent query failed (exit {code})"
        return installation, service_status, f"Unavailable ({reason})", f"Unavailable ({reason})"
    try:
        report = json.loads(data)
    except ValueError:
        report = None
    if not isinstance(report, dict):
        return installation, service_status, "Unavailable (invalid agent response)", "Unavailable (invalid agent response)"
    status = report.get("status")
    connection = {
        "connected": "Connected", "disconnected": "Disconnected", "expired": "Expired",
        "not registered": "Not registered",
    }.get(status.strip().lower() if isinstance(status, str) else "", "Unavailable (status not reported or unrecognized)")
    heartbeat = utc_heartbeat(report.get("lastHeartbeat")) or "Unavailable (heartbeat not reported or invalid)"
    return installation, service_status, connection, heartbeat


def label(value):
    return "".join(char for char in value if char.isprintable())[:120] or "Unavailable"


if __name__ == "__main__":
    if sys.argv[1:] == ["--welcome"]:
        release = "Unavailable"
        try:
            with open("/etc/os-release", encoding="utf-8") as source:
                release = next((line.partition("=")[2].strip().strip('"') for line in source
                                if line.startswith("PRETTY_NAME=")), release)
        except OSError:
            pass
        print(f"Welcome to {label(socket.gethostname())} | {label(release)} | {label(pwd.getpwuid(os.getuid()).pw_name)}",
              flush=True)
    installation, service, connection, heartbeat = arc_fields()
    for name, value in (("Arc agent", f"{installation} · {service}"), ("Arc connection", connection),
                        ("Last Arc heartbeat", heartbeat)):
        print(f"{name:<19}{value}")
PY
then
    exit 0
else
    result=$?
    if [[ $result == 124 || $result == 137 ]]; then reason='local status check timed out'
    else reason='local status check could not run'; fi
    printf '%-19sUnavailable (%s)\n' 'Arc agent' "$reason" 'Arc connection' "$reason" 'Last Arc heartbeat' "$reason"
fi
