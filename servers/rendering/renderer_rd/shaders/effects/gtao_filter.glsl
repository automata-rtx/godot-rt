#[compute]

#version 450

#VERSION_DEFINES

// The passes that turn the gather's output into the buffer the forward shader
// samples: a separable edge-aware blur run twice, then a weighted upsample.
//
// The width follows the noise rather than being fixed. The gather's variance
// rises with how far the march reaches and falls with how many slices it splits
// the hemisphere into, so at a large effect radius it is several times what a
// 3x3 can absorb, while at a small radius there is little noise to remove and
// extra width only destroys contact detail. The radius is therefore derived on
// the CPU from the effect radius and the slice count.
//
// The weight knows the surface, not just its distance. Rejecting a neighbor on
// relative depth difference has no notion of orientation, so on a plane seen at
// a glancing angle it throws away neighbors lying on that very plane, and it
// keeps neighbors across a shallow step that is a real silhouette. Weighting on
// a neighbor's distance from the shaded point's own plane -- its depth AND its
// normal -- fixes both.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 dest_size;

	// Full internal resolution, and full resolution pixels per gather texel.
	// The gather answers for pixel k * stride, so this is what maps a gather
	// texel back to the surface it actually describes.
	ivec2 full_size;
	ivec2 gather_stride;

	// Turns a screen UV into a view space ray, so a neighbor's stored depth can
	// be turned back into the point it came from and tested against a plane.
	vec2 uv_to_view_mul;
	vec2 uv_to_view_add;

	// How far off the shaded point's own plane a neighbor may sit, as a
	// fraction of that point's depth, before it counts as another surface.
	float plane_tolerance;
	int filter_radius;
	// Which axis this pass blurs along. The blur is separable, so it runs
	// twice: once across and once down.
	ivec2 direction;

	// Whether the gather shaded a checkerboard packed two full resolution pixels
	// to a texel along x, rather than a coarser grid. It changes what a gather
	// texel maps to, and it changes the reconstruction from a bilateral over a
	// 2x2 block to an exact copy for half the pixels and a four neighbor average
	// for the rest.
	bool checkerboard;
	uint pad0;
	uint pad1;
	uint pad2;
}
params;

layout(set = 0, binding = 0) uniform sampler2D source_ao;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
layout(rgba8, set = 0, binding = 2) uniform restrict readonly image2D source_normal;

#ifdef MODE_DENOISE
layout(rg16f, set = 0, binding = 3) uniform restrict writeonly image2D dest_ao;
#else
layout(r8, set = 0, binding = 3) uniform restrict writeonly image2D dest_final;
#endif

vec3 view_pos(ivec2 full_pos, float view_depth) {
	vec2 uv = (vec2(full_pos) + 0.5) / vec2(params.full_size);
	return vec3((params.uv_to_view_mul * uv + params.uv_to_view_add) * view_depth, view_depth);
}

// The same decode the gather uses, so both describe normals in the same space.
vec3 load_view_normal(ivec2 full_pos) {
	vec3 n = normalize(imageLoad(source_normal, full_pos).xyz * 2.0 - 1.0);
	n.z = -n.z;
	return n;
}

// What a neighbor is worth: one if it lies on the shaded point's plane, falling
// to zero as it leaves it. Scaled by depth so the tolerance means the same
// thing near and far.
float plane_weight(vec3 center_pos, vec3 center_normal, vec3 tap_pos) {
	float off = abs(dot(center_normal, tap_pos - center_pos));
	return max(1.0 - off / max(params.plane_tolerance * center_pos.z, 0.0001), 0.0);
}

// The full resolution pixel a gather texel answers for. On the checkerboard the
// parity alternates per row, so texel (u, y) holds pixel (2u + (y & 1), y).
ivec2 gather_to_full(ivec2 gather_pos) {
	ivec2 full_pos = params.checkerboard
			? ivec2(gather_pos.x * 2 + (gather_pos.y & 1), gather_pos.y)
			: gather_pos * params.gather_stride;
	return min(full_pos, params.full_size - ivec2(1));
}

// The inverse, valid only for a pixel the checkerboard actually shaded, which is
// every pixel whose coordinates sum to an even number.
ivec2 full_to_gather_checker(ivec2 full_pos) {
	return ivec2((full_pos.x - (full_pos.y & 1)) >> 1, full_pos.y);
}

bool is_shaded_checker(ivec2 full_pos) {
	return ((full_pos.x + full_pos.y) & 1) == 0;
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.dest_size))) {
		return;
	}

	ivec2 max_pos = params.source_size - ivec2(1);

