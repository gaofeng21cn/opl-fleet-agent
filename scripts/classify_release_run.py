#!/usr/bin/env python3
"""Classify a completed native Release workflow run from its jobs."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def classify(jobs: list[dict[str, object]]) -> str:
    indexed: dict[str, str] = {}
    for job in jobs:
        name, conclusion = job.get("name"), job.get("conclusion")
        if isinstance(name, str) and isinstance(conclusion, str):
            if name in indexed:
                raise ValueError(f"duplicate workflow job: {name}")
            indexed[name] = conclusion

    native = all(indexed.get(name) == "success" for name in ("macos", "windows", "publish"))
    if native and indexed.get("preflight", "success") == "success":
        return "native"

    package_only = (
        indexed.get("preflight") == "success"
        and all(indexed.get(name) == "skipped" for name in ("macos", "windows", "publish"))
    )
    if package_only:
        return "package-only"

    raise ValueError("run is neither a successful native release nor an exact Package-only skip")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: classify_release_run.py JOBS_JSON")
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    jobs = payload.get("jobs") if isinstance(payload, dict) else None
    if not isinstance(jobs, list):
        raise SystemExit("workflow jobs response is malformed")
    try:
        print(classify(jobs))
    except ValueError as error:
        raise SystemExit(str(error)) from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
