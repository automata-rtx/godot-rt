#!/usr/bin/env python3
"""Run the native TLAS reuse and upload-lifetime fixtures with isolated user data.

Use --env GODOT_RT_VALIDATE_TLAS_REUSE=1 for a candidate oracle run, or
--env GODOT_RT_DISABLE_TLAS_REUSE=1 for its original-path comparison.
No output directory is overwritten. These are correctness tests, not benchmarks.
"""

import argparse
import importlib.util
import json
import os
import platform
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent / "shadow_validation"
HELPERS = HERE.parent / "amd_gi_optimization_2026_10_26" / "run_regressions.py"
FIXTURES = {
    "tlas_cpu_reuse": "RT TLAS CPU reuse: 136 queued ray queries, 0 failures",
    "tlas_instance_upload_lifetime": "TLAS upload lifetime: 24 queued ray queries, 0 failures",
}
ORACLE_MARKER = "RT TLAS reuse oracle: checked=true"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--parse-timeout", type=float, default=90)
    args = parser.parse_args()
    args.engine = args.engine.resolve()
    args.output = args.output.resolve()
    if not args.engine.is_file():
        parser.error(f"Engine does not exist: {args.engine}")
    if min(args.timeout, args.parse_timeout) <= 0:
        parser.error("Timeouts must be positive")
    spec = importlib.util.spec_from_file_location("regression_helpers", HELPERS)
    assert spec is not None and spec.loader is not None
    helpers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    try:
        extra_env = helpers.assignments(args.env)
    except ValueError as error:
        parser.error(str(error))
    require_oracle = extra_env.get("GODOT_RT_VALIDATE_TLAS_REUSE") == "1"
    if require_oracle and extra_env.get("GODOT_RT_DISABLE_TLAS_REUSE") == "1":
        parser.error("A bypass run cannot exercise the retained-cache oracle; run the modes separately")
    args.output.mkdir(parents=True, exist_ok=False)
    record = {
        "engine": str(args.engine),
        "engine_sha256": helpers.sha256(args.engine),
        "runner_sha256": helpers.sha256(Path(__file__)),
        "project_sha256": helpers.sha256(PROJECT / "project.godot"),
        "platform": platform.platform(),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "require_oracle": require_oracle,
        "results": [],
        "passed": False,
    }
    try:
        for fixture, completion in FIXTURES.items():
            output = args.output / fixture
            output.mkdir()
            environment = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith(("GODOT_AMD_GI_", "GODOT_RT_", "GODOT_RD_TLAS_"))
                and key not in ("RT_CPU_OUT", "SHADOW_OUT_DIR", "GI_BINDING_OUT")
            }
            configured = dict(extra_env)
            for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
                isolated = output / "user" / key.lower()
                isolated.mkdir(parents=True)
                configured[key] = str(isolated)
            environment.update(configured)
            result = {
                "fixture": fixture,
                "fixture_sha256": helpers.sha256(PROJECT / f"{fixture}.gd"),
                "environment": configured,
                "completion": completion,
                "passed": False,
            }
            record["results"].append(result)
            base = [str(args.engine), "--path", str(PROJECT)]
            script = ["--script", f"res://{fixture}.gd"]
            print(f"Running {fixture}; logs: {output}", flush=True)
            try:
                result["parse"] = helpers.execute(
                    base + ["--headless", "--check-only"] + script,
                    environment,
                    PROJECT,
                    output / "parse.log",
                    args.parse_timeout,
                )
                helpers.require_clean(result["parse"])
                result["render"] = helpers.execute(
                    base
                    + [
                        "--rendering-driver",
                        "vulkan",
                        "--audio-driver",
                        "Dummy",
                        "--windowed",
                        "--resolution",
                        "320x180",
                    ]
                    + script,
                    environment,
                    PROJECT,
                    output / "run.log",
                    args.timeout,
                )
                log = helpers.require_clean(result["render"])
                required = [completion, ORACLE_MARKER] if require_oracle else [completion]
                for marker in required:
                    if marker not in log:
                        raise RuntimeError(f"Missing required marker {marker!r}")
                result["passed"] = True
            except (OSError, ValueError, RuntimeError) as error:
                result["failure"] = str(error)
                print(f"FAIL {fixture}: {error}", flush=True)
        record["passed"] = all(result["passed"] for result in record["results"])
    finally:
        (args.output / "manifest.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(json.dumps(record, indent=2))
    return 0 if record["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
