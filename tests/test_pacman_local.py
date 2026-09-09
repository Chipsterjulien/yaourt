#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real pacman preview with synthetic metadata; never use the system database."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

babet, source = (Path(value).resolve() for value in sys.argv[1:3])
executable = shutil.which(os.environ.get("YAOURT_TEST_PACMAN", "pacman"))
if not executable:
    print("[SKIP] plan de suppression réel : pacman absent")
    sys.exit(0)
executable = str(Path(executable).resolve())

with tempfile.TemporaryDirectory(prefix="yaourt-pacman-tests-") as temp:
    work = Path(temp)
    root, db = work / "root", work / "db"
    paths = [root, db / "local", work / "cache", work / "hooks", work / "gpg"]
    for path in paths:
        path.mkdir(parents=True)
    (db / "local" / "ALPM_DB_VERSION").write_text("9\n")
    config = work / "pacman.conf"
    config.write_text("[options]\n" + "\n".join([
        f"RootDir = {root}", f"DBPath = {db}", f"CacheDir = {work / 'cache'}",
        f"LogFile = {work / 'pacman.log'}", f"HookDir = {work / 'hooks'}",
        f"GPGDir = {work / 'gpg'}", "Architecture = auto", "SigLevel = Never",
    ]) + "\n")
    # No archives, downloads, installation, scripts or hooks. Write minimal
    # local metadata directly and keep all package files inside the test root.
    for name, dependencies in {
        "old-lib": [], "old-orphan": [], "new-lib": [],
        "new-tool": ["new-lib", "old-lib"],
    }.items():
        package = db / "local" / (name + "-1-1")
        package.mkdir()
        fields = {"NAME": [name], "VERSION": ["1-1"], "BASE": [name],
                  "DESC": ["Yaourt test fixture"], "ARCH": ["any"],
                  "REASON": ["1"], "SIZE": ["1"], "VALIDATION": ["none"]}
        if dependencies:
            fields["DEPENDS"] = dependencies
        package.joinpath("desc").write_text("".join(
            f"%{key}%\n" + "\n".join(values) + "\n\n" for key, values in fields.items()))
        package.joinpath("files").write_text(f"%FILES%\n{name}\n\n")
        root.joinpath(name).write_text("KEEP\n")

    def snapshot():
        return {str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest()
                for directory in (root, db) for path in directory.rglob("*") if path.is_file()}

    def query(args):
        result = subprocess.run([executable, "--config", str(config)] + args,
                                input="n\n", capture_output=True, text=True,
                                env={**os.environ, "LC_ALL": "C"}, timeout=30)
        assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result.stdout.splitlines()

    before = snapshot()
    assert set(query(["-Qq"])) == {"old-lib", "old-orphan", "new-lib", "new-tool"}
    # Check pacman's actual option semantics, independent of Lua mocks.
    for flags in (["--print-format", "%n"], ["--print", "--print-format", "%n"]):
        assert set(query(["-Rs"] + flags + ["new-tool"])) == {"new-tool", "new-lib", "old-lib"}
        assert snapshot() == before, "preview changed temporary packages or database"
    print("[PASS] pacman réel : --print-format implique --print, base temporaire inchangée")

    stage = work / "stage"
    stage.mkdir()
    shutil.copyfile(source / "tests/pacman_local/main.lua", stage / "main.lua")
    shutil.copytree(source / "lib", stage / "lib")
    embedded = work / "planner"
    subprocess.run([str(babet), "--create-exe", str(stage), str(embedded)],
                   check=True, capture_output=True, text=True)
    env = {**os.environ, "YAOURT_TEST_REAL_PACMAN": executable,
           "YAOURT_TEST_PACMAN_CONFIG": str(config)}
    for mode, command in (("dossier", [str(babet), str(stage)]), ("embarqué", [str(embedded)])):
        result = subprocess.run(command, env=env, cwd=work, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (mode, result.stdout, result.stderr)
        assert "YAOURT_PACMAN_PLAN_OK" in result.stdout
        assert snapshot() == before, "planner changed temporary packages or database"
        print(f"[PASS] nettoyage {mode} : vrai plan pacman filtré, anciens paquets préservés, refus sans suppression")
