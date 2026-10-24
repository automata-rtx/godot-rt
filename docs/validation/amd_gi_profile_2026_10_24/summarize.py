import json
import pathlib
import statistics
import sys

for f in sys.argv[1:]:
    p = pathlib.Path(f)
    lines = p.read_text(errors="replace").splitlines()
    data = [
        json.loads(line.split("DEEP_PROFILE_SAMPLES ", 1)[1])
        for line in lines
        if line.startswith("DEEP_PROFILE_SAMPLES ")
    ]
    if not data:
        print(p.stem, "NO SAMPLES")
        continue
    rows = data[0]
    result = {
        k: {
            "median": statistics.median([r.get(k, 0) for r in rows]),
            "mean": statistics.mean([r.get(k, 0) for r in rows]),
            "p90": sorted([r.get(k, 0) for r in rows])[int(0.9 * (len(rows) - 1))],
        }
        for k in rows[0]
    }
    p.with_suffix(".json").write_text(json.dumps({"frames": len(rows), "metrics": result}, indent=2))
    print(p.stem, len(rows), [(k, round(v["median"], 3)) for k, v in result.items() if v["median"] > 0.2])
