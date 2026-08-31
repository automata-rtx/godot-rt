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

// Channel carrying no light. Matches SLOT_NONE in rt_shadow_trace.glsl.
#define SLOT_NONE 255u

// Visibility is stored as its square root and squared on read. Eight bits spread
// evenly over [0,1] put the same absolute step everywhere, but a shadow's detail
// is all at the dark end, where that step is a large RELATIVE error and shows as
// banding across a wide penumbra. Storing the root spends about five times more
// of the range below a quarter visibility, where the eye is, and gives up
// precision near fully lit, where nothing is happening.
//
// Filtering still happens in linear visibility. Averaging roots and squaring the
// result, which is what NVIDIA's SIGMA does, would darken every penumbra by
// Jensen's inequality: that is a look change, not a precision gain, so the
// encode and decode bracket the storage only.
#define VIS_DECODE(v) ((v) * (v))
#define VIS_ENCODE(v) sqrt(max(v, vec4(0.0)))

// Widest penumbra the hit distance channel describes, in pixels. Must match
// MAX_PENUMBRA_PIXELS in rt_shadow_trace.glsl.
#define MAX_PENUMBRA_PIXELS 32.0

// How much wider than its own measured penumbra a freshly disoccluded pixel may
// be filtered while its history refills. Four leaves the widening at its full
// reach for any penumbra of eight pixels or more, and folds it away entirely at
// a contact edge, where the traced answer needs no help.
#define HISTORY_FILL_SCALE 4.0

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
	float min_filter_pixels;
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

	vec4 center = VIS_DECODE(texelFetch(source_visibility, pos, 0));
	float center_depth = texelFetch(source_depth, pos, 0).r;
	uvec4 center_index = texelFetch(source_index, pos, 0);

	// Sky has nothing to filter and must not draw the surrounding geometry in.
	// A pixel no raytraced light reaches is fully lit in every channel, which no
	// amount of filtering changes; in an outdoor scene that is most of the
	// screen, and skipping it here is what keeps the denoiser's cost
	// proportional to how much of the frame the raytraced lights actually touch.
	if (center_depth <= 0.0 || center_index == uvec4(SLOT_NONE)) {
		imageStore(dest_visibility, pos, VIS_ENCODE(center));
		if (params.write_history != 0u) {
			imageStore(dest_history_visibility, pos, VIS_ENCODE(center));
			imageStore(dest_history_meta, pos, vec4(0.0, 0.0, 0.0, 0.0));
			imageStore(dest_history_index, pos, center_index);
		}
		return;
	}

	vec3 center_normal = normalize(texelFetch(source_normal_roughness, pos, 0).xyz * 2.0 - 1.0);
	vec4 hit_distance = texelFetch(source_hit_distance, pos, 0);
	float history_length = texelFetch(source_history_length, pos, 0).r;

	// How far the filter may reach, per light, in pixels — the same unit the
	// kernel steps in, so the filter can be made to match the penumbra instead of
	// merely tapering inside a footprint chosen by the iteration count. A blocker
	// resting on the surface produces a penumbra a pixel or two wide and must be
	// filtered that narrowly; filtering it across the eight pixels the last
	// iteration reaches is exactly what destroys contact hardening.
	//
	// A pixel with little accumulated history is still noisy whatever its
	// penumbra, so it keeps the wide filter until the history fills in.
	vec4 penumbra_pixels = clamp(hit_distance, vec4(0.0), vec4(1.0));

	// The center pixel's own penumbra is not enough to size the filter. With one
	// sample per pixel a point inside a penumbra either hits a blocker or misses,
	// and the ones that miss report no penumbra at all, because there was no
	// blocker to measure a distance to. Sizing from the center alone therefore
	// filters the shadowed half of a penumbra and leaves the lit half speckled.
	//
	// Taking the widest penumbra any immediate neighbor reports fixes that, and
	// costs nothing where it matters most: at a real contact edge every neighbor
	// also reports zero, so the filter still switches itself off entirely.
	for (int ny = -1; ny <= 1; ny++) {
		for (int nx = -1; nx <= 1; nx++) {
			ivec2 ntap = clamp(pos + ivec2(nx, ny), ivec2(0), params.screen_size - ivec2(1));
			if (texelFetch(source_index, ntap, 0) != center_index) {
				continue;
			}
			penumbra_pixels = max(penumbra_pixels,
					clamp(texelFetch(source_hit_distance, ntap, 0), vec4(0.0), vec4(1.0)));
		}
	}
	// Whether there is anything here to smooth at all. A blocker resting on the
	// surface produces a penumbra of literally zero, and with one sample per pixel
	// every ray around it agrees, so the traced answer is already exact. Filtering
	// it is pure loss, and it is exactly the contact hardening that makes a
	// raytraced shadow worth tracing. So both floors below -- the constant one and
	// the wide one a pixel gets while its history fills in -- apply only where a
	// penumbra was actually measured.
	penumbra_pixels *= MAX_PENUMBRA_PIXELS;

	vec4 has_penumbra = step(vec4(0.0001), penumbra_pixels);

	// A pixel whose history has just been thrown away has only this frame's one
	// ray to go on, so it is widened while the history refills. That is worth
	// doing -- without it a disocclusion is a burst of single-sample noise -- but
	// it was not bounded by what the geometry allows: the old code widened to
	// MAX_PENUMBRA_PIXELS outright, so a contact shadow whose true penumbra is a
	// fifth of a pixel was smeared over thirty-one of them, which is the exact
	// mistake the penumbra estimate exists to prevent, made one line after it was
	// computed.
	//
	// Capping the widening by a multiple of the measured penumbra leaves it
	// untouched wherever it was doing real work -- a wide penumbra still reaches
	// the full width -- and removes it where there was never anything to hide,
	// because a contact shadow's rays all agree and its raw answer is exact.
	//
	// The decay is deliberately still spread over the whole accumulation window
	// rather than a few frames. Shortening it was tried and made freshly
	// disoccluded pixels visibly grainy: the noise this hides outlives the first
	// handful of frames at one sample per light.
	float history_boost = 1.0 - clamp(history_length, 0.0, 1.0);
	vec4 fill_pixels = history_boost * min(vec4(MAX_PENUMBRA_PIXELS), penumbra_pixels * HISTORY_FILL_SCALE);
	vec4 floor_pixels = max(vec4(params.min_filter_pixels), fill_pixels);
	vec4 reach_pixels = max(penumbra_pixels, has_penumbra * floor_pixels);

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

			vec4 tap_visibility = VIS_DECODE(texelFetch(source_visibility, tap, 0));

			// Per-light reach, measured against where this tap actually lands on
			// screen. The kernel's step doubles every iteration, so the same tap
			// offset means one pixel on the first pass and eight on the last; a
			// tight penumbra simply stops contributing once the step outruns it.
			float tap_pixels = length(vec2(x, y)) * float(params.step_size);
			vec4 reach = clamp(vec4(1.0) - vec4(tap_pixels) / reach_pixels, vec4(0.0), vec4(1.0));
			vec4 weight = vec4(geometric) * reach;

			sum += tap_visibility * weight;
			weight_sum += weight;
		}
	}

	vec4 result = sum / max(weight_sum, vec4(1e-6));

	imageStore(dest_visibility, pos, VIS_ENCODE(result));

	if (params.write_history != 0u) {
		// The accumulation is handed back what it produced, NOT what this pass
		// made of it. Feeding the filtered result back would re-filter an
		// already-filtered signal every frame, and with a filter that never
		// fully collapses that compounds without bound: a two pixel kernel ends
		// up as a twenty pixel smear, and the contact hardening the trace worked
		// out is the first thing it destroys. Spatial filtering belongs on the
		// way to the screen, not in the loop.
		imageStore(dest_history_visibility, pos, VIS_ENCODE(center));
		imageStore(dest_history_index, pos, center_index);

		// Stored raw rather than normalized: the temporal pass compares it against
		// the w of a reprojected clip position, which is the same quantity in the
		// same units.
		imageStore(dest_history_meta, pos,
				vec4(linear_view_depth(center_depth), history_length, 0.0, 0.0));
	}
}
