#!/usr/bin/env python3
"""Portable subprocess smoke checks, NOT a Swift/macOS runtime test.

Reads command options from FileOperationsManager.swift, then runs the platform's
ZIP/Git on disposable files. The native suite exercises actual Swift call paths.
No user repositories, system Trash, clipboard, network or credentials are used.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import zipfile

SOURCE = (Path(__file__).resolve().parents[1] / "Sources/Burrow/Engine/FileOperationsManager.swift").read_text()

def command(executable, arguments, cwd, env):
    return subprocess.run([executable, *arguments], cwd=cwd, env=env, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

with tempfile.TemporaryDirectory(prefix="bf-fileops-process-smoke-") as tmp:
    root = Path(tmp)
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"), GIT_CONFIG_NOSYSTEM="1")
    env["ZIPOPT"] = "-m"  # Deliberately hostile inherited archive options.
    names = ["-m", "-T", "space name.txt", "line\nbreak.txt", "Zażółć.txt"]
    work = root / "zip-fixture"
    work.mkdir()
    original = {name: ("contents:" + name).encode() for name in names}
    for name, data in original.items():
        (work / name).write_bytes(data)
    assert 'items.map { "./" + $0.url.lastPathComponent }' in SOURCE
    zip_literal = re.search(r'Self.runProcess\("/usr/bin/zip", arguments: (\[[^\n]+?\]) \+ names', SOURCE).group(1)
    archive = work / "archive.zip"
    zip_arguments = json.loads(zip_literal.replace("stagedURL.path", json.dumps(str(archive))))
    archive_environment_literal = re.search(r'var environment = (\["PATH": [^\n]+\])', SOURCE).group(1)
    archive_env = json.loads("{" + archive_environment_literal[1:-1] + "}")
    archive_allowlist = json.loads(re.search(r'for key in (\[[^\n]+\])', SOURCE).group(1))
    archive_env.update({key: env[key] for key in archive_allowlist if key in env})
    assert "ZIPOPT" not in archive_env and "environment: Self.archiveProcessEnvironment()" in SOURCE
    command("/usr/bin/zip", zip_arguments + ["./" + name for name in names], work, archive_env)
    with zipfile.ZipFile(archive) as zipped:
        for name, data in original.items():
            assert (work / name).read_bytes() == data, f"Source changed: {name!r}"
            assert zipped.read(name) == data, f"Archive content mismatch: {name!r}"
    vulnerable = root / "zip-env-positive-control"
    vulnerable.mkdir()
    (vulnerable / "important.txt").write_text("fixture only")
    command("/usr/bin/zip", ["-r", "-q", "-y", str(vulnerable / "control.zip"), "./important.txt"], vulnerable, env)
    assert not (vulnerable / "important.txt").exists(), "ZIPOPT=-m positive control did not delete fixture source"
    print("PASS ZIP arguments and production environment allowlist preserve five sources with inherited ZIPOPT=-m; vulnerable positive control deletes only fixture")

    git_options = json.loads(re.search(r'let safeOptions = (\[[^\n]+\])', SOURCE).group(1))
    status_options = json.loads(re.search(r'arguments: safeOptions \+ disabledFilters \+ (\[[^\n]*"status"[^\n]*\])', SOURCE).group(1))
    repo = root / "git-fixture"
    repo.mkdir()
    marker = root / "helper-executed"
    helper = root / "fsmonitor"
    helper.write_text(f"#!/bin/sh\n/usr/bin/touch '{marker}'\n")
    helper.chmod(0o755)
    command("/usr/bin/git", ["init", "-q"], repo, env)
    command("/usr/bin/git", ["config", "core.fsmonitor", str(helper)], repo, env)
    (repo / "file.txt").write_text("untracked")
    output = command("/usr/bin/git", git_options + status_options, repo, env)
    assert b"?? file.txt\0" in output and not marker.exists()
    (repo / "file.txt").unlink()
    assert command("/usr/bin/git", git_options + status_options, repo, env) == b""
    assert not marker.exists()
    # Positive control proves this installed Git actually honors the test helper.
    command("/usr/bin/git", ["status", "--porcelain=v1", "-z", "-uall"], repo, env)
    assert marker.exists(), "Positive control did not execute fsmonitor; security check is inconclusive"
    print("PASS Git safe options suppress local fsmonitor helper, with positive vulnerable control")
    filter_repo = root / "filter-fixture"
    filter_repo.mkdir()
    def filter_git(args):
        return command("/usr/bin/git", args, filter_repo, env)
    filter_git(["init", "-q"])
    (filter_repo / ".gitattributes").write_text("*.txt filter=fixture\n")
    tracked = filter_repo / "tracked.txt"
    tracked.write_text("original\n")
    filter_git(["add", "--", ".gitattributes", "tracked.txt"])
    filter_git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
    filter_marker = root / "clean-filter-executed"
    filter_helper = root / "clean-filter"
    filter_helper.write_text(f"#!/bin/sh\n/usr/bin/touch '{filter_marker}'\n/bin/cat\n")
    filter_helper.chmod(0o755)
    filter_git(["config", "filter.fixture.clean", str(filter_helper)])
    time.sleep(1.1)
    tracked.write_text("modified\n")
    filter_git(git_options + status_options)
    assert filter_marker.exists(), "Same-size edit positive control did not run clean filter"
    filter_marker.unlink()
    config_options = json.loads(re.search(r'arguments: safeOptions \+ (\[[^\n]*"config"[^\n]*\])', SOURCE).group(1))
    keys = filter_git(git_options + config_options).decode().split("\0")
    drivers = set()
    for key in keys:
        lower = key.lower()
        suffix = next((tail for tail in (".clean", ".process", ".required") if lower.endswith(tail)), None)
        if lower.startswith("filter.") and suffix:
            driver = key[len("filter."):-len(suffix)]
            assert driver and not any(character in driver for character in "=\r\n")
            drivers.add(driver)
    # Only the parser is mirrored here; native tests exercise the actual Swift parser.
    filters = []
    for driver in sorted(drivers):
        filters += ["-c", f"filter.{driver}.clean=", "-c", f"filter.{driver}.process=",
                    "-c", f"filter.{driver}.required=false"]
    output = filter_git(git_options + filters + status_options)
    assert b" M tracked.txt\0" in output and not filter_marker.exists()
    print("PASS Git clean-filter same-size edit: positive helper control executes, enumerated overrides suppress it")
    process_marker = root / "process-filter-executed"
    process_helper = root / "process-filter"
    # Speak the server greeting, then stop deliberately. Even this optional-filter
    # failure executes attacker code before Git falls back to raw content.
    process_helper.write_text(f"#!/bin/sh\n/usr/bin/touch '{process_marker}'\nprintf '0016git-filter-server\\n000eversion=2\\n0000'\n")
    process_helper.chmod(0o755)
    filter_git(["config", "filter.processor.process", str(process_helper)])
    filter_git(["config", "filter.processor.required", "false"])
    (filter_repo / ".gitattributes").write_text("*.txt filter=processor\n")
    subprocess.run(["/usr/bin/git", *git_options, *status_options], cwd=filter_repo, env=env,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10)
    assert process_marker.exists(), "Process-filter positive control did not execute helper"
    process_marker.unlink()
    process_filters = ["-c", "filter.processor.clean=", "-c", "filter.processor.process=", "-c", "filter.processor.required=false"]
    output = filter_git(git_options + filters + process_filters + status_options)
    assert b" M tracked.txt\0" in output and not process_marker.exists()
    print("PASS Git process-filter greeting/early-exit positive control executes; process override suppresses invocation")
print("4 portable subprocess checks passed. Native Swift/macOS behavior remains a separate verification gate.")
