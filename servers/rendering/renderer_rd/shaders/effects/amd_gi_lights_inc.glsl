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

// Capsaicin v1.3 GridStream default: 16 cells/axis, 64 strided reservoirs,
// expanded-cell volume weights, jittered lookup and eight segments without
// replacement. Analytic lights and emissive triangles share one distribution.
uint gi_environment_count() {
	return (uint(frame.sky.w) >> 2u) & 1u;
}
uint gi_light_count() {
	return params.light_count + frame.emitters.x + gi_environment_count();
}
uint ordered_float(float f) {
	uint u = floatBitsToUint(f);
	return (u & 0x80000000u) != 0u ? ~u : u ^ 0x80000000u;
}
float unordered_float(uint u) {
	return uintBitsToFloat((u & 0x80000000u) != 0u ? u ^ 0x80000000u : ~u);
}
void reset_light_bounds() {
	light_grid.minimum = uvec4(0xffffffffu);
	light_grid.maximum = uvec4(0u);
}
void register_light_bounds(vec3 position) {
	// requestLightSampleLocation is part of registering the visibility hit,
	// as in Capsaicin. No full-capacity ray scan or extra bounds pass.
	for (uint axis = 0u; axis < 3u; axis++) {
		atomicMin(light_grid.minimum[axis], ordered_float(position[axis]));
		atomicMax(light_grid.maximum[axis], ordered_float(position[axis]));
	}
}
void light_grid_configuration(out vec3 minimum, out vec3 cell_size, out uvec3 dimensions) {
	if (light_grid.minimum.x == 0xffffffffu) {
		minimum = params.camera_position.xyz - vec3(1);
		cell_size = vec3(2);
		dimensions = uvec3(1);
		return;
	}
	minimum = vec3(unordered_float(light_grid.minimum.x), unordered_float(light_grid.minimum.y), unordered_float(light_grid.minimum.z));
	vec3 maximum = vec3(unordered_float(light_grid.maximum.x), unordered_float(light_grid.maximum.y), unordered_float(light_grid.maximum.z));
	// Preserve AMD's actual bounds, including flat directions. The approved
	// zero-extent policy selects the sole cell without dividing by zero.
	vec3 extent = maximum - minimum;
	float scale = max(max(extent.x, extent.y), extent.z) / 16.0;
	dimensions = scale == 0.0 ? uvec3(1) : uvec3(max(ceil(extent / scale), vec3(1)));
	cell_size = extent / vec3(dimensions);
}
uvec3 light_grid_cell(vec3 position, vec3 minimum, vec3 cell_size, uvec3 dimensions, vec3 jitter) {
	uvec3 cell = uvec3(0);
	for (uint axis = 0u; axis < 3u; axis++) {
		if (dimensions[axis] > 1u) {
			cell[axis] = uint(clamp(floor((position[axis] - minimum[axis]) / cell_size[axis] + jitter[axis]), 0.0, float(dimensions[axis] - 1u)));
		}
	}
	return cell;
}
// Proposal colors are recomputed for this viewport every frame. This is not
// material caching across time: texture/uniform/animation changes remain live.
const uint GI_GRID_ENTRIES = 16u * 16u * 16u * 64u;
uint proposal_strata() {
	return max(min(64u, gi_light_count()), 1u);
}
uint proposal_leaf_count() {
	return (gi_light_count() + proposal_strata() * 64u - 1u) / (proposal_strata() * 64u);
}
uint proposal_leaf_offset() {
	return GI_GRID_ENTRIES + frame.emitters.x;
}
uint proposal_top_offset() {
	return proposal_leaf_offset() + proposal_leaf_count() * 64u;
}

