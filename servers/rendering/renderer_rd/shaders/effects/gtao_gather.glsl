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

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	// Resolution the gather runs at, and the full internal resolution the depth
	// pyramid and the normal buffer are stored at.
	ivec2 gather_size;
	ivec2 full_size;

	// Turns a normalized device position into a view space ray, the same two
	// terms the other screen space effects derive from the projection.
	vec2 ndc_to_view_mul;
	vec2 ndc_to_view_add;

	// World units the march reaches, before any distance scaling.
	float radius;
	// How far behind a sample its back face is assumed to sit, in world units.
	// This is what lets light pass behind a thin surface.
	float thickness;
	// Occlusion is raised to this power on the way out, matching the knob the
	// existing screen space occlusion exposes.
	float power;
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
	// Fraction of screen width the march covers when it does.
	float screen_radius;

	bool orthogonal;
	bool use_bitmask;
}
params;

layout(set = 0, binding = 0) uniform sampler2D source_depth;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image2D source_normal;
layout(rg16f, set = 0, binding = 2) uniform restrict writeonly image2D dest_ao;

vec3 ndc_to_view(vec2 ndc, float view_depth) {
	if (params.orthogonal) {
		return vec3(params.ndc_to_view_mul * ndc + params.ndc_to_view_add, view_depth);
	}
	return vec3((params.ndc_to_view_mul * ndc + params.ndc_to_view_add) * view_depth, view_depth);
}

// Same decode the existing screen space occlusion uses, so both describe
// normals in the same space.
vec3 load_view_normal(ivec2 pos) {
	vec3 n = normalize(imageLoad(source_normal, pos).xyz * 2.0 - 1.0);
	n.z = -n.z;
	return n;
}

