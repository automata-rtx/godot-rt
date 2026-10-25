// Optional GI cache statistics. No atomics execute when debug statistics are off.
// Layout: 16 header words, per-bucket failed allocation attempt counts,
// then occupancy and overflow-attempt histograms (bucket capacity + 1 each).
layout(set = 0, binding = 65, std430) restrict buffer DebugStatistics {
	uint values[];
}
debug_statistics;

void debug_cache_overflow(uint bucket) {
	if ((frame.debug_options.z & 1u) != 0u) {
		atomicAdd(debug_statistics.values[0], 1u);
		atomicAdd(debug_statistics.values[16u + bucket], 1u);
	}
}
