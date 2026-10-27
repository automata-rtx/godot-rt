#!/usr/bin/env python3
"""Require current-record oracles on the actual mutated fixture subjects."""

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

REQUIRED = {
    "mesh": [
        "unchanged metadata with TIME advancing",
        "shared local uniform only",
        "global and instance values only",
        "recovery after discarded partial preparation",
        "same texture resource pixels",
        "same Texture2D resource replaced RD image",
        "different texture binding",
        "uniform buffer layout grows",
        "original shader layout restored",
        "retained subjects write emission",
        "emissive sampling disabled",
        "emissive sampling restored",
        "emission removed restores retained subjects",
        "emission restored rebuilds retained emitter ranges",
        "configured emission mode restored",
        "UV attribute region without dependency notification",
        "vertex region without dependency notification",
        "earlier emitter triangle count changes downstream prefixes",
        "earlier emitter membership removed",
        "earlier emitter membership restored",
        "earlier emitter source restored",
    ],
    "multimesh": [
        "MultiMesh added",
        "earlier emitter triangle count changes downstream prefixes",
        "earlier emitter membership removed",
        "earlier emitter membership restored",
        "earlier emitter source restored",
        "MultiMesh shadow mask disabled",
        "MultiMesh material override",
        "MultiMesh material and shadow mask restored",
        "MultiMesh color and custom data only",
        "visible nonfirst MultiMesh element moves with count unchanged",
        "MultiMesh bulk transforms colors and custom data",
        "retained MultiMesh bulk replacement",
        "MultiMesh resource identity restored",
        "one shared MultiMesh parent moves",
        "custom AABB bulk write after cached expansion",
        "same MultiMesh identity reallocates data layout",
    ],
}


def score(log):
    subjects = {}
    counts = defaultdict(Counter)
    positive_emitters = defaultdict(Counter)
    zero_emitters = defaultdict(Counter)
    mode_match = re.search(r"RETAINED_METADATA mode (nonemissive|emissive)", log)
    mode = mode_match[1] if mode_match else None
    stage = "startup"
    deferred_identity = None
    deferred_failures = 0
    for line in log.splitlines():
        if line.startswith("SCENE_METADATA stage "):
            stage = line.removeprefix("SCENE_METADATA stage ").strip()
        match = re.search(r"RETAINED_METADATA subject (mesh|multimesh) (.+)", line)
        if match:
            subjects[match[1]] = match[2].strip()
        match = re.search(r"RETAINED_METADATA subject deferred (.+)", line)
        if match:
            deferred_identity = match[1].strip()
        match = re.search(r"AMD GI retained preparation deferred: instance=(.*?) surface=\d+", line)
        if match and match[1] == deferred_identity and stage == "late geometry failure after earlier record writes":
            deferred_failures += 1
        match = re.search(
            r"AMD GI retained group oracle: instance=(.*?) multimesh=.*? inputs=(\d+) surfaces=(\d+) matches=true"
            r"(?: batches=(\d+) triangles=(\d+))?",
            line,
        )
        if match and int(match[2]) > 0 and int(match[3]) > 0:
            for kind, identity in subjects.items():
                if match[1] == identity:
                    counts[kind][stage] += 1
                    if match[4] is not None and match[5] is not None:
                        batches, triangles = int(match[4]), int(match[5])
                        if batches > 0 and triangles > 0:
                            positive_emitters[kind][stage] += 1
                        elif batches == 0 and triangles == 0:
                            zero_emitters[kind][stage] += 1
    failures = []
    if re.search(r"\b(?:SCRIPT\s+)?ERROR\b|VK_ERROR_", log):
        failures.append("Engine log contains an error")
    if "SCENE_METADATA complete" not in log:
        failures.append("Missing fixture completion")
    if mode is None:
        failures.append("Missing subject emission mode")
    if deferred_failures < 2:
        failures.append("The late geometry source did not exercise repeated preparation failure")
    for kind, stages in REQUIRED.items():
        if kind not in subjects:
            failures.append(f"Missing {kind} subject identity")
        for name in stages:
            # Two checks prevent an in-flight previous frame from providing the
            # only apparent hit after a mutation's stage marker.
            if counts[kind][name] < 2:
                failures.append(f"{kind}: fewer than two retained candidate checks in {name!r}")
    zero_stages = {
        "mesh": {"emissive sampling disabled", "emission removed restores retained subjects"},
        "multimesh": {"MultiMesh material override"},
    }
    positive_stages = {
        "mesh": {
            "retained subjects write emission",
            "emissive sampling restored",
            "emission restored rebuilds retained emitter ranges",
        },
        "multimesh": set(),
    }
    if mode == "emissive":
        for kind, stages in REQUIRED.items():
            positive_stages[kind].update(set(stages) - zero_stages[kind])
    elif mode == "nonemissive":
        for kind, stages in REQUIRED.items():
            zero_stages[kind].update(set(stages) - positive_stages[kind])
    for kind, stages in positive_stages.items():
        for name in sorted(stages):
            if positive_emitters[kind][name] < 2:
                failures.append(f"{kind}: missing positive retained emitter batch/triangle oracles in {name!r}")
    for kind, stages in zero_stages.items():
        for name in sorted(stages):
            if zero_emitters[kind][name] < 2:
                failures.append(f"{kind}: missing zero-emitter retained oracles in {name!r}")
    return {
        "passed": not failures,
        "mode": mode,
        "subjects": subjects,
        "checks": counts,
        "positive_emitter_checks": positive_emitters,
        "zero_emitter_checks": zero_emitters,
        "deferred_failures": deferred_failures,
        "failures": failures,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    result = score(args.log.read_text(encoding="utf-8", errors="replace"))
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
