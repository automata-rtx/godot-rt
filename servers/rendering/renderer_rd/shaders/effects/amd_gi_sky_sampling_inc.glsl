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
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

// Capsaicin 914b9159 lights/box_sampling.hlsl and light_sampling.hlsl.
// The hierarchy uses ordinary box-mean cubemap mips, never GGX-prefiltered
// radiance. Face coordinates follow the Vulkan conversion shader, so every
// hierarchy lookup and the returned direction address the same native texel.
vec3 gi_sky_cube_position(uint face, vec2 uv) {
	vec2 p = uv * 2.0 - 1.0;
	switch (face) {
		case 0u:
			return vec3(1, -p.y, -p.x);
		case 1u:
			return vec3(-1, -p.y, p.x);
		case 2u:
			return vec3(p.x, 1, p.y);
		case 3u:
			return vec3(p.x, -1, -p.y);
		case 4u:
			return vec3(p.x, -p.y, 1);
		default:
			return vec3(-p.x, -p.y, -1);
	}
}

float gi_sky_texel_mass(uint face, vec2 uv, int level) {
	// AMD floors child masses at epsilon. Also floor face masses: an all-black
	// native sky otherwise divides by zero, and a black face has no CDF interval.
	return max(luma(textureLod(sky_radiance, gi_sky_cube_position(face, uv), float(level)).rgb), 1e-7);
}

vec3 gi_sky_importance_sample(vec2 samples, out float pdf) {
	// Reservoir parameters cross AMD's half-float handoff, which can round to
	// exactly one. Keep hierarchy residuals in their required half-open interval.
	const float maximum_sample = 0.9999999403953552;
	vec2 residual = clamp(samples, vec2(0), vec2(maximum_sample));
	int levels = textureQueryLevels(sky_radiance);
	float masses[6];
	float total = 0.0;
	for (uint face = 0u; face < 6u; face++) {
		masses[face] = gi_sky_texel_mass(face, vec2(0.5), levels - 1);
		total += masses[face];
	}
	float selection = residual.y * total;
	uint face = 0u;
	for (; face < 5u && selection >= masses[face]; face++) {
		selection -= masses[face];
	}
	residual.y = clamp(selection / masses[face], 0.0, maximum_sample);
	pdf = masses[face] / total;
	ivec2 offset = ivec2(0);
	float width = 1.0;
	for (int level = levels - 2; level >= 0; level--) {
		offset *= 2;
		width *= 2.0;
		vec2 uv = (vec2(offset) + 0.5) / width;
		float step_size = 1.0 / width;
		vec4 mass = vec4(
				gi_sky_texel_mass(face, uv, level),
				gi_sky_texel_mass(face, uv + vec2(step_size, 0), level),
				gi_sky_texel_mass(face, uv + vec2(0, step_size), level),
				gi_sky_texel_mass(face, uv + vec2(step_size), level));
		vec2 rows = vec2(mass.x + mass.y, mass.z + mass.w);
		float py = rows.x / (rows.x + rows.y);
		int y = residual.y < py ? 0 : 1;
		float px = y == 0 ? mass.x / rows.x : mass.z / rows.y;
		int x = residual.x < px ? 0 : 1;
		float selected_y = y == 0 ? py : 1.0 - py;
		float selected_x = x == 0 ? px : 1.0 - px;
		residual.y = (residual.y - (y == 0 ? 0.0 : py)) / selected_y;
		residual.x = (residual.x - (x == 0 ? 0.0 : px)) / selected_x;
		residual = clamp(residual, vec2(0), vec2(maximum_sample));
		pdf *= selected_x * selected_y;
		offset += ivec2(x, y);
	}
	vec2 uv = (vec2(offset) + residual) / width;
	vec3 direction = normalize(gi_sky_cube_position(face, uv));
	float projected_cosine = max(max(abs(direction.x), abs(direction.y)), abs(direction.z));
	// Discrete leaf probability -> UV density -> solid-angle density.
	pdf *= width * width / (4.0 * projected_cosine * projected_cosine * projected_cosine);
	return normalize(transpose(frame.world_to_sky) * direction);
}

vec3 gi_sample_environment(vec2 samples, vec3 normal, out float pdf) {
	if (frame.options.x == 2u) {
		return gi_sky_importance_sample(samples, pdf);
	}
	if (frame.options.x == 1u) {
		// math/sampling.hlsl::mapToCosineHemisphere.
		float sine = sqrt(samples.x);
		float phi = 2.0 * PI * samples.y;
		vec3 direction = normalize(basis(normal) * vec3(sine * cos(phi), sine * sin(phi), sqrt(max(1.0 - samples.x, 0.0))));
		pdf = max(dot(normal, direction), 0.0) / PI;
		return direction;
	}
	// Preserve the baseline uniform-hemisphere mapping and random dimensions.
	float theta = 2.0 * PI * samples.x;
	float cosine = 1.0 - samples.y;
	float sine = sin(acos(cosine));
	pdf = 1.0 / (2.0 * PI);
	return normalize(basis(normal) * vec3(sine * cos(theta), sine * sin(theta), cosine));
}
