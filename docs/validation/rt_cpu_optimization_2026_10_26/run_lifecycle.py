#!/usr/bin/env python3
"""Capture RT CPU cache lifecycle states in an isolated user-data directory.

Uses the same timeout/error-handling helpers as the earlier GI regressions.
No output directory is overwritten; compare baseline and candidate with score.py.
"""

import argparse
import importlib.util
import json
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE / "lifecycle"
HELPERS = HERE.parent / "amd_gi_optimization_2026_10_26" / "run_regressions.py"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--require-marker", action="append", default=[])
    args = parser.parse_args()
    args.engine = args.engine.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("regression_helpers", HELPERS)
    assert spec is not None and spec.loader is not None
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("GODOT_AMD_GI_", "GODOT_RT_", "GODOT_RD_TLAS_")) and key != "RT_CPU_OUT"
    }
    configured = {"RT_CPU_OUT": str(args.output), "GODOT_RT_DEBUG": "1", **helpers.assignments(args.env)}
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        isolated = args.output / "user" / key.lower()
        isolated.mkdir(parents=True)
        configured[key] = str(isolated)
    environment.update(configured)
    record = {
        "engine": str(args.engine),
        "engine_sha256": helpers.sha256(args.engine),
        "project_sha256": helpers.sha256(PROJECT / "project.godot"),
        "script_sha256": helpers.sha256(PROJECT / "lifecycle.gd"),
        "environment": configured,
        "passed": False,
    }
    try:
        base = [str(args.engine), "--path", str(PROJECT)]
        record["parse"] = helpers.execute(
            base + ["--headless", "--check-only", "--script", "res://lifecycle.gd"],
            environment,
            PROJECT,
            args.output / "parse.log",
            90,
        )
        helpers.require_clean(record["parse"])
        record["render"] = helpers.execute(
            base
            + [
                "--rendering-driver",
                "vulkan",
                "--audio-driver",
                "Dummy",
                "--windowed",
                "--resolution",
                "641x359",
                "--script",
                "res://lifecycle.gd",
            ],
            environment,
            PROJECT,
            args.output / "run.log",
            180,
        )
        log = helpers.require_clean(record["render"])
        for marker in ["RT_CPU_FIXTURE complete failures=0", "tlas_instances=", *args.require_marker]:
            if marker not in log:
                raise RuntimeError(f"Missing required marker {marker!r}")
        report = json.loads((args.output / "lifecycle.json").read_text())
        expected = re.findall(r'await _stage\("([^"]+)"', (PROJECT / "lifecycle.gd").read_text())
        if report["failures"] or [row["stage"] for row in report["stages"]] != expected:
            raise RuntimeError("Not every lifecycle stage completed in order")
        two_views = {"two_independent_views", "both_views_changed", "source_freed", "source_recreated"}
        for row in report["stages"]:
            if len(row["views"]) != (2 if row["stage"] in two_views else 1):
                raise RuntimeError(f"Unexpected viewport count in {row['stage']}")
            for index in range(len(row["views"])):
                if not (args.output / f"{row['stage']}_{index}.png").is_file():
                    raise RuntimeError(f"Missing capture for {row['stage']}/{index}")
        record["passed"] = True
    finally:
        (args.output / "manifest.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
