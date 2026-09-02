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

	// Turns a depth buffer value into a distance along the camera's forward
	// axis, the same four terms the a-trous pass uses. Needed because the
	// reprojection above carries a scale that has to be undone before the
	// result can be compared against a stored distance; see below.
	vec4 depth_unproject;

	ivec2 screen_size;
	float depth_tolerance;
	float max_history;

	// How far outside the current frame's local spread the history is allowed to
	// sit, in standard deviations. Zero disables the test.
	float clamp_sigma;
	// Rays per light this frame, so the clamp can tell a neighborhood that
	// genuinely agrees from one that has too few samples to disagree yet.
	float sample_count;
	uint frame_index;
	float pad;
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

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}

	vec4 current = VIS_DECODE(texelFetch(source_visibility, pos, 0));
	float depth = texelFetch(source_depth, pos, 0).r;

	uvec4 current_index = texelFetch(source_index, pos, 0);

	// Sky, or a pixel no raytraced light reaches. Neither has anything to
	// accumulate, and leaving a history behind would bleed into whatever moves
	// in front of it later.
	if (depth <= 0.0 || current_index == uvec4(SLOT_NONE)) {
		imageStore(dest_visibility, pos, VIS_ENCODE(current));
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

		// The reprojection maps a point given in this frame's normalized device
		// coordinates, so what comes out is the previous frame's clip position
		// scaled by the reciprocal of this pixel's view depth. The scale cancels
		// in the division above, which is why the reprojected position is right,
		// but it does not cancel in w: that leaves the RATIO of the previous view
		// depth to this one. Multiplying by this pixel's own view depth turns it
		// back into the distance the history stores.
		float expected_depth = previous_clip.w * linear_view_depth(depth);

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
				visibility_sum += VIS_DECODE(texelFetch(history_visibility, tap, 0)) * weight;
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

	// Reject history that this frame could not plausibly have produced.
	//
	// The surface test above only asks whether the same surface is still here.
	// It cannot see a shadow move ACROSS a surface: the floor under a moving
	// blocker reprojects perfectly, passes every test, and hands back a shadow
	// that is no longer there. With a thirty-two frame window that trails for
	// half a second.
	//
	// So measure what this frame actually sees nearby, and clamp the history
	// into that range. Where the neighborhood agrees -- open floor, deep umbra --
	// the window is only as wide as the binomial floor below allows, and the
	// history is pulled back to what this frame sees within a frame or two.
	// Inside a penumbra, where one ray per pixel makes neighbors genuinely
	// disagree, the spread is wide and accumulation proceeds untouched. The test
	// costs nothing where it is not needed and everything where it is.
	if (params.clamp_sigma > 0.0 && history_length > 0.0) {
		vec4 moment1 = vec4(0.0);
		vec4 moment2 = vec4(0.0);
		float taps = 0.0;
		for (int cy = -1; cy <= 1; cy++) {
			for (int cx = -1; cx <= 1; cx++) {
				ivec2 tap = clamp(pos + ivec2(cx, cy), ivec2(0), params.screen_size - ivec2(1));
				// A neighbor carrying different lights describes something else.
				if (texelFetch(source_index, tap, 0) != current_index) {
					continue;
				}
				vec4 v = VIS_DECODE(texelFetch(source_visibility, tap, 0));
				moment1 += v;
				moment2 += v * v;
				taps += 1.0;
			}
		}
		if (taps > 0.0) {
			moment1 /= taps;
			moment2 /= taps;
			vec4 sigma = sqrt(max(moment2 - moment1 * moment1, vec4(0.0)));

			// The spread of the neighborhood is not all of the uncertainty in it.
			// Each of those values is a count of blocked rays out of a handful,
			// so in the shallow ends of a penumbra the nine of them agree often
			// -- at one ray per light and a true visibility of 0.95, about two
			// frames in three -- and the measured spread is then exactly zero.
			// Clamping to a window of no width pins the accumulated value to that
			// binary answer, and doing it over and over erases the tails of every
			// penumbra.
			//
			// So floor the spread with the standard error those ray counts
			// actually carry. The two pseudo counts are the usual continuity
			// correction, and they are what stops the floor collapsing along with
			// the spread when the samples happen to be unanimous. It tightens on
			// its own as the sample count rises, because then unanimity really
			// does mean the answer is 0 or 1.
			float trials = max(taps * params.sample_count, 1.0);
			vec4 corrected = (moment1 * trials + 2.0) / (trials + 4.0);
			sigma = max(sigma, sqrt(corrected * (1.0 - corrected) / (trials + 4.0)));

			vec4 clamped = clamp(history,
					moment1 - sigma * params.clamp_sigma,
					moment1 + sigma * params.clamp_sigma);

			// How far the clamp had to move the history is a measure of how wrong
			// it was, and a history that wrong has no business keeping the weight
			// of a long one. Shortening the window in proportion lets the pixel
			// re-converge over the next few frames instead of over the whole
			// window: without it a blocker that moves leaves no stale shadow
			// behind -- the clamp saw to that -- but its new one fades in over
			// half a second rather than arriving with it.
			//
			// A history sitting inside the window is not moved at all, which is
			// every pixel in the steady state, so this costs nothing where nothing
			// is wrong. Taking the worst of the four channels is deliberate: they
			// share one window, and being late is worse than being brief.
			vec4 moved = abs(clamped - history);
			float lag = max(max(moved.x, moved.y), max(moved.z, moved.w));
			history_length *= 1.0 - clamp(lag, 0.0, 1.0);

			history = clamped;
		}
	}

	// Exponential moving average with a bounded window. The first frames after a
	// disocclusion weight the new sample heavily so the shadow appears
	// immediately; once the window fills, alpha settles at 1 / max_history and
	// the estimate is stable.
	history_length = history_length > 0.0 ? min(history_length + 1.0, params.max_history) : 1.0;
	float alpha = 1.0 / history_length;

	vec4 accumulated = mix(history, current, alpha);

	// Rounding to eight bits is not a detail here, because this accumulator
	// re-reads its own rounded output every frame. Once the step it wants to take
	// is smaller than half a quantization level the value stops moving, and that
	// is not symmetric: in the lit end of a penumbra at one ray per light, the
	// occasional blocked ray is a step down large enough to land while the many
	// lit rays each ask for a step up too small to, so the value ratchets darker
	// and the shadow's soft edge creeps outward, which is exactly the softening
	// the traced answer exists to avoid.
	//
	// Offsetting by a per pixel, per frame fraction of a step before the store
	// makes the rounding error zero mean, so the accumulation converges on the
	// value it actually computed. It costs one hash and no memory.
	float dither = dither_offset(pos, params.frame_index) - 0.5;
	imageStore(dest_visibility, pos, VIS_ENCODE(accumulated) + vec4(dither / 255.0));
	imageStore(dest_history_length, pos, vec4(history_length / max(params.max_history, 1.0)));
}
