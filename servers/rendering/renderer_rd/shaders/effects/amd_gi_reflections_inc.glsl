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
layout(set = 0, binding = 38, std430) restrict buffer ReflectionSamples {
	ReflectionSample data[];
}
reflection_samples;
layout(set = 0, binding = 39, std430) restrict readonly buffer PreviousReflections {
	ReflectionSample data[];
}
previous_reflections;
layout(set = 0, binding = 40, std430) restrict buffer Reflections {
	ReflectionSample data[];
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
	return min(pixel * int(frame.reflections.x) + reflection_phase(params.padding), ivec2(params.size) - 1);
}
float surface_roughness(ivec2 pixel) {
	// Godot packs the material flag in the other half of this channel.
	float r = texelFetch(normal_buffer, pixel, 0).w;
	return clamp((r > 0.5 ? 1.0 - r : r) * (255.0 / 127.0), 0.0, 1.0);
}
float ggx_lambda(float cosine, float alpha) {
	float c2 = max(cosine * cosine, 0.000001);
	return 0.5 * (sqrt(1.0 + alpha * alpha * (1.0 - c2) / c2) - 1.0);
}
float ggx_distribution(float nh, float alpha) {
	float a2 = alpha * alpha;
	float d = nh * nh * (a2 - 1.0) + 1.0;
	return a2 / max(PI * d * d, 1e-12);
}
// Heitz 2018 GGX VNDF, also used by Capsaicin's reflection sampler.
vec3 sample_visible_ggx(vec3 v, float alpha, vec2 u) {
	vec3 vh = normalize(vec3(alpha * v.xy, max(v.z, 0.0001)));
	float lensq = dot(vh.xy, vh.xy);
	vec3 t1 = lensq > 0.0 ? vec3(-vh.y, vh.x, 0) / sqrt(lensq) : vec3(1, 0, 0);
	vec3 t2 = cross(vh, t1);
	float r = sqrt(u.x), phi = 2.0 * PI * u.y;
	float x = r * cos(phi), y = r * sin(phi);
	float s = 0.5 * (1.0 + vh.z);
	y = mix(sqrt(max(0.0, 1.0 - x * x)), y, s);
	vec3 nh = x * t1 + y * t2 + sqrt(max(0.0, 1.0 - x * x - y * y)) * vh;
	return normalize(vec3(alpha * nh.xy, max(0.0, nh.z)));
}
float reflection_kernel(vec3 n, vec3 v, vec3 l, float roughness) {
	float nl = dot(n, l), nv = dot(n, v);
	if (nl <= 0.0 || nv <= 0.0) {
		return 0.0;
	}
	float alpha = max(roughness * roughness, 0.002);
	float nh = max(dot(n, normalize(v + l)), 0.0);
	return ggx_distribution(nh, alpha) / (4.0 * nv * (1.0 + ggx_lambda(nv, alpha) + ggx_lambda(nl, alpha)));
}
float reflection_surface_weight(vec3 p, vec3 n, float roughness, ReflectionSample other) {
	if (other.position_roughness.w < 0.0) {
		return 0.0;
	}
	float plane = abs(dot(other.position_roughness.xyz - p, n));
	float normal_weight = pow(max(dot(n, other.normal_distance.xyz), 0.0), mix(256.0, 16.0, roughness));
	return normal_weight * exp(-plane / max(footprint(p) * 0.05, 0.001) - abs(roughness - other.position_roughness.w) * 32.0);
}
vec3 rough_probe_reflection(ivec2 pixel, vec3 p, vec3 n, vec3 v, float roughness, out bool valid) {
	uint probe = closest_probe(pixel, ivec2(0));
	valid = probe != INVALID;
	if (!valid) {
		return vec3(0);
	}
	Probe source = probes.data[probe];
	valid = dot(n, source.normal.xyz) > 0.8 && abs(dot(source.position.xyz - p, n)) < footprint(p);
	if (!valid) {
		return vec3(0);
	}
	vec3 sum = vec3(0);
	float weight = 0.0;
	mat3 local = basis(source.normal.xyz);
	for (uint i = 0u; i < 64u; i++) {
		vec3 direction = local * hemi_direction((vec2(i & 7u, i >> 3u) + 0.5) / 8.0);
		float w = reflection_kernel(n, v, direction, roughness);
		sum += radiance.data[probe * 64u + i].rgb * w;
		weight += w;
	}
	return clean_color(sum / max(weight, 0.000001));
}
void trace_reflection(ivec2 pixel, uint id) {
	ReflectionSample result;
	result.position_roughness = vec4(0, 0, 0, -1);
	result.normal_distance = vec4(0);
	result.direction_pdf = vec4(0);
	result.color_count = vec4(0);
	result.virtual_variance = vec4(0);
	ivec2 full_pixel = reflection_pixel(pixel);
	vec3 p, n;
	if (!surface(full_pixel, p, n)) {
		reflection_samples.data[id] = result;
		return;
	}
	float roughness = surface_roughness(full_pixel);
	vec3 v = normalize(params.camera_position.xyz - p);
	result.position_roughness = vec4(p, roughness);
	result.normal_distance = vec4(n, -1);
	result.virtual_variance = vec4(p, 0);
	if (roughness >= frame.reflections.y) {
		bool valid;
		vec3 color = rough_probe_reflection(full_pixel, p, n, v, roughness, valid);
		if (valid) {
			// Negative PDF marks an already integrated probe estimate.
			result.direction_pdf.w = -1.0;
			result.color_count = vec4(color, 1);
			reflection_samples.data[id] = result;
			return;
		}
	}
	float alpha = max(roughness * roughness, 0.002);
	mat3 local = basis(n);
	vec3 h = local * sample_visible_ggx(transpose(local) * v, alpha, lookup_jitter(full_pixel));
	vec3 l = reflect(-v, h);
	float nv = max(dot(n, v), 0.0001);
	float pdf = ggx_distribution(max(dot(n, h), 0.0), alpha) / (4.0 * nv * (1.0 + ggx_lambda(nv, alpha)));
	result.direction_pdf = vec4(l, pdf);
	if (dot(n, l) > 0.0) {
		RayHit hit = trace_hit(p + n * 0.002, l);
		vec3 value = environment_radiance(l, true);
		if (hit.position.w > 0.0) {
			uint cell = find_cell(hit.position.xyz, l, hit.position.w);
			vec4 cached = hit.position.w < cache_cell_size(hit.position.xyz) ? vec4(0) : read_cache(cell, false);
			uint state = pcg(id + params.padding * 2891336453u);
			value = hit.emission.rgb + (cached.w > 0.0 ? cached.rgb : shade_transport(hit, state, INVALID));
			result.normal_distance.w = hit.position.w;
			result.virtual_variance.xyz = p + reflect(l, n) * hit.position.w;
		}
		result.color_count = vec4(clean_color(value), 1);
	}
	reflection_samples.data[id] = result;
}
void resolve_reflection(ivec2 pixel, uint id) {
	ReflectionSample center = reflection_samples.data[id];
	vec3 p = center.position_roughness.xyz, n = center.normal_distance.xyz;
	float roughness = center.position_roughness.w;
	if (roughness < 0.0 || center.direction_pdf.w < 0.0) {
		imageStore(reflection_filter_a, pixel, vec4(center.color_count.rgb, 0));
		return;
	}
	vec3 v = normalize(params.camera_position.xyz - p);
	vec3 sum = vec3(0), squared_sum = vec3(0);
	float weight = 0.0;
	int radius = frame.flags.x == 0u || roughness < 0.05 ? 0 : 2;
	for (int y = -radius; y <= radius; y++) {
		for (int x = -radius; x <= radius; x++) {
			ivec2 q = pixel + ivec2(x, y);
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, reflection_size()))) {
				continue;
			}
			ReflectionSample other = reflection_samples.data[reflection_index(q)];
			if (other.direction_pdf.w <= 0.0) {
				continue;
			}
			vec3 l = other.direction_pdf.xyz;
			if (other.normal_distance.w > 0.0) {
				l = normalize(other.position_roughness.xyz + l * other.normal_distance.w - p);
			}
			float w = reflection_surface_weight(p, n, roughness, other) * exp(-float(x * x + y * y) * 0.25);
			w *= reflection_kernel(n, v, l, roughness) / max(other.direction_pdf.w, 1e-8);
			sum += other.color_count.rgb * w;
			squared_sum += other.color_count.rgb * other.color_count.rgb * w;
			weight += w;
		}
	}
	vec3 color = weight > 0.0 ? sum / weight : center.color_count.rgb;
	float variance = luma(max(squared_sum / max(weight, 1e-8) - color * color, vec3(0)));
	imageStore(reflection_filter_a, pixel, vec4(clean_color(color), min(variance, 60000.0)));
}
void temporal_reflection(ivec2 pixel, uint id) {
	ReflectionSample current = reflection_samples.data[id];
	vec4 estimate = imageLoad(reflection_filter_a, pixel);
	current.color_count = vec4(estimate.rgb, 1);
	current.virtual_variance.w = estimate.w;
	float roughness = current.position_roughness.w;
	bool mirror = roughness < 0.1 && current.normal_distance.w > 0.0;
	vec3 point = mirror ? current.virtual_variance.xyz : current.position_roughness.xyz;
	vec4 clip = frame.previous_view_projection * vec4(point, 1);
	if (frame.grid.w == 0u && frame.flags.x != 0u && roughness >= 0.0 && clip.w > 0.0 && !motion_intersects(current.position_roughness.xyz, current.direction_pdf.xyz, current.normal_distance.w > 0.0 ? current.normal_distance.w : params.max_distance)) {
		vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
		vec2 coord = (uv * vec2(params.size) - vec2(reflection_phase(params.padding - 1u)) - 0.5) / frame.reflections.x;
		ivec2 base = ivec2(floor(coord));
		vec4 sum = vec4(0);
		float variance = 0.0, weight = 0.0;
		for (int y = 0; y <= 1; y++) {
			for (int x = 0; x <= 1; x++) {
				ivec2 q = base + ivec2(x, y);
				if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, reflection_size()))) {
					continue;
				}
				ReflectionSample old = previous_reflections.data[reflection_index(q)];
				if (motion_intersects(old.position_roughness.xyz, old.direction_pdf.xyz, old.normal_distance.w > 0.0 ? old.normal_distance.w : params.max_distance)) {
					continue;
				}
				float w = reflection_surface_weight(current.position_roughness.xyz, current.normal_distance.xyz, roughness, old);
				float error = distance(mirror ? old.virtual_variance.xyz : old.position_roughness.xyz, point);
				if (error > footprint(point) * frame.reflections.x || (old.normal_distance.w > 0.0) != (current.normal_distance.w > 0.0)) {
					continue;
				}
				vec2 bilinear = max(vec2(0), 1.0 - abs(vec2(q) - coord));
				w *= bilinear.x * bilinear.y;
				sum += old.color_count * w;
				variance += old.virtual_variance.w * w;
				weight += w;
			}
		}
		if (weight > 0.0001) {
			sum /= weight;
			variance /= weight;
			vec3 lo = estimate.rgb, hi = estimate.rgb;
			for (int y = -1; y <= 1; y++) {
				for (int x = -1; x <= 1; x++) {
					ivec2 q = clamp(pixel + ivec2(x, y), ivec2(0), reflection_size() - 1);
					ReflectionSample other = reflection_samples.data[reflection_index(q)];
					if (reflection_surface_weight(current.position_roughness.xyz, current.normal_distance.xyz, roughness, other) < 0.5) {
						continue;
					}
					vec3 color = imageLoad(reflection_filter_a, q).rgb;
					lo = min(lo, color);
					hi = max(hi, color);
				}
			}
			float sigma = sqrt(max(estimate.w, 0.0));
			sum.rgb = clamp(sum.rgb, max(lo - sigma, vec3(0)), hi + sigma);
			float count = min(sum.w + 1.0, mix(8.0, 32.0, roughness));
			current.color_count = vec4(mix(sum.rgb, estimate.rgb, 1.0 / count), count);
			current.virtual_variance.w = mix(variance, estimate.w, 1.0 / count);
		}
	}
	reflections.data[id] = current;
}
vec4 reflection_filter_input(ivec2 pixel, uint iteration) {
	if (iteration == 0u) {
		ReflectionSample s = reflections.data[reflection_index(pixel)];
		return vec4(s.color_count.rgb, s.virtual_variance.w);
	}
	return (iteration & 1u) != 0u ? imageLoad(reflection_filter_b, pixel) : imageLoad(reflection_filter_a, pixel);
}
void filter_reflection(ivec2 pixel, uint id) {
	ReflectionSample center = reflections.data[id];
	vec4 value = reflection_filter_input(pixel, params.samples);
	vec4 sum = vec4(0);
	float weight = 0.0;
	float roughness = center.position_roughness.w;
	int step_size = 1 << params.samples;
	int radius = roughness < 0.05 || frame.flags.x == 0u ? 0 : 1;
	for (int y = -radius; y <= radius; y++) {
		for (int x = -radius; x <= radius; x++) {
			ivec2 q = pixel + ivec2(x, y) * step_size;
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, reflection_size()))) {
				continue;
			}
			ReflectionSample other = reflections.data[reflection_index(q)];
			vec4 c = reflection_filter_input(q, params.samples);
			float w = reflection_surface_weight(center.position_roughness.xyz, center.normal_distance.xyz, roughness, other);
			float sigma = sqrt(max(value.w + c.w, 0.000001));
			w *= exp(-abs(luma(c.rgb) - luma(value.rgb)) / (4.0 * sigma + 0.01));
			w *= exp(-float(x * x + y * y) * 0.5);
			if ((other.normal_distance.w > 0.0) != (center.normal_distance.w > 0.0)) {
				w *= roughness;
			}
			sum.rgb += c.rgb * w;
			sum.w += c.w * w * w;
			weight += w;
		}
	}
	value = weight > 0.0 ? vec4(sum.rgb / weight, sum.w / (weight * weight)) : value;
	if ((params.samples & 1u) == 0u) {
		imageStore(reflection_filter_b, pixel, value);
	} else {
		imageStore(reflection_filter_a, pixel, value);
	}
}
void upsample_reflection(ivec2 pixel) {
	vec3 p, n;
	if (!surface(pixel, p, n)) {
		imageStore(output_reflection, pixel, vec4(0));
		return;
	}
	if (frame.reflections.x == 1.0) {
		ReflectionSample sample_value = reflections.data[reflection_index(pixel)];
		vec3 color = frame.flags.x == 0u ? sample_value.color_count.rgb : reflection_filter_input(pixel, uint(frame.reflections.z)).rgb;
		imageStore(output_reflection, pixel, vec4(clean_color(color) * params.exposure, 1));
		return;
	}
	float roughness = surface_roughness(pixel);
	vec2 coord = (vec2(pixel) - vec2(reflection_phase(params.padding))) / frame.reflections.x;
	ivec2 base = ivec2(floor(coord));
	vec3 sum = vec3(0);
	float weight = 0.0;
	for (int y = -1; y <= 2; y++) {
		for (int x = -1; x <= 2; x++) {
			ivec2 q = base + ivec2(x, y);
			if (any(lessThan(q, ivec2(0))) || any(greaterThanEqual(q, reflection_size()))) {
				continue;
			}
			ReflectionSample other = reflections.data[reflection_index(q)];
			float w = reflection_surface_weight(p, n, roughness, other);
			w *= exp(-dot(vec2(q) - coord, vec2(q) - coord) * mix(3.0, 1.0, roughness));
			vec3 value = frame.flags.x == 0u ? other.color_count.rgb : reflection_filter_input(q, uint(frame.reflections.z)).rgb;
			sum += value * w;
			weight += w;
		}
	}
	// Uncovered edge pixels retain native IBL rather than inventing geometry.
	imageStore(output_reflection, pixel, weight > 0.0001 ? vec4(clean_color(sum / weight) * params.exposure, 1) : vec4(0));
}