#ifdef MODE_DENOISE

	vec2 center = texelFetch(source_ao, pos, 0).rg;
	ivec2 center_full = gather_to_full(pos);
	vec3 center_pos = view_pos(center_full, center.g);
	vec3 center_normal = load_view_normal(center_full);

	float sum = 0.0;
	float weight_sum = 0.0;

	for (int i = -params.filter_radius; i <= params.filter_radius; i++) {
		ivec2 tap = clamp(pos + params.direction * i, ivec2(0), max_pos);
		vec2 value = texelFetch(source_ao, tap, 0).rg;
		// A tent, so the far taps taper off instead of ending abruptly.
		float kernel = float(params.filter_radius + 1 - abs(i));
		float weight = kernel * plane_weight(center_pos, center_normal, view_pos(gather_to_full(tap), value.g));
		sum += value.r * weight;
		weight_sum += weight;
	}

	// The center tap always weighs itself fully, so this cannot divide by zero;
	// the guard is for a degenerate normal.
	imageStore(dest_ao, pos, vec4(weight_sum > 0.0 ? sum / weight_sum : center.r, center.g, 0.0, 0.0));

#else // MODE_UPSAMPLE

	// The reference surface is this pixel's own, at full resolution, rather than
	// the nearest gather texel's: at half resolution that would quantize every
	// silhouette to the coarse grid.
	float center_depth = texelFetch(source_depth, pos, 0).r;
	vec3 center_pos = view_pos(pos, center_depth);
	vec3 center_normal = load_view_normal(pos);

	// The checkerboard reconstructs rather than upsamples, and the two cases are
	// not a filter and a narrower filter -- they are an exact value and an
	// average of four exact values.
	//
	// Half the pixels were shaded, so they are copied through untouched: no
	// interpolation, no bilateral, nothing to soften a silhouette. Each of the
	// rest has all four of its immediate neighbors shaded, one pixel away rather
	// than two, and averaging exactly those four is complete -- widening it to
	// twelve neighbors was measured and changed nothing to five decimal places,
	// because there is no further information to gather. The plane weights still
	// run, so a neighbor across a silhouette is still rejected; where every
	// neighbor is rejected the nearest surviving value is taken whole rather
	// than blending surfaces this pixel is not on.
	if (params.checkerboard) {
		if (is_shaded_checker(pos)) {
			ivec2 tap = clamp(full_to_gather_checker(pos), ivec2(0), max_pos);
			imageStore(dest_final, pos, vec4(texelFetch(source_ao, tap, 0).r));
			return;
		}

		const ivec2 OFFSETS[4] = ivec2[](ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1));
		float sum = 0.0;
		float weight_sum = 0.0;
		float nearest = -1.0;

		for (int i = 0; i < 4; i++) {
			ivec2 neighbor = pos + OFFSETS[i];
			// A neighbor off the screen is skipped rather than clamped: clamping
			// would land on an unshaded pixel and duplicate whichever tap sits
			// opposite it. An edge pixel simply has two or three neighbors.
			if (any(lessThan(neighbor, ivec2(0))) || any(greaterThanEqual(neighbor, params.full_size))) {
				continue;
			}
			ivec2 tap = clamp(full_to_gather_checker(neighbor), ivec2(0), max_pos);
			vec2 value = texelFetch(source_ao, tap, 0).rg;
			if (nearest < 0.0) {
				nearest = value.r;
			}
			float weight = plane_weight(center_pos, center_normal, view_pos(neighbor, value.g));
			sum += value.r * weight;
			weight_sum += weight;
		}

		imageStore(dest_final, pos, vec4(weight_sum > 0.0001 ? sum / weight_sum : max(nearest, 0.0)));
		return;
	}

	// Gather texel k answers for full resolution PIXEL k * stride, whose center
	// sits at continuous coordinate k * stride + 0.5. Inverting that gives
	// pos / stride. The obvious form, (pos + 0.5) * source_size / dest_size - 0.5,
	// assumes instead that texel k represents the CENTER of its block, and is
	// wrong by half a full resolution pixel on each axis.
	vec2 source_pos = vec2(pos) / vec2(params.gather_stride);
	ivec2 base = ivec2(floor(source_pos));
	vec2 frac_pos = source_pos - vec2(base);

	float sum = 0.0;
	float weight_sum = 0.0;

	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			ivec2 tap = clamp(base + ivec2(x, y), ivec2(0), max_pos);
			vec2 value = texelFetch(source_ao, tap, 0).rg;
			float bilinear = (x == 0 ? 1.0 - frac_pos.x : frac_pos.x) * (y == 0 ? 1.0 - frac_pos.y : frac_pos.y);
			float weight = bilinear * plane_weight(center_pos, center_normal, view_pos(gather_to_full(tap), value.g));
			sum += value.r * weight;
			weight_sum += weight;
		}
	}

	// Every candidate is on a different surface. Take the nearest one whole
	// rather than a blend of surfaces this pixel is not on -- a floor mixed into
	// the weights instead would drag a silhouette's own value toward whatever
	// lies across it, which is exactly where it shows.
	if (weight_sum <= 0.0001) {
		ivec2 tap = clamp(base + ivec2(frac_pos.x >= 0.5 ? 1 : 0, frac_pos.y >= 0.5 ? 1 : 0), ivec2(0), max_pos);
		imageStore(dest_final, pos, vec4(texelFetch(source_ao, tap, 0).r));
		return;
	}

	imageStore(dest_final, pos, vec4(sum / weight_sum));

#endif
}
