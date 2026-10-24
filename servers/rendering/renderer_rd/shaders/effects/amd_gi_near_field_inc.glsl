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

// Capsaicin SSGI::Main, default one slice / two steps. Native bindings and
// projection-axis signs are supplied by AMDGI; integration stays in irradiance units.
layout(set = 0, binding = 56, rgba16f) uniform image2D near_field_occlusion;
layout(set = 0, binding = 57, rgba16f) uniform image2D near_field_lighting;

vec3 near_field_rotate(vec3 value) {
	return value + 2.0 * cross(params.camera_rotation.xyz, cross(params.camera_rotation.xyz, value) + params.camera_rotation.w * value);
}
vec3 near_field_world(vec2 uv) {
	float depth = textureLod(depth_buffer, uv, 0).r;
	vec4 position = params.inv_view_projection * vec4(uv * 2.0 - 1.0, depth, 1);
	// Match the reference homogeneous reconstruction. Do not substitute an
	// arbitrary finite endpoint for an infinite projection's w=0 boundary.
	return position.xyz / position.w;
}
vec3 near_field_normal(vec2 uv) {
	return normalize(textureLod(primary_shading_normal, uv, 0).xyz * 2.0 - 1.0);
}
float near_field_intersect(vec3 direction, vec3 normal, vec3 point) {
	return -dot(point, normal) / max(1e-5, -dot(direction, normal));
}
vec3 near_field_rotate_from_to(vec3 from, vec3 to, vec3 value) {
	float e = dot(from, to);
	if (abs(e) > 1.0 - 0.0003) {
		return value;
	}
	vec3 v = cross(from, to);
	return e * value + cross(v, value) + v * dot(v, value) / (1.0 + e);
}
float near_field_half_arc(float horizon, float normal_angle) {
	return (cos(normal_angle) + 2.0 * horizon * sin(normal_angle) - cos(2.0 * horizon - normal_angle)) / 4.0;
}
vec3 near_field_bent_normal(float h0, float h1, float n, vec3 eye_direction, vec3 slice) {
	float t0 = (6.0 * sin(h0 - n) - sin(3.0 * h0 - n) + 6.0 * sin(h1 - n) - sin(3.0 * h1 - n) + 16.0 * sin(n) - 3.0 * (sin(h0 + n) + sin(h1 + n))) / 12.0;
	float t1 = (-cos(3.0 * h0 - n) - cos(3.0 * h1 - n) + 8.0 * cos(n) - 3.0 * (cos(h0 + n) + cos(h1 + n))) / 12.0;
	return near_field_rotate_from_to(near_field_rotate(vec3(0, 0, 1)), eye_direction, near_field_rotate(vec3(slice.xy * t0, t1)));
}
void integrate_near_field(ivec2 pixel) {
	vec3 world, unused_normal;
	if (!surface(pixel, world, unused_normal)) {
		imageStore(near_field_occlusion, pixel, vec4(0));
		imageStore(near_field_lighting, pixel, vec4(0));
		return;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.size);
	vec3 normal = shading_normal(pixel);
	vec3 eye_direction = normalize(params.camera_position.xyz - world);
	vec2 noise = lookup_jitter(pixel, 0u);
	float slice_radius = frame.near_field.x / gi_view_depth(world);
	float angle = noise.x * PI;
	vec3 slice = vec3(cos(angle), sin(angle), 0);
	vec2 uv_direction = slice.xy * frame.near_field.yz * slice_radius;
	vec3 world_direction = near_field_rotate(slice);
	vec3 orthogonal = world_direction - dot(world_direction, eye_direction) * eye_direction;
	vec3 axis = normalize(cross(orthogonal, eye_direction));
	vec3 projected = normal - dot(normal, axis) * axis;
	float projected_length = length(projected);
	float normal_cosine = clamp(dot(projected, eye_direction) / projected_length, 0.0, 1.0);
	float normal_angle = sign(dot(orthogonal, projected)) * acos(normal_cosine);
	float horizons[2];
	float occlusion = 0.0;
	vec3 lighting = vec3(0);
	for (int side_index = 0; side_index < 2; side_index++) {
		float side = side_index == 0 ? 1.0 : -1.0;
		float minimum = cos(normal_angle + side * PI * 0.5);
		float horizon = minimum;
		vec3 previous_world = vec3(0);
		for (int step_index = 0; step_index < 2; step_index++) {
			float sample_step = (float(step_index) + noise.y) / 2.0;
			vec2 sample_uv = uv + side * sample_step * uv_direction;
			vec3 sample_world = near_field_world(sample_uv);
			vec3 direction = sample_world - world;
			float distance = length(direction);
			direction /= distance;
			// Reference radius=.2, falloff_range=.05: mul=-100, add=20.
			float sample_weight = clamp(distance * -100.0 + 20.0, 0.0, 1.0);
			float sample_cosine = mix(minimum, dot(direction, eye_direction), sample_weight);
			float previous_horizon = horizon;
			horizon = max(horizon, sample_cosine);
			if (sample_cosine >= previous_horizon) {
				vec3 sample_lighting = frame.grid.w == 0u ? textureLod(previous_lighting, sample_uv, 0).rgb / frame.settings.w : vec3(0);
				vec3 sample_normal = near_field_normal(sample_uv);
				if (step_index > 0) {
					vec3 closest = previous_world * min(near_field_intersect(previous_world, sample_normal, sample_world), near_field_intersect(previous_world, normal, world));
					previous_horizon = clamp(dot(normalize(closest - world), eye_direction), previous_horizon, horizon);
				}
				float h0 = normal_angle + max(side * acos(previous_horizon) - normal_angle, -PI * 0.5);
				float h1 = normal_angle + min(side * acos(horizon) - normal_angle, PI * 0.5);
				float sample_occlusion = near_field_half_arc(h0, normal_angle) - near_field_half_arc(h1, normal_angle);
				lighting += sample_lighting * sample_occlusion * step(0.0, dot(-direction, sample_normal));
			}
			previous_world = sample_world;
		}
		horizons[side_index] = side * acos(horizon);
		occlusion += projected_length * near_field_half_arc(horizons[side_index], normal_angle);
		lighting *= projected_length;
	}
	vec3 bent_normal = normalize(projected_length * near_field_bent_normal(horizons[0], horizons[1], normal_angle, eye_direction, slice));
	imageStore(near_field_occlusion, pixel, vec4(bent_normal * 0.5 + 0.5, occlusion));
	imageStore(near_field_lighting, pixel, vec4(lighting, 0));
}

