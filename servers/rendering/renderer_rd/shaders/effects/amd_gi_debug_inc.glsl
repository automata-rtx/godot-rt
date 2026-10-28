/**********************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

// Godot presentation of AMD GI-1.2 diagnostics. Probe layouts, cache sum/count
// normalization, adaptive mip selection, filtering gain and heat palette follow
// Capsaicin gi1.frag / gi1.vert / hash_grid_cache.hlsl at 914b91596cd119eda.
// Cache views are paged atlases of actual occupied tiles: no guessed lookup from
// a primary surface normal into the directional world cache is performed.
#if AMD_GI_PASS == PASS_DEBUG_VIEW
layout(rgba16f, set = 0, binding = 64) uniform restrict writeonly image2D debug_output;
layout(set = 0, binding = 67) uniform sampler2D debug_reflection;

vec3 debug_heat(float value) {
	float v = clamp(value, 0.0, 1.0);
	// Reverse-edge smoothstep is undefined in GLSL; invert the increasing form.
	return vec3(1.0 - smoothstep(0.0, 1.0, v), smoothstep(0.5, 0.8, v), v > 0.5 ? 1.0 - smoothstep(0.5, 1.0, v) : smoothstep(0.0, 0.5, v));
}
vec3 debug_radiance(vec3 value) {
	// Display transfer only: debug output is copied after scene tonemapping.
	return pow(max(value * exp2(frame.debug_settings.x), vec3(0.0)), vec3(1.0 / 2.2));
}
vec4 debug_cell(uint tile, uvec2 coord, uint mip, bool indirect) {
	uvec2 p = coord >> mip;
	uint cell = tile * TILE_CELLS + MIP_OFFSET[mip] + p.x + p.y * (8u >> mip);
	return gi_cache_unpack(indirect ? indirect_cache.data[cell] : cache.data[cell]);
}
vec4 debug_filtered_cell(uint tile, uvec2 coord, bool indirect, out uint selected_mip) {
	vec4 value = vec4(0);
	for (uint mip = 0u; mip < 4u; mip++) {
		value = debug_cell(tile, coord, mip, indirect);
		selected_mip = mip;
		if (value.w >= frame.tuning.x || mip == 3u) {
			break;
		}
	}
	return value;
}
vec3 debug_normalized(vec4 value) {
	return value.rgb / max(value.w, 1.0);
}
void debug_view(ivec2 pixel) {
	if (any(greaterThanEqual(pixel, ivec2(params.size)))) {
		return;
	}
	uint mode = frame.debug_options.x;
	vec3 color = vec3(0);
	if ((mode == 2u || mode == 23u) && frame.options.y == 0u) {
		// Disabled reflections bind harmless tiny placeholders, never index them
		// using viewport dimensions or interpret stale buffers from an older run.
		color = vec3(0);
	} else if (mode == 2u) {
		color = debug_radiance(texelFetch(debug_reflection, pixel, 0).rgb / max(params.exposure, 0.000001));
	} else if (mode >= 3u && mode <= 6u) {
		uvec2 p = uvec2(pixel);
		uvec2 tile = mode == 4u ? p % frame.grid.xy : p / 8u;
		uvec2 direction = mode == 4u ? p / frame.grid.xy : p % 8u;
		uint probe = probe_index(ivec2(tile));
		bool valid = probe != INVALID && probes.data[probe].position.w > 0.0;
		if (mode == 5u) {
			color = valid ? vec3(0, 1, 0) : vec3(1, 0, 0);
		} else if (mode == 6u) {
			color = valid ? debug_heat(float(params.padding - probes.data[probe].state.z) / max(float(frame.debug_options.w), 1.0)) : vec3(0);
		} else if (valid && all(lessThan(direction, uvec2(8)))) {
			color = debug_radiance(gi_cache_unpack(radiance.data[probe * 64u + direction.x + direction.y * 8u]).rgb / PI);
		} else {
			color = vec3(1, 0, 0);
		}
	} else if ((mode >= 7u && mode <= 17u) || mode == 22u) {
		// A tile occupies an 8x8 texel block; a page contains the number of
		// complete blocks that fit in this viewport. Page order follows the
		// renderer's occupied-tile list and can change as tiles expire.
		uvec2 block_count = max(params.size / 8u, uvec2(1));
		uvec2 block = uvec2(pixel) / 8u;
		uint page_size = block_count.x * block_count.y;
		uint page = uint(max(frame.debug_settings.z, 0.0));
		uint entry_count = mode == 16u || mode == 17u ? frame.cache_config.x : keys.occupied[params.padding & 1u];
		if (any(greaterThanEqual(block, block_count)) || page >= (entry_count + page_size - 1u) / page_size) {
			imageStore(debug_output, pixel, vec4(0, 0, 0, 1));
			return;
		}
		uint entry = page * page_size + block.x + block.y * block_count.x;
		if (mode == 16u || mode == 17u) {
			if (entry < frame.cache_config.x) {
				uint occupied = 0u;
				for (uint slot = 0u; slot < frame.cache_config.y; slot++) {
					occupied += uint(keys.data[entry * frame.cache_config.y + slot].state.x != 0u);
				}
				float value = mode == 16u ? float(occupied) / float(frame.cache_config.y) : float(debug_statistics.values[16u + entry]) / max(frame.debug_settings.y, 1.0);
				color = debug_heat(value);
			}
		} else if (entry < keys.occupied[params.padding & 1u]) {
			uint tile = uint(keys.data[TILE_COUNT + entry].key[params.padding & 1u]);
			uint age = params.padding - keys.data[tile].state.y;
			uvec2 coord = uvec2(pixel) % 8u;
			uint mip = min(frame.debug_options.y, 3u);
			bool indirect = mode == 22u || (frame.debug_options.z & 2u) != 0u;
			bool available = !indirect || params.bounces != 0u;
			vec4 raw = available ? debug_cell(tile, coord, mip, indirect) : vec4(0);
			uint selected_mip = 0u;
			vec4 filtered = available ? debug_filtered_cell(tile, coord, indirect, selected_mip) : vec4(0);
			if (mode == 7u || mode == 22u) {
				color = debug_radiance(debug_normalized(raw));
			} else if (mode == 8u || mode == 11u) {
				float count = mode == 8u ? raw.w : filtered.w;
				color = count > 0.0 ? debug_heat(count / max(frame.debug_settings.y, 1.0)) : vec3(0);
			} else if (mode == 9u) {
				color = debug_radiance(debug_normalized(filtered));
			} else if (mode == 10u) {
				vec4 fine = available ? debug_cell(tile, coord, 0u, indirect) : vec4(0);
				color = debug_radiance(max(debug_normalized(filtered) - debug_normalized(fine), vec3(0)));
			} else if (mode == 12u) {
				color = filtered.w > 0.0 ? debug_heat(1.0 - float(selected_mip) / 3.0) : vec3(0);
			} else if (mode == 13u) {
				uint used = 0u, side = 8u >> mip;
				for (uint y = 0u; y < side; y++) {
					for (uint x = 0u; x < side; x++) {
						used += uint(available && debug_cell(tile, uvec2(x, y) << mip, mip, indirect).w > 0.0);
					}
				}
				color = debug_heat(float(used) / float(side * side));
			} else if (mode == 14u) {
				color = debug_heat(float(age) / max(float(frame.debug_options.w), 1.0));
			} else if (mode == 15u) {
				color = raw.w > 0.0 ? vec3(0, 1, 0) : vec3(1, 0, 0);
			}
			if (age > frame.debug_options.w) {
				color = vec3(0);
			}
		}
	} else if (mode == 23u) {
		ivec2 sample_pixel = pixel / int(frame.reflections.x);
		ReflectionSample sample_value = unpack_reflection(reflection_samples.data[reflection_index(sample_pixel)]);
		color = sample_value.position_roughness.w >= 0.0 ? debug_radiance(sample_value.color_count.rgb / max(vec3(1.0) - sample_value.color_count.rgb, vec3(1e-3))) : vec3(0);
	} else if (mode == 24u || mode == 25u) {
		color = mode == 24u ? texelFetch(primary_shading_normal, pixel, 0).rgb : texelFetch(geometry_normal_buffer, pixel, 0).rgb;
	} else if (mode == 26u) {
		color = vec3(texelFetch(primary_roughness, pixel, 0).r);
	} else if (mode == 27u) {
		if (frame.grid.w == 0u && frame.settings.w > 0.0) {
			color = debug_radiance(texelFetch(previous_lighting, pixel, 0).rgb / frame.settings.w);
		}
	} else if (mode >= 28u && mode <= 31u && frame.flags.w != 0u) {
		uvec2 blocks = max(params.size / 8u, uvec2(1));
		uvec2 block = uvec2(pixel) / 8u;
		uint page_size = blocks.x * blocks.y;
		uint page = uint(max(frame.debug_settings.z, 0.0));
		if (page >= (CACHED_PROBES + page_size - 1u) / page_size) {
			imageStore(debug_output, pixel, vec4(0, 0, 0, 1));
			return;
		}
		uint rank = page * page_size + block.x + block.y * blocks.x;
		if (all(lessThan(block, blocks)) && rank < CACHED_PROBES) {
			// Previous-frame LRU order is the immutable input to this frame's
			// allocator. Display it directly without reading a write-only output.
			uint cached = previous_cached_order.data[rank];
			Probe seed = cached_probes.data[cached].probe;
			bool valid = seed.position.w > 0.0;
			if (mode == 28u) {
				uvec2 direction = uvec2(pixel) % 8u;
				color = valid ? debug_radiance(gi_cache_unpack(cached_probes.data[cached].radiance[direction.x + 8u * direction.y]).rgb / PI) : vec3(1, 0, 0);
			} else if (mode == 29u) {
				// Seed age is distinct from radiance age: reused probes can update
				// their radiance without replacing the stored seed metadata.
				color = valid ? debug_heat(float(params.padding - seed.state.z) / max(float(frame.debug_options.w), 1.0)) : vec3(0);
			} else if (mode == 30u) {
				color = valid ? vec3(0, 1, 0) : vec3(1, 0, 0);
			} else {
				uint owner = cached_state.data[cached].z;
				color = !valid ? vec3(1, 0, 0) : (owner == INVALID ? vec3(0.2) : ((owner & 0xc0000000u) != 0u ? vec3(0, 1, 0) : vec3(0, 0, 1)));
			}
		}
	}
	imageStore(debug_output, pixel, vec4(color, 1));
}
#endif

#if AMD_GI_PASS == PASS_DEBUG_STATS
void debug_stats(uint id) {
	if (id == 0u) {
		debug_statistics.values[7] = keys.dispatch.w;
		debug_statistics.values[10] = work.counts.y;
		debug_statistics.values[11] = work.counts.z;
		debug_statistics.values[13] = params.padding;
		debug_statistics.values[14] = TILE_COUNT * 64u;
	}
	if (id < frame.grid.x * frame.grid.y && probes.data[id].position.w > 0.0) {
		atomicAdd(debug_statistics.values[8], 1u);
		if (probes.data[id].state.z == params.padding) {
			atomicAdd(debug_statistics.values[9], 1u);
		}
	}
	if (frame.flags.w != 0u && id < CACHED_PROBES && cached_probes.data[id].probe.position.w > 0.0) {
		atomicAdd(debug_statistics.values[15], 1u);
	}
	if (id >= frame.cache_config.x) {
		return;
	}
	uint occupied = 0u, sampled = 0u, sample_sum = 0u, maximum_samples = 0u;
	for (uint slot = 0u; slot < frame.cache_config.y; slot++) {
		uint tile = id * frame.cache_config.y + slot;
		if (keys.data[tile].state.x == 0u) {
			continue;
		}
		occupied++;
		for (uint cell = 0u; cell < 64u; cell++) {
			uint count = uint(gi_cache_unpack(cache.data[tile * TILE_CELLS + cell]).w);
			sampled += uint(count > 0u);
			sample_sum += count;
			maximum_samples = max(maximum_samples, count);
		}
	}
	atomicAdd(debug_statistics.values[1], occupied);
	atomicAdd(debug_statistics.values[2], uint(occupied > 0u));
	atomicAdd(debug_statistics.values[3], sampled);
	uint old_sum = atomicAdd(debug_statistics.values[4], sample_sum);
	if (old_sum > 0xffffffffu - sample_sum) {
		atomicAdd(debug_statistics.values[5], 1u);
	}
	atomicMax(debug_statistics.values[6], maximum_samples);
	atomicAdd(debug_statistics.values[12], uint(occupied == frame.cache_config.y));
	uint histogram = 16u + frame.cache_config.x;
	atomicAdd(debug_statistics.values[histogram + occupied], 1u);
	uint overflow = min(debug_statistics.values[16u + id], frame.cache_config.y);
	atomicAdd(debug_statistics.values[histogram + frame.cache_config.y + 1u + overflow], 1u);
}
#endif
