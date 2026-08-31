#[compute]

#version 450

#VERSION_DEFINES

// Linear view depth pyramid for the GTAO gather.
//
// This is deliberately NOT the pyramid the screen space effects already build.
// That one is deinterleaved into four array slices, so a shader reading it can
// only address its own slice -- fine for a disk of scattered point samples, but
// a horizon march walks a straight line and needs to read whatever texel that
// line lands on. It is also based at half resolution, so the innermost steps of
// a march would have no full resolution depth to read at all, and it is filtered
// toward the CLOSEST of each group of four.
//
// The bias is the important difference. A coarse texel that reports the nearest
// of its four depths dilates thin geometry across its whole footprint, and a
// march that reads one such texel early keeps that horizon for every step after
// it -- one fattened sample darkens the rest of the ray. Biasing toward the
// farthest instead lets thin geometry fall out of the coarse levels rather than
// spread across them, which is both the more forgiving error and the steadier
// one under camera motion. The technique is Intel's, from XeGTAO.

#define TILE 16
#define MIP_COUNT 5

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(push_constant, std430) uniform Params {
	ivec2 screen_size;

	// The two terms of the depth linearization, folded on the CPU exactly the
	// way the other screen space effects fold them, so both pyramids describe
	// the same depths. Under an orthogonal projection they are the raw near and
	// far planes instead.
	float linearize_mul;
	float linearize_add;

	// Weighting for the coarse levels, derived from the effect radius on the
	// CPU. A sample far behind the farthest of its four contributes nothing.
	float falloff_mul;
	float falloff_add;

	bool orthogonal;
	uint pad;
}
params;

layout(set = 0, binding = 0) uniform sampler2D source_depth;

layout(r16f, set = 1, binding = 0) uniform restrict writeonly image2D dest_mip0;
layout(r16f, set = 1, binding = 1) uniform restrict writeonly image2D dest_mip1;
layout(r16f, set = 1, binding = 2) uniform restrict writeonly image2D dest_mip2;
layout(r16f, set = 1, binding = 3) uniform restrict writeonly image2D dest_mip3;
layout(r16f, set = 1, binding = 4) uniform restrict writeonly image2D dest_mip4;

shared float tile_depth[TILE][TILE];

float linear_view_depth(float depth) {
	if (params.orthogonal) {
		float ndc = depth * 2.0 - 1.0;
		return -(ndc * (params.linearize_add - params.linearize_mul) - (params.linearize_add + params.linearize_mul)) * 0.5;
	}
	return params.linearize_mul / (params.linearize_add - depth);
}

// Weighted mean of four depths, biased toward the farthest of them.
float filter_quad(float d0, float d1, float d2, float d3) {
	float furthest = max(max(d0, d1), max(d2, d3));
	vec4 depths = vec4(d0, d1, d2, d3);
	vec4 weights = clamp((vec4(furthest) - depths) * params.falloff_mul + params.falloff_add, vec4(0.0), vec4(1.0));
	float total = dot(weights, vec4(1.0));
	// Every sample rejected means the quad straddles more than the effect can
	// see across; the farthest is then the honest answer rather than a mean of
	// surfaces that are not neighbors.
	return total > 0.0001 ? dot(weights, depths) / total : furthest;
}

void store_mip(int level, ivec2 coord, float value) {
	switch (level) {
		case 1:
			imageStore(dest_mip1, coord, vec4(value));
			break;
		case 2:
			imageStore(dest_mip2, coord, vec4(value));
			break;
		case 3:
			imageStore(dest_mip3, coord, vec4(value));
			break;
		default:
			imageStore(dest_mip4, coord, vec4(value));
			break;
	}
}

void main() {
	ivec2 tile_origin = ivec2(gl_WorkGroupID.xy) * TILE;
	ivec2 local = ivec2(gl_LocalInvocationID.xy);
	ivec2 max_coord = params.screen_size - ivec2(1);

	// One thread per 2x2 of full resolution pixels, so an 8x8 group covers a
	// 16x16 tile and the whole pyramid below it reduces in shared memory.
	ivec2 base = tile_origin + local * 2;

	for (int dy = 0; dy < 2; dy++) {
		for (int dx = 0; dx < 2; dx++) {
			ivec2 coord = base + ivec2(dx, dy);
			// Clamped so a tile hanging off the edge of the screen reduces
			// against real depths rather than whatever the sampler invents.
			ivec2 read = clamp(coord, ivec2(0), max_coord);
			float depth = linear_view_depth(texelFetch(source_depth, read, 0).r);

			tile_depth[local.y * 2 + dy][local.x * 2 + dx] = depth;

			if (all(lessThanEqual(coord, max_coord))) {
				imageStore(dest_mip0, coord, vec4(depth));
			}
		}
	}

	// Each level halves the live square of threads: 8x8 writes mip 1, then 4x4,
	// 2x2, and finally one thread writes mip 4. Both barriers sit outside the
	// conditional, because a barrier reached by only some invocations of a
	// group is undefined.
	int extent = TILE / 2;
	for (int level = 1; level < MIP_COUNT; level++) {
		barrier();

		bool thread_live = local.x < extent && local.y < extent;
		float value = 0.0;

		if (thread_live) {
			ivec2 src = local * 2;
			value = filter_quad(
					tile_depth[src.y][src.x],
					tile_depth[src.y][src.x + 1],
					tile_depth[src.y + 1][src.x],
					tile_depth[src.y + 1][src.x + 1]);

			ivec2 coord = (tile_origin >> level) + local;
			ivec2 level_max = max((max_coord >> level), ivec2(0));
			if (all(lessThanEqual(coord, level_max))) {
				store_mip(level, coord, value);
			}
		}

		// The next level reduces what this one produced, so every thread must
		// be done reading its four inputs before any of them is overwritten.
		barrier();

		if (thread_live) {
			tile_depth[local.y][local.x] = value;
		}

		extent >>= 1;
	}
}
