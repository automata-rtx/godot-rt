#!/usr/bin/env python3
"""Reject emitter regeneration caused solely by analytic-light membership."""

import re
import sys
from pathlib import Path


def check(text: str) -> str:
    if "ERROR:" in text or "SCRIPT ERROR" in text:
        raise ValueError("engine or script error in validation log")
    before, separator, checked = text.partition("LIGHT_STORAGE checked")
    if not separator or "LIGHT_STORAGE complete" not in checked:
        raise ValueError("fixture did not complete its checked section")
    pattern = re.compile(
        r"AMD GI light storage: reference=(\d+) lights=(\d+) capacity=(\d+) "
        r"full=(\d+) dispatches=(\d+) emitters=(\d+)"
    )
    warmup = [tuple(map(int, match)) for match in pattern.findall(before)]
    if not any(reference == 0 and dispatches > 0 for reference, _, _, _, dispatches, _ in warmup):
        raise ValueError("no initial normal-path emitter construction observed")
    records = [tuple(map(int, match)) for match in pattern.findall(checked)]
    normal = [record for record in records if record[0] == 0]
    reference = [record for record in records if record[0] == 1]
    if len(normal) < 80 or len(reference) < len(normal):
        raise ValueError("insufficient normal/reference update coverage")
    repacked = [int(value) for value in re.findall(r"AMD GI transform cache: repacked=(\d+)", checked)]
    if len(repacked) < len(normal) or any(repacked):
        raise ValueError("analytic lights or rejected flares repacked static instance transforms")
    if any(full != 0 or dispatches != 0 or emitters <= 0 for _, _, _, full, dispatches, emitters in normal):
        raise ValueError("analytic-only update regenerated normal-path emitters")
    if any(full != 1 or dispatches <= 0 for _, _, _, full, dispatches, _ in reference):
        raise ValueError("full-regeneration reference was not exercised")
    if len({record[5] for record in records}) != 1:
        raise ValueError("fixture changed emitter membership")
    if not {0, 1, 2, 3, 5, 9, 17}.issubset({record[1] for record in normal}):
        raise ValueError("missing analytic-count transitions")
    capacities = [record[2] for record in normal]
    if capacities != sorted(capacities) or any(count > capacity for _, count, capacity, _, _, _ in normal):
        raise ValueError("analytic allocation shrank or overflowed")
    copies = [
        tuple(map(int, match))
        for match in re.findall(
            r"AMD GI light storage copy: lights=(\d+) capacity=(\d+) emitters=(\d+) bytes=(\d+)", checked
        )
    ]
    if not {2, 4, 8, 16, 32}.issubset({capacity for _, capacity, _, _ in copies}):
        raise ValueError("missing retained-emitter copies across allocation boundaries")
    if any(size != emitters * 64 or emitters <= 0 for _, _, emitters, size in copies):
        raise ValueError("incorrect retained-emitter copy extent")
    oracle = re.findall(r"AMD GI emitter validation: triangles=(\d+) matches=(\w+)", checked)
    if len(oracle) < len(normal) or any(matches != "true" or int(count) <= 0 for count, matches in oracle):
        raise ValueError("missing or failed emitter byte-equivalence oracle")
    for stage in ["same count different light identity", "same count newly allocated light", "blink 7 off"]:
        if "LIGHT_STORAGE stage " + stage not in checked:
            raise ValueError("missing fixture stage: " + stage)
    stages = re.split(r"LIGHT_STORAGE stage ([^\r\n]+)\r?\n", checked)
    for index in range(1, len(stages), 2):
        label, output = stages[index : index + 2]
        if label.startswith("active count "):
            expected_count = int(label.removeprefix("active count "))
        elif label in {"zero analytic lights", "negative analytic light excluded"}:
            expected_count = 0
        elif label in {
            "one analytic light restored",
            "positive analytic light restored",
            "unchanged after blinks",
        } or label.endswith(" off"):
            expected_count = 1
        else:
            expected_count = 2
        stage_normal = [tuple(map(int, match)) for match in pattern.findall(output) if match[0] == "0"]
        if not stage_normal or stage_normal[-1][1] != expected_count:
            raise ValueError(f"stage {label!r} did not settle at {expected_count} analytic lights")
    return f"PASS: {len(normal)} analytic-only updates, zero normal emitter dispatches, {len(copies)} preserved-buffer copies"


if __name__ == "__main__":
    try:
        print(check(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")))
    except (OSError, ValueError, IndexError) as error:
        raise SystemExit(f"FAIL: {error}") from error
