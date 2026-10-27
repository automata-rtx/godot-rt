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

// GI-1.1-style glossy path: GGX visible-normal samples, spatial ratio
// reconstruction, virtual/surface history, and variance-guided a-trous filtering.
// The native forward material applies Fresnel/DFG after this incoming-radiance
// estimate. No primary material atlas lookup or additional camera ray is needed.
struct ReflectionSample {
	vec4 position_roughness; // negative roughness marks sky/invalid
	vec4 normal_distance;
	vec4 direction_pdf;
	vec4 color_count;
	vec4 virtual_variance;
};
struct StoredReflection {
	vec4 position_roughness;
	vec4 normal_distance;
	uvec2 direction_pdf;
	uvec2 color_count;
	uvec2 virtual_variance;
};
StoredReflection pack_reflection(ReflectionSample value) {
	return StoredReflection(value.position_roughness, value.normal_distance, gi_cache_pack(value.direction_pdf), gi_cache_pack(value.color_count), gi_cache_pack(value.virtual_variance));
}
ReflectionSample unpack_reflection(StoredReflection value) {
	return ReflectionSample(value.position_roughness, value.normal_distance, gi_cache_unpack(value.direction_pdf), gi_cache_unpack(value.color_count), gi_cache_unpack(value.virtual_variance));
}

layout(set = 0, binding = 38, std430) restrict buffer ReflectionSamples {
	StoredReflection data[];
}
reflection_samples;
layout(set = 0, binding = 39, std430) restrict readonly buffer PreviousReflections {
	StoredReflection data[];
}
previous_reflections;
layout(set = 0, binding = 40, std430) restrict buffer Reflections {
	StoredReflection data[];
}
reflections;
layout(rgba16f, set = 0, binding = 41) uniform restrict image2D reflection_filter_a;
layout(rgba16f, set = 0, binding = 42) uniform restrict image2D reflection_filter_b;
layout(rgba16f, set = 0, binding = 43) uniform restrict writeonly image2D output_reflection;

ivec2 reflection_size() {
	return (ivec2(params.size) + int(frame.reflections.x) - 1) / int(frame.reflections.x);
}
uint reflection_index(ivec2 pixel) {
	return uint(pixel.x + pixel.y * reflection_size().x);
}
ivec2 reflection_phase(uint number) {
	return frame.reflections.x > 1.0 ? ivec2(number & 1u, (number >> 1u) & 1u) : ivec2(0);
}
ivec2 reflection_pixel(ivec2 pixel) {
	return pixel * int(frame.reflections.x) + reflection_phase(params.padding);
}
float surface_roughness(ivec2 pixel) {
	return texelFetch(primary_roughness, pixel, 0).r;
}

#ifdef AMD_GI_REFLECTION_RECORDING
// First observer records post-trace values before any firefly or spatial filter.
// Pass 49 supplies the fallback when fireflies are disabled; pass 53 does so
// only with the denoiser disabled. Each checker-active pixel has one owner.
void reflection_diagnostic_raw(ivec2 pixel, uint id) {
	ivec2 full_pixel = reflection_pixel(pixel);
	uint base = reflection_diagnostic_base(full_pixel);
	if (base == INVALID) {
		return;
	}
	ReflectionSample sample_value = unpack_reflection(reflection_samples.data[id]);
	if (floatBitsToUint(source_validation.values[base + 45u]).w == 0u) {
		source_validation.values[base + 40u] = sample_value.position_roughness;
		source_validation.values[base + 41u] = sample_value.normal_distance;
		source_validation.values[base + 42u] = sample_value.direction_pdf;
		source_validation.values[base + 43u] = sample_value.color_count;
		// TRACE stores exact provenance in this otherwise unused sample field.
		// Do not unpack its bits as half floats (cell IDs can exceed 24 bits).
		source_validation.values[base + 44u] = uintBitsToFloat(uvec4(reflection_samples.data[id].virtual_variance, 0u, 0u));
		source_validation.values[base + 45u] = uintBitsToFloat(uvec4(full_pixel, params.padding, uint(pass_id)));
	}
	if (pass_id == PASS_REFLECTION_FIRST) {
		source_validation.values[base + 46u] = sample_value.color_count;
		source_validation.values[base + 47u] = vec4(sample_value.direction_pdf.xyz, sample_value.normal_distance.w);
	}
}
#endif

float reflection_kernel(vec3 n, vec3 v, vec3 l, float roughness) {
	float nl = clamp(dot(n, l), -1.0, 1.0), nv = clamp(dot(n, v), -1.0, 1.0);
	float alpha = max(roughness * roughness, 1e-6), a2 = max(alpha * alpha, 1e-6);
	float d = gi_ggx_ndf(a2, clamp(dot(n, normalize(v + l)), -1.0, 1.0));
	float reciprocal_v = (abs(nl) + sqrt(a2 + (1.0 - a2) * nl * nl)) * (abs(nv) + sqrt(a2 + (1.0 - a2) * nv * nv));
	return max(nl, 0.0) * d / reciprocal_v;
}

layout(rgba16f, set = 0, binding = 50) uniform restrict image2D reflection_moments_a;
layout(rgba16f, set = 0, binding = 51) uniform restrict image2D reflection_moments_b;

