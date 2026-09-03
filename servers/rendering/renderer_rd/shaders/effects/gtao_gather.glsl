#[compute]

#version 450

#VERSION_DEFINES

// Ground truth ambient occlusion with a visibility bitmask.
//
// The march is GTAO's: slices through the hemisphere, each one a straight line
// in screen space, each sample turned into an elevation angle. What differs is
// what a slice remembers. GTAO keeps one running horizon angle, which says
// everything past the first occluder is solid and every occluder is infinitely
// thick. This keeps a 32 bit occupancy mask over the slice's half turn instead,
// and every sample marks the RANGE of sectors between its front face and a back
// face pushed a fixed distance further from the camera. Two occluders with sky
// between them stay two occluders, and a thin wall stops occluding once the
// march passes behind it.
//
// After Therrien, Levesque and Gilet, "Screen Space Indirect Lighting with
// Visibility Bitmask" (2023), reduced to the occlusion term; the slice geometry
// is Jimenez et al.'s GTAO (2016).

#define SECTOR_COUNT 32
#define PI 3.14159265359
#define HALF_PI 1.57079632679

// Sine of the smallest elevation a sample must clear to count as an occluder.
#define ANGLE_BIAS 0.03

#define SECTOR_STEP (PI / float(SECTOR_COUNT))
// One sector of rotation, at the doubled rate the sector weights step at.
#define ROT_COS 0.98078528040
#define ROT_SIN 0.19509032201

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	// Resolution the gather runs at, and the full internal resolution the depth
	// pyramid and the normal buffer are stored at.
	ivec2 gather_size;
	ivec2 full_size;

	// Turns a screen UV into a view space ray, the same two terms the other
	// screen space effects derive from the projection. Note the input is a UV in
	// zero to one, not a normalized device position.
	vec2 uv_to_view_mul;
	vec2 uv_to_view_add;

	// World units the march reaches, before any distance scaling.
	float radius;
	// How far behind a sample its back face is assumed to sit, in world units.
	// This is what lets light pass behind a thin surface.
	float thickness;
	// Occlusion is raised to this power on the way out, matching the knob the
	// existing screen space occlusion exposes.
	float power;
	// Strength, applied as a ratio rather than as a subtraction at the bottom of
	// this shader. Already scaled on the CPU, because the Environment default it
	// comes from was calibrated for the other estimator.
	float intensity;

	// Distance past which occlusion fades out, and the reciprocal of the width
	// of that fade.
	float fade_from;
	float fade_inv_span;

	int slice_count;
	int steps_per_slice;

	// When set, the radius is chosen so the march covers a fixed fraction of
	// the screen at every depth rather than a fixed distance in the world.
	bool scale_radius_with_distance;
	// Fraction of screen HEIGHT the march covers when it does.
	float screen_radius;

	bool orthogonal;
	bool use_bitmask;

	// Full resolution pixels per gather texel, per axis. Passed rather than
	// recovered here, because the gather size is rounded UP and an integer
	// division rounds DOWN: at any odd width the two disagree, the recovered
	// stride collapses from two to one, and the gather then answers only for
	// the top left quadrant of the screen while the rest is magnified over it.
	ivec2 gather_stride;
	// When set, the gather shades a CHECKERBOARD packed two full resolution
	// pixels to a texel along x and one row to a row, rather than a coarser grid.
	// Half the pixels get their own answer instead of a quarter, and every pixel
	// that does not has all four of its immediate neighbors shaded, one pixel
	// away rather than two. The stride above does not describe that mapping and
	// is ignored on this path.
	bool checkerboard;
	uint pad0;
}
params;

// The full resolution pixel a gather texel answers for.
//
// On the checkerboard the parity alternates per row, so texel (u, y) holds pixel
// (2u + (y & 1), y): row 0 shades the even columns, row 1 the odd ones. At an odd
// width the last texel of an odd row lands one past the right edge; clamping it
// costs one lane per odd row and nothing ever reads the result, because no
// full resolution pixel maps back to it.
ivec2 gather_to_full(ivec2 gather_pos) {
	ivec2 full_pos = params.checkerboard
			? ivec2(gather_pos.x * 2 + (gather_pos.y & 1), gather_pos.y)
			: gather_pos * params.gather_stride;
	return min(full_pos, params.full_size - ivec2(1));
}

layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image2D source_normal;
layout(rg16f, set = 0, binding = 2) uniform restrict writeonly image2D dest_ao;

vec3 uv_to_view(vec2 uv, float view_depth) {
	if (params.orthogonal) {
		return vec3(params.uv_to_view_mul * uv + params.uv_to_view_add, view_depth);
	}
	return vec3((params.uv_to_view_mul * uv + params.uv_to_view_add) * view_depth, view_depth);
}

// Same decode the existing screen space occlusion uses, so both describe
// normals in the same space.
vec3 load_view_normal(ivec2 pos) {
	vec3 n = normalize(imageLoad(source_normal, pos).xyz * 2.0 - 1.0);
	n.z = -n.z;
	return n;
}

// Spatially fixed dither. Deliberately carries no frame counter: with no
// temporal antialiasing downstream nothing would resolve a changing pattern,
// and a fixed one reads as a still texture rather than as a crawl.
vec2 spatial_noise(ivec2 pos) {
	float a = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))));
	float b = fract(float((pos.x ^ pos.y) * 1103515245u % 1024u) * (1.0 / 1024.0));
	return vec2(a, b);
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.gather_size))) {
		return;
	}

	// The gather may run at half resolution, but every world space quantity
	// below is derived from the FULL resolution pixel footprint. That is what
	// keeps the near field identical between the two resolutions: only how many
	// pixels get their own answer changes, not how far the march reaches or how
	// close its first step lands.
	ivec2 full_pos = gather_to_full(pos);

	float center_depth = texelFetch(source_depth, full_pos, 0).r;

	vec2 uv = (vec2(full_pos) + 0.5) / vec2(params.full_size);
	vec3 center_pos = uv_to_view(uv, center_depth);
	vec3 view_dir = params.orthogonal ? vec3(0.0, 0.0, 1.0) : normalize(-center_pos);
	vec3 normal = load_view_normal(full_pos);

	// Nothing in front of the far plane, or a surface facing away: fully lit.
	float fade = clamp(1.0 - (center_depth - params.fade_from) * params.fade_inv_span, 0.0, 1.0);
	if (fade <= 0.0) {
		imageStore(dest_ao, pos, vec4(1.0, center_depth, 0.0, 0.0));
		return;
	}

	// The two radii are the same quantity read from opposite ends. Off, the
	// world radius is what the artist set and the on-screen disk shrinks as the
	// surface recedes, until at distance the steps land on the same texel and
	// most of the sample budget is spent re-reading it. On, the on-screen span
	// is fixed and the world radius follows the depth, so every step lands
	// somewhere new at any distance. That is what buys coverage far away.
	float world_radius = params.radius;
	float screen_radius_px;
	if (params.scale_radius_with_distance) {
		// Anchored to the VERTICAL axis. A camera holds its vertical field of
		// view fixed and widening the window adds horizontal field, so a
		// fraction of screen WIDTH is a fraction of a quantity that grows with
		// the aspect ratio -- and the same setting would reach almost twice as
		// far on a sixteen by nine viewport as on a square one. Height is the
		// axis that does not move.
		// The radius property is a multiplier on that span rather than a distance,
		// because the span is what is being held fixed. It has to scale the span
		// itself and not only the world reach derived from it: those two describe
		// the same march, so if only one of them moved, raising the radius would
		// widen a cutoff the steps never walk far enough to reach and lowering it
		// would truncate the march while still spreading its steps over the full
		// span.
		screen_radius_px = params.radius * params.screen_radius * float(params.full_size.y);
		world_radius = params.radius * params.screen_radius * abs(params.uv_to_view_mul.y) * center_depth;
	} else {
		// The whole screen spans uv_to_view_mul.x * depth in view space, so a
		// world radius is that fraction of it. This one needs no aspect
		// correction and must not be given one: a pixel is the same world
		// length on either axis, so width over the horizontal extent and height
		// over the vertical extent are the same number.
		float view_extent = params.orthogonal ? 1.0 : max(center_depth, 0.0001);
		screen_radius_px = (world_radius / max(abs(params.uv_to_view_mul.x) * view_extent, 0.0001)) * float(params.full_size.x);
	}
	screen_radius_px = clamp(screen_radius_px, 2.0, float(params.full_size.x));

	// Thickness follows the radius rather than staying a fixed distance. If it
	// did not, a march that reaches ten times further at distance would push
	// every back face into the same shallow shell and the mask would read as
	// almost solid.
	float thickness = params.thickness * world_radius;

	vec2 noise = spatial_noise(pos);
	float slice_bias = noise.x;
	float step_bias = noise.y;

	// Occlusion resolves as a ratio of two sums rather than as a mean of per
	// slice fractions. Every slice weighs into both, so a surface with nothing
	// above it comes out at exactly one whatever its orientation and whatever
	// the dither picked, while the weighting between slices stays the one the
	// integral asks for.
	float open_sum = 0.0;
	float total_sum = 0.0;
	float slice_norm = 1.0 / float(max(params.slice_count, 1));

	for (int slice = 0; slice < params.slice_count; slice++) {
		float phi = (float(slice) + slice_bias) * PI * slice_norm;
		vec2 slice_dir = vec2(cos(phi), sin(phi));

		// An orthonormal basis for the slice plane, which is spanned by the view
		// direction and the slice direction lifted into view space. Two details
		// are load bearing. The basis has to be orthonormalized, because stepping
		// along the slice at constant depth gives a direction that lies in the
		// plane but is not perpendicular to the view direction under perspective,
		// and measuring elevations against a skewed axis puts every sample at the
		// wrong one. And the probe steps in PIXELS, because that is what the march
		// walks in -- a UV sized step points somewhere else entirely on a viewport
		// that is not square.
		vec2 probe_uv = uv + slice_dir * 8.0 / vec2(params.full_size);
		vec3 in_plane = uv_to_view(probe_uv, center_depth) - center_pos;
		vec3 slice_bitangent = normalize(cross(in_plane, view_dir));
		vec3 slice_tangent = cross(view_dir, slice_bitangent);
		vec3 projected_normal = normal - slice_bitangent * dot(normal, slice_bitangent);
		float projected_len = length(projected_normal);

		// A normal lying in the slice's own bitangent has no arc to integrate
		// over. Dropping the slice from both sums leaves the remaining ones to
		// answer, rather than voting the whole hemisphere open.
		if (projected_len < 0.0001) {
			continue;
		}

		// Where the arc sits: the signed angle of the projected normal away from
		// the view direction, measured inside the slice plane.
		float n_angle = atan(dot(projected_normal, slice_tangent), dot(projected_normal, view_dir));

		uint occupancy = 0u;

		for (int side = 0; side < 2; side++) {
			float side_sign = side == 0 ? 1.0 : -1.0;

			for (int step = 0; step < params.steps_per_slice; step++) {
				// Even spacing across the disk. A horizon march can afford to
				// crowd its steps near the shaded point, because one early hit
				// stands in for everything behind it. A mask cannot: an occluder
				// that falls between two steps is not approximated, it is simply
				// absent, and the far half of a quadratic march is where the gaps
				// get wide enough for a whole box to fall through one.
				float t = (float(step) + step_bias) / float(params.steps_per_slice);
				float offset_px = max(t * screen_radius_px, 1.0);

				vec2 sample_px = vec2(full_pos) + slice_dir * offset_px * side_sign;
				if (any(lessThan(sample_px, vec2(0.0))) || any(greaterThanEqual(sample_px, vec2(params.full_size)))) {
					break;
				}

				// Coarser levels only once a step is far enough out that the
				// full resolution texels it skips could not have mattered.
				float mip = clamp(floor(log2(offset_px)) - 3.0, 0.0, 4.0);

				// Read the texel CENTER, and reconstruct the sample there too.
				// The pyramid is bound to a nearest sampler, so the depth that
				// comes back describes the surface at the middle of whichever
				// texel the step landed in, not at the point the step asked for.
				// Pairing that depth with the asked for direction puts the sample
				// off the surface it came from by up to half a texel of depth
				// slope, in a direction that depends only on where the step
				// happened to fall. On a plane seen at a glancing angle half of
				// those land above the shaded point, and the floor quietly
				// occludes itself.
				ivec2 mip_size = max(params.full_size >> int(mip), ivec2(1));
				vec2 mip_texel = floor((sample_px + 0.5) * (vec2(mip_size) / vec2(params.full_size)));
				mip_texel = clamp(mip_texel, vec2(0.0), vec2(mip_size - ivec2(1)));
				vec2 sample_uv = (mip_texel + 0.5) / vec2(mip_size);

				float sample_depth = textureLod(source_depth, sample_uv, mip).r;

				vec3 sample_pos = uv_to_view(sample_uv, sample_depth);

				vec3 delta = sample_pos - center_pos;
				float dist = length(delta);
				if (dist < 0.0001 || dist > world_radius) {
					continue;
				}

				// A sample at or below the shaded surface's own plane cannot
				// occlude the hemisphere above it, and one within a few degrees
				// of that plane is grazing rather than occluding. The floor
				// would otherwise occlude itself: at any finite depth precision
				// a coplanar neighbor reconstructs to either side of the plane
				// at random, and the half that lands above marks sectors.
				if (dot(delta, normal) < dist * ANGLE_BIAS) {
					continue;
				}

				// The back face is the same sample pushed away from the camera.
				// Everything between the two is treated as solid; everything
				// beyond it is open again, which is the whole point.
				vec3 back_delta = delta - view_dir * thickness;

				// Angles have to be measured INSIDE the slice plane and carry a
				// sign, so each is the sample resolved onto that plane's two
				// axes. An unsigned angle against the view direction in three
				// dimensions instead puts a sample lying flat on the shaded
				// surface -- where the elevation is zero and it should occlude
				// nothing -- into the middle of the arc, which darkens every
				// flat plane uniformly.
				float front_angle = atan(dot(delta, slice_tangent), dot(delta, view_dir));
				float back_angle = atan(dot(back_delta, slice_tangent), dot(back_delta, view_dir));

				// Into the slice's own coordinate, where 0 and 1 are the two
				// ends of the half turn centered on the projected normal.
				float h1 = clamp((front_angle - n_angle + HALF_PI) / PI, 0.0, 1.0);
				float h2 = clamp((back_angle - n_angle + HALF_PI) / PI, 0.0, 1.0);
				float lo = min(h1, h2);
				float hi = max(h1, h2);

				int first = int(floor(lo * float(SECTOR_COUNT)));
				int count = int(ceil((hi - lo) * float(SECTOR_COUNT)));
				if (count <= 0) {
					continue;
				}
				first = clamp(first, 0, SECTOR_COUNT - 1);
				count = min(count, SECTOR_COUNT - first);

				uint mask = count >= SECTOR_COUNT ? 0xffffffffu : ((1u << uint(count)) - 1u) << uint(first);
				occupancy |= mask;
			}
		}

		// Which sectors light still reaches. The mask answers that directly.
		// Without it the answer is the horizon one: only the unbroken run of
		// open sectors around the normal survives, so the first occluder on
		// each side closes everything past it however much sky lies beyond.
		uint open_mask;
		if (params.use_bitmask) {
			open_mask = ~occupancy;
		} else {
			open_mask = 0u;
			for (int i = SECTOR_COUNT / 2 - 1; i >= 0; i--) {
				if ((occupancy & (1u << uint(i))) != 0u) {
					break;
				}
				open_mask |= 1u << uint(i);
			}
			for (int i = SECTOR_COUNT / 2; i < SECTOR_COUNT; i++) {
				if ((occupancy & (1u << uint(i))) != 0u) {
					break;
				}
				open_mask |= 1u << uint(i);
			}
		}

		// What a sector is worth is the cosine weighted solid angle it covers,
		// which is not its share of the arc. Sweeping the slice about the view
		// direction turns each sector into a ring, and that ring's
		// circumference goes with the sine of the angle from the view axis: a
		// sector pointing straight back at the camera sweeps almost no solid
		// angle, one at the edge of the arc sweeps the most. Weighting sectors
		// by angular width alone drops that factor, and the result is wrong
		// everywhere anything is actually occluded -- it does not average out
		// and it does not shrink with more samples.
		//
		// The integral of cos(t - n) * |sin t| has a closed form, so the
		// cumulative weight up to each sector boundary is evaluated outright.
		// Only cos(2t - n) varies per boundary, and that is a rotation, so it
		// steps by a multiply-add instead of a trig call.
		float sin_n = sin(n_angle);
		float cos_n = cos(n_angle);
		float bound = n_angle - HALF_PI;
		float cos_2t = -cos_n; // cos(2 * bound - n), at bound = n - pi/2.
		float sin_2t = -sin_n;
		float a_zero = -cos_n * 0.25;
		float a_low = -cos_2t * 0.25 + bound * sin_n * 0.5;

		float prev_weight = 0.0;
		float arc_open = 0.0;

		for (int i = 0; i < SECTOR_COUNT; i++) {
			float next_c = cos_2t * ROT_COS - sin_2t * ROT_SIN;
			sin_2t = sin_2t * ROT_COS + cos_2t * ROT_SIN;
			cos_2t = next_c;
			bound += SECTOR_STEP;

			float a = -cos_2t * 0.25 + bound * sin_n * 0.5;
			// The integrand folds at the view direction, where the sine
			// changes sign, so the antiderivative is mirrored below it.
			float weight = bound <= 0.0 ? (a_low - a) : (a - 2.0 * a_zero + a_low);

			if ((open_mask & (1u << uint(i))) != 0u) {
				arc_open += weight - prev_weight;
			}
			prev_weight = weight;
		}

		// The slice counts for how much of the normal it holds, which is what
		// makes slices through the steep direction of a tilted surface matter
		// more than slices across it. prev_weight is the whole arc, taken from
		// the same running sum as the open part so the two cannot disagree.
		open_sum += projected_len * arc_open;
		total_sum += projected_len * prev_weight;
	}

	float visibility = total_sum > 0.000001 ? open_sum / total_sum : 1.0;
	visibility = clamp(visibility, 0.0, 1.0);

	// Shape first, strength second -- but strength as a RATIO rather than as a
	// subtraction. What the line above produces is a normalized cosine weighted
	// visibility, so scaling its distance from white by the intensity subtracts
	// a fixed multiple of a quantity that is already the right size, and that
	// form has a hard floor: at an intensity of two, every visibility at or
	// below 0.63 -- roughly what an ordinary concave corner IS -- lands on
	// exactly zero. A third of the tonal range collapses onto one flat black
	// value here, inside the gather, before the filter downstream ever sees it,
	// and no filter can recover a value that was never stored.
	//
	// The ratio below has the same slope at the white end, so the curve's shape
	// asks nothing new of an artist's tuning -- though the number itself now
	// arrives scaled, because the Environment default was calibrated for the
	// other estimator. It approaches zero without arriving, so a corner stays a
	// gradient. At an intensity of one it is the identity, which is what the
	// validation harness measures.
	float open = pow(visibility, params.power);
	visibility = open / max(open + (1.0 - open) * params.intensity, 0.0001);
	visibility = mix(1.0, visibility, fade);

	imageStore(dest_ao, pos, vec4(visibility, center_depth, 0.0, 0.0));
}
