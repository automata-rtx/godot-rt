/**********************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

// Vulkan/Godot adaptation of GI-1.x's two-level diffuse radiance caching.
// Reference: Capsaicin 914b91596cd119eda85fbc1d3c7ee6ac391b1452.
// See docs/features/amd-gi.md for the implemented subset and port differences.
#[compute]
#version 460
#VERSION_DEFINES
#extension GL_EXT_ray_query : require
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(constant_id = 0) const int pass_id = 0;
// Keep in the same order as AMDGI::Pass.
const int PASS_RESET = 0;
const int PASS_REPROJECT = 1;
const int PASS_BIN_CACHED = 2;
const int PASS_SELECT = 3;
const int PASS_PATCH = 4;
const int PASS_PREPARE = 5;
const int PASS_TRACE = 6;
const int PASS_ALLOCATE = 7;
const int PASS_REGISTER = 8;
const int PASS_POPULATE = 9;
const int PASS_ALLOCATE_SECONDARY = 10;
const int PASS_REGISTER_SECONDARY = 11;
const int PASS_UPDATE = 12;
const int PASS_MIP1 = 13;
const int PASS_MIP2 = 14;
const int PASS_MIP3 = 15;
const int PASS_UPDATE_INDIRECT = 16;
const int PASS_INDIRECT_MIP1 = 17;
const int PASS_INDIRECT_MIP2 = 18;
const int PASS_INDIRECT_MIP3 = 19;
const int PASS_RESOLVE = 20;
const int PASS_FILTER_X = 21;
const int PASS_FILTER_Y = 22;
const int PASS_PROJECT = 23;
const int PASS_ORDER_CACHED = 24;
const int PASS_STORE_CACHED = 25;
const int PASS_MASK = 26;
const int PASS_INTERPOLATE = 27;
const int PASS_TEMPORAL = 28;
const int PASS_BLUR_X = 29;
const int PASS_BLUR_Y = 30;
const int PASS_REFLECTION_TRACE = 31;
const int PASS_REFLECTION_RESOLVE = 32;
const int PASS_REFLECTION_TEMPORAL = 33;
const int PASS_REFLECTION_FILTER = 34;
const int PASS_REFLECTION_UPSAMPLE = 35;
#include "../oct_inc.glsl"
#include "rt_gi_transport_inc.glsl"
layout(set = 0, binding = 37) uniform sampler2D sky_radiance;

layout(set = 0, binding = 31, std430) restrict readonly buffer BlueNoise {
	uint data[];
}
blue_noise;

// One light proposal per base world-cache cell, double-buffered independently
// of radiance. Packed light index, octahedral normal, RIS weight W, confidence M.
layout(set = 0, binding = 32, std430) restrict buffer PreviousLightReservoirs {
	uvec4 data[];
}
previous_light_reservoirs;
layout(set = 0, binding = 33, std430) restrict buffer LightReservoirs {
	uvec4 data[];
}
light_reservoirs;

vec2 lookup_jitter(ivec2 pixel) {
	uint index = uint((pixel.x & 127) + (pixel.y & 127) * 128);
	uint packed = blue_noise.data[index >> 1u] >> ((index & 1u) * 16u);
	vec2 sample_value = (vec2(packed & 255u, (packed >> 8u) & 255u) + 0.5) / 256.0;
	return fract(sample_value + float(params.padding & 255u) * 1.6180339887498948482);
}

layout(set = 0, binding = 10, std140) uniform Frame {
	mat4 previous_view_projection;
	mat4 view_projection;
	uvec4 grid;
	vec4 settings;
	uvec4 flags;
	uvec4 tracing;
	mat3 world_to_sky;
	vec4 sky;
	vec4 ambient;
	vec4 reflections;
	uvec4 motion;
	vec4 motion_bounds[16];
}
frame;
struct Probe {
	vec4 position;
	vec4 normal;
	vec4 sh[9];
	uvec4 state; // seed pixel, last traced frame, previous probe / scheduled update slot
};
struct RayHit {
	vec4 position;
	vec4 direction_cache;
	vec4 normal_mask;
	vec4 diffuse;
	vec4 emission;
};
struct Tile {
	ivec4 key;
	uvec4 state;
};
struct Pixel {
	vec4 position;
	vec4 normal_delta;
	vec4 color;
};
layout(set = 0, binding = 11, std430) restrict buffer Probes {
	Probe data[];
}
probes;
layout(set = 0, binding = 12, std430) restrict readonly buffer PreviousProbes {
	Probe data[];
}
previous_probes;
layout(set = 0, binding = 13, std430) restrict buffer Rays {
	RayHit data[];
}
rays;
layout(set = 0, binding = 36, std430) restrict buffer SecondaryRays {
	RayHit data[];
}
secondary_rays;
layout(set = 0, binding = 14, std430) restrict buffer Radiance {
	vec4 data[];
}
radiance;
layout(set = 0, binding = 15, std430) restrict readonly buffer PreviousRadiance {
	vec4 data[];
}
previous_radiance;
layout(set = 0, binding = 16, std430) coherent restrict buffer Keys {
	Tile data[];
}
keys;
layout(set = 0, binding = 17, std430) restrict buffer PreviousCache {
	vec4 data[];
}
previous_cache;
layout(set = 0, binding = 18, std430) restrict buffer Cache {
	vec4 data[];
}
cache;
layout(set = 0, binding = 34, std430) restrict buffer PreviousIndirectCache {
	vec4 data[];
}
previous_indirect_cache;
layout(set = 0, binding = 35, std430) restrict buffer IndirectCache {
	vec4 data[];
}
indirect_cache;
layout(set = 0, binding = 19, std430) restrict buffer Owners {
	uint data[];
}
owners;
layout(set = 0, binding = 20, std430) restrict buffer Scratch {
	vec4 data[];
}
scratch;
layout(set = 0, binding = 21, std430) restrict readonly buffer PreviousPixels {
	Pixel data[];
}
previous_pixels;
layout(set = 0, binding = 22, std430) restrict buffer Pixels {
	Pixel data[];
}
pixels;
layout(rgba16f, set = 0, binding = 23) uniform restrict image2D filter_image;
layout(set = 0, binding = 24, std430) restrict buffer Spawn {
	uvec4 data[]; // dense probe index, seed pixel XY, unused
}
spawn;
layout(set = 0, binding = 25, std430) restrict buffer Queues {
	uvec4 counts; // holes, reusable update slots, unused, unused
	uint data[]; // dense-probe-capacity holes, then update-capacity overrides
}
queues;
layout(set = 0, binding = 26, std430) restrict buffer ProbeMask {
	uint data[];
}
probe_mask;
struct CachedProbe {
	Probe probe;
	vec4 radiance[64];
};
layout(set = 0, binding = 27, std430) restrict buffer CachedProbes {
	CachedProbe data[];
}
cached_probes;
layout(set = 0, binding = 28, std430) restrict buffer CachedState {
	uvec4 data[]; // unused, touched this frame, update owner, bin linked-list next
}
cached_state;
layout(set = 0, binding = 29, std430) restrict buffer PreviousCachedOrder {
	uint data[];
}
previous_cached_order;
layout(set = 0, binding = 30, std430) restrict writeonly buffer CachedOrder {
	uint data[];
}
cached_order;
const uint CACHED_PROBES = 4096u;
const uint INVALID = 0xffffffffu;
const uint TILE_COUNT = 4096u;
const uint TILE_CELLS = 85u;
const uint MIP_OFFSET[4] = uint[](0u, 64u, 80u, 84u);

uint pcg(uint v) {
	return random_bits(v);
}
vec3 clean_color(vec3 v) {
	return any(isnan(v)) || any(isinf(v)) ? vec3(0) : clamp(v, vec3(0), vec3(60000));
}
float luma(vec3 v) {
	return dot(v, vec3(0.2126, 0.7152, 0.0722));
}
mat3 basis(vec3 n) {
	vec3 t = normalize(cross(abs(n.z) < 0.99 ? vec3(0, 0, 1) : vec3(0, 1, 0), n));
	return mat3(t, cross(n, t), n);
}
// Capsaicin's equal-area hemi-octahedral mapping (sampling.hlsl).
vec3 hemi_direction(vec2 uv) {
	vec2 st = 2.0 * uv - 1.0;
	st = vec2(st.x + st.y, st.x - st.y) * 0.5;
	vec2 a = abs(st);
	float d = 1.0 - a.x - a.y;
	float r = 1.0 - abs(d);
	float phi = r == 0.0 ? 0.0 : (PI * 0.25) * ((a.y - a.x) / r + 1.0);
	float s = r * sqrt(2.0 - r * r);
	return vec3(s * sign(st.x) * cos(phi), s * sign(st.y) * sin(phi), sign(d) * (1.0 - r * r));
}
vec2 hemi_uv(vec3 d) {
	vec3 a = abs(d);
	float r = sqrt(max(0.0, 1.0 - a.z));
	float ratio = max(a.x, a.y) == 0.0 ? 0.0 : min(a.x, a.y) / max(a.x, a.y);
	float phi = atan(ratio) * (2.0 / PI);
	phi = a.x >= a.y ? phi : 1.0 - phi;
	vec2 st = vec2(r - phi * r, phi * r) * sign(d.xy);
	return vec2(st.x + st.y, st.x - st.y) * 0.5 + 0.5;
}
void sh_coefficients(vec3 n, out float sh[9]) {
	sh[0] = 0.2820947917738781;
	sh[1] = -0.4886025119029199 * n.y;
	sh[2] = 0.4886025119029199 * n.z;
	sh[3] = -0.4886025119029199 * n.x;
	sh[4] = 1.092548430592079 * n.x * n.y;
	sh[5] = -1.092548430592079 * n.y * n.z;
	sh[6] = 0.3153915652525201 * (3.0 * n.z * n.z - 1.0);
	sh[7] = -1.092548430592079 * n.x * n.z;
	sh[8] = 0.5462742152960395 * (n.x * n.x - n.y * n.y);
}
bool surface(ivec2 pixel, out vec3 position, out vec3 normal) {
	position = vec3(0);
	normal = vec3(0);
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, ivec2(params.size)))) {
		return false;
	}
	float d = texelFetch(depth_buffer, pixel, 0).r;
	vec3 n = texelFetch(normal_buffer, pixel, 0).xyz * 2.0 - 1.0;
	if (d <= 0.0 || dot(n, n) < 0.01) {
		return false;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.size);
	vec4 p = params.inv_view_projection * vec4(uv * 2.0 - 1.0, d, 1);
	position = p.xyz / p.w;
	n = normalize(n);
	normal = normalize(n + 2.0 * cross(params.camera_rotation.xyz, cross(params.camera_rotation.xyz, n) + params.camera_rotation.w * n));
	return true;
}
float footprint(vec3 p) {
	return max(0.002, distance(p, params.camera_position.xyz) * tan(frame.settings.y * 8.0));
}
uint probe_index(ivec2 p) {
	if (any(lessThan(p, ivec2(0))) || any(greaterThanEqual(p, ivec2(frame.grid.xy)))) {
		return INVALID;
	}
	return uint(p.x) + uint(p.y) * frame.grid.x;
}
uint angular_index(vec3 direction, vec3 normal) {
	ivec2 p = clamp(ivec2(hemi_uv(transpose(basis(normal)) * direction) * 8.0), ivec2(0), ivec2(7));
	return uint(p.x + p.y * 8);
}

// GI-1's distance-quantized world tiles and direction-dependent 2D cell layout.
// Full keys are retained, so hash collisions cannot alias unrelated tiles.
float cache_cell_size(vec3 position) {
	float desired = max(distance(params.camera_position.xyz, position) * tan(frame.settings.y * 32.0), frame.settings.x);
	return 0.001 * exp2(floor(log2(1000.0 * desired)));
}
ivec4 cache_key(vec3 position, vec3 direction, float hit_distance, out uvec2 cell) {
	float cell_size = cache_cell_size(position);
	int level = int(round(log2(1000.0 * cell_size)));
	float tile_size = cell_size * 8.0;
	ivec3 tile = ivec3(floor(position / tile_size));
	uvec3 d = uvec3(floor(0.5 + (direction * 0.5 + 0.5) * 4.0));
	uint packed = uint(level) & 255u;
	packed |= d.x << 8u;
	packed |= d.y << 11u;
	packed |= d.z << 14u;
	packed |= uint(hit_distance < tile_size) << 17u;
	uvec3 e = uvec3(clamp(floor(position / cell_size) - vec3(tile) * 8.0, vec3(0), vec3(7)));
	vec3 a = abs(direction);
	cell = a.x >= max(a.y, a.z) ? e.yz : (a.y >= a.z ? e.xz : e.xy);
	return ivec4(tile, int(packed));
}
uint key_hash(ivec4 key) {
	return max(2u, pcg(uint(key.x) + pcg(uint(key.y) + pcg(uint(key.z) + pcg(uint(key.w))))));
}
uint find_tile(ivec4 key) {
	uint hash = key_hash(key), bucket = (hash % 1024u) * 4u;
	for (uint i = 0u; i < 4u; i++) {
		uint t = bucket + i;
		if (keys.data[t].state.x == hash && all(equal(keys.data[t].key, key))) {
			return t;
		}
	}
	return INVALID;
}
uint find_cell(vec3 position, vec3 direction, float distance) {
	uvec2 cell;
	ivec4 key = cache_key(position, direction, distance, cell);
	uint tile = find_tile(key);
	return tile == INVALID ? INVALID : tile * TILE_CELLS + cell.x + 8u * cell.y;
}
vec4 read_component(uint cell, bool previous, bool indirect) {
	if (cell == INVALID) {
		return vec4(0);
	}
	uint tile = cell / TILE_CELLS;
	uint local = cell % TILE_CELLS;
	uvec2 coord = uvec2(local % 8u, local / 8u);
	for (uint mip = 0u; mip < 4u; mip++) {
		uvec2 p = coord >> mip;
		uint index = tile * TILE_CELLS + MIP_OFFSET[mip] + p.x + p.y * (8u >> mip);
		vec4 value = indirect ? (previous ? previous_indirect_cache.data[index] : indirect_cache.data[index]) : (previous ? previous_cache.data[index] : cache.data[index]);
		// GI-1 chooses the finest mip with enough accumulated samples.
		// A merely nonempty fine cell still contains a noisy single estimate.
		if (value.w >= 16.0 || mip == 3u) {
			return value;
		}
	}
	return vec4(0);
}
vec4 read_cache(uint cell, bool previous) {
	vec4 direct = read_component(cell, previous, false);
	if (params.bounces != 0u) {
		direct.rgb += read_component(cell, previous, true).rgb;
	}
	return direct;
}
vec3 environment_radiance(vec3 direction, bool reflection) {
	float energy = reflection ? frame.sky.y : frame.sky.x;
	if (energy <= 0.0 || dot(direction, direction) < 0.5) {
		return vec3(0);
	}
	vec2 uv = vec3_to_oct_with_border(frame.world_to_sky * direction, vec2(frame.sky.z, 1.0 - 2.0 * frame.sky.z));
	return textureLod(sky_radiance, uv, 0.0).rgb * energy;
}
uint primary_ray_count() {
	return frame.tracing.x * frame.tracing.y * 64u;
}
RayHit empty_ray() {
	RayHit ray;
	ray.position = vec4(0, 0, 0, -1);
	ray.direction_cache = vec4(0, 0, 0, uintBitsToFloat(INVALID));
	ray.normal_mask = vec4(0);
	ray.diffuse = vec4(0);
	ray.emission = vec4(0);
	return ray;
}
RayHit trace_hit(vec3 origin, vec3 direction) {
	RayHit ray = empty_ray();
	ray.direction_cache.xyz = direction;
	uint instance;
	vec3 position, uv, normal;
	if (trace(origin, direction, params.max_distance, 0u, instance, position, uv, normal)) {
		ray.position = vec4(position, length(position - origin));
		ray.normal_mask = vec4(faceforward(normal, direction, normal), uintBitsToFloat(hits.data[instance].z));
		ray.diffuse = vec4(textureLod(albedo_atlas, uv, 0).rgb * (1.0 - textureLod(orm_atlas, uv, 0).b), 0);
		ray.emission = textureLod(emission_atlas, uv, 0);
	}
	return ray;
}

uint cached_heads_offset() {
	return frame.grid.x * frame.grid.y + frame.tracing.x * frame.tracing.y;
}
uint eviction_owners_offset() {
	return cached_heads_offset() + frame.grid.x * frame.grid.y;
}
uint eviction_queue_offset() {
	return eviction_owners_offset() + frame.grid.x * frame.grid.y;
}
// Invalidate history only where moving geometry can have changed a cached
// connection. This uses the same swept world bounds for surface, ray and tile
// tests; the zero-mover path exits without any loop iterations.
bool motion_overlaps(vec3 lo, vec3 hi) {
	for (uint i = 0u; i < frame.motion.x; i++) {
		if (all(lessThanEqual(lo, frame.motion_bounds[i * 2u + 1u].xyz)) && all(greaterThanEqual(hi, frame.motion_bounds[i * 2u].xyz))) {
			return true;
		}
	}
	return false;
}
bool motion_intersects(vec3 origin, vec3 direction, float distance) {
	for (uint i = 0u; i < frame.motion.x; i++) {
		vec3 lo = frame.motion_bounds[i * 2u].xyz;
		vec3 hi = frame.motion_bounds[i * 2u + 1u].xyz;
		float near_t = 0.0, far_t = max(distance, 0.0);
		for (int axis = 0; axis < 3; axis++) {
			if (abs(direction[axis]) < 1e-7) {
				if (origin[axis] < lo[axis] || origin[axis] > hi[axis]) {
					far_t = -1.0;
				}
			} else {
				float a = (lo[axis] - origin[axis]) / direction[axis];
				float b = (hi[axis] - origin[axis]) / direction[axis];
				near_t = max(near_t, min(a, b));
				far_t = min(far_t, max(a, b));
			}
		}
		if (near_t <= far_t) {
			return true;
		}
	}
	return false;
}
bool probe_motion(Probe p, uint source, bool cached) {
	if (frame.motion.x == 0u || p.position.w == 0.0) {
		return false;
	}
	mat3 tbn = basis(p.normal.xyz);
	for (uint cell = 0u; cell < 64u; cell++) {
		float distance = cached ? cached_probes.data[source].radiance[cell].w : previous_radiance.data[source * 64u + cell].w;
		vec3 direction = tbn * hemi_direction((vec2(cell % 8u, cell / 8u) + 0.5) / 8.0);
		if (distance > 0.0 && motion_intersects(p.position.xyz, direction, distance)) {
			return true;
		}
	}
	return false;
}
shared bool reset_tile;
void reset_cache(uint lane) {
	uint tile = gl_WorkGroupID.x;
	if (tile == 0u && lane == 0u) {
		queues.counts = uvec4(0);
	}
	if (lane == 0u) {
		reset_tile = frame.grid.w != 0u || (keys.data[tile].state.x != 0u && params.padding - keys.data[tile].state.y > 50u);
		if (!reset_tile && frame.motion.x > 0u && keys.data[tile].state.x != 0u) {
			float extent = 0.008 * exp2(float(keys.data[tile].key.w & 255));
			vec3 lo = vec3(keys.data[tile].key.xyz) * extent;
			reset_tile = motion_overlaps(lo, lo + extent);
		}
	}
	barrier();
	if (lane == 0u && reset_tile) {
		keys.data[tile].state = uvec4(0);
	}
	for (uint local = lane; local < TILE_CELLS; local += 64u) {
		uint index = tile * TILE_CELLS + local;
		owners.data[index] = INVALID;
		if (reset_tile) {
			previous_cache.data[index] = vec4(0);
		}
		cache.data[index] = reset_tile ? vec4(0) : previous_cache.data[index];
		if (params.bounces != 0u) {
			if (reset_tile) {
				previous_indirect_cache.data[index] = vec4(0);
			}
			indirect_cache.data[index] = previous_indirect_cache.data[index];
		}
		if (frame.tracing.w != 0u && local < 64u) {
			uint reservoir = tile * 64u + local;
			if (reset_tile) {
				previous_light_reservoirs.data[reservoir] = uvec4(INVALID, 0, 0, 0);
			}
			light_reservoirs.data[reservoir] = previous_light_reservoirs.data[reservoir];
		}
	}
	uint cached = tile * 64u + lane;
	if (frame.flags.w != 0u && cached < CACHED_PROBES) {
		cached_state.data[cached] = uvec4(0, 0, INVALID, INVALID);
		if (frame.grid.w != 0u) {
			previous_cached_order.data[cached] = cached;
			cached_probes.data[cached].probe.position.w = 0.0;
		} else if (cached_probes.data[cached].probe.position.w > 0.0 && (params.padding - cached_probes.data[cached].probe.state.z > 50u || probe_motion(cached_probes.data[cached].probe, cached, true))) {
			cached_probes.data[cached].probe.position.w = 0.0;
		}
	}
}
uint previous_probe(vec3 p, vec3 normal) {
	if (frame.grid.w != 0u) {
		return INVALID;
	}
	vec4 clip = frame.previous_view_projection * vec4(p, 1);
	if (clip.w <= 0.0) {
		return INVALID;
	}
	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	if (any(lessThan(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
		return INVALID;
	}
	ivec2 center = ivec2(uv * vec2(params.size) / 8.0);
	uint other = probe_index(center);
	if (other == INVALID) {
		return INVALID;
	}
	Probe old = previous_probes.data[other];
	vec3 delta = old.position.xyz - p;
	if (old.position.w == 0.0 || motion_overlaps(p, p) || params.padding - old.state.z > 50u || dot(old.normal.xyz, normal) < 0.95 || abs(dot(delta, normal)) >= footprint(p) * 0.1 || length(delta) >= footprint(p) * 1.5) {
		return INVALID;
	}
	return other;
}
shared vec4 spawn_position;
shared vec4 spawn_normal;
shared uint reused_probe;
// Rebin nine neighboring probes and one evicted-cache probe into 64 angular cells. Integer linked lists allow
// full floating-point HDR accumulation without optional float atomics or
// overflowing fixed-point sums. Each lane owns one sample per neighbor.
shared uint bin_head[64];
shared uint bin_next[640];
shared vec4 bin_value[640];
shared uint cached_match;
shared float sampling_cdf[64];
shared float sampling_total;
shared vec4 radiance_backup;

void clear_bins(uint lane) {
	bin_head[lane] = INVALID;
	barrier();
}
void insert_bin(uint cell, uint lane, vec4 value) {
	bin_value[lane] = value;
	bin_next[lane] = atomicExchange(bin_head[cell], lane);
}
vec4 sum_bin(uint cell, out uint count) {
	vec4 value = vec4(0);
	count = 0u;
	for (uint sample_id = bin_head[cell]; sample_id != INVALID; sample_id = bin_next[sample_id]) {
		value += bin_value[sample_id];
		count++;
	}
	return value;
}
// Exclusive scan from GI-1's ScreenProbes_ScanRadiance. No subgroup-size
// assumptions: all 64 lanes participate, including invalid/sky probes.
void scan_radiance(uint lane, float weight) {
	sampling_cdf[lane] = weight;
	barrier();
	for (uint stride = 1u; stride < 64u; stride <<= 1u) {
		if (lane < 64u / (2u * stride)) {
			sampling_cdf[2u * (lane + 1u) * stride - 1u] += sampling_cdf[(2u * lane + 1u) * stride - 1u];
		}
		barrier();
	}
	if (lane == 0u) {
		sampling_total = sampling_cdf[63];
		sampling_cdf[63] = 0.0;
	}
	barrier();
	for (uint stride = 32u; stride > 0u; stride >>= 1u) {
		if (lane < 64u / (2u * stride)) {
			uint a = (2u * lane + 1u) * stride - 1u;
			uint b = 2u * (lane + 1u) * stride - 1u;
			float value = sampling_cdf[a];
			sampling_cdf[a] = sampling_cdf[b];
			sampling_cdf[b] += value;
		}
		barrier();
	}
}
uint sample_cell(float sample_value) {
	float target = sample_value * sampling_total;
	uint first = 0u, count = 64u;
	while (count > 0u) {
		uint half_count = count / 2u;
		uint mid = first + half_count;
		if (sampling_cdf[mid] > target) {
			count = half_count;
		} else {
			first = mid + 1u;
			count -= half_count + 1u;
		}
	}
	return max(first, 1u) - 1u;
}

// AMD keeps an 8-pixel stored grid independently of the sparse update budget.
shared uint candidate_score;
shared uint candidate_lane;
shared uint previous_index[64];
shared vec4 candidate_position[64];
shared vec4 candidate_normal[64];

void reproject_probe(uint probe, uint lane) {
	uvec2 tile = uvec2(probe % frame.grid.x, probe / frame.grid.x);
	uvec2 pixel = tile * 8u + uvec2(lane % 8u, lane / 8u);
	vec3 position, normal;
	bool valid = surface(ivec2(pixel), position, normal);
	uint previous = valid ? previous_probe(position, normal) : INVALID;
	candidate_position[lane] = vec4(position, valid ? 1.0 : 0.0);
	candidate_normal[lane] = vec4(normal, 0);
	previous_index[lane] = previous;
	if (lane == 0u) {
		candidate_score = INVALID;
		candidate_lane = INVALID;
	}
	barrier();
	if (valid) {
		// Reusable samples rank before disoccluded samples. The exact old
		// seed wins on a static surface, avoiding unnecessary probe movement.
		uint score = previous == INVALID ? (0x80000000u | (pcg(lane + probe * 64u + params.padding) & 0x7fffff80u) | lane) : ((floatBitsToUint(distance(position, previous_probes.data[previous].position.xyz) / footprint(position)) & 0x7fffffc0u) | lane);
		atomicMin(candidate_score, score);
	}
	barrier();
	if (lane == 0u) {
		candidate_lane = candidate_score == INVALID ? INVALID : candidate_score & 63u;
		vec4 p = candidate_lane == INVALID ? vec4(0) : candidate_position[candidate_lane];
		vec4 n = candidate_lane == INVALID ? vec4(0) : candidate_normal[candidate_lane];
		reused_probe = candidate_lane == INVALID ? INVALID : previous_index[candidate_lane];
		spawn_position = p;
		spawn_normal = n;
		probes.data[probe].position = vec4(p.xyz, reused_probe != INVALID ? 1.0 : 0.0);
		probes.data[probe].normal = n;
		queues.data[cached_heads_offset() + probe] = INVALID;
		queues.data[eviction_owners_offset() + probe] = INVALID;
		probes.data[probe].state = uvec4(candidate_lane == INVALID ? uvec2(0) : tile * 8u + uvec2(candidate_lane % 8u, candidate_lane / 8u), reused_probe == INVALID ? 0u : previous_probes.data[reused_probe].state.z, reused_probe);
	}
	barrier();
	clear_bins(lane);
	if (reused_probe != INVALID) {
		vec4 old = previous_radiance.data[reused_probe * 64u + lane];
		vec3 direction = basis(previous_probes.data[reused_probe].normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		vec3 delta = previous_probes.data[reused_probe].position.xyz + direction * old.w - spawn_position.xyz;
		float d = length(delta);
		if (old.w > 0.0 && d > 0.0001 && dot(delta, spawn_normal.xyz) > 0.0 && !motion_intersects(previous_probes.data[reused_probe].position.xyz, direction, old.w)) {
			insert_bin(angular_index(delta / d, spawn_normal.xyz), lane, vec4(old.rgb, d));
		}
	}
	barrier();
	uint count;
	vec4 sum = sum_bin(lane, count);
	barrier();
	bin_value[lane] = vec4(sum.rgb, count > 0u ? 1.0 : 0.0);
	barrier();
	for (uint stride = 1u; stride < 64u; stride <<= 1u) {
		if (lane < 64u / (2u * stride)) {
			bin_value[2u * (lane + 1u) * stride - 1u] += bin_value[(2u * lane + 1u) * stride - 1u];
		}
		barrier();
	}
	vec4 total = bin_value[63];
	if (lane == 0u && total.w == 0.0) {
		probes.data[probe].position.w = 0.0;
	}
	vec4 backup = vec4(total.rgb / (max(total.w, 1.0) * max(64.0 - total.w, 1.0)), params.max_distance);
	radiance.data[probe * 64u + lane] = count > 0u ? sum / float(count) : backup;
}

// Bin cached world positions into the current screen grid for bounded
// neighborhood lookup. Entries outside the screen remain resident until eviction.
void bin_cached_probe(uint index) {
	if (index >= CACHED_PROBES || cached_probes.data[index].probe.position.w == 0.0) {
		return;
	}
	vec4 clip = frame.view_projection * vec4(cached_probes.data[index].probe.position.xyz, 1);
	vec2 uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	if (clip.w <= 0.0 || any(lessThan(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
		return;
	}
	uint cell = probe_index(ivec2(uv * vec2(params.size) / 8.0));
	cached_state.data[index].w = atomicExchange(queues.data[cached_heads_offset() + cell], index);
}
uint find_cached_probe(vec3 p, vec3 n, ivec2 pixel) {
	float best = footprint(p);
	uint selected = INVALID;
	ivec2 center = pixel / 8;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			uint cell = probe_index(center + ivec2(x, y));
			if (cell == INVALID) {
				continue;
			}
			for (uint index = queues.data[cached_heads_offset() + cell]; index != INVALID; index = cached_state.data[index].w) {
				Probe candidate = cached_probes.data[index].probe;
				vec3 delta = candidate.position.xyz - p;
				float distance = length(delta);
				if (dot(candidate.normal.xyz, n) > 0.95 && abs(dot(delta, n)) < footprint(p) * 0.1 && distance < best) {
					selected = index;
					best = distance;
				}
			}
		}
	}
	return selected;
}

float radical_inverse(uint index, uint base) {
	float value = 0.0, digit = 1.0 / float(base);
	while (index != 0u) {
		value += float(index % base) * digit;
		index /= base;
		digit /= float(base);
	}
	return value;
}
void select_probe(uint slot) {
	uvec2 region = uvec2(slot % frame.tracing.x, slot / frame.tracing.x);
	uvec2 jitter = min(uvec2(vec2(radical_inverse(((params.padding - 1u) & 255u) + 1u, 2u), radical_inverse(((params.padding - 1u) & 255u) + 1u, 3u)) * float(frame.grid.z)), uvec2(frame.grid.z - 1u));
	uvec2 seed = min(region * frame.grid.z + jitter, params.size - 1u);
	uint selected = probe_index(ivec2(seed / 8u));
	vec3 p, n;
	bool found = surface(ivec2(seed), p, n);
	uint span = frame.grid.z / 8u;
	// Reuse a valid candidate if the low-discrepancy seed lands on sky.
	if (!found) {
		selected = INVALID;
		for (uint y = 0u; y < span && selected == INVALID; y++) {
			for (uint x = 0u; x < span; x++) {
				uint candidate = probe_index(ivec2(region * span + uvec2(x, y)));
				if (candidate != INVALID && dot(probes.data[candidate].normal.xyz, probes.data[candidate].normal.xyz) > 0.5) {
					selected = candidate;
					seed = probes.data[candidate].state.xy;
					p = probes.data[candidate].position.xyz;
					n = probes.data[candidate].normal.xyz;
					break;
				}
			}
		}
	}
	spawn.data[slot] = uvec4(selected, seed, 0u);
	bool reusable = selected == INVALID;
	if (selected != INVALID) {
		Probe old = probes.data[selected];
		reusable = old.position.w > 0.0 && dot(old.normal.xyz, n) > 0.95 && abs(dot(old.position.xyz - p, n)) < footprint(p) * 0.1;
	}
	if (frame.tracing.z == 0u) {
		return;
	}
	uint count = frame.grid.x * frame.grid.y;
	if (reusable) {
		uint index = atomicAdd(queues.counts.y, 1u);
		queues.data[count + index] = slot;
	}
	// Regions do not overlap. Each unselected, uncovered dense tile can be
	// queued once without racing another region's selection.
	for (uint y = 0u; y < span; y++) {
		for (uint x = 0u; x < span; x++) {
			uint candidate = probe_index(ivec2(region * span + uvec2(x, y)));
			if (candidate == INVALID || candidate == selected) {
				continue;
			}
			Probe other = probes.data[candidate];
			if (other.position.w == 0.0 && dot(other.normal.xyz, other.normal.xyz) > 0.5) {
				uint index = atomicAdd(queues.counts.x, 1u);
				queues.data[index] = candidate;
			}
		}
	}
}
void patch_probe(uint index) {
	if (frame.tracing.z == 0u || index >= min(queues.counts.x, queues.counts.y)) {
		return;
	}
	// One-to-one matching avoids duplicate destinations or extra rays. A
	// rotating offset prevents a fixed prefix of holes winning every frame.
	uint hole = queues.data[(index + pcg(params.padding) % queues.counts.x) % queues.counts.x];
	uint slot = queues.data[frame.grid.x * frame.grid.y + index];
	spawn.data[slot] = uvec4(hole, probes.data[hole].state.xy, 0u);
}

void prepare_probe(uint slot, uint lane) {
	uint probe = spawn.data[slot].x;
	if (probe == INVALID) {
		return;
	}
	if (lane == 0u) {
		vec3 p, n;
		bool found = surface(ivec2(spawn.data[slot].yz), p, n);
		spawn_position = vec4(p, found ? 1.0 : 0.0);
		spawn_normal = vec4(n, 0);
		cached_match = INVALID;
		spawn.data[slot].w = INVALID;
		if (frame.flags.w != 0u && found) {
			cached_match = find_cached_probe(p, n, ivec2(spawn.data[slot].yz));
			if (cached_match != INVALID) {
				atomicMax(cached_state.data[cached_match].y, 1u);
				atomicMin(cached_state.data[cached_match].z, slot);
			}
			uint evicted = probes.data[probe].state.w;
			// Disocclusion can reject the previous surface before TRACE sees
			// it. Retain the old tile's world probe as well, otherwise these
			// are precisely the histories that the cache would never receive.
			if (evicted == INVALID) {
				evicted = probe;
			}
			if (evicted != INVALID && frame.grid.w == 0u) {
				Probe previous = previous_probes.data[evicted];
				vec3 delta = previous.position.xyz - p;
				bool valid_previous = previous.position.w > 0.0 && params.padding - previous.state.z <= 50u;
				if (valid_previous && (dot(previous.normal.xyz, n) < 0.95 || abs(dot(delta, n)) > footprint(p) * 0.1 || length(delta) > footprint(p))) {
					// Several reprojected tiles may refer to the same old probe.
					// Publish it only once; eviction queue capacity is the update budget.
					if (atomicCompSwap(queues.data[eviction_owners_offset() + evicted], INVALID, slot) == INVALID) {
						uint index = atomicAdd(queues.counts.z, 1u);
						spawn.data[slot].w = evicted;
						queues.data[eviction_queue_offset() + index] = slot;
					}
				}
			}
		}
	}
	barrier();
	clear_bins(lane);
	// Read the immutable current-grid reprojection. TRACE publishes new seeds
	// only after every workgroup has finished gathering its neighbors.
	if (frame.grid.w == 0u && spawn_position.w > 0.0) {
		ivec2 center = ivec2(spawn.data[slot].yz / 8u);
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				uint previous = probe_index(center + ivec2(x, y));
				if (previous == INVALID) {
					continue;
				}
				Probe old_probe = probes.data[previous];
				if (old_probe.position.w == 0.0 || params.padding - old_probe.state.z > 50u || dot(old_probe.normal.xyz, spawn_normal.xyz) < 0.95 || abs(dot(old_probe.position.xyz - spawn_position.xyz, spawn_normal.xyz)) > footprint(spawn_position.xyz) * 0.1) {
					continue;
				}
				vec4 old = radiance.data[previous * 64u + lane];
				vec3 direction = basis(old_probe.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
				vec3 delta = old_probe.position.xyz + direction * old.w - spawn_position.xyz;
				float d = length(delta);
				if (old.w > 0.0 && d > 0.0001 && dot(delta, spawn_normal.xyz) > 0.0 && !motion_intersects(old_probe.position.xyz, direction, old.w)) {
					uint sample_index = uint(x + 1 + (y + 1) * 3) * 64u + lane;
					insert_bin(angular_index(delta / d, spawn_normal.xyz), sample_index, vec4(old.rgb, d));
				}
			}
		}
	}
	if (cached_match != INVALID) {
		Probe cached = cached_probes.data[cached_match].probe;
		vec4 old = cached_probes.data[cached_match].radiance[lane];
		vec3 direction = basis(cached.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		vec3 delta = cached.position.xyz + direction * old.w - spawn_position.xyz;
		float d = length(delta);
		if (old.w > 0.0 && d > 0.0001 && dot(delta, spawn_normal.xyz) > 0.0 && !motion_intersects(cached.position.xyz, direction, old.w)) {
			insert_bin(angular_index(delta / d, spawn_normal.xyz), 576u + lane, vec4(old.rgb, d));
		}
	}
	barrier();
	uint reused_count;
	vec4 history = sum_bin(lane, reused_count);
	history = reused_count > 0u ? history / float(reused_count) : vec4(0, 0, 0, -1);
	uint id = probe * 64u + lane;
	scratch.data[id] = history;
}

void trace_probe(uint slot, uint lane) {
	uint ray_id = slot * 64u + lane;
	if (params.bounces != 0u) {
		secondary_rays.data[ray_id] = empty_ray();
	}
	uint probe = spawn.data[slot].x;
	if (probe == INVALID) {
		rays.data[ray_id] = empty_ray();
		return;
	}
	if (lane == 0u) {
		vec3 p, n;
		bool found = surface(ivec2(spawn.data[slot].yz), p, n);
		spawn_position = vec4(p, found ? 1.0 : 0.0);
		spawn_normal = vec4(n, 0);
		probes.data[probe].position = spawn_position;
		probes.data[probe].normal = spawn_normal;
		probes.data[probe].state = uvec4(spawn.data[slot].yz, params.padding, slot);
	}
	barrier();
	vec4 history = scratch.data[probe * 64u + lane];
	if (frame.flags.y != 0u) {
		vec3 local_direction = hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		scan_radiance(lane, luma(history.rgb) * max(local_direction.z, 0.0));
	}
	RayHit ray = empty_ray();
	if (spawn_position.w > 0.0) {
		uint state = pcg(ray_id + params.padding * 747796405u);
		uint cell = lane;
		// As in GI-1, cells without valid reprojected history retain their
		// stratified sample. A black/empty CDF also falls back to uniform.
		if (frame.flags.y != 0u && history.w > 0.0 && sampling_total > 0.00001) {
			cell = sample_cell(random_float(state));
		}
		vec2 jitter = vec2(random_float(state), random_float(state));
		vec3 dir = basis(spawn_normal.xyz) * hemi_direction((vec2(cell % 8u, cell / 8u) + jitter) / 8.0);
		vec3 origin = spawn_position.xyz + spawn_normal.xyz * 0.002;
		ray = trace_hit(origin, dir);
	}
	rays.data[ray_id] = ray;
}
void allocate_tile(uint id) {
	RayHit ray = pass_id == PASS_ALLOCATE_SECONDARY ? secondary_rays.data[id] : rays.data[id];
	if (ray.position.w < 0.0) {
		return;
	}
	uvec2 cell;
	ivec4 key = cache_key(ray.position.xyz, ray.direction_cache.xyz, ray.position.w, cell);
	uint hash = key_hash(key), bucket = (hash % 1024u) * 4u;
	for (uint i = 0u; i < 4u; i++) {
		uint t = bucket + i;
		uint old = atomicCompSwap(keys.data[t].state.x, 0u, 1u);
		if (old == 0u) {
			keys.data[t].key = key;
			keys.data[t].state.y = params.padding;
			memoryBarrierBuffer();
			atomicExchange(keys.data[t].state.x, hash);
			return;
		}
		// Another lane is publishing this slot. Resolve in the next dispatch;
		// never spin, read an incomplete key, or allocate duplicates behind it.
		if (old == 1u) {
			return;
		}
		if (old == hash && all(equal(keys.data[t].key, key))) {
			return;
		}
	}
}
void register_ray(uint id) {
	bool secondary = pass_id == PASS_REGISTER_SECONDARY;
	RayHit ray = secondary ? secondary_rays.data[id] : rays.data[id];
	if (ray.position.w < 0.0) {
		return;
	}
	uint cell = find_cell(ray.position.xyz, ray.direction_cache.xyz, ray.position.w);
	if (secondary) {
		secondary_rays.data[id].direction_cache.w = uintBitsToFloat(cell);
	} else {
		rays.data[id].direction_cache.w = uintBitsToFloat(cell);
	}
	if (cell != INVALID) {
		atomicMin(owners.data[cell], secondary ? id + primary_ray_count() : id);
		atomicMax(keys.data[cell / TILE_CELLS].state.y, params.padding);
	}
}
uint pack_reservoir_normal(vec3 n) {
	n /= abs(n.x) + abs(n.y) + abs(n.z);
	vec2 p = n.xy;
	if (n.z < 0.0) {
		p = (1.0 - abs(p.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
	}
	return packSnorm2x16(p);
}
vec3 unpack_reservoir_normal(uint packed) {
	vec2 p = unpackSnorm2x16(packed);
	vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));
	float t = max(-n.z, 0.0);
	n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);
	return normalize(n);
}
vec3 light_target(RayHit ray, uint light) {
	vec3 direction;
	float distance;
	return ray.diffuse.rgb * unshadowed_irradiance(light, ray.position.xyz, ray.normal_mask.xyz, floatBitsToUint(ray.normal_mask.w), direction, distance) / PI;
}
struct LightNode {
	vec3 minimum;
	uint light;
	vec3 maximum;
	uint count;
	vec4 power;
};
layout(set = 0, binding = 44, std430) restrict readonly buffer LightTree {
	LightNode data[];
}
light_tree;

float light_node_weight(LightNode node, vec3 position) {
	vec3 delta = max(max(node.minimum - position, position - node.maximum), vec3(0));
	return node.power.x / max(dot(delta, delta), 0.01) + node.power.y;
}
uint sample_light(vec3 position, inout uint state, out float probability) {
	uint node = 1u;
	probability = 1.0;
	while (light_tree.data[node].light == INVALID) {
		LightNode left = light_tree.data[node * 2u];
		LightNode right = light_tree.data[node * 2u + 1u];
		float uniform_probability = float(left.count) / float(left.count + right.count);
		float lw = light_node_weight(left, position), rw = light_node_weight(right, position);
		// Retain support for every light, including non-inverse-square falloff,
		// unusual spot cones and black-light transitions. Exact targets and the
		// walk PDF, not this approximate bound, determine the RIS contribution.
		float p = lw + rw > 0.0 ? mix(uniform_probability, lw / (lw + rw), 0.9) : uniform_probability;
		bool choose_left = random_float(state) < p;
		probability *= choose_left ? p : 1.0 - p;
		node = node * 2u + (choose_left ? 0u : 1u);
	}
	return light_tree.data[node].light;
}
void reservoir_add(uint light, float target, float weight, inout uint selected, inout float selected_target, inout float sum, inout uint state) {
	if (weight <= 0.0 || isnan(weight) || isinf(weight)) {
		return;
	}
	sum += weight;
	if (random_float(state) * sum < weight) {
		selected = light;
		selected_target = target;
	}
}
// GI-1 reservoir construction: eight fresh RIS candidates, normalized to one
// unit of confidence, then up to four compatible previous world reservoirs.
// Proposals are re-evaluated at this hit and visibility is always traced here.
vec3 resampled_direct(RayHit ray, inout uint state, out uvec4 packed) {
	uint selected = INVALID;
	float selected_target = 0.0, sum = 0.0;
	for (uint i = 0u; i < 8u; i++) {
		float proposal;
		uint light = sample_light(ray.position.xyz, state, proposal);
		float target = luma(abs(light_target(ray, light)));
		reservoir_add(light, target, target / proposal, selected, selected_target, sum, state);
	}
	sum /= 8.0;
	float confidence = 1.0;
	uvec4 visited = uvec4(INVALID);
	mat3 tangent = basis(ray.normal_mask.xyz);
	for (uint i = 0u; i < 4u; i++) {
		vec3 position = ray.position.xyz;
		if (i > 0u) {
			vec2 jitter = (vec2(random_float(state), random_float(state)) * 2.0 - 1.0) * cache_cell_size(position) * sqrt(2.0);
			position += tangent[0] * jitter.x + tangent[1] * jitter.y;
		}
		uint cell = find_cell(position, ray.direction_cache.xyz, ray.position.w);
		if (cell == INVALID || any(equal(visited, uvec4(cell)))) {
			continue;
		}
		visited[i] = cell;
		uvec4 old = previous_light_reservoirs.data[cell / TILE_CELLS * 64u + cell % TILE_CELLS];
		if (old.x >= params.light_count || uintBitsToFloat(old.w) <= 0.0) {
			continue;
		}
		float agreement = max(dot(ray.normal_mask.xyz, unpack_reservoir_normal(old.y)), 0.0);
		if (agreement * agreement * agreement * agreement < 0.5) {
			continue;
		}
		float count = min(uintBitsToFloat(old.w), 20.0);
		float target = luma(abs(light_target(ray, old.x)));
		reservoir_add(old.x, target, target * uintBitsToFloat(old.z) * count, selected, selected_target, sum, state);
		confidence += count;
	}
	packed = uvec4(INVALID, 0, 0, 0);
	if (selected == INVALID || selected_target <= 0.0) {
		return vec3(0);
	}
	float weight = sum / (confidence * selected_target);
	packed = uvec4(selected, pack_reservoir_normal(ray.normal_mask.xyz), floatBitsToUint(weight), floatBitsToUint(confidence));
	vec3 direction;
	float distance;
	vec3 irradiance = unshadowed_irradiance(selected, ray.position.xyz, ray.normal_mask.xyz, floatBitsToUint(ray.normal_mask.w), direction, distance);
	return ray.diffuse.rgb * irradiance * (weight * light_visibility(selected, ray.position.xyz, ray.normal_mask.xyz, direction, distance) / PI);
}
// Cache reflected radiance only. Emission is evaluated at the actual ray hit:
// spatial filtering it would enlarge emitters and leak their light across edges.
vec3 shade_direct(RayHit ray, inout uint state, uint cell) {
	if (frame.tracing.w != 0u) {
		uvec4 reservoir;
		vec3 value = resampled_direct(ray, state, reservoir);
		if (cell != INVALID) {
			light_reservoirs.data[cell / TILE_CELLS * 64u + cell % TILE_CELLS] = reservoir;
		}
		return value;
	}
	return ray.diffuse.rgb * direct_irradiance(ray.position.xyz, ray.normal_mask.xyz, floatBitsToUint(ray.normal_mask.w)) / PI;
}
// Unregistered/short connections retain uncached evaluation. The normal cached
// path populates and shades secondary cells in explicit ordered stages below.
vec3 shade_transport(RayHit ray, uint state, uint cell) {
	vec3 value = shade_direct(ray, state, cell);
	if (params.bounces != 0u && random_float(state) < frame.settings.z) {
		vec3 direction = cosine_direction(ray.normal_mask.xyz, state);
		RayHit secondary = trace_hit(ray.position.xyz + ray.normal_mask.xyz * 0.002, direction);
		if (secondary.position.w > 0.0) {
			uint target = find_cell(secondary.position.xyz, direction, secondary.position.w);
			vec4 cached = secondary.position.w < cache_cell_size(secondary.position.xyz) ? vec4(0) : read_cache(target, true);
			vec3 outgoing = cached.w > 0.0 ? cached.rgb : shade_direct(secondary, state, INVALID);
			value += ray.diffuse.rgb * (secondary.emission.rgb + outgoing) / frame.settings.z;
		} else {
			value += ray.diffuse.rgb * environment_radiance(direction, false) / frame.settings.z;
		}
	}
	return clean_color(value);
}
void populate_secondary(uint cell) {
	if (cell >= TILE_COUNT * TILE_CELLS || cell % TILE_CELLS >= 64u) {
		return;
	}
	uint owner = owners.data[cell];
	if (owner >= primary_ray_count()) {
		return;
	}
	uint state = pcg(owner + params.padding * 2891336453u);
	if (random_float(state) >= frame.settings.z) {
		return;
	}
	RayHit source = rays.data[owner];
	vec3 direction = cosine_direction(source.normal_mask.xyz, state);
	secondary_rays.data[owner] = trace_hit(source.position.xyz + source.normal_mask.xyz * 0.002, direction);
}
RayHit owned_hit(uint owner) {
	if (owner < primary_ray_count()) {
		return rays.data[owner];
	}
	return secondary_rays.data[owner - primary_ray_count()];
}
void update_indirect(uint cell) {
	if (cell >= TILE_COUNT * TILE_CELLS || cell % TILE_CELLS >= 64u) {
		return;
	}
	uint owner = owners.data[cell];
	if (owner == INVALID) {
		return;
	}
	if (owner >= primary_ray_count()) {
		// No continuation was scheduled from this secondary-only receiver.
		// Do not retain stale indirect light if it was a primary in the past.
		indirect_cache.data[cell] = vec4(0);
		return;
	}
	vec3 value = vec3(0);
	RayHit secondary = secondary_rays.data[owner];
	if (secondary.position.w > 0.0) {
		uint target = floatBitsToUint(secondary.direction_cache.w);
		bool bypass = secondary.position.w < cache_cell_size(secondary.position.xyz);
		vec4 direct = bypass ? vec4(0) : read_component(target, false, false);
		uint state = pcg(owner + params.padding * 747796405u);
		vec3 outgoing = direct.w > 0.0 ? direct.rgb : shade_direct(secondary, state, INVALID);
		// Current direct lighting plus previous indirect avoids a feedback race.
		// Returning to a previously populated receiver carries further bounces.
		if (!bypass) {
			outgoing += read_component(target, true, true).rgb;
		}
		value = rays.data[owner].diffuse.rgb * (outgoing + secondary.emission.rgb) / frame.settings.z;
	} else if (dot(secondary.direction_cache.xyz, secondary.direction_cache.xyz) > 0.5) {
		// Empty unscheduled rays have a zero direction; only actual misses see sky.
		value = rays.data[owner].diffuse.rgb * environment_radiance(secondary.direction_cache.xyz, false) / frame.settings.z;
	}
	vec4 old = previous_indirect_cache.data[cell];
	float count = min(old.w + 1.0, 16.0);
	// A discarded/missed continuation is a zero sample, not stale lighting.
	indirect_cache.data[cell] = vec4(mix(old.rgb, clean_color(value), 1.0 / count), count);
}
void update_cell(uint cell) {
	if (cell >= TILE_COUNT * TILE_CELLS || cell % TILE_CELLS >= 64u) {
		return;
	}
	uint owner = owners.data[cell];
	if (owner == INVALID) {
		return;
	}
	uint state = pcg(owner + params.padding * 2891336453u);
	vec3 value = shade_direct(owned_hit(owner), state, cell);
	vec4 old = previous_cache.data[cell];
	float count = min(old.w + 1.0, 16.0);
	cache.data[cell] = vec4(mix(old.rgb, clean_color(value), 1.0 / count), count);
}
void build_mip(uint tile, uint lane, uint mip) {
	bool indirect = pass_id >= PASS_INDIRECT_MIP1 && pass_id <= PASS_INDIRECT_MIP3;
	uint width = 8u >> mip;
	if (lane >= width * width) {
		return;
	}
	uvec2 pos = uvec2(lane % width, lane / width) * 2u;
	uint source = tile * TILE_CELLS + MIP_OFFSET[mip - 1u];
	vec4 sum = vec4(0);
	for (uint y = 0u; y < 2u; y++) {
		for (uint x = 0u; x < 2u; x++) {
			uint index = source + pos.x + x + (pos.y + y) * (width * 2u);
			vec4 value = indirect ? indirect_cache.data[index] : cache.data[index];
			sum += vec4(value.rgb * value.w, value.w);
		}
	}
	// Mips carry the sum of their children's evidence, not a second capped
	// temporal history. Preserve it for both mip selection and parent weights.
	vec4 value = vec4(sum.rgb / max(sum.w, 1.0), sum.w);
	if (indirect) {
		indirect_cache.data[tile * TILE_CELLS + MIP_OFFSET[mip] + lane] = value;
	} else {
		cache.data[tile * TILE_CELLS + MIP_OFFSET[mip] + lane] = value;
	}
}
void resolve_probe(uint slot, uint lane) {
	uint probe = spawn.data[slot].x;
	if (probe == INVALID) {
		return;
	}
	uint id = probe * 64u + lane;
	RayHit ray = rays.data[slot * 64u + lane];
	vec3 value = environment_radiance(ray.direction_cache.xyz, false);
	float hit_distance = ray.position.w < 0.0 ? params.max_distance : ray.position.w;
	if (ray.position.w > 0.0) {
		// A ray shorter than one world cell can connect opposite sides of a
		// thin partition. AMD bypasses filtered readback for these samples.
		vec4 c = ray.position.w < cache_cell_size(ray.position.xyz) ? vec4(0) : read_cache(floatBitsToUint(ray.direction_cache.w), false);
		value = ray.emission.rgb + (c.w > 0.0 ? c.rgb : shade_transport(ray, pcg(slot * 64u + lane + params.padding * 2891336453u), INVALID));
	}
	clear_bins(lane);
	if (probes.data[probe].position.w > 0.0) {
		uint cell = angular_index(ray.direction_cache.xyz, probes.data[probe].normal.xyz);
		insert_bin(cell, lane, vec4(clean_color(value), hit_distance));
	}
	barrier();
	uint sample_count;
	vec4 sum = sum_bin(lane, sample_count);
	// Finish every linked-list read before repurposing shared sample storage.
	barrier();
	bin_value[lane] = vec4(sum.rgb, sample_count > 0u ? 1.0 : 0.0);
	barrier();
	for (uint stride = 1u; stride < 64u; stride <<= 1u) {
		if (lane < 64u / (2u * stride)) {
			bin_value[2u * (lane + 1u) * stride - 1u] += bin_value[(2u * lane + 1u) * stride - 1u];
		}
		barrier();
	}
	if (lane == 0u) {
		// GI-1 BlendScreenProbes' backup for angular cells receiving no ray.
		// This is a radiance-field reconstruction, not a PDF-weighted path sum.
		vec4 total = bin_value[63];
		radiance_backup = vec4(total.rgb / (max(total.w, 1.0) * max(64.0 - total.w, 1.0)), params.max_distance);
	}
	barrier();
	vec4 result = sample_count > 0u ? sum / float(sample_count) : radiance_backup;
	vec4 history = scratch.data[id];
	if (history.w > 0.0) {
		// AMD's shadow-preserving temporal hysteresis suppresses abrupt bright
		// outliers without dragging old bright values into newly dark cells.
		float a = luma(result.rgb), b = luma(history.rgb);
		float blend = clamp(max(a - b - min(a, b), 0.0) / max(max(a, b), 0.0001), 0.0, 0.95);
		result = mix(result, history, blend * blend);
	}
	radiance.data[id] = vec4(clean_color(result.rgb), result.w);
}
vec4 filter_source(uint id) {
	return pass_id == PASS_FILTER_X ? radiance.data[id] : scratch.data[id];
}
void filter_probe(uint probe, uint lane) {
	uint id = probe * 64u + lane;
	Probe center = probes.data[probe];
	vec4 value = filter_source(id);
	float weight = 1.0;
	if (center.position.w > 0.0 && center.state.z == params.padding) {
		vec3 direction = basis(center.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		ivec2 location = ivec2(probe % frame.grid.x, probe / frame.grid.x);
		for (int step = -3; step <= 3; step++) {
			if (step == 0) {
				continue;
			}
			uint other = probe_index(location + (pass_id == PASS_FILTER_X ? ivec2(step, 0) : ivec2(0, step)));
			if (other == INVALID) {
				continue;
			}
			Probe neighbor = probes.data[other];
			if (neighbor.position.w == 0.0 || dot(direction, neighbor.normal.xyz) < 0.0) {
				continue;
			}
			if (abs(dot(neighbor.position.xyz - center.position.xyz, center.normal.xyz)) > footprint(center.position.xyz) * 0.1) {
				continue;
			}
			uint cell = angular_index(direction, neighbor.normal.xyz);
			vec4 sample_value = filter_source(other * 64u + cell);
			vec3 sample_direction = basis(neighbor.normal.xyz) * hemi_direction((vec2(cell % 8u, cell / 8u) + 0.5) / 8.0);
			float hit_distance = min(value.w / weight, sample_value.w);
			vec3 hit = neighbor.position.xyz + sample_direction * hit_distance;
			if (dot(normalize(hit - center.position.xyz), direction) < 0.9980267284) {
				continue;
			}
			float w = pow(clamp(1.0 - abs(length(neighbor.position.xyz - params.camera_position.xyz) - length(center.position.xyz - params.camera_position.xyz)) / max(length(center.position.xyz - params.camera_position.xyz), 0.001), 0.0, 1.0), 8.0);
			value += vec4(sample_value.rgb, hit_distance) * w;
			weight += w;
		}
	}
	if (pass_id == PASS_FILTER_X) {
		scratch.data[id] = value / weight;
	} else {
		radiance.data[id] = value / weight;
	}
}
void project_probe(uint probe, uint lane) {
	if (lane == 0u) {
		probe_mask.data[probe] = probes.data[probe].position.w > 0.0 ? probe : INVALID;
	}
	if (lane >= 9u) {
		return;
	}
	vec3 value = vec3(0);
	if (probes.data[probe].position.w > 0.0) {
		mat3 tbn = basis(probes.data[probe].normal.xyz);
		for (uint cell = 0u; cell < 64u; cell++) {
			vec3 dir = tbn * hemi_direction((vec2(cell % 8u, cell / 8u) + 0.5) / 8.0);
			float sh[9];
			sh_coefficients(dir, sh);
			value += radiance.data[probe * 64u + cell].rgb * sh[lane] * (2.0 * PI / 64.0);
		}
	}
	probes.data[probe].sh[lane] = vec4(value, 0);
}
vec3 probe_irradiance(uint probe, vec3 normal) {
	float sh[9];
	sh_coefficients(normal, sh);
	vec3 value = vec3(0);
	// Cosine convolution / PI: Forward+ applies the visible diffuse material.
	for (uint i = 0u; i < 9u; i++) {
		value += probes.data[probe].sh[i].rgb * sh[i] * (i == 0u ? 1.0 : (i < 4u ? 2.0 / 3.0 : 0.25));
	}
	return max(value, vec3(0));
}
// A bounded 4096-element exclusive scan and stable partition maintain
// frame-granularity LRU order without sorting or CPU readback. This scan and
// the angular bins together fit Vulkan's minimum 32 KiB workgroup storage.
shared uint lru_scan[4096];
shared uint lru_used;
void order_cached_probes(uint lane) {
	for (uint index = lane; index < CACHED_PROBES; index += 64u) {
		lru_scan[index] = cached_state.data[previous_cached_order.data[index]].y;
	}
	barrier();
	for (uint stride = 1u; stride < CACHED_PROBES; stride <<= 1u) {
		for (uint index = lane; index < CACHED_PROBES / (2u * stride); index += 64u) {
			lru_scan[2u * (index + 1u) * stride - 1u] += lru_scan[(2u * index + 1u) * stride - 1u];
		}
		barrier();
	}
	if (lane == 0u) {
		lru_used = lru_scan[CACHED_PROBES - 1u];
		lru_scan[CACHED_PROBES - 1u] = 0u;
	}
	barrier();
	for (uint stride = CACHED_PROBES / 2u; stride > 0u; stride >>= 1u) {
		for (uint index = lane; index < CACHED_PROBES / (2u * stride); index += 64u) {
			uint a = (2u * index + 1u) * stride - 1u;
			uint b = 2u * (index + 1u) * stride - 1u;
			uint value = lru_scan[a];
			lru_scan[a] = lru_scan[b];
			lru_scan[b] += value;
		}
		barrier();
	}
	uint unused = CACHED_PROBES - lru_used;
	uint allocated = min(queues.counts.z, unused);
	for (uint index = lane; index < CACHED_PROBES; index += 64u) {
		uint cached = previous_cached_order.data[index];
		uint prefix = lru_scan[index];
		uint destination;
		if (cached_state.data[cached].y != 0u) {
			destination = unused - allocated + prefix;
		} else {
			uint rank = index - prefix;
			if (rank < allocated) {
				cached_state.data[cached].z = 0x80000000u | rank;
				destination = CACHED_PROBES - allocated + rank;
			} else {
				destination = rank - allocated;
			}
		}
		cached_order.data[destination] = cached;
	}
}
void store_cached_probe(uint cached, uint lane) {
	uint owner = cached_state.data[cached].z;
	if (owner == INVALID) {
		return;
	}
	bool evicted = (owner & 0x80000000u) != 0u;
	uint slot = evicted ? queues.data[eviction_queue_offset() + (owner & 0x7fffffffu)] : owner;
	uint probe = evicted ? spawn.data[slot].w : spawn.data[slot].x;
	if (lane == 0u) {
		cached_probes.data[cached].probe = evicted ? previous_probes.data[probe] : probes.data[probe];
		if (evicted && probe_motion(previous_probes.data[probe], probe, false)) {
			cached_probes.data[cached].probe.position.w = 0.0;
		}
	}
	cached_probes.data[cached].radiance[lane] = evicted ? previous_radiance.data[probe * 64u + lane] : radiance.data[probe * 64u + lane];
}

uvec2 mask_dimensions(uint level) {
	return (frame.grid.xy + (1u << level) - 1u) >> level;
}
uint mask_offset(uint level) {
	uint offset = 0u;
	for (uint i = 0u; i < level; i++) {
		uvec2 size = mask_dimensions(i);
		offset += size.x * size.y;
	}
	return offset;
}
void filter_mask(uvec2 pixel) {
	uint level = params.samples;
	uvec2 size = mask_dimensions(level);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	uvec2 source_size = mask_dimensions(level - 1u);
	uint source = mask_offset(level - 1u);
	uint selected = INVALID;
	for (uint y = 0u; y < 2u && selected == INVALID; y++) {
		for (uint x = 0u; x < 2u; x++) {
			uvec2 p = pixel * 2u + uvec2(x, y);
			if (all(lessThan(p, source_size))) {
				selected = probe_mask.data[source + p.x + p.y * source_size.x];
				if (selected != INVALID) {
					break;
				}
			}
		}
	}
	probe_mask.data[mask_offset(level) + pixel.x + pixel.y * size.x] = selected;
}
uint closest_probe(ivec2 pixel, ivec2 offset) {
	ivec2 pos = pixel / 8;
	uint base = 0u;
	for (uint mip = 0u; mip < frame.flags.z; mip++) {
		ivec2 size = ivec2(mask_dimensions(mip));
		ivec2 location = pos + offset;
		if (any(lessThan(location, ivec2(0))) || any(greaterThanEqual(location, size))) {
			break;
		}
		uint result = probe_mask.data[base + uint(location.x + location.y * size.x)];
		if (result != INVALID) {
			return result;
		}
		base += uint(size.x * size.y);
		pos /= 2;
	}
	return INVALID;
}
void interpolate_pixel(ivec2 pixel, uint id) {
	Pixel result;
	vec3 p, n;
	bool valid = surface(pixel, p, n);
	result.position = vec4(p, valid ? 1.0 : 0.0);
	result.normal_delta = vec4(n, 0);
	result.color = vec4(0);
	if (valid) {
		// GI-1 jitters the lookup only when the new point remains on the
		// original surface plane. The source BRDF still uses the original pixel.
		ivec2 jitter = ivec2((lookup_jitter(pixel) * 2.0 - 1.0) * float(frame.grid.z));
		ivec2 sample_pixel = clamp(pixel + jitter, ivec2(0), ivec2(params.size) - 1);
		vec3 sample_p, sample_n;
		if (!surface(sample_pixel, sample_p, sample_n) || abs(dot(sample_p - p, n)) >= footprint(p) * 0.5) {
			sample_pixel = pixel;
		}
		uvec4 indices = uvec4(INVALID);
		indices.x = closest_probe(sample_pixel, ivec2(0));
		if (indices.x != INVALID) {
			ivec2 seed = ivec2(probes.data[indices.x].state.xy);
			ivec2 offset = ivec2(sample_pixel.x < seed.x ? -1 : 1, sample_pixel.y < seed.y ? -1 : 1);
			indices.y = closest_probe(sample_pixel, ivec2(offset.x, 0));
			indices.z = closest_probe(sample_pixel, ivec2(0, offset.y));
			indices.w = closest_probe(sample_pixel, offset);
			vec4 weights = vec4(0);
			vec3 forward = vec3(0, 0, -1);
			forward += 2.0 * cross(params.camera_rotation.xyz, cross(params.camera_rotation.xyz, forward) + params.camera_rotation.w * forward);
			float depth = dot(p - params.camera_position.xyz, forward);
			for (uint i = 0u; i < 4u; i++) {
				for (uint j = 0u; j < i; j++) {
					if (indices[i] == indices[j]) {
						indices[i] = INVALID;
					}
				}
				if (indices[i] == INVALID) {
					continue;
				}
				Probe other = probes.data[indices[i]];
				if (abs(dot(other.position.xyz - p, n)) <= footprint(p)) {
					float probe_depth = dot(other.position.xyz - params.camera_position.xyz, forward);
					weights[i] = pow(clamp(1.0 - abs(probe_depth - depth) / max(depth, 0.001), 0.0, 1.0) * max(dot(n, other.normal.xyz), 0.0), 8.0);
				}
			}
			if (dot(weights, vec4(1)) <= 0.00001) {
				// AMD's relaxed fallback keeps uncovered surfaces from going
				// black. Mark it low confidence so it cannot grow temporal history.
				weights = vec4(1.0, indices.y != INVALID ? 1.0 : 0.0, indices.z != INVALID ? 1.0 : 0.0, indices.w != INVALID ? 1.0 : 0.0);
				result.position.w = 2.0;
			}
			weights /= dot(weights, vec4(1));
			vec3 sum = vec3(0);
			for (uint i = 0u; i < 4u; i++) {
				if (indices[i] != INVALID) {
					sum += weights[i] * probe_irradiance(indices[i], n);
				}
			}
			result.color = vec4(sum, 1);
		}
	}
	pixels.data[id] = result;
}
void reproject_pixel(ivec2 pixel, uint id) {
	Pixel current = pixels.data[id];
	if (current.position.w == 0.0 || frame.flags.x == 0u) {
		return;
	}
	vec4 old_sum = vec4(0);
	float delta = 0.0, weight = 0.0;
	vec4 clip = frame.previous_view_projection * vec4(current.position.xyz, 1);
	vec2 uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	if (frame.grid.w == 0u && !motion_overlaps(current.position.xyz, current.position.xyz) && clip.w > 0.0 && all(greaterThan(uv, vec2(0))) && all(lessThan(uv, vec2(1)))) {
		ivec2 center = ivec2(uv * vec2(params.size));
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				ivec2 p = center + ivec2(x, y);
				if (any(lessThan(p, ivec2(0))) || any(greaterThanEqual(p, ivec2(params.size)))) {
					continue;
				}
				Pixel old = previous_pixels.data[uint(p.x) + uint(p.y) * params.size.x];
				if (old.position.w != 1.0 || old.color.w < 1.0) {
					continue;
				}
				if (dot(old.normal_delta.xyz, current.normal_delta.xyz) < 0.95 || distance(old.position.xyz, current.position.xyz) > footprint(current.position.xyz) * 0.5) {
					continue;
				}
				float w = clamp(1.0 - length(vec2(p) + 0.5 - uv * vec2(params.size)) * 0.707107, 0.0, 1.0);
				old_sum += old.color * w;
				delta += old.normal_delta.w * w;
				weight += w;
			}
		}
	}
	if (weight > 0.0) {
		old_sum /= weight;
		delta /= weight;
		vec3 lo = vec3(1e10), hi = vec3(0);
		// Clamp history to this frame's reconstructed neighborhood.
		// Reads only the immutable interpolation image, not concurrently updated pixels.
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				ivec2 p = clamp(pixel + ivec2(x, y), ivec2(0), ivec2(params.size) - 1);
				vec4 c = imageLoad(filter_image, p);
				if (c.w > 0.0) {
					lo = min(lo, c.rgb);
					hi = max(hi, c.rgb);
				}
			}
		}
		if (all(greaterThanEqual(hi, lo))) {
			old_sum.rgb = clamp(old_sum.rgb, lo, hi);
		}
	}
	if (current.position.w == 2.0) {
		if (old_sum.w > 0.0) {
			current.color = vec4(old_sum.rgb, 1.0);
		}
	} else if (current.color.w > 0.0) {
		float old_luma = luma(old_sum.rgb);
		delta = mix(delta, luma(current.color.rgb) - old_luma, 0.125);
		float blend = clamp(1.0 - abs(delta) / max(old_luma, 0.0001), 0.0, 1.0);
		float count = min(old_sum.w + 1.0, mix(4.0, 64.0, blend));
		current.color = vec4(mix(old_sum.rgb, current.color.rgb, 1.0 / max(count, 1.0)), count);
	} else if (old_sum.w > 0.0) {
		current.color = vec4(old_sum.rgb, max(old_sum.w - 1.0, 0.0));
	}
	current.normal_delta.w = delta;
	pixels.data[id] = current;
}
void filter_pixel(ivec2 pixel, uint id) {
	Pixel center = pixels.data[id];
	vec4 color = pass_id == PASS_BLUR_X ? center.color : imageLoad(filter_image, pixel);
	float weight = color.w > 0.0 ? 1.0 : 0.0;
	vec3 sum = color.rgb * weight;
	int radius = frame.flags.x == 0u ? 0 : int(clamp(8.0 - center.color.w, 0.0, 8.0));
	if (center.position.w > 0.0) {
		for (int r = -radius; r <= radius; r++) {
			if (r == 0) {
				continue;
			}
			ivec2 p = clamp(pixel + (pass_id == PASS_BLUR_X ? ivec2(r, 0) : ivec2(0, r)), ivec2(0), ivec2(params.size) - 1);
			uint other = uint(p.x) + uint(p.y) * params.size.x;
			vec4 neighbor_position = pixels.data[other].position;
			vec3 neighbor_normal = pixels.data[other].normal_delta.xyz;
			vec4 c = pass_id == PASS_BLUR_X ? pixels.data[other].color : imageLoad(filter_image, p);
			if (neighbor_position.w == 0.0 || c.w <= 0.0) {
				continue;
			}
			float plane = abs(dot(neighbor_position.xyz - center.position.xyz, center.normal_delta.xyz));
			float w = exp(-plane / max(footprint(center.position.xyz) * 0.05, 0.001)) * pow(max(dot(center.normal_delta.xyz, neighbor_normal), 0.0), 4.0);
			sum += c.rgb * w;
			weight += w;
		}
	}
	color.rgb = clean_color(sum / max(weight, 0.00001));
	if (pass_id == PASS_BLUR_X) {
		imageStore(filter_image, pixel, color);
	} else {
		// Only color is written here. The neighborhood reads immutable geometry
		// and the separate filter image, never another lane's output color.
		pixels.data[id].color = color;
		imageStore(output_diffuse, pixel, vec4((color.rgb + frame.ambient.rgb) * params.exposure, center.position.w > 0.0 ? frame.ambient.a : 0.0));
	}
}
#include "amd_gi_reflections_inc.glsl"
void main() {
	uint lane = gl_LocalInvocationIndex;
	uint probe = gl_WorkGroupID.x;
	uint id = probe * 64u + lane;
	if (pass_id >= PASS_REFLECTION_TRACE) {
		ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = pass_id == PASS_REFLECTION_UPSAMPLE ? ivec2(params.size) : reflection_size();
		if (any(greaterThanEqual(pixel, size))) {
			return;
		}
		uint reflection_id = reflection_index(pixel);
		if (pass_id == PASS_REFLECTION_TRACE) {
			trace_reflection(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_RESOLVE) {
			resolve_reflection(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_TEMPORAL) {
			temporal_reflection(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_FILTER) {
			filter_reflection(pixel, reflection_id);
		} else {
			upsample_reflection(pixel);
		}
	} else if (pass_id == PASS_RESET) {
		reset_cache(lane);
	} else if (pass_id == PASS_REPROJECT) {
		reproject_probe(probe, lane);
	} else if (pass_id == PASS_BIN_CACHED) {
		bin_cached_probe(id);
	} else if (pass_id == PASS_SELECT) {
		if (lane == 0u) {
			select_probe(probe);
		}
	} else if (pass_id == PASS_PATCH) {
		if (lane == 0u) {
			patch_probe(probe);
		}
	} else if (pass_id == PASS_PREPARE) {
		prepare_probe(probe, lane);
	} else if (pass_id == PASS_TRACE) {
		trace_probe(probe, lane);
	} else if (pass_id == PASS_ALLOCATE || pass_id == PASS_ALLOCATE_SECONDARY) {
		allocate_tile(id);
	} else if (pass_id == PASS_REGISTER || pass_id == PASS_REGISTER_SECONDARY) {
		register_ray(id);
	} else if (pass_id == PASS_POPULATE) {
		populate_secondary(id);
	} else if (pass_id == PASS_UPDATE_INDIRECT) {
		update_indirect(id);
	} else if (pass_id == PASS_UPDATE) {
		update_cell(id);
	} else if (pass_id >= PASS_MIP1 && pass_id <= PASS_MIP3) {
		build_mip(probe, lane, uint(pass_id - PASS_MIP1 + 1));
	} else if (pass_id >= PASS_INDIRECT_MIP1 && pass_id <= PASS_INDIRECT_MIP3) {
		build_mip(probe, lane, uint(pass_id - PASS_INDIRECT_MIP1 + 1));
	} else if (pass_id == PASS_RESOLVE) {
		resolve_probe(probe, lane);
	} else if (pass_id == PASS_FILTER_X || pass_id == PASS_FILTER_Y) {
		filter_probe(probe, lane);
	} else if (pass_id == PASS_PROJECT) {
		project_probe(probe, lane);
	} else if (pass_id == PASS_ORDER_CACHED) {
		order_cached_probes(lane);
	} else if (pass_id == PASS_STORE_CACHED) {
		store_cached_probe(probe, lane);
	} else if (pass_id == PASS_MASK) {
		filter_mask(gl_GlobalInvocationID.xy);
	} else {
		ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
		if (any(greaterThanEqual(pixel, ivec2(params.size)))) {
			return;
		}
		uint pixel_id = uint(pixel.x) + uint(pixel.y) * params.size.x;
		if (pass_id == PASS_INTERPOLATE) {
			interpolate_pixel(pixel, pixel_id);
			imageStore(filter_image, pixel, vec4(pixels.data[pixel_id].color.rgb, pixels.data[pixel_id].position.w == 2.0 ? 0.0 : pixels.data[pixel_id].color.w));
		} else if (pass_id == PASS_TEMPORAL) {
			reproject_pixel(pixel, pixel_id);
		} else {
			filter_pixel(pixel, pixel_id);
		}
	}
}