// gi1.comp:InterpolateScreenProbes. Preserve the reference's four-probe
// stochastic lookup between the low/high roughness thresholds.
vec3 reflection_probe_value(ivec2 pixel, vec3 p, vec3 n, vec3 view, float roughness, out vec3 direction) {
	ivec2 jitter = ivec2((lookup_jitter(pixel, 1u) * 2.0 - 1.0) * float(frame.grid.z));
	ivec2 sample_pixel = clamp(pixel + jitter, ivec2(0), ivec2(params.size) - 1);
	vec3 sample_p, sample_n;
	if (!surface(sample_pixel, sample_p, sample_n) || abs(dot(sample_p - p, n)) >= footprint(p) * 0.5) {
		sample_pixel = pixel;
	}
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	reflection_diagnostic_write(pixel, 5u, vec4(sample_pixel, jitter));
#endif
	uvec4 indices = uvec4(INVALID);
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	reflection_diagnostic_write(pixel, 6u, uintBitsToFloat(indices));
#endif
	indices.x = closest_probe(sample_pixel, ivec2(0));
	direction = n;
	if (indices.x == INVALID) {
		return vec3(0);
	}
	ivec2 seed = ivec2(probes.data[indices.x].state.xy);
	ivec2 offset = ivec2(sample_pixel.x < seed.x ? -1 : 1, sample_pixel.y < seed.y ? -1 : 1);
	indices.y = closest_probe(sample_pixel, ivec2(offset.x, 0));
	indices.z = closest_probe(sample_pixel, ivec2(0, offset.y));
	indices.w = closest_probe(sample_pixel, offset);
	vec4 weights = vec4(0);
	float depth = gi_view_depth(p);
	for (uint i = 0u; i < 4u; i++) {
		for (uint j = 0u; j < i; j++) {
			if (indices[i] == indices[j]) {
				indices[i] = INVALID;
			}
		}
		if (indices[i] == INVALID) {
			continue;
		}
		Probe probe = probes.data[indices[i]];
		if (abs(dot(probe.position.xyz - p, n)) <= footprint(p)) {
			weights[i] = pow(clamp(1.0 - abs(gi_view_depth(probe.position.xyz) - depth) / depth, 0.0, 1.0) * max(dot(n, probe.normal.xyz), 0.0), 8.0);
		}
	}
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	bool diagnostic_fallback_weights = dot(weights, weights) == 0.0;
#endif
	if (dot(weights, weights) == 0.0) {
		weights = vec4(1.0, indices.y != INVALID ? 1.0 : 0.0, indices.z != INVALID ? 1.0 : 0.0, indices.w != INVALID ? 1.0 : 0.0);
	}
	weights /= dot(weights, vec4(1));
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	reflection_diagnostic_write(pixel, 6u, uintBitsToFloat(indices));
	reflection_diagnostic_write(pixel, 7u, weights);
#endif
	vec3 detail_normal = shading_normal(pixel);
	vec4 rotation = gi_rotation_z(detail_normal);
	vec3 local_view = gi_rotate(rotation, view);
	vec3 h = gi_sample_ggx_bounded(max(roughness * roughness, 1e-6), local_view, lookup_jitter(pixel, 1u));
	direction = normalize(gi_rotate(vec4(-rotation.xyz, rotation.w), reflect(-local_view, h)));
	vec3 value = vec3(0);
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	float diagnostic_accepted_weight = 0.0;
#endif
	for (uint i = 0u; i < 4u; i++) {
		if (indices[i] == INVALID) {
			continue;
		}
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
		if (reflection_diagnostic_base(pixel) != INVALID) {
			Probe diagnostic_probe = probes.data[indices[i]];
			float diagnostic_hemisphere = dot(direction, diagnostic_probe.normal.xyz);
			bool diagnostic_accepted = roughness > frame.reflections.y || diagnostic_hemisphere >= 0.0;
			uint diagnostic_cell = diagnostic_accepted && roughness <= frame.reflections.y ? angular_index(direction, diagnostic_probe.normal.xyz) : INVALID;
			reflection_diagnostic_write(pixel, 8u + i * 5u, uintBitsToFloat(diagnostic_probe.state));
			reflection_diagnostic_write(pixel, 9u + i * 5u, diagnostic_probe.position);
			reflection_diagnostic_write(pixel, 10u + i * 5u, diagnostic_probe.normal);
			reflection_diagnostic_write(pixel, 11u + i * 5u, vec4(diagnostic_cell == INVALID ? -1.0 : float(diagnostic_cell), diagnostic_hemisphere, diagnostic_accepted ? weights[i] : 0.0, weights[i]));
			reflection_diagnostic_write(pixel, 12u + i * 5u, diagnostic_cell != INVALID ? gi_cache_unpack(radiance.data[indices[i] * 64u + diagnostic_cell]) : vec4(0));
			diagnostic_accepted_weight += diagnostic_accepted ? weights[i] : 0.0;
		}
#endif
		if (roughness > frame.reflections.y) {
			value += weights[i] * probe_irradiance(indices[i], detail_normal) / PI;
		} else if (dot(direction, probes.data[indices[i]].normal.xyz) >= 0.0) {
			uint cell = angular_index(direction, probes.data[indices[i]].normal.xyz);
			value += weights[i] * gi_cache_unpack(radiance.data[indices[i] * 64u + cell]).rgb;
		}
	}
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	reflection_diagnostic_write(pixel, 4u, vec4(direction, diagnostic_accepted_weight));
	reflection_diagnostic_write(pixel, 28u, vec4(value, diagnostic_fallback_weights ? 1.0 : 0.0));
#endif
	return value;
}

