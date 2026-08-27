#[compute]

#version 450

#VERSION_DEFINES

// Temporal accumulation for the raytraced shadow mask.
//
// This deliberately keeps its own history rather than leaning on the image's
// temporal antialiasing: with SMAA, or with no antialiasing at all, nothing
// downstream would average the shadow signal over time, so the accumulation
// has to converge on its own.

// Channel carrying no light. Matches SLOT_NONE in rt_shadow_trace.glsl.
#define SLOT_NONE 255u

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_visibility;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
// Previous frame's filtered visibility.
layout(set = 0, binding = 3) uniform sampler2D history_visibility;
// Previous frame's (view depth, history length).
layout(set = 0, binding = 4) uniform sampler2D history_meta;

layout(rgba8, set = 0, binding = 5) uniform restrict writeonly image2D dest_visibility;
layout(r8, set = 0, binding = 6) uniform restrict writeonly image2D dest_history_length;

// Which light each channel of the mask carries, this frame and last. Every
// pixel picks its own set of lights, so a history sample is only usable if it
// carries the same lights in the same channels.
layout(set = 0, binding = 7) uniform usampler2D source_index;
layout(set = 0, binding = 8) uniform usampler2D history_index;

layout(push_constant, std430) uniform Params {
	// Maps this frame's clip space straight to the previous frame's. Motion
	// vectors would be the obvious source for this, but they are written during
	// the opaque pass, which runs after the shadow mask is needed, so reading
	// them here would reproject against the frame before last. This is exact for
	// static geometry and for any camera movement; geometry that moved on its
	// own reprojects as though it had not, and is then rejected by the surface
	// test below rather than smeared.
	mat4 reprojection;

	ivec2 screen_size;
	float depth_tolerance;
	float max_history;
}
params;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}

	vec4 current = texelFetch(source_visibility, pos, 0);
	float depth = texelFetch(source_depth, pos, 0).r;

	uvec4 current_index = texelFetch(source_index, pos, 0);

	// Sky, or a pixel no raytraced light reaches. Neither has anything to
	// accumulate, and leaving a history behind would bleed into whatever moves
	// in front of it later.
	if (depth <= 0.0 || current_index == uvec4(SLOT_NONE)) {
		imageStore(dest_visibility, pos, current);
		imageStore(dest_history_length, pos, vec4(0.0));
		return;
	}

	vec2 uv = (vec2(pos) + 0.5) / vec2(params.screen_size);
	vec4 previous_clip = params.reprojection * vec4(uv * 2.0 - 1.0, depth, 1.0);

	float history_length = 0.0;
	vec4 history = current;

	// Behind the previous camera: there is no history to find.
	if (previous_clip.w > 0.0) {
		vec2 previous_uv = (previous_clip.xy / previous_clip.w) * 0.5 + 0.5;
		// For a perspective projection w is the distance along the camera's forward
		// axis, so this is where the surface should have been in the previous frame
		// if it did not move. The history stores what was actually there.
		float expected_depth = previous_clip.w;

		// The history is filtered by hand rather than by the sampler: the channel
		// assignment cannot be interpolated, so each of the four bilinear taps has
		// to be accepted or rejected on its own before it is weighted in.
		if (all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThan(previous_uv, vec2(1.0)))) {
			vec2 previous_texel = previous_uv * vec2(params.screen_size) - 0.5;
			ivec2 base = ivec2(floor(previous_texel));
			vec2 subpixel = previous_texel - vec2(base);

			vec4 tap_weights = vec4(
					(1.0 - subpixel.x) * (1.0 - subpixel.y),
					subpixel.x * (1.0 - subpixel.y),
					(1.0 - subpixel.x) * subpixel.y,
					subpixel.x * subpixel.y);
			ivec2 tap_offsets[4] = ivec2[4](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));

			vec4 visibility_sum = vec4(0.0);
			float length_sum = 0.0;
			float weight_sum = 0.0;

			for (int i = 0; i < 4; i++) {
				ivec2 tap = base + tap_offsets[i];
				if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, params.screen_size))) {
					continue;
				}
				if (texelFetch(history_index, tap, 0) != current_index) {
					continue;
				}

				vec2 previous_meta = texelFetch(history_meta, tap, 0).rg;

				// Reject the history when the surface that was there is not the
				// surface that should have been there. The tolerance is relative so
				// that distant geometry, where depth precision and reprojection error
				// are both worse, is not rejected purely for being far away.
				float depth_error = abs(previous_meta.r - expected_depth) / max(expected_depth, 0.001);
				if (depth_error >= params.depth_tolerance) {
					continue;
				}

				float weight = tap_weights[i];
				visibility_sum += texelFetch(history_visibility, tap, 0) * weight;
				length_sum += previous_meta.g * weight;
				weight_sum += weight;
			}

			if (weight_sum > 0.0) {
				history = visibility_sum / weight_sum;
				// The meta buffer stores the history length normalized against the
				// same window, so that it survives being written through an 8 bit
				// target elsewhere in the chain.
				history_length = (length_sum / weight_sum) * params.max_history;
			}
		}
	}

	// Exponential moving average with a bounded window. The first frames after a
	// disocclusion weight the new sample heavily so the shadow appears
	// immediately; once the window fills, alpha settles at 1 / max_history and
	// the estimate is stable.
	history_length = history_length > 0.0 ? min(history_length + 1.0, params.max_history) : 1.0;
	float alpha = 1.0 / history_length;

	vec4 accumulated = mix(history, current, alpha);

	imageStore(dest_visibility, pos, accumulated);
	imageStore(dest_history_length, pos, vec4(history_length / max(params.max_history, 1.0)));
}
