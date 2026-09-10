#[compute]

#version 450

#VERSION_DEFINES

// Screen space shadows for a single directional light.
//
// A port of Bend Studio's public screen-space shadow shader (Apache-2.0, see
// thirdparty/bend_sss/LICENSE.txt) from HLSL to Godot's RD GLSL. The companion
// CPU side, which decides how many dispatches a light needs and what wave
// offset each one gets, is vendored at thirdparty/bend_sss with no changes but
// the line endings and trailing whitespace this repository normalizes.
//
// The idea: instead of every pixel marching its own ray toward the light, a
// wavefront of WAVE_SIZE threads is laid out ALONG one light ray, reads its
// depths once into shared memory, and then every thread tests itself against
// the whole line. The reads are shared, so the cost per pixel is a handful of
// texture fetches rather than one per step.
//
// Deviations from the original, all forced by the target rather than chosen:
//
//  - Godot is reverse-Z with a [0,1] clip range, so NearDepthValue is 1.0 and
//    FarDepthValue is 0.0. The shader's own z_sign handles that generically;
//    nothing here assumes one or the other.
//  - HLSL's Sample() with a compile-time integer offset has no portable GLSL
//    equivalent that is worth the trouble, so the original's USE_UV_PIXEL_BIAS
//    path is the only one kept.
//  - DispatchParameters cannot exist as a struct here: GLSL has no samplers in
//    structs. Its scalars are the push constant below and its two textures are
//    plain bindings.
//  - The store is bounds checked. The original relies on a graphics API where
//    an out of range write is defined as a no-op, and it deliberately writes up
//    to 2 * WAVE_SIZE pixels outside the requested bounds; since this pass is
//    always given full screen bounds, out of bounds is out of texture.

// Wavefront size. Fixed at 64, which is the only value the original is tested
// with, and it is a workgroup size rather than a hardware wave size: the
// early-out below copes with a workgroup made of several smaller hardware waves
// (an RTX 5090 is 32 wide) through shared memory. Do not confuse this with
// gl_SubgroupSize.
#define WAVE_SIZE 64

// SAMPLE_COUNT, HARD_SHADOW_SAMPLES and FADE_OUT_SAMPLES arrive from
// VERSION_DEFINES, one set per quality tier.

// Bilinear reads performed per thread.
#define READ_COUNT (SAMPLE_COUNT / WAVE_SIZE + 2)

#extension GL_KHR_shader_subgroup_basic : enable
#extension GL_KHR_shader_subgroup_vote : enable

layout(local_size_x = WAVE_SIZE, local_size_y = 1, local_size_z = 1) in;

// Point sampled, clamped to a border of FarDepthValue. The border matters: the
// march reads outside the screen on purpose and those reads must come back as
// "nothing here" rather than as the edge texel smeared outward.
layout(set = 0, binding = 0) uniform sampler2D depth_texture;

layout(r8, set = 0, binding = 1) uniform restrict writeonly image2D shadow_image;

// One byte per pixel saying whether that pixel's surface is allowed to cast.
// Written in the depth pre-pass, so it describes the surface the depth test
// already chose. Bound to a 4x4 white fallback when the restriction is off,
// which reads as 1.0 everywhere and lets everything cast -- exactly the
// behavior without this feature.
layout(set = 0, binding = 2) uniform sampler2D caster_mask_texture;

layout(push_constant, std430) uniform Params {
	// From BuildDispatchList: the light's pixel coordinate, its depth, and the
	// sign of its clip space w.
	vec4 light_coordinate;
	// From BuildDispatchList, different for every dispatch of the same light.
	ivec2 wave_offset;

	ivec2 screen_size;
	vec2 inv_depth_texture_size;

	// Depth range the light's on screen volume spans. (0, 1) for a directional
	// light, which is what this pass is for; only read when the early-out is on.
	vec2 depth_bounds;

	float surface_thickness;
	float bilinear_threshold;
	float shadow_contrast;
	float far_depth_value;

	float near_depth_value;
	uint flags;
	// How much a single bulk sample may shadow on its own. See the blend below.
	float hardness;
}
params;

