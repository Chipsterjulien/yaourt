#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Julien Freyermuth

"""Validate the Lua-parent -> babet.spawn-child terminal handoff."""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import termios
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("babet", type=Path)
    parser.add_argument("project", type=Path)
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


def session_processes(session_id: int) -> list[int]:
    """Return Linux PIDs still attached to the test session."""

    pids: list[int] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text(encoding="ascii")
            fields = stat[stat.rfind(")") + 2 :].split()
            if int(fields[3]) == session_id:
                pids.append(int(entry.name))
        except (FileNotFoundError, PermissionError, ValueError, IndexError):
            continue
    return pids


def main() -> int:
    args = parse_args()
    babet = args.babet.resolve()
    project = args.project.resolve()
    test_project = project / "tests" / "interactive"
    master_fd, slave_fd = pty.openpty()
    output = bytearray()

    def child_setup() -> None:
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [str(babet), str(test_project)],
        cwd=project,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        preexec_fn=child_setup,
    )
    os.close(slave_fd)

    def read_available(deadline: float) -> bool:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        readable, _, _ = select.select([master_fd], [], [], remaining)
        if not readable:
            return False
        try:
            chunk = os.read(master_fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return False
            raise
        if not chunk:
            return False
        output.extend(chunk)
        return True

    def wait_for(marker: bytes, deadline: float) -> None:
        while marker not in output:
            if not read_available(deadline):
                rendered = output.decode("utf-8", errors="replace")
                raise RuntimeError(
                    f"marqueur {marker!r} absent avant le délai\n{rendered}"
                )

    deadline = time.monotonic() + args.timeout
    try:
        wait_for(b"YAOURT_PARENT_PROMPT", deadline)
        os.write(master_fd, b"parent\n")
        wait_for(b"YAOURT_CHILD_PROMPT", deadline)
        os.write(master_fd, b"child\n")
        wait_for(b"YAOURT_INTERACTIVE_OK", deadline)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("délai dépassé avant la fin du processus")
        code = process.wait(timeout=remaining)
        if code != 0:
            rendered = output.decode("utf-8", errors="replace")
            raise RuntimeError(f"Babet a terminé avec le code {code}\n{rendered}")
    finally:
        if process.poll() is None:
            for pid in session_processes(process.pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=2)
        os.close(master_fd)

    print("[PASS] spawn interactif : lecture parent puis enfant sous PTY")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"[FAIL] spawn interactif sous PTY : {exc}", file=sys.stderr)
        raise SystemExit(1)
