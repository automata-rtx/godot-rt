#[compute]

#version 450

#VERSION_DEFINES

// The two passes that turn the gather's output into the buffer the forward
// shader samples.
//
// DENOISE runs at the gather's own resolution and averages a 3x3 neighborhood,
// rejecting neighbors that sit on a different surface. UPSAMPLE writes the
// result into the full resolution occlusion buffer, weighting the four nearest
// gather texels by how well each one's depth matches the full resolution pixel
// it is being asked to describe.
//
// The guide depth is carried in the gather's own second channel rather than
// re-read from the depth pyramid, so a texel always answers for the exact
// surface it was computed on. That is what stops a half resolution result from
// bleeding across a silhouette when it is stretched back to full resolution.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	ivec2 source_size;
	ivec2 dest_size;

	// How far apart two view depths may be, relative to the nearer of them,
	// before they are taken to be different surfaces.
	float depth_tolerance;
	// Keeps a pixel that matches nothing from dividing by almost zero; it
	// relaxes toward the unfiltered value instead.
	float weight_floor;
	uint pad0;
	uint pad1;
}
params;

layout(set = 0, binding = 0) uniform sampler2D source_ao;

#ifdef MODE_DENOISE
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image2D dest_ao;
#else
layout(r8, set = 0, binding = 1) uniform restrict writeonly image2D dest_final;
#endif

float surface_weight(float center_depth, float tap_depth) {
	float error = abs(tap_depth - center_depth) / max(min(abs(center_depth), abs(tap_depth)), 0.0001);
	return max(1.0 - error / max(params.depth_tolerance, 0.0001), 0.0);
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.dest_size))) {
		return;
	}

#ifdef MODE_DENOISE

	vec2 center = texelFetch(source_ao, pos, 0).rg;
	ivec2 max_pos = params.source_size - ivec2(1);

	float sum = center.r;
	float weight_sum = 1.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			if (x == 0 && y == 0) {
				continue;
			}
			ivec2 tap = clamp(pos + ivec2(x, y), ivec2(0), max_pos);
			vec2 value = texelFetch(source_ao, tap, 0).rg;
			// Diagonals are further away and count for less, which keeps the
			// filter close to isotropic on a square grid.
			float kernel = (x == 0 || y == 0) ? 1.0 : 0.5;
			float weight = kernel * surface_weight(center.g, value.g);
			sum += value.r * weight;
			weight_sum += weight;
		}
	}

	imageStore(dest_ao, pos, vec4(sum / weight_sum, center.g, 0.0, 0.0));

#else // MODE_UPSAMPLE

	// Where this full resolution pixel lands in the gather, in texel space.
	vec2 scale = vec2(params.source_size) / vec2(params.dest_size);
	vec2 source_pos = (vec2(pos) + 0.5) * scale - 0.5;
	ivec2 base = ivec2(floor(source_pos));
	vec2 frac_pos = source_pos - vec2(base);
	ivec2 max_pos = params.source_size - ivec2(1);

	// The depth this pixel actually has, taken from the gather texel it sits
	// nearest. At matching resolutions that is the pixel's own depth and every
	// weight below collapses to the bilinear one.
	float center_depth = texelFetch(source_ao, clamp(base + ivec2(frac_pos.x > 0.5 ? 1 : 0, frac_pos.y > 0.5 ? 1 : 0), ivec2(0), max_pos), 0).g;

	float sum = 0.0;
	float weight_sum = 0.0;

	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			ivec2 tap = clamp(base + ivec2(x, y), ivec2(0), max_pos);
			vec2 value = texelFetch(source_ao, tap, 0).rg;
			float bilinear = (x == 0 ? 1.0 - frac_pos.x : frac_pos.x) * (y == 0 ? 1.0 - frac_pos.y : frac_pos.y);
			float weight = bilinear * surface_weight(center_depth, value.g) + params.weight_floor;
			sum += value.r * weight;
			weight_sum += weight;
		}
	}

	imageStore(dest_final, pos, vec4(sum / max(weight_sum, 0.0001)));

#endif
}
