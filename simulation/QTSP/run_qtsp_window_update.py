#!/usr/bin/env python3
"""Run the continuous QTSP window-update experiment through Julia."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
JULIA = os.environ.get("JULIA", "julia")


def main() -> int:
    cmd = [
        JULIA,
        "-tauto",
        f"--project={REPO_ROOT}",
        str(SCRIPT_DIR / "run_qtsp_window_update.jl"),
        *sys.argv[1:],
    ]
    return subprocess.call(cmd, cwd=REPO_ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