#define FLAG_IGNORE_EDGE_PIXELS (1u << 0)
#define FLAG_USE_PRECISION_OFFSET (1u << 1)
#define FLAG_BILINEAR_SAMPLING_OFFSET_MODE (1u << 2)
#define FLAG_USE_EARLY_OUT (1u << 3)
#define FLAG_DEBUG_EDGE_MASK (1u << 4)
#define FLAG_DEBUG_THREAD_INDEX (1u << 5)
#define FLAG_DEBUG_WAVE_INDEX (1u << 6)
#define FLAG_RESTRICT_CASTERS (1u << 7)
#define FLAG_DEBUG_CASTER_MASK (1u << 8)

bool has_flag(uint p_flag) {
	return (params.flags & p_flag) != 0u;
}

shared float depth_data[READ_COUNT * WAVE_SIZE];
shared bool lds_early_out;

bool early_out_pixel(float p_depth) {
	// The hook the original leaves for a custom test, culling the sky and
	// anything else outside the light's depth range.
	//
	// Bend suggest also skipping pixels an existing shadow pass already found
	// occluded, and the raytraced shadow mask IS available here -- it is written
	// earlier in _pre_opaque_render than this pass. It is deliberately not read:
	// this pass has to work with raytraced shadows switched off, and binding a
	// mask that may not exist to buy a partial early-out is not worth the second
	// code path.
	return p_depth >= params.depth_bounds.y || p_depth <= params.depth_bounds.x;
}

// Start pixel for each thread in the wavefront, plus the delta that walks to the
// next pixel WAVE_SIZE steps along the ray.
void compute_wavefront_extents(out vec2 r_delta_xy, out vec2 r_pixel_xy, out float r_pixel_distance, out bool r_major_axis_x) {
	// gl_WorkGroupID is unsigned and wave_offset is routinely negative, so the
	// cast has to happen before the add. Without it the sum wraps and the
	// quadrants left of and above the light silently fill with garbage.
	ivec2 xy = ivec2(gl_WorkGroupID.yz) * WAVE_SIZE + params.wave_offset;

	// Integer light position, and the fraction it sits away from that pixel's
	// center.
	vec2 light_xy = floor(params.light_coordinate.xy) + 0.5;
	vec2 light_xy_fraction = params.light_coordinate.xy - light_xy;
	bool reverse_direction = params.light_coordinate.w > 0.0;

	ivec2 sign_xy = sign(xy);
	bool horizontal = abs(xy.x + sign_xy.y) < abs(xy.y - sign_xy.x);

	ivec2 axis;
	axis.x = horizontal ? (+sign_xy.y) : 0;
	axis.y = horizontal ? 0 : (-sign_xy.x);

	xy = axis * int(gl_WorkGroupID.x) + xy;
	vec2 xy_f = vec2(xy);

	// Only the larger of the two axes matters when interpolating to the light.
	bool x_axis_major = abs(xy_f.x) > abs(xy_f.y);
	float major_axis = x_axis_major ? xy_f.x : xy_f.y;

	float major_axis_start = abs(major_axis);
	float major_axis_end = abs(major_axis) - float(WAVE_SIZE);

	float ma_light_frac = x_axis_major ? light_xy_fraction.x : light_xy_fraction.y;
	ma_light_frac = major_axis > 0.0 ? -ma_light_frac : ma_light_frac;

	vec2 start_xy = xy_f + light_xy;

	// The innermost ring has to interpolate to a pixel centered UV so that the
	// UV to pixel rounding does not skip output pixels.
	vec2 end_xy = mix(params.light_coordinate.xy, start_xy, (major_axis_end + ma_light_frac) / (major_axis_start + ma_light_frac));

	vec2 xy_delta = start_xy - end_xy;

	// Read order inverts when the light is behind the camera.
	float thread_step = float(gl_LocalInvocationID.x ^ (reverse_direction ? 0u : uint(WAVE_SIZE - 1)));

	r_pixel_xy = mix(start_xy, end_xy, thread_step / float(WAVE_SIZE));
	r_pixel_distance = major_axis_start - thread_step + ma_light_frac;
	r_delta_xy = xy_delta;
	r_major_axis_x = x_axis_major;
}

