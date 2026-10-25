#!/usr/bin/env python3
"""Validate raw AMD GI debug counter snapshots without starting the engine.

Usage: score_amd_gi_debug_stats.py snapshot.bin --buckets N --capacity 16
The raw uint32 little-endian buffer is binding65 from PASS_DEBUG_STATS.
With --self-test, checks synthetic valid/invalid snapshots only, not GPU behavior.
"""

import argparse
import struct
from pathlib import Path


def score(values, buckets, capacity):
    assert buckets > 0 and capacity > 0, "invalid cache layout"
    assert len(values) == 16 + buckets + 2 * (capacity + 1), "buffer size mismatch"
    overflow = values[16 : 16 + buckets]
    occupancy_histogram = values[16 + buckets : 17 + buckets + capacity]
    overflow_histogram = values[17 + buckets + capacity :]
    assert sum(occupancy_histogram) == buckets, "occupancy histogram loses buckets"
    assert sum(overflow_histogram) == buckets, "overflow histogram loses buckets"
    assert sum(overflow) == values[0], "overflow attempt total mismatch"
    assert sum(i * n for i, n in enumerate(occupancy_histogram)) == values[1], "tile total mismatch"
    assert buckets - occupancy_histogram[0] == values[2], "used bucket mismatch"
    assert occupancy_histogram[-1] == values[12], "full bucket mismatch"
    expected_overflow_histogram = [0] * (capacity + 1)
    for attempts in overflow:
        expected_overflow_histogram[min(attempts, capacity)] += 1
    assert expected_overflow_histogram == list(overflow_histogram), "overflow histogram bins mismatch"
    assert values[3] <= values[1] * 64, "sampled cells exceed occupied tiles"
    sample_sum = values[4] + (values[5] << 32)
    assert values[3] <= sample_sum <= values[3] * values[6], "sample sum/count mismatch"
    assert values[7] <= values[1], "active tiles exceed occupied tiles"
    assert values[9] <= values[8], "updated probes exceed valid probes"
    assert values[14] == buckets * capacity * 64, "cache capacity mismatch"
    return {"occupied_tiles": values[1], "sampled_cells": values[3], "sample_sum": sample_sum}


def self_test():
    # Four buckets with occupancy 0,1,2,2; overflow attempts 0,0,1,5.
    valid = [0] * (16 + 4 + 2 * 3)
    valid[:15] = [6, 5, 3, 64, 128, 0, 2, 4, 10, 3, 12, 5, 2, 19, 512]
    valid[16:] = [0, 0, 1, 5, 1, 1, 2, 2, 1, 1]
    score(valid, 4, 2)
    rejected = 0
    for word, wrong in (
        (0, 5),
        (1, 4),
        (2, 4),
        (3, 400),
        (4, 129),
        (7, 6),
        (9, 11),
        (12, 1),
        (14, 1),
        (20, 0),
        (24, 0),
    ):
        bad = valid.copy()
        bad[word] = wrong
        try:
            score(bad, 4, 2)
        except AssertionError:
            rejected += 1
        else:
            raise AssertionError(f"corrupt word {word} was accepted")
    # Real capacities can accumulate more than uint32 samples. Verify high word
    # preservation; do not silently truncate the GPU's atomic carry.
    huge = [0] * (16 + 1024 + 2 * 17)
    huge[1:8] = [16384, 1024, 1048576, 0, 8, 32768, 16384]
    huge[12] = 1024
    huge[14] = 1048576
    huge[16 + 1024 + 16] = 1024
    huge[16 + 1024 + 17] = 1024
    assert score(huge, 1024, 16)["sample_sum"] == 1 << 35
    print(f"PASS: 2 synthetic snapshots accepted; {rejected} corrupt snapshots rejected")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", nargs="?", type=Path)
    parser.add_argument("--buckets", type=int, default=4096)
    parser.add_argument("--capacity", type=int, default=16)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.snapshot:
        raw = args.snapshot.read_bytes()
        assert len(raw) % 4 == 0, "incomplete uint32 snapshot"
        print(score(struct.unpack(f"<{len(raw) // 4}I", raw), args.buckets, args.capacity))
    else:
        parser.error("provide snapshot.bin or --self-test")


if __name__ == "__main__":
    main()