bool prepare_reflection(ivec2 pixel, out ReflectionSample result) {
	result.position_roughness = vec4(0, 0, 0, -1);
	result.normal_distance = vec4(0, 0, 0, -1);
	result.direction_pdf = vec4(0, 0, 0, -1);
	result.color_count = vec4(0);
	result.virtual_variance = vec4(0);
	ivec2 full_pixel = reflection_pixel(pixel);
	vec3 p, n;
	if (!surface(full_pixel, p, n)) {
		return false;
	}
	float roughness = surface_roughness(full_pixel);
	result.position_roughness = vec4(p, roughness);
	result.normal_distance.xyz = n;
	if (roughness > frame.glossy.x) {
		vec3 direction;
		vec3 color = reflection_probe_value(full_pixel, p, n, normalize(params.camera_position.xyz - p), roughness, direction);
		result.direction_pdf = gi_cache_unpack(gi_cache_pack(vec4(direction, -1)));
		result.normal_distance.w = 1.0;
		result.color_count = gi_cache_unpack(gi_cache_pack(vec4(color / (1.0 + color), 1)));
		return false;
	}
	result.direction_pdf.w = 0.0;
	return true;
}
void classify_reflection(ivec2 pixel, uint id) {
	ReflectionSample result;
	bool needs_ray = prepare_reflection(pixel, result);
	reflection_samples.data[id] = pack_reflection(result);
#ifdef AMD_GI_REFLECTION_RECORDING
	ivec2 diagnostic_pixel = reflection_pixel(pixel);
	if (reflection_diagnostic_base(diagnostic_pixel) != INVALID) {
		reflection_diagnostic_write(diagnostic_pixel, 0u, uintBitsToFloat(uvec4(diagnostic_pixel, params.padding, result.position_roughness.w < 0.0 ? 1u : (needs_ray ? 2u : 3u))));
		reflection_diagnostic_write(diagnostic_pixel, 1u, vec4(result.normal_distance.xyz, 0));
		reflection_diagnostic_write(diagnostic_pixel, 2u, vec4(shading_normal(diagnostic_pixel), 0));
		reflection_diagnostic_write(diagnostic_pixel, 3u, result.position_roughness);
		reflection_diagnostic_write(diagnostic_pixel, 29u, result.color_count);
		reflection_diagnostic_write(diagnostic_pixel, 30u, vec4(result.direction_pdf.xyz, result.normal_distance.w));
	}
#endif
	if (needs_ray) {
		uint index = atomicAdd(queues.data[frame.emitters.z + 3u], 1u);
		queues.data[frame.emitters.z + 4u + index] = id;
	}
}
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
uint reflection_diagnostic_cache_mip(uint cell, bool indirect) {
	uint tile = cell / TILE_CELLS;
	uint local = cell % TILE_CELLS;
	uvec2 coord = uvec2(local % 8u, local / 8u);
	for (uint mip = 0u; mip < 4u; mip++) {
		uvec2 p = coord >> mip;
		uint index = tile * TILE_CELLS + MIP_OFFSET[mip] + p.x + p.y * (8u >> mip);
		vec4 value = gi_cache_unpack(indirect ? indirect_cache.data[index] : cache.data[index]);
		if (value.w >= 16.0 || mip == 3u) {
			return mip;
		}
	}
	return 4u;
}
#endif
void trace_reflection(ivec2 pixel, uint id) {
	ReflectionSample result;
	if (frame.emitters.w != 0u) {
		result = unpack_reflection(reflection_samples.data[id]);
	} else if (!prepare_reflection(pixel, result)) {
		reflection_samples.data[id] = pack_reflection(result);
		return;
	}
	ivec2 full_pixel = reflection_pixel(pixel);
	vec3 p = result.position_roughness.xyz, n = result.normal_distance.xyz;
	vec3 v = normalize(params.camera_position.xyz - p);
	float alpha = max(result.position_roughness.w * result.position_roughness.w, 1e-6);
	vec4 rotation = gi_rotation_z(shading_normal(full_pixel));
	vec3 local_view = gi_rotate(rotation, v);
	vec2 sample_value = lookup_jitter(full_pixel, 2u);
	vec3 h = gi_sample_ggx_bounded(alpha, local_view, sample_value);
	vec3 local_light = reflect(-local_view, h);
	vec3 l = normalize(gi_rotate(vec4(-rotation.xyz, rotation.w), local_light));
	float nh = clamp(normalize(local_view + local_light).z, -1.0, 1.0);
	float pdf = gi_ggx_bounded_pdf(alpha, max(alpha * alpha, 1e-6), nh, local_view);
	result.direction_pdf = vec4(l, pdf);
	RayHit hit = trace_hit(gi_offset_position(p, n), l);
	vec3 value = environment_radiance(l, true);
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
	// Exact raw words in StoredReflection.virtual_variance; samples do not
	// consume variance. The full-resolution reconstruction owns its own field.
	uint diagnostic_source = 1u; // sky, emission, screen feedback, cache, unavailable
	uint diagnostic_cell = INVALID;
	uint diagnostic_direct_mip = 4u, diagnostic_indirect_mip = 4u;
	float diagnostic_direct_fraction = 0.0;
#endif
	result.normal_distance.w = 65519.0;
	if (hit.position.w >= 0.0) {
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
		diagnostic_source = 5u;
#endif
		// A geometric hit without usable radiance keeps TRACE_NONE_DISTANCE.
		// It must not masquerade as a valid black cache sample in reconstruction.
		result.normal_distance.w = -1.0;
		value = vec3(0);
		if (hit.emission.w > 0.0) {
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
			diagnostic_source = 2u;
#endif
			value = hit.emission.rgb;
			result.normal_distance.w = hit.position.w;
		} else if (screen_lighting(hit, true, value)) {
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
			diagnostic_source = 3u;
#endif
			result.normal_distance.w = hit.position.w;
		} else {
			vec2 jitter = (2.0 * sample_value - 1.0) * cache_cell_size(hit.position.xyz);
			mat3 tangent = basis(hit.normal_mask.xyz);
			vec3 lookup_position = hit.position.xyz + jitter.x * tangent[0] + jitter.y * tangent[1];
			uint cell = find_cell(lookup_position, l, hit.position.w);
			if (cell != INVALID) {
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
				diagnostic_source = 4u;
				diagnostic_cell = cell;
				diagnostic_direct_mip = reflection_diagnostic_cache_mip(cell, false);
				if (params.bounces != 0u) {
					diagnostic_indirect_mip = reflection_diagnostic_cache_mip(cell, true);
				}
				float diagnostic_direct_luma = luma(read_component(cell, false, false).rgb);
				float diagnostic_indirect_luma = params.bounces != 0u ? luma(read_component(cell, false, true).rgb) : 0.0;
				float diagnostic_total_luma = diagnostic_direct_luma + diagnostic_indirect_luma;
				diagnostic_direct_fraction = diagnostic_total_luma > 0.0 ? diagnostic_direct_luma / diagnostic_total_luma : 0.0;
#endif
				atomicExchange(keys.data[cell / TILE_CELLS].state.y, params.padding);
				value = read_cache(cell, false).rgb;
				result.normal_distance.w = hit.position.w;
			}
		}
	}
	result.color_count = gi_cache_unpack(gi_cache_pack(vec4(value / (1.0 + value), 1)));
	// AMD stores camera-relative hit points for short connections, and a
	// direction otherwise, in the same RGBA16F direction target.
	bool short_hit = result.normal_distance.w > 0.0 && result.normal_distance.w < 100.0;
	result.direction_pdf = gi_cache_unpack(gi_cache_pack(short_hit ? vec4(p + result.normal_distance.w * l - params.camera_position.xyz, 1) : vec4(l, 0)));
	result.normal_distance.w = unpackHalf2x16(packHalf2x16(vec2(result.normal_distance.w, 0))).x;
#ifdef AMD_GI_REFLECTION_TRACE_RECORDING
	StoredReflection stored_result = pack_reflection(result);
	uint diagnostic_fraction_bits = packHalf2x16(vec2(diagnostic_direct_fraction, 0.0)) & 0xffffu;
	stored_result.virtual_variance = uvec2(diagnostic_source | (diagnostic_direct_mip << 8u) | (diagnostic_indirect_mip << 11u) | (diagnostic_fraction_bits << 16u), diagnostic_cell);
	reflection_samples.data[id] = stored_result;
#else
	reflection_samples.data[id] = pack_reflection(result);
#endif
}