// Zero RGB is a removable zero-weight candidate only when the geometric
// weight is finite. Keep exceptional/near-corner geometry in the original
// stream, including possible 0 * infinity / NaN cases. Conservative bounds
// deliberately retain ambiguous candidates instead of changing their behavior.
bool finite_zero_proposal(Emitter light) {
	vec3 minimum, size;
	uvec3 dimensions;
	light_grid_configuration(minimum, size, dimensions);
	vec3 center = light.position_area.xyz + (light.edge1_power.xyz + light.edge2.xyz) / 3.0;
	vec3 normal = normalize(cross(light.edge1_power.xyz, light.edge2.xyz));
	float magnitude = max(max(max(abs(center.x), abs(center.y)), abs(center.z)), max(max(abs(minimum.x), abs(minimum.y)), abs(minimum.z)));
	if (any(isnan(center)) || any(isinf(center)) || any(isnan(normal)) || any(isinf(normal)) || any(isnan(minimum)) || any(isinf(minimum)) || any(isnan(size)) || any(isinf(size)) || magnitude > 1000000.0 || any(greaterThan(abs(size), vec3(1000000.0))) || !(light.position_area.w <= 1e12)) {
		return false;
	}
	vec3 nearest = minimum;
	for (uint axis = 0u; axis < 3u; axis++) {
		if (size[axis] != 0.0) {
			if (abs(size[axis]) < 0.001) {
				return false;
			}
			float corner = clamp(round((center[axis] - minimum[axis]) / size[axis] + 0.5), 0.0, float(dimensions[axis] + 1u));
			nearest[axis] += (corner - 0.5) * size[axis];
		}
	}
	// Covers roundoff in the two equivalent lattice-coordinate expressions.
	float margin = max(0.01, max(magnitude, max(max(abs(size.x), abs(size.y)), abs(size.z))) * 0.00001);
	return length(center - nearest) > margin;
}
void prepare_light(uint light_index) {
	if (light_index >= gi_light_count()) {
		return;
	}
	bool keep = true;
	uint prefix = params.light_count + gi_environment_count();
	if (light_index >= prefix) {
		uint emitter = light_index - prefix;
		Emitter light = gi_emitter(emitter);
		vec3 color = vec3(0);
		if (light.position_area.w <= 0.0) {
			keep = false;
		} else {
			color = gi_source_material_filtered(floatBitsToUint(light.edge2.w), floatBitsToUint(light.emission_tile.w), vec2(1.0 / 3.0), true, 0.0, true).emission.rgb;
			keep = !all(equal(color, vec3(0))) || !finite_zero_proposal(light);
		}
		light_grid.data[GI_GRID_ENTRIES + emitter] = uvec4(floatBitsToUint(color), 0u);
	}
	if (keep) {
		uint strata = proposal_strata();
		uint sequence = light_index / strata;
		uint word = proposal_leaf_offset() + (sequence / 64u) * 64u + light_index % strata;
		uint bit = sequence % 64u;
		if (bit < 32u) {
			atomicOr(light_grid.data[word].x, 1u << bit);
		} else {
			atomicOr(light_grid.data[word].y, 1u << (bit - 32u));
		}
	}
}
void prepare_light_mask(uint id) {
	uint leaf = id / 64u, lane = id % 64u;
	if (leaf >= proposal_leaf_count() || lane >= proposal_strata()) {
		return;
	}
	uvec2 mask = light_grid.data[proposal_leaf_offset() + id].xy;
	if (any(notEqual(mask, uvec2(0)))) {
		uint word = proposal_top_offset() + (leaf / 64u) * 64u + lane;
		uint bit = leaf % 64u;
		if (bit < 32u) {
			atomicOr(light_grid.data[word].x, 1u << bit);
		} else {
			atomicOr(light_grid.data[word].y, 1u << (bit - 32u));
		}
	}
}
float gi_volume_weight(uint index, vec3 minimum, vec3 extent, bool prepared) {
	vec3 color;
	float weight = 0.0;
	if (index < gi_environment_count()) {
		vec3 total = vec3(0);
		for (int axis = 0; axis < 3; axis++) {
			vec3 direction = vec3(0);
			direction[axis] = 1.0;
			float mip = float(textureQueryLevels(sky_radiance));
			total += environment_radiance_lod(direction, false, mip) + environment_radiance_lod(-direction, false, mip);
		}
		return luma(total) * (4.0 * PI / 6.0);
	}
	index -= gi_environment_count();
	if (index < params.light_count) {
		Light light = gi_light(index);
		color = abs(light.color);
		if (light.type == 0u) {
			return luma(color);
		}
		vec3 direction = minimum + extent * 0.5 - light.position;
		float radius = length(extent * 0.5);
		if (dot(direction, direction) > (radius + light.range) * (radius + light.range)) {
			return 0.0;
		}
		if (light.type == 2u) {
			// Reference Hale cone/sphere rejection. Native direction points
			// toward the light, matching Capsaicin's negative cone normal.
			float sine = sqrt(max(1.0 - light.cos_angle * light.cos_angle, 0.0));
			float tan_squared_plus_one = 1.0 / max(light.cos_angle * light.cos_angle, 1e-8);
			vec3 c = direction * sine - light.direction * radius;
			float offset = radius * sine;
			bool intersects = dot(direction + light.direction * offset, light.direction) < 0.0 ? dot(c, c) <= pow(dot(c, light.direction), 2.0) * tan_squared_plus_one : dot(direction, direction) <= radius * radius;
			if (!intersects) {
				return 0.0;
			}
		}
		for (uint corner = 0u; corner < 8u; corner++) {
			vec3 p = minimum + extent * vec3(corner & 1u, (corner >> 1u) & 1u, (corner >> 2u) & 1u);
			float distance = length(p - light.position);
			float nd = distance / max(light.range, 0.0001);
			// Preserve the game's native attenuation in the reference volume
			// integral; spot rejection above supplies the cone bound.
			weight += pow(max(1.0 - pow(nd, 4.0), 0.0), 2.0) * pow(max(distance, 0.0001), -light.decay);
		}
	} else {
		Emitter light = gi_emitter(index - params.light_count);
		if (light.position_area.w <= 0.0) {
			return 0.0;
		}
		// sampleLightVolume: centroid with the full triangle's UV footprint.
		color = prepared ? uintBitsToFloat(light_grid.data[GI_GRID_ENTRIES + index - params.light_count].xyz) : gi_source_material_filtered(floatBitsToUint(light.edge2.w), floatBitsToUint(light.emission_tile.w), vec2(1.0 / 3.0), true, 0.0, true).emission.rgb;
		vec3 center = light.position_area.xyz + (light.edge1_power.xyz + light.edge2.xyz) / 3.0;
		vec3 normal = normalize(cross(light.edge1_power.xyz, light.edge2.xyz));
		for (uint corner = 0u; corner < 8u; corner++) {
			vec3 delta = minimum + extent * vec3(corner & 1u, (corner >> 1u) & 1u, (corner >> 2u) & 1u) - center;
			float d2 = dot(delta, delta);
			weight += d2 > 0.0 ? abs(dot(normal, delta * inversesqrt(d2))) / d2 : 0.0;
		}
		weight *= light.position_area.w;
	}
	return luma(color) * weight * 0.125;
}
// The reference streaming reservoir uses a single residual variate until a
// replacement is selected, then restarts it. Retain that random consumption.
bool gi_stream_select(float weight, inout float total, inout float residual, inout float none, inout uint rng) {
	if (weight <= 0.0) {
		return false;
	}
	total += weight;
	float probability = weight / total;
	residual -= probability * none;
	none *= 1.0 - probability;
	if (residual <= 0.0) {
		residual = random_float(rng);
		none = 1.0;
		return true;
	}
	return false;
}
void build_light_grid(uint cell_index, uint lane) {
	vec3 minimum, cell_size;
	uvec3 dimensions;
	light_grid_configuration(minimum, cell_size, dimensions);
	if (cell_index >= dimensions.x * dimensions.y * dimensions.z) {
		return;
	}
	uint count = min(64u, gi_light_count());
	if (lane >= count) {
		return;
	}
	uvec3 cell = uvec3(cell_index % dimensions.x, (cell_index / dimensions.x) % dimensions.y, cell_index / (dimensions.x * dimensions.y));
	minimum += (vec3(cell) - 0.5) * cell_size;
	uint rng = gi_random(cell_index * count + lane);
	float residual = random_float(rng), none = 1.0, total = 0.0, selected_weight = 0.0;
	uint selected = INVALID;
	// Ascending bits preserve the original light % count strata, candidate
	// order and residual RNG updates. Zero candidates consume no random values.
	uint top_count = (proposal_leaf_count() + 63u) / 64u;
	for (uint top = 0u; top < top_count; top++) {
		uvec2 top_mask = light_grid.data[proposal_top_offset() + top * 64u + lane].xy;
		for (uint word_half = 0u; word_half < 2u; word_half++) {
			uint bits = top_mask[word_half];
			while (bits != 0u) {
				uint leaf = top * 64u + word_half * 32u + uint(findLSB(bits));
				bits &= bits - 1u;
				uvec2 leaf_mask = light_grid.data[proposal_leaf_offset() + leaf * 64u + lane].xy;
				for (uint lower_half = 0u; lower_half < 2u; lower_half++) {
					uint lower_bits = leaf_mask[lower_half];
					while (lower_bits != 0u) {
						uint light = (leaf * 64u + lower_half * 32u + uint(findLSB(lower_bits))) * count + lane;
						lower_bits &= lower_bits - 1u;
						float weight = gi_volume_weight(light, minimum, cell_size * 2.0, true);
						if (gi_stream_select(weight, total, residual, none, rng)) {
							selected = light;
							selected_weight = weight;
						}
					}
				}
			}
		}
	}
#ifdef AMD_GI_VALIDATE_LIGHT_GRID
	uint reference_rng = gi_random(cell_index * count + lane);
	float reference_residual = random_float(reference_rng), reference_none = 1.0, reference_total = 0.0, reference_weight = 0.0;
	uint reference_selected = INVALID;
	for (uint light = lane; light < gi_light_count(); light += count) {
		float weight = gi_volume_weight(light, minimum, cell_size * 2.0, false);
		if (gi_stream_select(weight, reference_total, reference_residual, reference_none, reference_rng)) {
			reference_selected = light;
			reference_weight = weight;
		}
	}
	if (selected != reference_selected || floatBitsToUint(selected_weight) != floatBitsToUint(reference_weight) || floatBitsToUint(total) != floatBitsToUint(reference_total) || rng != reference_rng || floatBitsToUint(residual) != floatBitsToUint(reference_residual) || floatBitsToUint(none) != floatBitsToUint(reference_none)) {
		atomicAdd(light_grid.maximum.w, 1u);
	}
#endif
	light_grid.data[cell_index * 64u + lane] = uvec4(selected, floatBitsToUint(selected_weight), floatBitsToUint(total), 0u);
}
uint light_grid_segment(uint start, uint count, inout uint rng, out float pdf) {
	float residual = random_float(rng), none = 1.0, total = 0.0, selected_weight = 0.0;
	uint selected = INVALID;
	for (uint i = 0u; i < count; i++) {
		uvec4 entry = light_grid.data[start + i];
		if (gi_stream_select(uintBitsToFloat(entry.z), total, residual, none, rng)) {
			selected = entry.x;
			selected_weight = uintBitsToFloat(entry.y);
		}
	}
	pdf = total > 0.0 ? selected_weight / total : 0.0;
	return selected;
}
vec3 gi_light_target_normal(RayHit ray, vec3 brdf_normal, uint index, vec2 sample_params, float solid_angle, out vec3 direction, out float distance) {
	vec3 incident;
	if (index < gi_environment_count()) {
		float theta = 2.0 * PI * sample_params.x;
		float cosine = 1.0 - sample_params.y;
		float sine = sin(acos(cosine));
		direction = normalize(basis(ray.normal_mask.xyz) * vec3(sine * cos(theta), sine * sin(theta), cosine));
		distance = params.max_distance;
		incident = environment_radiance_cone(direction, solid_angle);
	} else if (index - gi_environment_count() < params.light_count) {
		index = (index - gi_environment_count());
		// Passing the light direction as normal removes the cosine from the
		// shared native irradiance helper; the reference BRDF supplies it.
		Light light = gi_light(index);
		direction = light.type == 0u ? light.direction : normalize(light.position - ray.position.xyz);
		incident = unshadowed_irradiance(index, ray.position.xyz, direction, floatBitsToUint(ray.normal_mask.w), direction, distance);
	} else {
		Emitter light = gi_emitter(index - gi_environment_count() - params.light_count);
		vec3 delta = light.position_area.xyz + sample_params.x * light.edge1_power.xyz + sample_params.y * light.edge2.xyz - ray.position.xyz;
		float d2 = dot(delta, delta);
		distance = sqrt(d2);
		direction = distance > 0.0 ? delta / distance : ray.normal_mask.xyz;
		vec3 normal = normalize(cross(light.edge1_power.xyz, light.edge2.xyz));
		// evaluateAreaLightConeAM: retain AMD's area cap and projected cone.
		float width = min(light.position_area.w, solid_angle * distance);
		float lod_offset = -0.5 * log2(2.0 * light.position_area.w) + log2(width / abs(dot(direction, normal)));
		GISourceMaterial material = gi_source_material_filtered(floatBitsToUint(light.edge2.w), floatBitsToUint(light.emission_tile.w), sample_params, true, lod_offset, true);
		// The approved native encoding supplies emitted RGB as a function with
		// unit base factor. Godot opacity is a separate hit-coverage input;
		// it is not an additional alpha channel of that emission function.
		vec3 emission = material.emission.rgb;
		incident = d2 > 0.0 && light.position_area.w > 0.0 ? emission * abs(dot(normal, -direction)) / d2 : vec3(0);
	}
	return incident * gi_rough_brdf(ray.diffuse.rgb, brdf_normal, -ray.direction_cache.xyz, direction);
}
vec3 gi_light_target(RayHit ray, uint index, vec2 sample_params, float solid_angle, out vec3 direction, out float distance) {
	return gi_light_target_normal(ray, ray.normal_mask.xyz, index, sample_params, solid_angle, direction, distance);
}
float gi_light_visibility(RayHit ray, uint index, vec3 direction, float distance) {
	if (index >= gi_environment_count() && index - gi_environment_count() < params.light_count) {
		return light_visibility((index - gi_environment_count()), ray.position.xyz, ray.geometry_normal.xyz, direction, distance);
	}
	uint blocker;
	vec3 position, uv, normal;
	vec3 origin = gi_offset_position(ray.position.xyz, ray.geometry_normal.xyz);
	if (index >= gi_environment_count()) {
		direction = ray.position.xyz + direction * distance - origin;
		distance = 1.0 - 1.0 / 16384.0;
	}
	return trace(origin, direction, distance, 0xffffffffu, blocker, position, uv, normal) ? 0.0 : 1.0;
}
// reservoir.hlsl: updateReservoirRadianceBRDF / mergeReservoirsRadiance.
// Keep the incremental MIS normalization, including zero-target updates.
void gi_reservoir_merge(uint light, vec2 sample_params, float target, float incoming_weight, float incoming_count, inout uint selected, inout vec2 selected_params, inout float selected_target, inout float weight, inout float count, inout uint rng) {
	const float minimum = 1.1754943508222875e-38;
	float denominator = max(count + incoming_count, minimum);
	float w1 = (count / denominator) * selected_target * weight;
	float w2 = (incoming_count / denominator) * target * incoming_weight;
	float sum = w1 + w2;
	if (random_float(rng) * sum < w2) {
		selected = light;
		selected_params = sample_params;
		selected_target = target;
	}
	weight = sum / max(selected_target, minimum);
	count += incoming_count;
}
vec3 reservoir_material_albedo(vec3 value) {
	// packMaterial/unpackMaterial: rough dielectric uses gamma RGB565.
	vec3 scale = vec3(31, 63, 31);
	return pow(vec3(uvec3(pow(clamp(value, 0.0, 1.0), vec3(1.0 / 2.2)) * scale)) / scale, vec3(2.2));
}
vec3 resampled_direct(RayHit ray, inout uint rng, uint hit_id, out bool update_cell) {
	update_cell = false;
	vec3 shading_normal = ray.normal_mask.xyz;
	vec3 minimum, cell_size;
	uvec3 dimensions;
	light_grid_configuration(minimum, cell_size, dimensions);
	vec3 jitter = vec3(random_float(rng), random_float(rng), random_float(rng)) - 0.5;
	uvec3 cell = light_grid_cell(ray.position.xyz, minimum, cell_size, dimensions, jitter);
	uint base = (cell.x + dimensions.x * (cell.y + dimensions.y * cell.z)) * 64u;
	uint count = min(64u, gi_light_count()), segment_size = (count + 7u) / 8u;
	uint candidates[8];
	float pdfs[8];
	uint valid = 0u;
	for (uint start = 0u; start < count; start += segment_size) {
		float pdf;
		uint light = light_grid_segment(base + start, min(segment_size, count - start), rng, pdf);
		if (light != INVALID && pdf > 0.0) {
			candidates[valid] = light;
			pdfs[valid++] = pdf;
		}
	}
	uint selected = 0u;
	vec2 selected_params = vec2(0);
	float selected_target = 0.0, weight = 0.0, confidence = 0.0;
	for (uint i = 0u; i < valid; i++) {
		vec2 sample_params = vec2(random_float(rng), random_float(rng));
		float area_pdf = 1.0;
		if (candidates[i] < gi_environment_count()) {
			area_pdf = 1.0 / (2.0 * PI);
		} else if (candidates[i] >= params.light_count + gi_environment_count()) {
			float root = sqrt(sample_params.x);
			sample_params = vec2(1.0 - root, sample_params.y * root);
			area_pdf = 1.0 / gi_emitter(candidates[i] - gi_environment_count() - params.light_count).position_area.w;
		} else {
			sample_params = vec2(0);
		}
		vec3 direction;
		float distance;
		float target = luma(abs(gi_light_target(ray, candidates[i], sample_params, 4.0 * PI / (8.0 * 1.5), direction, distance)));
		// Reference fast merge divides the proposal PDF by actual valid segments.
		float pdf = (pdfs[i] / float(valid)) * area_pdf;
		gi_reservoir_merge(candidates[i], sample_params, target, 1.0 / max(pdf, 1.1754943508222875e-38), 1.0, selected, selected_params, selected_target, weight, confidence, rng);
	}
	if (confidence <= 0.0 || !(weight < 3.402823466e38)) {
		return vec3(0);
	}
	update_cell = true;
	if (frame.motion.y != 0u && hit_id != INVALID && hit_id >= primary_ray_count()) {
		// Approved correction to UpdateMultibounceCells: the compact shadow-ray
		// queue and visibility hits have different indices. Store this valid
		// shadow ray's bypass on its actual hit, retaining AMD's reconstructed
		// origin-to-hit distance and cell-size predicate.
		hit_samples.data[hit_id].links.w = uint(ray.position.w < cache_cell_size(ray.position.xyz));
	}
	uint resample_rng = frame.tracing.w != 0u ? gi_random(atomicAdd(work.counts.w, 1u)) : 0u;
	if (frame.tracing.w != 0u && hit_id != INVALID) {
		reservoir_insert(hit_id, reservoir_jitter(ray.position.xyz, ray.normal_mask.xyz, rng));
	}
	// These values cross the same packed shadow-ray handoff as AMD, even
	// when world-space resampling is disabled.
	selected_params = unpackHalf2x16(packHalf2x16(selected_params));
	ray.diffuse.rgb = reservoir_material_albedo(ray.diffuse.rgb);
	if (frame.tracing.w != 0u) {
		ray.normal_mask.xyz = unpack_reservoir_normal(pack_reservoir_normal(ray.normal_mask.xyz));
		rng = resample_rng;
		uint entry = reservoir_find_previous(reservoir_jitter(ray.position.xyz, ray.normal_mask.xyz, rng));
		if (entry != INVALID) {
			uint old_count = previous_light_reservoirs.data[RESERVOIR_ENTRIES + entry];
			uint start = reservoir_previous_prefix(entry), increment = (old_count + 3u) / 4u;
			uint offset = random_bits(rng) % increment;
			vec3 direction;
			float distance;
			float target = luma(abs(gi_light_target(ray, selected, selected_params, 4.0 * PI / (8.0 * 12000.0), direction, distance)));
			float fresh_weight = weight;
			uint fresh_light = selected;
			vec2 fresh_params = selected_params;
			selected = 0u;
			selected_params = vec2(0);
			selected_target = 0.0;
			weight = 0.0;
			confidence = 0.0;
			gi_reservoir_merge(fresh_light, fresh_params, target, fresh_weight, 1.0, selected, selected_params, selected_target, weight, confidence, rng);
			for (uint i = 0u; i < old_count; i += increment) {
				uint old_id = previous_light_reservoirs.data[reservoir_values_offset() + start + ((i + offset) % old_count)];
				uvec4 old = reservoir_load_previous(old_id);
				uint light = old.x;
				float merged_count = min(unpackHalf2x16(old.w).x, 20.0);
				// Approved reference correction: a nonzero-to-nonzero light-list
				// shrink retains history, but an out-of-list index is not a light.
				if (light >= gi_light_count() || merged_count <= 0.0 || !(uintBitsToFloat(old.z) < 3.402823466e38)) {
					continue;
				}
				vec3 old_normal = unpack_reservoir_normal(previous_light_reservoirs.data[reservoir_normals_offset() + old_id]);
				float agreement = max(dot(ray.normal_mask.xyz, old_normal), 0.0);
				if (pow(agreement, 4.0) < 0.5) {
					continue;
				}
				vec2 sample_params = unpackHalf2x16(old.y);
				vec3 direction;
				float distance;
				float target = luma(abs(gi_light_target(ray, light, sample_params, 4.0 * PI / (8.0 * 12000.0), direction, distance)));
				gi_reservoir_merge(light, sample_params, target, uintBitsToFloat(old.z), merged_count, selected, selected_params, selected_target, weight, confidence, rng);
			}
		}
	}
	selected_params = unpackHalf2x16(packHalf2x16(selected_params));
	vec3 direction;
	float distance;
	// PopulateCells reconstructs source normals; reservoir packing only applies
	// during resampling. Its BRDF/ray offset use geometry, while environment
	// sampling uses the distinct interpolated vertex normal.
	ray.normal_mask.xyz = shading_normal;
	vec3 value = gi_light_target_normal(ray, ray.geometry_normal.xyz, selected, selected_params, 4.0 * PI / (8.0 * 12000.0), direction, distance);
	float visibility = gi_light_visibility(ray, selected, direction, distance);
	if (frame.tracing.w != 0u && hit_id != INVALID) {
		// PopulateCellsHandleHit invalidates W for blocked light samples.
		reservoir_store(hit_id, uvec4(selected, packHalf2x16(selected_params), floatBitsToUint(visibility > 0.0 ? weight : 0.0), packHalf2x16(vec2(confidence, 1.0))), ray.normal_mask.xyz);
	}
	return value * (weight * visibility);
}
vec3 diffuse_hit_emission(RayHit ray) {
	return ray.emission.rgb;
}
vec3 shade_direct(RayHit ray, inout uint rng, uint hit_id, out bool update_cell) {
	update_cell = false;
	// GenerateReservoirs stops at an emissive primary hit; Le is injected into
	// the screen probe directly, rather than spread through the spatial cache.
	if ((hit_id == INVALID || hit_id < primary_ray_count()) && dot(ray.emission.rgb, ray.emission.rgb) > 0.0) {
		return vec3(0);
	}
	return gi_light_count() > 0u ? resampled_direct(ray, rng, hit_id, update_cell) : vec3(0);
}

vec3 shade_direct(RayHit ray, inout uint rng, uint hit_id) {
	bool update_cell;
	return shade_direct(ray, rng, hit_id, update_cell);
}
