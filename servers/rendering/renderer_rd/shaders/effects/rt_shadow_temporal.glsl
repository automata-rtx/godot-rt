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

// Visibility is stored as its square root and squared on read. Eight bits spread
// evenly over [0,1] put the same absolute step everywhere, but a shadow's detail
// is all at the dark end, where that step is a large RELATIVE error and shows as
// banding across a wide penumbra. Storing the root spends half of the code
// range below a quarter visibility, where the eye is, instead of a quarter of
// it, and gives up precision near fully lit, where nothing is happening.
//
// Filtering still happens in linear visibility. Averaging roots and squaring the
// result, which is what NVIDIA's SIGMA does, would darken every penumbra by
// Jensen's inequality: that is a look change, not a precision gain, so the
// encode and decode bracket the storage only.
#define VIS_DECODE(v) ((v) * (v))
#define VIS_ENCODE(v) sqrt(max(v, vec4(0.0)))

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_visibility;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
// Previous frame's accumulated visibility, before any spatial filtering.
layout(set = 0, binding = 3) uniform sampler2D history_visibility;
layout(set = 0, binding = 2) uniform sampler2D source_penumbra;
// Previous receiver depth, view normal and four independent light ages.
layout(set = 0, binding = 4) uniform usampler2D history_meta;
layout(set = 0, binding = 9) uniform sampler2D source_normal_roughness;

layout(rgba8, set = 0, binding = 5) uniform restrict writeonly image2D dest_visibility;
layout(rgba8, set = 0, binding = 6) uniform restrict writeonly image2D dest_history_length;

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

	// Turns a depth buffer value into a distance along the camera's forward
	// axis, the same four terms the a-trous pass uses. Needed because the
	// reprojection above carries a scale that has to be undone before the
	// result can be compared against a stored distance; see below.
	vec4 depth_unproject;

	vec4 previous_view_rotation;
	ivec2 screen_size;
	float max_history;
	float clamp_sigma;
	uint frame_index;
}
params;

// Where in a quantization step this pixel rounds this frame.
//
// Interleaved gradient noise for the spatial part, advanced by the conjugate of
// the golden ratio for the temporal one, so a single pixel's own sequence
// spreads evenly over the step rather than repeating a handful of positions.
float dither_offset(ivec2 pos, uint frame) {
	float spatial = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))));
	return fract(spatial + float(frame) * 0.61803399);
}

float linear_view_depth(float depth) {
	return -(params.depth_unproject.x * depth + params.depth_unproject.y) /
			(params.depth_unproject.z * depth + params.depth_unproject.w);
}