// Fraction of the cosine weighted half turn that sector i covers.
//
// The published method counts set bits, weighting every sector equally. That
// answers a different question from the one ambient occlusion asks: a direction
// along the surface normal admits far more light than one at the grazing edge,
// and the near field bounce approximation the forward shader applies on top was
// fitted against the cosine weighted quantity. Sector i spans the angles
// [i, i+1] * pi/32 measured from one edge of the arc, so its share of the
// integral is the difference of the sines at its two ends, halved to normalize.
float sector_weight(int i) {
	float lo = float(i) * (PI / float(SECTOR_COUNT)) - HALF_PI;
	float hi = float(i + 1) * (PI / float(SECTOR_COUNT)) - HALF_PI;
	return (sin(hi) - sin(lo)) * 0.5;
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
	ivec2 full_pos = pos * (params.full_size.x / max(params.gather_size.x, 1));
	full_pos = min(full_pos, params.full_size - ivec2(1));

	float center_depth = texelFetch(source_depth, full_pos, 0).r;

	vec2 uv = (vec2(full_pos) + 0.5) / vec2(params.full_size);
	vec2 ndc = uv * 2.0 - 1.0;
	vec3 center_pos = ndc_to_view(ndc, center_depth);
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
		screen_radius_px = params.screen_radius * float(params.full_size.x);
		world_radius = params.radius * params.screen_radius * center_depth * 2.0;
	} else {
		// Project the world radius onto the screen at this depth.
		float view_extent = params.orthogonal ? 1.0 : max(center_depth, 0.0001);
		screen_radius_px = (world_radius / (abs(params.ndc_to_view_mul.x) * view_extent)) * 0.5 * float(params.full_size.x);
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

	float visibility = 0.0;
	float slice_norm = 1.0 / float(max(params.slice_count, 1));

	for (int slice = 0; slice < params.slice_count; slice++) {
		float phi = (float(slice) + slice_bias) * PI * slice_norm;
		vec2 slice_dir = vec2(cos(phi), sin(phi));

		// The slice plane is spanned by the view direction and the slice
		// direction lifted into view space. Project the normal into it; the
		// signed angle between that projection and the view direction is where
		// the arc's center sits.
		vec3 slice_tangent = normalize(ndc_to_view(ndc + slice_dir * 0.01, center_depth) - center_pos);
		vec3 slice_bitangent = normalize(cross(slice_tangent, view_dir));
		vec3 projected_normal = normal - slice_bitangent * dot(normal, slice_bitangent);
		float projected_len = length(projected_normal);

		if (projected_len < 0.0001) {
			visibility += 1.0;
			continue;
		}

		vec3 projected_dir = projected_normal / projected_len;
		float sign_n = sign(dot(projected_dir, slice_tangent));
		float n_angle = sign_n * acos(clamp(dot(projected_dir, view_dir), -1.0, 1.0));

		uint occupancy = 0u;

		for (int side = 0; side < 2; side++) {
			float side_sign = side == 0 ? 1.0 : -1.0;

			for (int step = 0; step < params.steps_per_slice; step++) {
				// Quadratic spacing puts more steps near the shaded point,
				// where occlusion changes fastest.
				float t = (float(step) + step_bias) / float(params.steps_per_slice);
				float offset_px = max(t * t * screen_radius_px, 1.0);

				vec2 sample_px = vec2(full_pos) + slice_dir * offset_px * side_sign;
				if (any(lessThan(sample_px, vec2(0.0))) || any(greaterThanEqual(sample_px, vec2(params.full_size)))) {
					break;
				}

				// Coarser levels only once a step is far enough out that the
				// full resolution texels it skips could not have mattered.
				float mip = clamp(floor(log2(offset_px)) - 3.0, 0.0, 4.0);
				float sample_depth = textureLod(source_depth, (sample_px + 0.5) / vec2(params.full_size), mip).r;

				vec2 sample_ndc = ((sample_px + 0.5) / vec2(params.full_size)) * 2.0 - 1.0;
				vec3 sample_pos = ndc_to_view(sample_ndc, sample_depth);

				vec3 delta = sample_pos - center_pos;
				float dist = length(delta);
				if (dist < 0.0001 || dist > world_radius) {
					continue;
				}

				vec3 front_dir = delta / dist;
				// The back face is the same sample pushed away from the camera.
				// Everything between the two is treated as solid; everything
				// beyond it is open again, which is the whole point.
				vec3 back_dir = normalize(delta + view_dir * -thickness);

				float front_angle = acos(clamp(dot(front_dir, view_dir), -1.0, 1.0));
				float back_angle = acos(clamp(dot(back_dir, view_dir), -1.0, 1.0));

				// Both angles into the slice's own coordinate, where 0 and 1
				// are the two ends of the half turn centered on the normal.
				float h1 = clamp(((side_sign * -front_angle) - n_angle + HALF_PI) / PI, 0.0, 1.0);
				float h2 = clamp(((side_sign * -back_angle) - n_angle + HALF_PI) / PI, 0.0, 1.0);
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

		if (params.use_bitmask) {
			float open = 0.0;
			for (int i = 0; i < SECTOR_COUNT; i++) {
				if ((occupancy & (1u << uint(i))) == 0u) {
					open += sector_weight(i);
				}
			}
			visibility += open;
		} else {
			// Without the mask this collapses to the horizon behavior: the
			// arc is closed from each end inward to the outermost set bit.
			int lowest = SECTOR_COUNT;
			int highest = -1;
			for (int i = 0; i < SECTOR_COUNT; i++) {
				if ((occupancy & (1u << uint(i))) != 0u) {
					lowest = min(lowest, i);
					highest = max(highest, i);
				}
			}
			float open = 0.0;
			for (int i = 0; i < SECTOR_COUNT; i++) {
				if (i < lowest || i > highest) {
					open += sector_weight(i);
				}
			}
			visibility += highest < 0 ? 1.0 : open;
		}
	}

	visibility *= slice_norm;
	visibility = clamp(visibility, 0.0, 1.0);
	visibility = pow(visibility, params.power);
	visibility = clamp(1.0 - (1.0 - visibility) * params.intensity, 0.0, 1.0);
	visibility = mix(1.0, visibility, fade);

	imageStore(dest_ao, pos, vec4(visibility, center_depth, 0.0, 0.0));
}