vec3 probe_bent_irradiance(uint probe, vec3 n, float ao) {
	// SH_GetCoefficients_ClampedCosine_Cone, without replacing the reference
	// cone integral with scalar AO multiplication.
	float theta = acos(sqrt(clamp(1.0 - ao, 0.0, 1.0)));
	float st = sin(theta), ct = cos(theta);
	float s2 = st * st;
	float band1 = 1.023326707946489 * (1.0 - ct * ct * ct);
	float band2 = (4.0 - 3.0 * s2 * st) * s2;
	float sh[9];
	sh[0] = 0.886226925452758 * s2;
	sh[1] = -band1 * n.y;
	sh[2] = band1 * n.z;
	sh[3] = -band1 * n.x;
	sh[4] = 0.8580855308097834 * band2 * n.x * n.y;
	sh[5] = -0.8580855308097834 * band2 * n.y * n.z;
	sh[6] = 0.2477079561003757 * band2 * (3.0 * n.z * n.z - 1.0);
	sh[7] = -0.8580855308097834 * band2 * n.x * n.z;
	sh[8] = 0.4290427654048917 * band2 * (n.x * n.x - n.y * n.y);
	vec3 irradiance = vec3(0);
	for (uint i = 0u; i < 9u; i++) {
		irradiance += gi_cache_unpack(probes.data[probe].sh[i]).rgb * sh[i];
	}
	return max(irradiance, vec3(0));
}
