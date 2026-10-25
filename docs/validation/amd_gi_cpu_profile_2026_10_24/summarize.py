"""Summarize the single authorized Live World CPU profiling run."""

import csv
import json
import pathlib
import statistics
import sys
from typing import Any

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(__file__).parent
phases: dict[str, Any] = {}
phase = None
metadata = []
for line in source.read_text(errors="replace").splitlines():
    if line.startswith(("Godot Engine", "Vulkan", "CPU_CONFIG", "CPU_NPCS")):
        metadata.append(line)
    if line.startswith("CPU_BEGIN "):
        phase = line.removeprefix("CPU_BEGIN ")
        phases[phase] = {"details": []}
    elif line.startswith("CPU_DETAIL ") and phase:
        phases[phase]["details"].append(json.loads(line.removeprefix("CPU_DETAIL ")))
    elif line.startswith("CPU_SAMPLES "):
        row = json.loads(line.removeprefix("CPU_SAMPLES "))
        phases[row["phase"]]["samples"] = row
        phase = None
assert "CPU_PROFILE_END" in source.read_text(errors="replace")
keys = ("cpu/Update RT Acceleration Structures", "cpu/AMD GI", "cpu/render_span", "gpu/frame")
summary: dict[str, Any] = {"metadata": metadata, "exit_code": 0, "phases": {}}
render_rows: list[dict[str, Any]] = []
detail_rows: list[dict[str, Any]] = []
wall_rows: list[dict[str, Any]] = []
for name, data in phases.items():
    samples = data["samples"]
    details = data["details"]
    summary["phases"][name] = {
        "wall_frames": len(samples["wall"]),
        "render_frames": len(samples["render"]),
        "detail_frames": len(details),
        "wall_median_ms": statistics.median(samples["wall"]),
        "render_median_ms": {k: statistics.median(r.get(k, 0) for r in samples["render"]) for k in keys},
        "detail_median": {k: statistics.median(r[k] for r in details) for k in details[0] if k != "frame"},
    }
    render_rows.extend(
        {"phase": name, "sample": i, **{k: r.get(k, 0) for k in keys}} for i, r in enumerate(samples["render"])
    )
    detail_rows.extend({"phase": name, **r} for r in details)
    wall_rows.extend({"phase": name, "sample": i, "wall_ms": v} for i, v in enumerate(samples["wall"]))
(output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
for name, rows in (("render", render_rows), ("detail", detail_rows), ("wall", wall_rows)):
    with (output / f"{name}.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
print("Saved three completed phases; detailed timings include instrumentation overhead.")
