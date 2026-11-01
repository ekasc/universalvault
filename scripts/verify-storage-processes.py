#!/usr/bin/env python3
"""Verify compare-and-swap using two real processes and disposable storage."""

import pathlib
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parent.parent
binary_directory = pathlib.Path(
    subprocess.check_output(
        ["swift", "build", "--package-path", str(root), "--show-bin-path"], text=True
    ).strip()
)
with tempfile.TemporaryDirectory(prefix="UniversalVault-process-check-") as temporary:
    directory = pathlib.Path(temporary)
    worker = directory / "worker"
    subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            "-I",
            str(binary_directory),
            "-L",
            str(binary_directory),
            "-lUniversalVaultSecurity",
            "-lUniversalVaultCore",
            str(root / "scripts/verify-storage-processes.swift"),
            "-o",
            str(worker),
        ],
        check=True,
    )
    vault = directory / "vault"
    vault.mkdir(mode=0o700)
    (vault / "vault.uv").write_bytes(b"initial")
    processes = [
        subprocess.Popen(
            [str(worker), str(vault), name],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for name in ["one", "two"]
    ]
    try:
        deadline = time.monotonic() + 10
        while not all((vault / f"ready-{name}").exists() for name in ["one", "two"]):
            if time.monotonic() >= deadline:
                raise RuntimeError("Storage workers did not reach the barrier.")
            time.sleep(0.01)
        (vault / "go").touch()
        outputs = []
        for process in processes:
            out, err = process.communicate(timeout=15)
            if process.returncode != 0:
                raise RuntimeError(f"Storage worker failed: {err}")
            outputs.append(out.strip())
        assert sorted(outputs) == ["conflict", "saved"], outputs
        assert (vault / "vault.uv").read_bytes() in [b"one", b"two"]
        assert (vault / "vault.uv").stat().st_mode & 0o777 == 0o600
        print(
            "PASS: two processes, exactly one CAS commit, one conflict, final file mode 0600."
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