vec4 reflection_raw(ivec2 pixel) {
	ReflectionSample sample_value = unpack_reflection(reflection_samples.data[reflection_index(pixel)]);
	return vec4(sample_value.color_count.rgb, sample_value.normal_distance.w);
}

// gi1.comp:MarkFireflies. Thresholds are the upstream defaults unless explicitly
// changed through settings; no custom luminance multiple or geometry rank test.
// At exact 0/1 thresholds, finite nonnegative rank counts cannot mark a sample.
// Skip only that rank work; negative-distance cleanup and raw recording remain.
void mark_reflection_fireflies(ivec2 pixel, uint id) {
#ifdef AMD_GI_REFLECTION_RECORDING
	reflection_diagnostic_raw(pixel, id);
#endif
	ReflectionSample center = unpack_reflection(reflection_samples.data[id]);
	float marked = 0.0;
	if (center.position_roughness.w >= 0.0 && center.position_roughness.w <= frame.reflections.y) {
		if (center.normal_distance.w < 0.0) {
			marked = 1.0;
		} else if (frame.glossy.y != 0.0 || frame.glossy.z != 1.0) {
			float center_luma = luma(center.color_count.rgb), lower = 0.0, higher = 0.0;
			int full_radius = int(frame.reflection_options.z);
			int half_radius = frame.reflections.x > 1.0 ? (full_radius + 1) / 2 : full_radius;
			for (int x = -half_radius; x <= half_radius; x++) {
				for (int y = -half_radius; y <= half_radius; y++) {
					ivec2 q = pixel + ivec2(x, y);
					if ((x == 0 && y == 0) || any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, reflection_size()))) {
						continue;
					}
					ivec2 full_sample = reflection_pixel(q);
					if (any(lessThan(full_sample, ivec2(0))) || any(greaterThanEqual(full_sample, ivec2(params.size)))) {
						continue;
					}
					ReflectionSample sample_value = unpack_reflection(reflection_samples.data[reflection_index(q)]);
					if (sample_value.position_roughness.w > frame.reflections.y) {
						continue;
					}
					ivec2 distance = ivec2(x, y) * int(frame.reflections.x);
					float w = abs(distance.x) <= full_radius && abs(distance.y) <= full_radius ? 1.0 : 0.0;
					float sample_luma = luma(sample_value.color_count.rgb);
					higher += sample_luma < center_luma ? w : 0.0;
					lower += sample_luma > center_luma ? w : 0.0;
				}
			}
			float weight = lower + higher;
			marked = lower < frame.glossy.y * weight || higher > frame.glossy.z * weight ? 1.0 : 0.0;
		}
	}
	imageStore(reflection_filter_a, pixel, vec4(marked));
}
void clean_reflection_fireflies(ivec2 pixel, uint id) {
	vec4 value = reflection_raw(pixel);
	if (imageLoad(reflection_filter_a, pixel).x >= 0.5) {
		ReflectionSample center = unpack_reflection(reflection_samples.data[id]);
		vec4 sum = vec4(0);
		float weight = 0.0;
		int radius = int(frame.reflection_options.w);
		float depth = gi_view_depth(center.position_roughness.xyz);
		for (int x = -radius; x <= radius; x++) {
			for (int y = -radius; y <= radius; y++) {
				ivec2 q = pixel + ivec2(x, y);
				// D3D texture loads outside the image return zero. Preserve their
				// denominator contribution instead of dropping those filter taps.
				bool in_half = all(greaterThanEqual(q, ivec2(0))) && all(lessThan(q, reflection_size()));
				ivec2 full_sample = reflection_pixel(q);
				bool in_full = all(greaterThanEqual(full_sample, ivec2(0))) && all(lessThan(full_sample, ivec2(params.size)));
				float sample_depth = in_full ? texelFetch(depth_buffer, full_sample, 0).r : 0.0;
				vec2 sample_uv = (vec2(full_sample) + 0.5) / vec2(params.size);
				vec4 sample_world = params.inv_view_projection * vec4(sample_uv * 2.0 - 1.0, sample_depth, 1);
				vec3 other_position = sample_world.xyz / sample_world.w;
				float plane = 1.0 - clamp(abs(dot(center.normal_distance.xyz, center.position_roughness.xyz - other_position) / depth) * 200.0, 0.0, 1.0);
				float mark = in_half ? imageLoad(reflection_filter_a, q).x : 0.0;
				float w = (1.0 - mark) * plane * exp(-float(x * x + y * y) / float((radius + 1) * (radius + 1)));
				vec4 radiance = in_half ? reflection_raw(q) : vec4(0);
				sum += radiance * w;
				weight += w;
			}
		}
		if (abs(weight) < 1e-3) {
			sum += value;
			weight += 1.0;
		}
		value = gi_denoiser_remove_nans(weight > 0.0 ? sum / weight : sum);
		// Match AMD's in-place cleanup and half-precision specular target.
		// Unmarked samples remain untouched. Exceptional NaN behavior retains
		// the source's scheduling dependence; no snapshot policy is substituted.
		reflection_samples.data[id].color_count = gi_cache_pack(vec4(value.rgb, center.color_count.w));
		reflection_samples.data[id].normal_distance.w = unpackHalf2x16(packHalf2x16(vec2(value.w, 0))).x;
	}
}
vec4 reflection_filter_source(ivec2 pixel, uint iteration, bool moments) {
	if (iteration == 0u) {
		vec4 value = reflection_raw(pixel);
		return moments ? vec4(value.rgb * value.rgb, 0) : value;
	}
	bool source_a = (iteration & 1u) != 0u;
	if (moments) {
		vec3 value = source_a ? imageLoad(reflection_moments_a, pixel).rgb : imageLoad(reflection_moments_b, pixel).rgb;
		return vec4(value * value, 0);
	}
	return source_a ? imageLoad(reflection_filter_a, pixel) : imageLoad(reflection_filter_b, pixel);
}

