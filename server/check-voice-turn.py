#!/usr/bin/env python3
"""REQ-CALL-006 issuer tests with a fresh private PostgreSQL cluster."""
import importlib.util
import os
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location(
    "server_checks", Path(__file__).resolve().parents[1] / "scripts/check-server.py"
)
assert spec is not None and spec.loader is not None
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
original = subprocess.run


def focused(args, **kwargs):
    if args[0] == "cargo":
        args = ["cargo", "test", "--locked", "--manifest-path", "server/Cargo.toml",
                "--test", "voice_turn", os.environ.get("TEST_FILTER", ""),
                "--", "--test-threads=1", "--nocapture"]
    return original(args, **kwargs)


subprocess.run = focused
checks.run()
