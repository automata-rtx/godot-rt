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
uint gi_light_count() {
	return params.light_count + frame.emitters.x + 1u;
}
uint ordered_float(float f) {
	uint u = floatBitsToUint(f);
	return (u & 0x80000000u) != 0u ? ~u : u ^ 0x80000000u;
}
float unordered_float(uint u) {
	return uintBitsToFloat((u & 0x80000000u) != 0u ? u ^ 0x80000000u : ~u);
}
void light_grid_bounds(uint id) {
	if (id >= primary_ray_count() * (params.bounces != 0u ? 2u : 1u)) {
		return;
	}
	RayHit hit = id < primary_ray_count() ? rays.data[id] : secondary_rays.data[id - primary_ray_count()];
	if (hit.position.w <= 0.0) {
		return;
	}
	for (uint axis = 0u; axis < 3u; axis++) {
		atomicMin(light_grid.minimum[axis], ordered_float(hit.position[axis]));
		atomicMax(light_grid.maximum[axis], ordered_float(hit.position[axis]));
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
	// Degenerate (planar or single-hit) bounds still need a finite cell.
	vec3 extent = max(maximum - minimum, vec3(1e-5));
	float scale = max(max(extent.x, extent.y), extent.z) / 16.0;
	dimensions = uvec3(clamp(ceil(extent / scale), vec3(1), vec3(16)));
	cell_size = extent / vec3(dimensions);
}
float gi_volume_weight(uint index, vec3 minimum, vec3 extent) {
	vec3 color;
	float weight = 0.0;
	if (index == gi_light_count() - 1u) {
		vec3 total = vec3(0);
		for (int axis = 0; axis < 3; axis++) {
			vec3 direction = vec3(0);
			direction[axis] = 1.0;
			total += environment_radiance(direction, false) + environment_radiance(-direction, false);
		}
		return luma(total) * (4.0 * PI / 6.0);
	}
	if (index < params.light_count) {
		Light light = lights.data[index];
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
		Emitter light = lights.emitters[frame.emitters.y + index - params.light_count];
		if (light.position_area.w <= 0.0) {
			return 0.0;
		}
		color = light.emission_tile.rgb;
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
	for (uint light = lane; light < gi_light_count(); light += count) {
		float weight = gi_volume_weight(light, minimum, cell_size * 2.0);
		if (gi_stream_select(weight, total, residual, none, rng)) {
			selected = light;
			selected_weight = weight;
		}
	}
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
vec3 gi_light_target(RayHit ray, uint index, vec2 sample_params, out vec3 direction, out float distance) {
	vec3 incident;
	if (index == gi_light_count() - 1u) {
		float theta = 2.0 * PI * sample_params.x;
		float cosine = 1.0 - sample_params.y;
		float sine = sin(acos(cosine));
		direction = normalize(basis(ray.normal_mask.xyz) * vec3(sine * cos(theta), sine * sin(theta), cosine));
		distance = params.max_distance;
		incident = environment_radiance(direction, false);
	} else if (index < params.light_count) {
		// Passing the light direction as normal removes the cosine from the
		// shared native irradiance helper; the reference BRDF supplies it.
		Light light = lights.data[index];
		direction = light.type == 0u ? light.direction : normalize(light.position - ray.position.xyz);
		incident = unshadowed_irradiance(index, ray.position.xyz, direction, floatBitsToUint(ray.normal_mask.w), direction, distance);
	} else {
		Emitter light = lights.emitters[frame.emitters.y + index - params.light_count];
		vec3 delta = light.position_area.xyz + sample_params.x * light.edge1_power.xyz + sample_params.y * light.edge2.xyz - ray.position.xyz;
		float d2 = dot(delta, delta);
		distance = sqrt(d2);
		direction = distance > 0.0 ? delta / distance : ray.normal_mask.xyz;
		vec3 uv = atlas_tile_position(floatBitsToUint(light.emission_tile.w), sample_params);
		vec3 emission = textureLod(emission_atlas, uv, 0).rgb * textureLod(albedo_atlas, uv, 0).a;
		vec3 normal = normalize(cross(light.edge1_power.xyz, light.edge2.xyz));
		incident = d2 > 0.0 && light.position_area.w > 0.0 ? emission * abs(dot(normal, -direction)) / d2 : vec3(0);
	}
	return incident * gi_rough_brdf(ray.diffuse.rgb, ray.normal_mask.xyz, -ray.direction_cache.xyz, direction);
}
float gi_light_visibility(RayHit ray, uint index, vec3 direction, float distance) {
	if (index < params.light_count) {
		return light_visibility(index, ray.position.xyz, ray.normal_mask.xyz, direction, distance);
	}
	uint blocker;
	vec3 position, uv, normal;
	vec3 origin = gi_offset_position(ray.position.xyz, ray.normal_mask.xyz);
	if (index != gi_light_count() - 1u) {
		direction = ray.position.xyz + direction * distance - origin;
		distance = 1.0 - 1.0 / 16384.0;
	}
	return trace(origin, direction, distance, 0xffffffffu, blocker, position, uv, normal) ? 0.0 : 1.0;
}
void gi_reservoir_add(uint light, vec2 sample_params, float target, float weight, inout uint selected, inout vec2 selected_params, inout float selected_target, inout float sum, inout uint rng) {
	if (weight <= 0.0 || isnan(weight) || isinf(weight)) {
		return;
	}
	sum += weight;
	if (random_float(rng) * sum < weight) {
		selected = light;
		selected_params = sample_params;
		selected_target = target;
	}
}
vec3 resampled_direct(RayHit ray, inout uint rng, uint hit_id) {
	uint initial_rng = rng;
	vec3 minimum, cell_size;
	uvec3 dimensions;
	light_grid_configuration(minimum, cell_size, dimensions);
	vec3 jitter = vec3(random_float(rng), random_float(rng), random_float(rng)) - 0.5;
	uvec3 cell = uvec3(clamp(floor((ray.position.xyz - minimum) / cell_size + jitter), vec3(0), vec3(dimensions) - 1.0));
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
	uint selected = INVALID;
	vec2 selected_params = vec2(0);
	float selected_target = 0.0, sum = 0.0;
	for (uint i = 0u; i < valid; i++) {
		vec2 sample_params = vec2(random_float(rng), random_float(rng));
		float area_pdf = 1.0;
		if (candidates[i] == gi_light_count() - 1u) {
			area_pdf = 1.0 / (2.0 * PI);
		} else if (candidates[i] >= params.light_count) {
			float root = sqrt(sample_params.x);
			sample_params = vec2(1.0 - root, sample_params.y * root);
			area_pdf = 1.0 / lights.emitters[frame.emitters.y + candidates[i] - params.light_count].position_area.w;
		} else {
			sample_params = vec2(0);
		}
		vec3 direction;
		float distance;
		float target = luma(abs(gi_light_target(ray, candidates[i], sample_params, direction, distance)));
		// Division by valid segments in the proposal cancels the RIS mean.
		gi_reservoir_add(candidates[i], sample_params, target, target / (pdfs[i] * area_pdf), selected, selected_params, selected_target, sum, rng);
	}
	float confidence = 1.0;
	if (frame.tracing.w != 0u && hit_id != INVALID && selected != INVALID) {
		reservoir_insert(hit_id, reservoir_jitter(ray.position.xyz, ray.normal_mask.xyz, rng));
	}
	if (frame.tracing.w != 0u) {
		rng = initial_rng;
		uint entry = reservoir_find_previous(reservoir_jitter(ray.position.xyz, ray.normal_mask.xyz, rng));
		if (entry != INVALID) {
			uint old_count = previous_light_reservoirs.data[RESERVOIR_ENTRIES + entry];
			uint start = reservoir_previous_prefix(entry), increment = (old_count + 3u) / 4u;
			uint offset = random_bits(rng) % increment;
			for (uint i = 0u; i < old_count; i += increment) {
				uint old_id = previous_light_reservoirs.data[reservoir_values_offset() + start + ((i + offset) % old_count)];
				uvec4 old = reservoir_load_previous(old_id);
				uint light = old.x < frame.motion.w ? light_grid.remap[old.x] : INVALID;
				float merged_count = min(unpackHalf2x16(old.w).x, 20.0);
				if (light >= gi_light_count() || merged_count <= 0.0) {
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
				float target = luma(abs(gi_light_target(ray, light, sample_params, direction, distance)));
				gi_reservoir_add(light, sample_params, target, target * uintBitsToFloat(old.z) * merged_count, selected, selected_params, selected_target, sum, rng);
				confidence += merged_count;
			}
		}
	}
	if (selected == INVALID || selected_target <= 0.0) {
		return vec3(0);
	}
	float weight = sum / (confidence * selected_target);
	if (frame.tracing.w != 0u && hit_id != INVALID) {
		reservoir_store(hit_id, uvec4(selected, packHalf2x16(selected_params), floatBitsToUint(weight), packHalf2x16(vec2(confidence, 1.0))), ray.normal_mask.xyz);
	}
	vec3 direction;
	float distance;
	vec3 value = gi_light_target(ray, selected, selected_params, direction, distance);
	return value * (weight * gi_light_visibility(ray, selected, direction, distance));
}
vec3 diffuse_hit_emission(RayHit ray) {
	return ray.emission.rgb;
}
vec3 shade_direct(RayHit ray, inout uint rng, uint hit_id) {
	// GenerateReservoirs stops at an emissive primary hit; Le is injected into
	// the screen probe directly, rather than spread through the spatial cache.
	if ((hit_id == INVALID || hit_id < primary_ray_count()) && dot(ray.emission.rgb, ray.emission.rgb) > 0.0) {
		return vec3(0);
	}
	return gi_light_count() > 0u ? resampled_direct(ray, rng, hit_id) : vec3(0);
}