// gi1.comp:ResolveReflections_SplitRatioEstimatorX/Y. The horizontal target is
// full width and half height when tracing at half resolution. In particular,
// SplitToFullRes has no checker phase; the samples themselves do have the phase.
// Keep AMD's Gaussian, target PDF, low-weight three-tap fallback, second moments,
// vertical-pass blue-noise jitter and decompression before temporal reprojection.
void resolve_reflection_split(ivec2 pixel, uint id) {
	bool vertical = pass_id == PASS_REFLECTION_LAST;
	int stride = int(frame.reflections.x);
	ivec2 full_pixel = vertical ? pixel : ivec2(pixel.x, pixel.y * stride);
	vec3 p, n;
	if (!surface(full_pixel, p, n) || surface_roughness(full_pixel) > frame.reflections.y) {
		if (!vertical) {
			imageStore(reflection_filter_a, pixel, vec4(0));
			imageStore(reflection_moments_a, pixel, vec4(0));
		}
		return;
	}
	float roughness = surface_roughness(full_pixel), depth = gi_view_depth(p);
	vec3 view = normalize(params.camera_position.xyz - p);
	vec3 detail_normal = shading_normal(full_pixel);
	vec3 local_view = gi_rotate(gi_rotation_z(detail_normal), view);
	float alpha = max(roughness * roughness, 1e-6), alpha_squared = max(alpha * alpha, 1e-6);
	int full_radius = int(frame.reflection_options.y);
	int half_radius = (full_radius + stride - 1) / stride;
	ivec2 half_pixel = full_pixel / stride;
	ivec2 jitter = vertical ? ivec2(floor((lookup_jitter(full_pixel, 0u) - 0.5) * 2.0 + 0.5)) : ivec2(0);
	vec4 sum = vec4(0);
	vec3 squares = vec3(0);
	float weight = 0.0;
	// The second sweep is AMD's fallback, executed only when the ordinary
	// weights sum below 1e-3. It adds to (rather than discards) that first sum.
	for (int sweep = 0; sweep < 2; sweep++) {
		if (sweep == 1 && weight >= 1e-3) {
			break;
		}
		int radius = sweep == 0 ? half_radius : 1;
		for (int offset = -radius; offset <= radius; offset++) {
			ivec2 q = half_pixel + (vertical ? ivec2(sweep == 0 ? jitter.x : 0, offset) : ivec2(offset, 0));
			ivec2 full_q = reflection_pixel(q);
			if (any(lessThan(full_q, ivec2(0))) || any(greaterThanEqual(full_q, ivec2(params.size))) || surface_roughness(full_q) > frame.reflections.y) {
				continue;
			}
			float w = 1.0;
			if (sweep == 0) {
				ReflectionSample sample_value = unpack_reflection(reflection_samples.data[reflection_index(q)]);
				vec3 l = sample_value.direction_pdf.xyz;
				if (sample_value.direction_pdf.w > 0.5) {
					l = normalize(l + params.camera_position.xyz - p);
				}
				float nh = clamp(dot(detail_normal, normalize(view + l)), -1.0, 1.0);
				float pdf = gi_ggx_bounded_pdf(alpha, alpha_squared, nh, local_view);
				float sample_depth = texelFetch(depth_buffer, full_q, 0).r;
				vec2 sample_uv = (vec2(full_q) + 0.5) / vec2(params.size);
				vec4 sample_world = params.inv_view_projection * vec4(sample_uv * 2.0 - 1.0, sample_depth, 1);
				vec3 other_p = sample_world.xyz / sample_world.w;
				float plane = 1.0 - clamp(abs(dot(n, p - other_p) / depth) * 200.0, 0.0, 1.0);
				float delta = float(vertical ? full_q.y - full_pixel.y : full_q.x - full_pixel.x);
				float sigma = 0.375 * float(full_radius);
				w = exp(-(delta * delta) / (2.0 * sigma * sigma)) * plane * pdf;
			}
			vec4 value;
			vec3 moment;
			if (vertical) {
				ivec2 split_q = ivec2(full_q.x, q.y);
				value = imageLoad(reflection_filter_a, split_q);
				vec3 root_moment = imageLoad(reflection_moments_a, split_q).rgb;
				moment = root_moment * root_moment;
			} else {
				value = reflection_raw(q);
				moment = value.rgb * value.rgb;
			}
			sum += value * w;
			squares += moment * w;
			weight += w;
		}
	}
	if (weight > 0.0) {
		sum /= weight;
		squares /= weight;
	}
	if (vertical) {
		ReflectionSample result;
		result.position_roughness = vec4(p, roughness);
		result.normal_distance = vec4(n, unpackHalf2x16(packHalf2x16(vec2(sum.w, 0))).x);
		result.direction_pdf = vec4(0);
		vec3 deviation = sqrt(abs(squares - sum.rgb * sum.rgb));
		result.virtual_variance = gi_cache_unpack(gi_cache_pack(vec4(deviation / max(vec3(1.0) - deviation, vec3(1e-3)), 0)));
		result.color_count = gi_cache_unpack(gi_cache_pack(vec4(sum.rgb / max(vec3(1.0) - sum.rgb, vec3(1e-3)), 1)));
		reflections.data[id] = pack_reflection(result);
	} else {
		imageStore(reflection_filter_a, pixel, sum);
		imageStore(reflection_moments_a, pixel, vec4(sqrt(squares), 1));
	}
}

