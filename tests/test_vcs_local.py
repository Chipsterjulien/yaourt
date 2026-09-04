#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Julien Freyermuth

"""Exercise the real git ls-remote path against a local repository."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("babet", type=Path)
    parser.add_argument("project", type=Path)
    return parser.parse_args()


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C"},
    )


def commit(repository: Path, content: str) -> str:
    (repository / "tracked.txt").write_text(content, encoding="utf-8")
    run(["git", "add", "tracked.txt"], repository)
    run([
        "git", "-c", "user.name=yaourt tests",
        "-c", "user.email=tests@invalid.example",
        "commit", "-m", content,
    ], repository)
    return run(["git", "rev-parse", "HEAD"], repository).stdout.strip()


def observed_revision(babet: Path, project: Path, repository: Path) -> str:
    env = {
        **os.environ,
        "YAOURT_TEST_VCS_REPOSITORY": str(repository),
    }
    result = subprocess.run(
        [str(babet), str(project / "tests" / "vcs_local")],
        cwd=project,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    prefix = "YAOURT_VCS_REVISION="
    for line in result.stdout.splitlines():
        if line.startswith(prefix):
            return line.removeprefix(prefix)
    raise RuntimeError("révision VCS absente de la sortie du test")


def main() -> int:
    args = parse_args()
    babet = args.babet.resolve()
    project = args.project.resolve()

    with tempfile.TemporaryDirectory(prefix="yaourt-vcs-") as directory:
        repository = Path(directory) / "repository"
        repository.mkdir()
        run(["git", "init", "-q"], repository)
        first = commit(repository, "first")
        if observed_revision(babet, project, repository) != first:
            raise RuntimeError("la première révision Git n'a pas été détectée")
        second = commit(repository, "second")
        if second == first:
            raise RuntimeError("le dépôt Git local n'a pas avancé")
        if observed_revision(babet, project, repository) != second:
            raise RuntimeError("la nouvelle révision Git n'a pas été détectée")

    print("[PASS] suivi VCS réel : git ls-remote local et nouvelle révision")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"[FAIL] intégration VCS locale : {exc}", file=sys.stderr)
        raise SystemExit(1)