// Adaptive temporal mode. Ages belong to individual lights and count rendered
// samples (in units of eight frames in the UNORM history), independent of dt.
#include "../oct_inc.glsl"

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}
	vec4 raw = texelFetch(source_visibility, pos, 0);
	vec4 current = VIS_DECODE(raw);
	float depth = texelFetch(source_depth, pos, 0).r;
	uvec4 lights = texelFetch(source_index, pos, 0);
	vec4 center_width = texelFetch(source_penumbra, pos, 0) * 32.0;
	// Preserve a directly measured contact through subsequent spatial passes.
	vec4 ages = (1.0 - vec4(lessThan(current, vec4(0.999))) * vec4(lessThanEqual(center_width, vec4(1.0)))) / 8.0;
	imageStore(dest_visibility, pos, raw);
	imageStore(dest_history_length, pos, ages);
	if (depth <= 0.0 || lights == uvec4(SLOT_NONE) || params.max_history <= 1.0 || all(equal(ages * vec4(notEqual(lights, uvec4(SLOT_NONE))), vec4(0.0)))) {
		return;
	}

	vec3 normal = normalize(texelFetch(source_normal_roughness, pos, 0).xyz * 2.0 - 1.0);
	vec4 sum = vec4(0.0), count = vec4(0.0), hit_count = vec4(0.0);
	vec4 width_sum = vec4(0.0), nearest_width = vec4(32.0);
	vec4 lo = vec4(1.0), hi = vec4(0.0);
	for (int radius = 1; radius <= 2; radius++) {
		// Only pixels with soft blocker evidence need the outer moment taps.
		if (radius == 2 && all(lessThanEqual(width_sum * vec4(greaterThan(nearest_width, vec4(1.0))), hit_count))) {
			return;
		}
		for (int y = -radius; y <= radius; y++) {
			for (int x = -radius; x <= radius; x++) {
				if (radius == 2 && abs(x) < 2 && abs(y) < 2) {
					continue;
				}
				ivec2 tap = pos + ivec2(x, y);
				if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, params.screen_size))) {
					continue;
				}
				float tap_depth = texelFetch(source_depth, tap, 0).r;
				vec3 tap_normal = normalize(texelFetch(source_normal_roughness, tap, 0).xyz * 2.0 - 1.0);
				if (abs(tap_depth - depth) > 0.004 * depth || dot(tap_normal, normal) < 0.94) {
					continue;
				}
				bvec4 same = equal(texelFetch(source_index, tap, 0), lights);
				vec4 v = VIS_DECODE(texelFetch(source_visibility, tap, 0));
				if (radius == 1) {
					vec4 width = texelFetch(source_penumbra, tap, 0) * 32.0;
					vec4 hits = vec4(same) * vec4(lessThan(v, vec4(0.999)));
					width_sum += hits * width;
					hit_count += hits;
					nearest_width = min(nearest_width, mix(vec4(32.0), width, greaterThan(hits, vec4(0))));
				}
				count += vec4(same);
				sum += vec4(same) * v;
				lo = min(lo, mix(vec4(1.0), v, same));
				hi = max(hi, mix(vec4(0.0), v, same));
			}
		}
	}
	// A miss carries no blocker distance. Estimate softness from hits on this
	// receiver for both lit and blocked samples. A measured contact vetoes reuse.
	vec4 width = width_sum / max(hit_count, vec4(1.0));
	vec4 softness = smoothstep(vec4(1.0), vec4(5.0), width) * vec4(greaterThan(nearest_width, vec4(1.0)));
	softness *= vec4(notEqual(lights, uvec4(SLOT_NONE))) * vec4(greaterThan(hi, lo));
	if (all(equal(softness, vec4(0.0)))) {
		return;
	}

	vec2 uv = (vec2(pos) + 0.5) / vec2(params.screen_size);
	vec4 clip = params.reprojection * vec4(uv * 2.0 - 1.0, depth, 1);
	if (clip.w <= 0.0) {
		return;
	}
	vec2 old_uv = clip.xy / clip.w * 0.5 + 0.5;
	if (any(lessThan(old_uv, vec2(0))) || any(greaterThanEqual(old_uv, vec2(1)))) {
		return;
	}
	vec2 old_pixel = old_uv * vec2(params.screen_size) - 0.5;
	ivec2 base = ivec2(floor(old_pixel));
	vec2 frac = fract(old_pixel);
	float expected_depth = clip.w * linear_view_depth(depth);
	vec4 q = params.previous_view_rotation;
	vec3 old_normal = normal + 2.0 * cross(q.xyz, cross(q.xyz, normal) + q.w * normal);
	vec4 coverage = vec4(0.0), age_sum = vec4(0.0), history_sum = vec4(0.0);
	for (int i = 0; i < 4; i++) {
		ivec2 offset = ivec2(i & 1, i >> 1);
		ivec2 tap = base + offset;
		if (any(lessThan(tap, ivec2(0))) || any(greaterThanEqual(tap, params.screen_size))) {
			continue;
		}
		uvec4 meta = texelFetch(history_meta, tap, 0);
		float old_depth = unpackHalf2x16(meta.x).x;
		vec3 tap_normal = oct_to_vec3(unpackUnorm4x8(meta.y).xy * 2.0 - 1.0);
		if (old_depth <= 0.0 || abs(old_depth - expected_depth) > 0.004 * expected_depth || dot(tap_normal, old_normal) < 0.94) {
			continue;
		}
		vec2 weights = mix(vec2(1.0) - frac, frac, vec2(offset));
		vec4 tap_age = unpackUnorm4x8(meta.z | (meta.w << 16u)) * 8.0;
		vec4 w = weights.x * weights.y * vec4(equal(texelFetch(history_index, tap, 0), lights)) * vec4(greaterThan(tap_age, vec4(0.0)));
		coverage += w;
		age_sum += w * tap_age;
		history_sum += w * VIS_DECODE(texelFetch(history_visibility, tap, 0));
	}
	vec4 mean = sum / max(count, vec4(1.0));
	// A moving blocker changes the shadow on a stationary receiver. Limit
	// that history against fresh observations even when reprojection is exact.
	vec4 history = history_sum / max(coverage, vec4(1e-6));
	if (params.clamp_sigma > 0.0) {
		vec4 margin = max(vec4(0.015), params.clamp_sigma * sqrt(mean * (1.0 - mean) / max(count, vec4(1.0))));
		history = clamp(history, max(lo, mean - margin), min(hi, mean + margin));
	}
	vec4 prior = min(age_sum, vec4(params.max_history - 1.0) * softness) * coverage;
	vec4 length_now = 1.0 + prior;
	vec4 filtered = mix(current, history, prior / length_now);
	vec4 encoded = VIS_ENCODE(filtered) + (dither_offset(pos, params.frame_index) - 0.5) / 255.0;
	imageStore(dest_visibility, pos, mix(raw, encoded, greaterThan(prior, vec4(0))));
	imageStore(dest_history_length, pos, mix(ages, length_now / 8.0, greaterThan(prior, vec4(0))));
}