// The reference's first/iter/last a-trous ratio estimator uses the TARGET PDF,
// compressed radiance, propagated RGB second moments, and full-resolution last pass.
void resolve_reflection(ivec2 pixel, uint id) {
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_FIRST
	// Split X has full width; keep the raw sample observer one-to-one with
	// actual traced samples instead of indexing the wider intermediate target.
	if (frame.reflection_options.x != 0u || pixel.x < reflection_size().x) {
		reflection_diagnostic_raw(pixel, reflection_index(pixel));
	}
#endif
	if (frame.reflection_options.x == 0u) {
		resolve_reflection_split(pixel, id);
		return;
	}
	bool last = pass_id == PASS_REFLECTION_LAST;
	uint iteration = pass_id == PASS_REFLECTION_FIRST ? 0u : (last ? uint(frame.reflections.z) - 1u : params.samples);
	ivec2 full_pixel = last ? pixel : reflection_pixel(pixel);
	vec3 p, n;
	if (!surface(full_pixel, p, n) || surface_roughness(full_pixel) > frame.reflections.y) {
		if (!last) {
			if ((iteration & 1u) == 0u) {
				imageStore(reflection_filter_a, pixel, vec4(0));
				imageStore(reflection_moments_a, pixel, vec4(0));
			} else {
				imageStore(reflection_filter_b, pixel, vec4(0));
				imageStore(reflection_moments_b, pixel, vec4(0));
			}
		}
		return;
	}
	float roughness = surface_roughness(full_pixel), depth = gi_view_depth(p);
	vec3 view = normalize(params.camera_position.xyz - p);
	vec3 detail_normal = shading_normal(full_pixel);
	vec3 local_view = gi_rotate(gi_rotation_z(detail_normal), view);
	float alpha = max(roughness * roughness, 1e-6), alpha_squared = max(alpha * alpha, 1e-6);
	int full_step = 1 << iteration, full_radius = 2 * full_step;
	int stride = int(frame.reflections.x);
	int half_step = (full_step + stride - 1) / stride, half_radius = (full_radius + stride - 1) / stride;
	ivec2 half_pixel = full_pixel / stride, jitter = ivec2(0);
	if (last) {
		float average = 0.0, squared_average = 0.0, count = 0.0;
		for (int x = -4; x <= 4; x += 2) {
			for (int y = -4; y <= 4; y += 2) {
				ivec2 q = full_pixel + ivec2(x, y);
				if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, ivec2(params.size)))) {
					continue;
				}
				float r = surface_roughness(q);
				average += r;
				squared_average += r * r;
				count += 1.0;
			}
		}
		average /= max(count, 1.0);
		squared_average /= max(count, 1.0);
		float deviation = sqrt(abs(squared_average - average * average));
		float scale = average > 0.0 ? clamp(4.0 * deviation / average, 0.0, 1.0) : 0.0;
		jitter = ivec2(floor((lookup_jitter(full_pixel, 0u) - 0.5) * (float(half_step) * scale) + 0.5));
	}
	vec4 sum = vec4(0);
	vec3 squares = vec3(0);
	float weight = 0.0;
	for (int x = -half_radius; x <= half_radius; x += half_step) {
		for (int y = -half_radius; y <= half_radius; y += half_step) {
			ivec2 q = half_pixel + ivec2(x, y) + jitter;
			ivec2 full_q = q * stride + reflection_phase(params.padding);
			if (any(lessThan(full_q, ivec2(0))) || any(greaterThanEqual(full_q, ivec2(params.size))) || surface_roughness(full_q) > frame.reflections.y) {
				continue;
			}
			vec3 other_p, other_n;
			if (!surface(full_q, other_p, other_n)) {
				continue;
			}
			ReflectionSample sample_value = unpack_reflection(reflection_samples.data[reflection_index(q)]);
			vec3 l = sample_value.direction_pdf.xyz;
			if (sample_value.direction_pdf.w > 0.0) {
				l = normalize(l + params.camera_position.xyz - p);
			}
			float nh = clamp(dot(detail_normal, normalize(view + l)), -1.0, 1.0);
			float pdf = gi_ggx_bounded_pdf(alpha, alpha_squared, nh, local_view);
			float plane = 1.0 - clamp(abs(dot(n, p - other_p) / depth) * 200.0, 0.0, 1.0);
			vec2 delta = vec2(full_q - full_pixel);
			float sigma = 1.065 * float(full_step);
			float gaussian = pow(float(full_step) / (sqrt(2.0 * PI) * sigma), 2.0) * exp(-dot(delta, delta) / (2.0 * sigma * sigma));
			float w = gaussian * plane * pdf;
			sum += reflection_filter_source(q, iteration, false) * w;
			squares += reflection_filter_source(q, iteration, true).rgb * w;
			weight += w;
		}
	}
	if (weight > (last ? 0.0 : 1e-3)) {
		sum /= weight;
		squares /= weight;
	}
	if (last) {
		ReflectionSample result;
		result.position_roughness = vec4(p, roughness);
		result.normal_distance = vec4(n, unpackHalf2x16(packHalf2x16(vec2(sum.w, 0))).x);
		result.direction_pdf = vec4(0);
		vec3 deviation = sqrt(abs(squares - sum.rgb * sum.rgb));
		result.virtual_variance = gi_cache_unpack(gi_cache_pack(vec4(deviation / max(vec3(1.0) - deviation, vec3(1e-3)), 0)));
		result.color_count = gi_cache_unpack(gi_cache_pack(vec4(sum.rgb / max(vec3(1.0) - sum.rgb, vec3(1e-3)), 1)));
		reflections.data[id] = pack_reflection(result);
	} else if ((iteration & 1u) == 0u) {
		imageStore(reflection_filter_a, pixel, sum);
		imageStore(reflection_moments_a, pixel, vec4(sqrt(squares), 1));
	} else {
		imageStore(reflection_filter_b, pixel, sum);
		imageStore(reflection_moments_b, pixel, vec4(sqrt(squares), 1));
	}
}