void main() {
	vec2 xy_delta;
	vec2 pixel_xy;
	float pixel_distance;
	bool x_axis_major;

	compute_wavefront_extents(xy_delta, pixel_xy, pixel_distance, x_axis_major);

	float sampling_depth[READ_COUNT];
	float shadowing_depth[READ_COUNT];
	bool may_cast[READ_COUNT];
	float depth_thickness_scale[READ_COUNT];
	float sample_distance[READ_COUNT];

	const float direction = -params.light_coordinate.w;
	const float z_sign = params.near_depth_value > params.far_depth_value ? -1.0 : 1.0;

	int i;
	bool is_edge = false;
	bool skip_pixel = false;
	vec2 write_xy = floor(pixel_xy);

	for (i = 0; i < READ_COUNT; i++) {
		// Depth is sampled twice per pixel and interpolated with an edge detect.
		// Interpolation only happens on the ray's minor axis; the major axis
		// coordinate stays at a pixel center.
		vec2 read_xy = floor(pixel_xy);
		float minor_axis = x_axis_major ? pixel_xy.y : pixel_xy.x;

		// Pushes an edge sample far out of range rather than branching, when edge
		// pixels are being excluded from casting.
		const float edge_skip = 1e20;

		vec2 depths;
		float bilinear = fract(minor_axis) - 0.5;

		read_xy += 0.5;

		float bias = bilinear > 0.0 ? 1.0 : -1.0;
		vec2 offset_xy = vec2(x_axis_major ? 0.0 : bias, x_axis_major ? bias : 0.0);

		depths.x = textureLod(depth_texture, read_xy * params.inv_depth_texture_size, 0.0).r;
		depths.y = textureLod(depth_texture, (read_xy + offset_xy) * params.inv_depth_texture_size, 0.0).r;

		// Only the CASTER side is restricted. sampling_depth and
		// depth_thickness_scale below describe the RECEIVER and must keep coming
		// from the full depth buffer: pointing either at a restricted source makes
		// depth_thickness_scale zero on every non-caster pixel, which divides by
		// zero in depth_scale, and makes the early-out reject every non-caster --
		// so grass would self shadow and the ground it stands on would receive
		// nothing.
		may_cast[i] = !has_flag(FLAG_RESTRICT_CASTERS) ||
				textureLod(caster_mask_texture, read_xy * params.inv_depth_texture_size, 0.0).r > 0.5;

		// Thickness and edge thresholds are fractions of the gap between this
		// sample and the far plane, not of the whole depth range.
		depth_thickness_scale[i] = abs(params.far_depth_value - depths.x);

		// Too much variance between the pair means an edge: point filter instead.
		bool use_point_filter = abs(depths.x - depths.y) > depth_thickness_scale[i] * params.bilinear_threshold;

		if (i == 0) {
			is_edge = use_point_filter;
		}

		if (has_flag(FLAG_BILINEAR_SAMPLING_OFFSET_MODE)) {
			bilinear = use_point_filter ? 0.0 : bilinear;
			// Sampling and shadowing depth are the same in this mode.
			sampling_depth[i] = mix(depths.x, depths.y, abs(bilinear));
			shadowing_depth[i] = (has_flag(FLAG_IGNORE_EDGE_PIXELS) && use_point_filter) ? edge_skip : sampling_depth[i];
		} else {
			sampling_depth[i] = depths.x;

			float edge_depth = has_flag(FLAG_IGNORE_EDGE_PIXELS) ? edge_skip : depths.x;
			// Any sample in this wavefront may be interpolated toward the bilinear
			// sample, so shadows are cast from the further of the pair.
			float shadow_depth = depths.x + abs(depths.x - depths.y) * z_sign;

			shadowing_depth[i] = use_point_filter ? edge_depth : shadow_depth;
		}

		sample_distance[i] = pixel_distance + float(WAVE_SIZE * i) * direction;

		// On to the next pixel along the ray, WAVE_SIZE pixels further.
		pixel_xy += xy_delta * direction;
	}

	if (has_flag(FLAG_USE_EARLY_OUT) && !has_flag(FLAG_DEBUG_WAVE_INDEX | FLAG_DEBUG_THREAD_INDEX | FLAG_DEBUG_EDGE_MASK | FLAG_DEBUG_CASTER_MASK)) {
		skip_pixel = early_out_pixel(sampling_depth[0]);

		bool early_out = !subgroupAny(!skip_pixel);

		if (gl_SubgroupSize == uint(WAVE_SIZE)) {
			// One workgroup is one hardware wave, so the vote is the whole answer.
			if (early_out) {
				return;
			}
		} else {
			// The workgroup spans several hardware waves and they have to agree
			// before any of them may leave, or the shared memory writes below would
			// be missing entries the survivors read.
			lds_early_out = true;

			memoryBarrierShared();
			barrier();

			if (!early_out) {
				lds_early_out = false;
			}

			memoryBarrierShared();
			barrier();

			if (lds_early_out) {
				return;
			}
		}
	}

	for (i = 0; i < READ_COUNT; i++) {
		// Perspective correct the shadowing depth. In this space every light ray
		// is parallel, which is what lets one line of shared depths answer for
		// every thread on it.
		float stored_depth = (shadowing_depth[i] - params.light_coordinate.z) / sample_distance[i];

		if (i != 0) {
			// Close to the light, an extended read can overshoot the light itself.
			// Those samples must not shadow anything.
			stored_depth = sample_distance[i] > 0.0 ? stored_depth : 1e10;
		}

		// The array already carries "cannot shadow" as a value, so the restriction
		// costs a select rather than anything crossing the barrier.
		depth_data[(i * WAVE_SIZE) + int(gl_LocalInvocationID.x)] = may_cast[i] ? stored_depth : 1e10;
	}

	memoryBarrierShared();
	barrier();

	if (skip_pixel) {
		return;
	}

	float start_depth = sampling_depth[0];

	if (has_flag(FLAG_USE_PRECISION_OFFSET)) {
		start_depth = mix(start_depth, params.far_depth_value, -1.0 / 65535.0);
	}

	start_depth = (start_depth - params.light_coordinate.z) / sample_distance[0];

	int sample_index = int(gl_LocalInvocationID.x) + 1;

	vec4 shadow_value = vec4(1.0);
	float hard_shadow = 1.0;

	// Inverse width of the shadowing window for the projected samples. Everything
	// in the shared list is divided by its sample distance, so multiplying by
	// sample_distance[0] undoes that projection for the pixel being shaded.
	// 1 / surface_thickness turns the user's percentage into that window, and
	// dividing by depth_thickness_scale[0] is because the percentage is of the
	// remaining depth to the far plane rather than of the whole range. The min()
	// keeps the window from collapsing very close to the light, and the
	// + direction biases the pixel at the light's exact center to fully lit or
	// fully shadowed rather than half of each.
	float depth_scale = min(sample_distance[0] + direction, 1.0 / params.surface_thickness) * sample_distance[0] / depth_thickness_scale[0];

	start_depth = start_depth * depth_scale - z_sign;

	// The first samples are allowed to shadow the pixel on their own, which is
	// what grounds a surface against something touching it.
	for (i = 0; i < HARD_SHADOW_SAMPLES; i++) {
		float depth_delta = abs(start_depth - depth_data[sample_index + i] * depth_scale);
		hard_shadow = min(hard_shadow, depth_delta);
	}

	// The bulk, accumulated in groups of four. Averaging those four is what stops
	// any single sample from fully shadowing the pixel; see the blend at the end.
	for (i = HARD_SHADOW_SAMPLES; i < SAMPLE_COUNT - FADE_OUT_SAMPLES; i++) {
		float depth_delta = abs(start_depth - depth_data[sample_index + i] * depth_scale);
		shadow_value[i & 3] = min(shadow_value[i & 3], depth_delta);
	}

	// The tail, faded so the shadow does not simply stop at its maximum length.
	for (i = SAMPLE_COUNT - FADE_OUT_SAMPLES; i < SAMPLE_COUNT; i++) {
		float depth_delta = abs(start_depth - depth_data[sample_index + i] * depth_scale);
		const float fade_out = float(i + 1 - (SAMPLE_COUNT - FADE_OUT_SAMPLES)) / float(FADE_OUT_SAMPLES + 1) * 0.75;
		shadow_value[i & 3] = min(shadow_value[i & 3], depth_delta + fade_out);
	}

	// Zero means a sample matched the reference depth exactly. The contrast boost
	// spreads that so a near miss still shadows.
	shadow_value = clamp(shadow_value * params.shadow_contrast + (1.0 - params.shadow_contrast), 0.0, 1.0);
	hard_shadow = clamp(hard_shadow * params.shadow_contrast + (1.0 - params.shadow_contrast), 0.0, 1.0);

	// Bend average the four accumulators, so a pixel needs four samples' worth of
	// evidence before it is fully shadowed. That is the right call when a stray
	// sample is likelier than a genuine one-sample occluder, and it is why only
	// the first HARD_SHADOW_SAMPLES are allowed to shadow on their own.
	//
	// Grass inverts the assumption. A blade narrower than the march's one pixel
	// spacing IS a one-sample occluder, so averaging under-darkens it however the
	// rest is tuned. Measured against this fork's raytraced shadow of the same
	// blades, IN LINEAR LIGHT, the screen space shadow reached 0.445 of the
	// trace's per-pixel darkening spread over one and a half times the area, and
	// neither surface_thickness nor shadow_contrast could close it: thickness buys
	// darkness only by widening the window until the shadow is visibly too wide,
	// and contrast saturates -- 4 to 16 moves mass 11% and darkness 5%.
	//
	// Do not restate these as "a quarter" or "a third". Both figures were
	// published once and retracted: the first had no measurement behind it, and
	// the second (0.335) was the same ratio taken in gamma space, which is what
	// differencing sRGB PNG values measures rather than light.
	//
	// Taking the minimum of the four instead is the same test with the evidence
	// requirement dropped back to one sample. hardness blends between them, so
	// zero is Bend's original behavior exactly and one shadows from any single
	// sample. It costs three min() for the whole march.
	float result = mix(dot(shadow_value, vec4(0.25)),
			min(min(shadow_value.x, shadow_value.y), min(shadow_value.z, shadow_value.w)),
			params.hardness);
	result = min(hard_shadow, result);

	if (has_flag(FLAG_DEBUG_EDGE_MASK)) {
		result = is_edge ? 1.0 : 0.0;
	}
	if (has_flag(FLAG_DEBUG_THREAD_INDEX)) {
		result = float(gl_LocalInvocationID.x) / float(WAVE_SIZE);
	}
	if (has_flag(FLAG_DEBUG_WAVE_INDEX)) {
		result = fract(float(gl_WorkGroupID.x) / float(WAVE_SIZE));
	}
	if (has_flag(FLAG_DEBUG_CASTER_MASK)) {
		// Which pixels are allowed to cast. White is a caster. With the restriction
		// off this is white everywhere, which is the correct answer rather than a
		// broken one.
		result = may_cast[0] ? 1.0 : 0.0;
	}

	// The original leans on an API where an out of range store is dropped. Being
	// explicit costs one compare against work that has already been paid for.
	ivec2 store_xy = ivec2(write_xy);
	if (store_xy.x >= 0 && store_xy.y >= 0 && store_xy.x < params.screen_size.x && store_xy.y < params.screen_size.y) {
		imageStore(shadow_image, store_xy, vec4(result));
	}
}
