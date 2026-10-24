"""Extract completed GPU samples and runtime settings from profile.gd logs."""

import csv
import json
import pathlib
import statistics
import sys
from typing import Any

output = pathlib.Path(__file__).parent
results: dict[str, Any] = {}
frames: list[dict[str, Any]] = []
metrics = (
    "GPU total",
    "AMD GI",
    "Update RT Acceleration Structures",
    "GI TLAS",
    "GI emitter geometry",
    "GI prepare emission",
    "GI prepare masks",
    "GI light grid",
    "GI remaining passes",
)
for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    lines = path.read_text(errors="replace").splitlines()
    assert "DEEP_PROFILE_END" in lines, f"Incomplete run: {path}"
    samples = next(
        json.loads(s.removeprefix("DEEP_PROFILE_SAMPLES ")) for s in lines if s.startswith("DEEP_PROFILE_SAMPLES ")
    )
    assert len(samples) == 90 and all("GPU total" in s for s in samples), "Run with --gpu-profile"
    settings = dict(s.removeprefix("PROFILE_SETTING ").split("=", 1) for s in lines if s.startswith("PROFILE_SETTING "))
    assert settings["rendering/global_illumination/amd_gi/enabled"] == "true"
    assert settings["rendering/global_illumination/amd_gi/emissive_sampling"] == "true"
    results[path.stem] = {
        "engine": lines[0],
        "configuration": next(s for s in lines if s.startswith("DEEP_PROFILE_BEGIN ")),
        "settings": settings,
        "samples": len(samples),
        "metrics_ms": {
            key: {
                "median": statistics.median(s[key] for s in samples),
                "mean": statistics.mean(s[key] for s in samples),
                "p90": sorted(s[key] for s in samples)[int(0.9 * (len(samples) - 1))],
            }
            for key in metrics
            if key in samples[0]
        },
    }
    frames.extend(
        {"run": path.stem, "sample": i, **{k: s[k] for k in metrics if k in s}} for i, s in enumerate(samples)
    )
(output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
with (output / "frames.csv").open("w", newline="") as stream:
    writer = csv.DictWriter(stream, fieldnames=("run", "sample", *metrics))
    writer.writeheader()
    writer.writerows(frames)
for name, result in results.items():
    print(name, {k: round(v["median"], 4) for k, v in result["metrics_ms"].items()})