// ReprojectReflections has two simultaneous history sources: the visible surface
// and the virtual point behind it. Preserve AMD's gather/rejection and blend.
vec4 reflection_history_at(vec2 uv, vec3 normal, float depth) {
	if (frame.grid.w != 0u || any(lessThan(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
		return vec4(0);
	}
	vec2 texel = uv * vec2(params.size) - 0.5;
	ivec2 base = ivec2(floor(texel));
	vec2 fraction = fract(texel);
	const ivec2 offsets[4] = ivec2[](ivec2(0, 1), ivec2(1, 1), ivec2(1, 0), ivec2(0, 0));
	vec4 weights = vec4((1.0 - fraction.x) * fraction.y, fraction.x * fraction.y, fraction.x * (1.0 - fraction.y), (1.0 - fraction.x) * (1.0 - fraction.y));
	vec3 previous_normal = vec3(0);
	vec4 previous_colors[4];
	vec4 previous_depths;
	for (uint i = 0u; i < 4u; i++) {
		ivec2 q = clamp(base + offsets[i], ivec2(0), ivec2(params.size) - 1);
		uint index = uint(q.x) + uint(q.y) * params.size.x;
		Pixel previous = unpack_pixel(previous_pixels.data[index]);
		previous_normal += previous.normal_delta.xyz * weights[i];
		previous_depths[i] = previous.position.w > 0.0 ? dot(previous.position.xyz - frame.previous_eye.xyz, frame.previous_forward.xyz) : 1e30;
		previous_colors[i] = gi_cache_unpack(previous_reflections.data[index].color_count);
	}
	vec4 agreement = exp(-abs(1.0 - max(0.0, dot(normal, previous_normal))) * 1.4) * exp(-abs(previous_depths - depth) / depth);
	if (all(greaterThan(agreement, vec4(0.9)))) {
		return previous_colors[0] * weights.x + previous_colors[1] * weights.y + previous_colors[2] * weights.z + previous_colors[3] * weights.w;
	}
	if (any(greaterThan(agreement, vec4(0.9)))) {
		uint selected = 0u;
		for (uint i = 1u; i < 4u; i++) {
			if (agreement[i] > agreement[selected]) {
				selected = i;
			}
		}
		// Preserve the explicit fallback Load coordinate used by upstream.
		ivec2 q = clamp(ivec2(uv * vec2(params.size)) + offsets[selected], ivec2(0), ivec2(params.size) - 1);
		return gi_cache_unpack(previous_reflections.data[uint(q.x) + uint(q.y) * params.size.x].color_count);
	}
	return vec4(0);
}
void temporal_reflection(ivec2 pixel, uint id) {
	vec3 p, n;
	if (!surface(pixel, p, n) || surface_roughness(pixel) > frame.reflections.y) {
		ReflectionSample empty;
		empty.position_roughness = vec4(0, 0, 0, -1);
		empty.normal_distance = vec4(0);
		empty.direction_pdf = vec4(0);
		empty.color_count = vec4(0);
		empty.virtual_variance = vec4(0);
		reflections.data[id] = pack_reflection(empty);
		return;
	}
	n = texelFetch(primary_shading_normal, pixel, 0).xyz * 2.0 - 1.0;
	ReflectionSample current = unpack_reflection(reflections.data[id]);
	vec3 color = current.color_count.rgb;
	vec3 ray = p - params.camera_position.xyz;
	vec3 virtual_position = p + normalize(ray) * current.normal_distance.w;
	vec4 virtual_clip = frame.previous_view_projection * vec4(virtual_position, 1);
	vec4 surface_clip = frame.previous_view_projection * vec4(previous_surface(pixel, p), 1);
	vec4 old_hit = virtual_clip.w > 0.0 ? reflection_history_at(virtual_clip.xy / virtual_clip.w * 0.5 + 0.5, n, gi_view_depth(p)) : vec4(0);
	vec4 old_surface = surface_clip.w > 0.0 ? reflection_history_at(surface_clip.xy / surface_clip.w * 0.5 + 0.5, n, gi_view_depth(p)) : vec4(0);
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_TEMPORAL
	reflection_diagnostic_write(pixel, 31u, current.color_count);
	reflection_diagnostic_write(pixel, 32u, vec4(current.virtual_variance.rgb, current.normal_distance.w));
	reflection_diagnostic_write(pixel, 33u, old_hit);
	reflection_diagnostic_write(pixel, 34u, old_surface);
	reflection_diagnostic_write(pixel, 38u, vec4(surface_clip.xy / surface_clip.w * 0.5 + 0.5, virtual_clip.xy / virtual_clip.w * 0.5 + 0.5));
#endif
	vec3 hit_color = old_hit.rgb / max(old_hit.w, 1.0), surface_color = old_surface.rgb / max(old_surface.w, 1.0);
	vec3 lo = color - current.virtual_variance.rgb, hi = color + current.virtual_variance.rgb;
	float exposure = params.exposure * frame.glossy.w;
	if (frame.near_field.w != 0.0) {
		exposure /= texelFetch(temporal_auto_exposure, ivec2(0), 0).r;
	}
	float scale = -100.0 * exposure;
	float hit_weight = old_hit.w > 0.0 ? clamp(exp2(scale * luma(hit_color - color)), 0.0, 1.0) : 0.0;
	float surface_weight = old_surface.w > 0.0 ? clamp(exp2(scale * luma(surface_color - color)), 0.0, 1.0) : 0.0;
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_TEMPORAL
	reflection_diagnostic_write(pixel, 35u, vec4(hit_weight, surface_weight, exposure, 1));
#endif
	float weight = max(hit_weight + surface_weight, 1e-7);
	vec3 dual_color = (hit_weight * clamp(hit_color, lo, hi) + surface_weight * clamp(surface_color, lo, hi)) / weight;
	float count = (hit_weight * old_hit.w + surface_weight * old_surface.w) / weight;
	vec4 lighting = vec4(dual_color * count, count) + vec4(color, 1);
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.size);
	vec2 vignette_uv = uv * (1.0 - uv.yx);
	float max_count = max(8.0 * pow(15.0 * vignette_uv.x * vignette_uv.y, 0.25), 1.0);
	if (lighting.w > max_count) {
		lighting *= max_count / lighting.w;
	}
	current.color_count = gi_cache_unpack(gi_cache_pack(vec4(gi_denoiser_remove_nans(vec4(lighting.rgb, 0)).rgb, lighting.w)));
	reflections.data[id] = pack_reflection(current);
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_TEMPORAL
	reflection_diagnostic_write(pixel, 36u, current.color_count);
#endif
}
void output_reflection_pixel(ivec2 pixel, uint id) {
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_OUTPUT
	if (reflection_diagnostic_base(pixel) != INVALID) {
		vec3 diagnostic_position = vec3(0), diagnostic_normal = vec3(0);
		bool diagnostic_valid = surface(pixel, diagnostic_position, diagnostic_normal);
		reflection_diagnostic_write(pixel, 1u, vec4(diagnostic_normal, diagnostic_valid ? 1.0 : 0.0));
		reflection_diagnostic_write(pixel, 2u, vec4(shading_normal(pixel), 0));
		reflection_diagnostic_write(pixel, 3u, vec4(diagnostic_position, diagnostic_valid ? surface_roughness(pixel) : -1.0));
		ivec2 half_pixel = pixel / int(frame.reflections.x);
		if (frame.reflection_options.x == 2u && all(equal(pixel, reflection_pixel(half_pixel)))) {
			reflection_diagnostic_raw(half_pixel, reflection_index(half_pixel));
		}
	}
#endif
	vec3 p, n;
	vec3 value = vec3(0);
	if (surface(pixel, p, n)) {
		float roughness = surface_roughness(pixel);
		if (roughness > frame.reflections.y) {
			// ResolveGI1 uses the denoised irradiance, before native ambient/exposure.
			vec4 irradiance = gi_cache_unpack(pixels.data[id].color);
			value = irradiance.rgb / (max(irradiance.w, 1.0) * PI);
		} else if (frame.reflection_options.x != 2u) {
			vec4 color = gi_cache_unpack(reflections.data[id].color_count);
			value = color.rgb / max(color.w, 1.0);
		} else {
			vec3 color = reflection_raw(pixel / int(frame.reflections.x)).rgb;
			value = gi_denoiser_remove_nans(vec4(color / max(vec3(1.0) - color, vec3(1e-3)), 0)).rgb;
		}
	}
	imageStore(output_reflection, pixel, vec4(value * params.exposure, 1));
#if defined(AMD_GI_REFLECTION_RECORDING) && AMD_GI_PASS == PASS_REFLECTION_OUTPUT
	reflection_diagnostic_write(pixel, 37u, vec4(value * params.exposure, 1));
	reflection_diagnostic_write(pixel, 39u, uintBitsToFloat(uvec4(pixel, params.padding, 1)));
#endif
}
