#!/usr/bin/env python3
"""Run isolated GPU correctness rigs with explicit completion and image checks.

Example (use a Python environment with Pillow and NumPy):
    python run_regressions.py --engine /path/to/godot --label stage1 \
        --output /path/to/artifacts --rig amd_gi_scene_metadata amd_gi_multimesh amd_gi_deformation

These runs include GPU readbacks and are not performance benchmarks. Linux
needs an existing display (for example, launch this runner under xvfb-run).
The runner never starts a display server or selects a software Vulkan driver.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent / "shadow_validation"
REPOSITORY = HERE.parents[2]
ERROR = re.compile(r"\b(?:SCRIPT\s+)?ERROR\b|\bVK_ERROR_", re.IGNORECASE)
DEFAULT_RIGS = ["amd_gi_scene_metadata", "amd_gi_multimesh", "amd_gi_deformation"]

# Same resolution and diagnostic requirements as shadow_validation/run.sh.
# History is additionally required by the deformation/MultiMesh image scorers.
PRESETS = {
    "amd_gi_scene_metadata": ("321x181", "SCENE_METADATA complete", ("VALIDATE_SCENE_CACHE",)),
    "amd_gi_multimesh": ("641x359", "AMD MultiMesh capture finished: 0 failures", ("VALIDATE_CACHE", "TRACE_HISTORY")),
    "amd_gi_deformation": (
        "641x359",
        "AMD deformation capture finished: 0 failures",
        ("VALIDATE_CACHE", "VALIDATE_MATERIALS", "TRACE_HISTORY"),
    ),
    "amd_gi_light_storage": (
        "321x181",
        "LIGHT_STORAGE complete",
        ("VALIDATE_LIGHT_STORAGE", "VALIDATE_EMITTER_UPDATES"),
    ),
    "amd_gi_reflections": (
        "641x359",
        "AMD reflection capture finished: 0 failures",
        ("VALIDATE_CACHE", "VALIDATE_REFLECTIONS"),
    ),
    "amd_gi_fsr2": ("641x359", "AMD FSR2 capture finished: 0 failures", ()),
    "amd_gi_budget_compare": ("641x359", "AMD budget comparison finished: 0 failures", ("VALIDATE_CACHE",)),
    "amd_gi_exposure": (
        "321x181",
        "AMD exposure integration completed: 0 failures",
        ("VALIDATE_REFLECTIONS", "TRACE_REFLECTION_HISTORY", "TRACE_HISTORY"),
    ),
    "amd_gi_consequential": (
        "321x181",
        "AMD consequential integration completed: 0 failures",
        ("VALIDATE_HITS", "VALIDATE_BOUNCES", "VALIDATE_CACHE"),
    ),
    "amd_gi_options": ("641x359", "AMD_GI_OPTIONS complete failures=0", ()),
    "bindings": ("640x360", "GI_BINDING_FIXTURE complete failures=0", ("VALIDATE_BINDINGS",)),
}


def assignments(values):
    result = {}
    for value in values:
        key, separator, item = value.partition("=")
        if not separator or not key or "\0" in value:
            raise ValueError(f"Expected NAME=VALUE, received {value!r}")
        result[key] = item
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def execute(command, environment, directory, log, timeout):
    """Terminate only the process created here, never matching other processes."""
    start = time.monotonic()
    timed_out = False
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, cwd=directory, env=environment, stdout=output, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if isinstance(error, KeyboardInterrupt):
                raise
            timed_out = True
    return {
        "command": [str(part) for part in command],
        "log": str(log),
        "returncode": process.returncode,
        "timed_out": timed_out,
        "seconds": round(time.monotonic() - start, 3),
    }


def require_clean(result):
    log = Path(result["log"]).read_text(encoding="utf-8", errors="replace")
    errors = [line for line in log.splitlines() if ERROR.search(line)]
    if result["timed_out"] or result["returncode"] != 0 or errors:
        raise RuntimeError(
            f"Process failed: {result['log']}; exit={result['returncode']}, timeout={result['timed_out']}, errors={errors[:5]}"
        )
    return log


def run_rig(args, rig, output, extra_env, completion_overrides, result):
    resolution, completion, flags = PRESETS.get(rig, ("641x359", None, ()))
    completion = completion_overrides.get(rig, completion)
    if not completion:
        raise ValueError(
            f"No completion contract for {rig}; supply --completion {rig}=TEXT after inspecting its fixture"
        )
    if rig not in PRESETS and not args.resolution:
        raise ValueError(
            f"No reference resolution configured for {rig}; supply --resolution and its required --env oracles from run.sh"
        )
    project = HERE / "bindings" if rig == "bindings" else PROJECT
    script = "lifecycle.gd" if rig == "bindings" else f"{rig}.gd"
    scene = project / f"{rig}.tscn"
    if not (project / script).is_file() or (rig != "bindings" and not scene.is_file()):
        raise ValueError(f"Missing fixture script/scene for {rig} in {project}")
    output.mkdir()
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("GODOT_AMD_GI_", "GODOT_RT_")) and key not in ("GI_BINDING_OUT", "SHADOW_OUT_DIR")
    }
    if args.retained_scene:
        # History diagnostics deliberately reconstruct every instance. Separate
        # ordinary runs retain that contract; this mode tests actual retention.
        flags = tuple(flag for flag in flags if flag != "TRACE_HISTORY") + ("TRACE_RETAINED_GROUPS",)
        if extra_env.get("GODOT_AMD_GI_TRACE_HISTORY", ""):
            raise ValueError("--retained-scene cannot enable TRACE_HISTORY, which bypasses retention")
        for flag in ("DISABLE_SCENE_REUSE", "DISABLE_RETAINED_GROUPS", "VALIDATE_SCENE_CACHE"):
            if extra_env.get("GODOT_AMD_GI_" + flag) == "1":
                raise ValueError(f"--retained-scene cannot enable {flag}, which bypasses actual record retention")
    required = {"GODOT_AMD_GI_" + flag: "1" for flag in flags}
    for key, value in required.items():
        if key in extra_env and extra_env[key] != value:
            raise ValueError(f"{rig} requires {key}={value}; custom overrides cannot disable its oracle")
    configured = {**required, **extra_env, "SHADOW_OUT_DIR": str(output), "GI_BINDING_OUT": str(output)}
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        isolated = output / "user" / key.lower()
        isolated.mkdir(parents=True)
        configured[key] = str(isolated)
    environment.update(configured)
    result.update(
        project=str(project),
        fixture=script,
        fixture_sha256=sha256(project / script),
        project_sha256=sha256(project / "project.godot"),
        resolution=args.resolution or resolution,
        environment=configured,
        retained_scene=args.retained_scene,
        completion=completion,
    )
    base = [str(args.engine), "--path", str(project)]
    result["parse"] = execute(
        base + ["--headless", "--check-only", "--script", f"res://{script}"],
        environment,
        project,
        output / "parse.log",
        args.parse_timeout,
    )
    require_clean(result["parse"])
    command = base + [
        "--rendering-driver",
        "vulkan",
        "--audio-driver",
        "Dummy",
        "--windowed",
        "--resolution",
        result["resolution"],
    ]
    command += ["--script", "res://lifecycle.gd"] if rig == "bindings" else [f"res://{rig}.tscn"]
    result["render"] = execute(command, environment, project, output / "run.log", args.timeout)
    log = require_clean(result["render"])
    if completion not in log:
        raise RuntimeError(f"Missing completion marker {completion!r} in {output / 'run.log'}")
    if "GI is suppressed" in log:
        raise RuntimeError("Fixture suppressed GI; inspect run.log")
    if args.retained_scene:
        retained = [int(value) for value in re.findall(r"AMD GI retained groups:.*?reused_surfaces=(\d+)", log)]
        if not retained or max(retained) == 0:
            raise RuntimeError("Retained-scene image test never used the actual retained-record path")
        result["retained_surface_max"] = max(retained)
    if rig == "amd_gi_scene_metadata" and "hit_records_match=true hit_upload_match=true" not in log:
        raise RuntimeError("Scene metadata fixture did not report the hit-record/upload oracle")
    if rig == "bindings":
        if "AMDGI bindings oracle: checked=true" not in log:
            raise RuntimeError(
                "No actual cached-descriptor oracle check ran; an older engine cannot validate this fixture"
            )
        report = json.loads((output / "lifecycle.json").read_text(encoding="utf-8"))
        stages = report.get("stages", [])
        expected = re.findall(r'await _stage\("([^"]+)"', (project / script).read_text(encoding="utf-8"))
        if report.get("failures") != 0 or not expected or [stage.get("stage") for stage in stages] != expected:
            raise RuntimeError("Binding lifecycle report did not complete every fixture stage in order")
        two_views = {"two_independent_viewports", "second_viewport_resize", "viewport_recreated"}
        if any(len(stage.get("views", [])) != (2 if stage["stage"] in two_views else 1) for stage in stages):
            raise RuntimeError("Binding lifecycle report has incomplete viewport coverage")
    scorer = PROJECT / f"score_{rig}.py"
    score_args = [str(output)]
    if rig == "amd_gi_light_storage":
        score_args = [str(output / "run.log")]
    if rig in ("amd_gi_consequential", "amd_gi_exposure"):
        scorer = PROJECT / "score_amd_gi_integration.py"
        score_args.append(rig)
    if args.retained_scene and rig in ("amd_gi_multimesh", "amd_gi_deformation"):
        score_args.append("--retained-scene")
    if args.retained_scene and rig == "amd_gi_light_storage":
        checked = log.split("LIGHT_STORAGE checked", 1)[-1]
        records = [
            {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}
            for line in checked.splitlines()
            if line.startswith("AMD GI retained groups:")
        ]
        complete = [
            record
            for record in records
            if record.get("reused_surfaces", 0) > 0
            and record["reused_surfaces"] == record.get("total_surfaces")
            and record.get("reused_emitter_batches", 0) > 0
            and record.get("reused_emitter_triangles", 0) > 0
        ]
        if len(complete) < 2:
            raise RuntimeError("Light-storage GPU oracle did not exercise complete actual scene/emitter retention")
        result["complete_emitter_retention_updates"] = len(complete)
    if scorer.is_file():
        result["score"] = execute(
            [sys.executable, str(scorer), *score_args], environment, project, output / "score.log", args.scorer_timeout
        )
        require_clean(result["score"])
    elif rig not in ("amd_gi_scene_metadata", "amd_gi_options", "bindings"):
        raise RuntimeError(f"No image scorer configured for {rig}; add its contract before accepting this run")
    result["captures"] = sorted(path.name for path in output.glob("*.png"))
    result["passed"] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument(
        "--label", required=True, help="Unique artifact subdirectory name; existing runs are never overwritten"
    )
    parser.add_argument("--output", type=Path, default=REPOSITORY / ".artifacts" / "amd-gi-optimization-regressions")
    parser.add_argument(
        "--rig",
        nargs="+",
        default=DEFAULT_RIGS,
        help="Default: scene_metadata, multimesh, deformation; also supports bindings",
    )
    parser.add_argument(
        "--env", action="append", default=[], metavar="NAME=VALUE", help="Additional environment variable, repeatable"
    )
    parser.add_argument(
        "--completion",
        action="append",
        default=[],
        metavar="RIG=TEXT",
        help="Explicit completion contract for another existing scored rig",
    )
    parser.add_argument("--resolution", help="Deliberate override of each fixture's reference resolution")
    parser.add_argument("--timeout", type=float, default=1800, help="Maximum seconds per rendered rig")
    parser.add_argument("--parse-timeout", type=float, default=120)
    parser.add_argument("--scorer-timeout", type=float, default=120)
    parser.add_argument("--keep-going", action="store_true", help="Run remaining selected fixtures after a failure")
    parser.add_argument(
        "--retained-scene",
        action="store_true",
        help="Run MultiMesh/deformation images or light-storage GPU oracle with actual retention; ordinary history runs remain separate",
    )
    args = parser.parse_args()
    args.engine = args.engine.resolve()
    if not args.engine.is_file():
        parser.error(f"Engine does not exist: {args.engine}")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.label):
        parser.error(
            "Label must contain only letters, digits, underscores, dots or dashes and begin with a letter/digit"
        )
    if len(set(args.rig)) != len(args.rig) or any(not re.fullmatch(r"[A-Za-z0-9_]+", rig) for rig in args.rig):
        parser.error("Fixture names must be unique and contain only letters, digits or underscores")
    if args.retained_scene and any(
        rig not in ("amd_gi_multimesh", "amd_gi_deformation", "amd_gi_light_storage") for rig in args.rig
    ):
        parser.error("--retained-scene requires MultiMesh, deformation and/or light-storage rigs")
    if args.resolution and not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", args.resolution):
        parser.error("Resolution must be WIDTHxHEIGHT")
    if min(args.timeout, args.parse_timeout, args.scorer_timeout) <= 0:
        parser.error("Timeouts must be positive")
    try:
        extra_env, completions = assignments(args.env), assignments(args.completion)
    except ValueError as error:
        parser.error(str(error))
    output = (args.output / args.label).resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest = {
        "label": args.label,
        "engine": str(args.engine),
        "engine_sha256": sha256(args.engine),
        "runner_sha256": sha256(Path(__file__)),
        "platform": platform.platform(),
        "python": sys.version,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "results": [],
        "retained_scene": args.retained_scene,
        "passed": False,
    }
    manifest_path = output / "manifest.json"
    try:
        for rig in args.rig:
            print(f"Running {rig}; logs: {output / rig}", flush=True)
            result = {"rig": rig, "passed": False}
            manifest["results"].append(result)
            try:
                run_rig(args, rig, output / rig, extra_env, completions, result)
            except (OSError, ValueError, RuntimeError) as error:
                result["failure"] = str(error)
                print(f"FAIL {rig}: {error}", flush=True)
                if not args.keep_going:
                    break
            else:
                print(f"PASS {rig}", flush=True)
            finally:
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        manifest["passed"] = len(manifest["results"]) == len(args.rig) and all(
            item["passed"] for item in manifest["results"]
        )
    except KeyboardInterrupt:
        manifest["interrupted"] = True
    finally:
        manifest["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Manifest: {manifest_path}")
    return 0 if manifest["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
