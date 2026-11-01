#!/usr/bin/env python3
"""Run one isolated native verification process with a bounded lifetime."""

import argparse
import json
import os
import pathlib
import signal
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True, type=pathlib.Path)
parser.add_argument("--output", required=True, type=pathlib.Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
# Exports from earlier runs are synthetic, but keep the evidence directory tidy.
for stale in args.output.glob("synthetic-native-*.uvbackup"):
    stale.unlink()
result = args.output / "result.json"
if result.exists():
    result.unlink()
(args.output / "checkpoint.txt").unlink(missing_ok=True)
(args.output / "storage-directory").unlink(missing_ok=True)
with (args.output / "process.log").open("w") as log:
    process = subprocess.Popen(
        [str(args.binary.resolve()), "--verify-native", str(args.output.resolve())],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    (args.output / "pid").write_text(str(process.pid))
    try:
        code = process.wait(timeout=180)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SystemExit(
            "Native verification exceeded 180 seconds; its process was stopped."
        )
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        (args.output / "pid").unlink(missing_ok=True)
        storage_marker = args.output / "storage-directory"
        if storage_marker.exists():
            storage = pathlib.Path(storage_marker.read_text()).resolve()
            if storage.parent != pathlib.Path(
                tempfile.gettempdir()
            ).resolve() or not storage.name.startswith("UniversalVault-native-"):
                raise RuntimeError(
                    "Refusing cleanup outside the isolated verification storage path."
                )
            if storage.exists():
                shutil.rmtree(storage)
            storage_marker.unlink()
if not result.exists():
    raise SystemExit(
        f"Native verification produced no result, exit {code}. See {args.output / 'process.log'}"
    )
report = json.loads(result.read_text())
print(json.dumps(report, indent=2))
raise SystemExit(0 if code == 0 and report.get("status") == "PASS" else 1)
