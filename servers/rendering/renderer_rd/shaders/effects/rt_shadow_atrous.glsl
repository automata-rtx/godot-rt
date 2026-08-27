#[compute]

#version 450

#VERSION_DEFINES

// Edge stopping a-trous wavelet pass over the raytraced shadow mask.
//
// The four lights packed into the channels share the geometric edge stopping
// weights, which depend only on the surface, and differ only in how far the
// filter is allowed to reach: a light whose occluder is close to the receiver
// keeps a tight shadow, one whose occluder is far away gets a wide penumbra.
//
// Each pixel chooses its own four lights, so a neighbor only contributes when
// it carries the same lights in the same channels. Channel assignments are
// sorted by light index, which makes that a single equality test.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_visibility;
layout(set = 0, binding = 1) uniform sampler2D source_hit_distance;
layout(set = 0, binding = 2) uniform sampler2D source_depth;
layout(set = 0, binding = 3) uniform sampler2D source_normal_roughness;
layout(set = 0, binding = 4) uniform sampler2D source_history_length;

layout(rgba8, set = 0, binding = 5) uniform restrict writeonly image2D dest_visibility;
// Only written on the first iteration, which is what next frame reprojects.
layout(rgba8, set = 0, binding = 6) uniform restrict writeonly image2D dest_history_visibility;
layout(rg16f, set = 0, binding = 7) uniform restrict writeonly image2D dest_history_meta;

// Which light each channel of the mask carries. Constant through the denoiser,
// so this is the trace's own output on every iteration.
layout(set = 0, binding = 8) uniform usampler2D source_index;
layout(rgba8ui, set = 0, binding = 9) uniform restrict writeonly uimage2D dest_history_index;

layout(push_constant, std430) uniform Params {
	// The four terms of the inverse projection that survive for a centered
	// perspective matrix, enough to turn a depth buffer value into a distance
	// along the camera's forward axis without reconstructing a world position.
	vec4 depth_unproject;

	ivec2 screen_size;
	int step_size;
	uint write_history;

	float depth_sigma;
	float normal_sigma;
	float min_filter_scale;
	float pad;
}
params;

const float KERNEL[3] = float[](0.375, 0.25, 0.0625);

float linear_view_depth(float depth) {
	return -(params.depth_unproject.x * depth + params.depth_unproject.y) /
			(params.depth_unproject.z * depth + params.depth_unproject.w);
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}

	vec4 center = texelFetch(source_visibility, pos, 0);
	float center_depth = texelFetch(source_depth, pos, 0).r;
	uvec4 center_index = texelFetch(source_index, pos, 0);

	if (center_depth <= 0.0) {
		// Sky: nothing to filter, and the surrounding geometry must not bleed in.
		imageStore(dest_visibility, pos, center);
		if (params.write_history != 0u) {
			imageStore(dest_history_visibility, pos, center);
			imageStore(dest_history_meta, pos, vec4(0.0, 0.0, 0.0, 0.0));
			imageStore(dest_history_index, pos, center_index);
		}
		return;
	}

	vec3 center_normal = normalize(texelFetch(source_normal_roughness, pos, 0).xyz * 2.0 - 1.0);
	vec4 hit_distance = texelFetch(source_hit_distance, pos, 0);
	float history_length = texelFetch(source_history_length, pos, 0).r;

	// How far the filter may reach, per light. A blocker far from the receiver
	// casts a wide penumbra and tolerates a wide filter; a blocker at the contact
	// point does not, and over-filtering there is what destroys contact hardening.
	// Pixels with little accumulated history are still noisy and get filtered
	// harder regardless.
	vec4 penumbra = clamp(hit_distance, vec4(0.0), vec4(1.0));
	float history_boost = 1.0 - clamp(history_length, 0.0, 1.0);
	vec4 filter_scale = clamp(max(penumbra, vec4(history_boost)), vec4(params.min_filter_scale), vec4(1.0));

	vec4 sum = center * KERNEL[0] * KERNEL[0];
	vec4 weight_sum = vec4(KERNEL[0] * KERNEL[0]);

	ivec2 max_pos = params.screen_size - ivec2(1);

	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			if (x == 0 && y == 0) {
				continue;
			}

			ivec2 tap = clamp(pos + ivec2(x, y) * params.step_size, ivec2(0), max_pos);

			float tap_depth = texelFetch(source_depth, tap, 0).r;
			if (tap_depth <= 0.0) {
				continue;
			}

			// A neighbor lit by a different set of lights holds unrelated values
			// in these channels, so it is skipped rather than blended.
			if (texelFetch(source_index, tap, 0) != center_index) {
				continue;
			}

			// Reverse-Z depth is proportional to the reciprocal of view distance,
			// so a relative difference in depth is a relative difference in
			// distance. That holds for any projection of this family and needs no
			// per-tap reconstruction.
			float depth_error = abs(tap_depth - center_depth) / max(center_depth, 1e-6);
			float depth_weight = exp(-depth_error / max(params.depth_sigma, 1e-4));

			vec3 tap_normal = normalize(texelFetch(source_normal_roughness, tap, 0).xyz * 2.0 - 1.0);
			float normal_weight = pow(max(dot(center_normal, tap_normal), 0.0), params.normal_sigma);

			float kernel_weight = KERNEL[abs(x)] * KERNEL[abs(y)];
			float geometric = kernel_weight * depth_weight * normal_weight;

			if (geometric <= 0.0) {
				continue;
			}

			vec4 tap_visibility = texelFetch(source_visibility, tap, 0);

			// Per-light reach: a light whose filter_scale is small takes less of
			// this tap the further away it is.
			float distance_ratio = length(vec2(x, y)) / 2.0;
			vec4 reach = clamp((filter_scale - vec4(distance_ratio - 1.0)), vec4(0.0), vec4(1.0));
			vec4 weight = vec4(geometric) * reach;

			sum += tap_visibility * weight;
			weight_sum += weight;
		}
	}

	vec4 result = sum / max(weight_sum, vec4(1e-6));

	imageStore(dest_visibility, pos, result);

	if (params.write_history != 0u) {
		imageStore(dest_history_visibility, pos, result);
		imageStore(dest_history_index, pos, center_index);

		// Stored raw rather than normalized: the temporal pass compares it against
		// the w of a reprojected clip position, which is the same quantity in the
		// same units.
		imageStore(dest_history_meta, pos,
				vec4(linear_view_depth(center_depth), history_length, 0.0, 0.0));
	}
}
