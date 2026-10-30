// Optional, owner-authorized temporal-response experiment. The zero-flag path
// retains AMD's equations. State is one byte: direction/streak in the low
// nibble, a gradually decaying confirmed-change confidence in the high nibble.
// An absent observation is not evidence of darkening.
uint gi_response_update(uint state, float old_luma, float new_luma) {
	uint confidence = state >> 4u;
	confidence -= min(confidence, 1u);
	float delta = new_luma - old_luma;
	float threshold = max(0.35 * max(old_luma, new_luma), 0.02);
	uint streak = 0u;
	if (abs(delta) > threshold) {
		uint direction = delta < 0.0 ? 8u : 0u;
		streak = (state & 8u) == direction ? min((state & 3u) + 1u, 3u) : 1u;
		if (streak == 3u) {
			confidence = 15u;
		}
		streak |= direction;
	}
	return (confidence << 4u) | streak;
}
float gi_response_confidence(uint state) {
	return float(state >> 4u) / 15.0;
}
uint gi_response_decay(uint state) {
	uint confidence = state >> 4u;
	return ((confidence - min(confidence, 1u)) << 4u) | (state & 15u);
}
float gi_cache_detail_blend(float count, float threshold) {
	return smoothstep(0.75 * threshold, threshold, count);
}
float gi_probe_priority(uint age, uint span, bool missing, float change) {
	bool overdue = !missing && age >= span * span;
	// Confidence describes an observed change, including a JUST refreshed
	// probe. Prioritizing confidence alone repeatedly traces that same probe.
	float demand_age = float(min(age - min(age, 1u), span * span)) / float(span * span);
	return overdue ? 1024.0 + float(min(age, 1024u)) : (missing ? 512.0 : change * demand_age * 16.0 + float(min(age, 64u)));
}

// One byte per cell, padded to 88 bytes per tile. Append to the existing cache
// binding, with no new descriptor or RGB cache. Four cell owners share each
// word, so both reads during update and masked writes must be atomic.
uint gi_response_word(uint cell) {
	return TILE_COUNT * TILE_CELLS * 2u + (cell / TILE_CELLS) * 22u + (cell % TILE_CELLS) / 4u;
}
uint gi_cache_response(uint cell, bool indirect) {
	uint word = gi_response_word(cell);
#if AMD_GI_PASS == PASS_UPDATE || AMD_GI_PASS == PASS_UPDATE_INDIRECT
	uint value = indirect ? atomicAdd(indirect_cache.data[word / 2u][word & 1u], 0u) : atomicAdd(cache.data[word / 2u][word & 1u], 0u);
#else
	// Mip passes read disjoint child words; resolve runs after all writes.
	// Those consumers need ordinary loads, not serialized atomic reads.
	uint value = indirect ? indirect_cache.data[word / 2u][word & 1u] : cache.data[word / 2u][word & 1u];
#endif
	return (value >> ((cell % TILE_CELLS & 3u) * 8u)) & 255u;
}
void gi_store_cache_response(uint cell, bool indirect, uint state) {
	uint word = gi_response_word(cell);
	uint shift = (cell % TILE_CELLS & 3u) * 8u;
	uint mask = 255u << shift;
	// AND/OR preserve other bytes, including simultaneous neighboring writes.
	if (indirect) {
		atomicAnd(indirect_cache.data[word / 2u][word & 1u], ~mask);
		atomicOr(indirect_cache.data[word / 2u][word & 1u], state << shift);
	} else {
		atomicAnd(cache.data[word / 2u][word & 1u], ~mask);
		atomicOr(cache.data[word / 2u][word & 1u], state << shift);
	}
}

// Follow the same mip choice as the radiance lookup. Parent confidence is
// evidence-weighted during mip construction; a lone changing fine cell cannot
// declare an entire parent estimate newly lit.
float gi_cache_change(uint cell, bool indirect) {
	if (cell == INVALID || (frame.options.z & 1u) == 0u) {
		return 0.0;
	}
	uint tile = cell / TILE_CELLS;
	uvec2 coord = uvec2(cell % TILE_CELLS % 8u, cell % TILE_CELLS / 8u);
	float finer_count = 0.0, finer_change = 0.0;
	for (uint mip = 0u; mip < 4u; mip++) {
		uvec2 p = coord >> mip;
		uint index = tile * TILE_CELLS + MIP_OFFSET[mip] + p.x + p.y * (8u >> mip);
		float count = gi_cache_unpack(indirect ? indirect_cache.data[index] : cache.data[index]).w;
		float change = gi_response_confidence(gi_cache_response(index, indirect));
		if (count >= frame.tuning.x || mip == 3u) {
			if ((frame.options.z & 4u) != 0u && finer_count > 0.75 * frame.tuning.x && count > 0.0) {
				change = mix(change, finer_change, gi_cache_detail_blend(finer_count, frame.tuning.x));
			}
			return count > 0.0 ? change : 0.0;
		}
		finer_count = count;
		finer_change = change;
	}
	return 0.0;
}
