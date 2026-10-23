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
const int PASS_RESERVOIR_RESET = 0;
const int PASS_RESET = 1;
const int PASS_REPROJECT = 2;
const int PASS_BIN_CACHED = 3;
const int PASS_SELECT = 4;
const int PASS_PATCH = 5;
const int PASS_PREPARE = 6;
const int PASS_TRACE = 7;
const int PASS_ALLOCATE = 8;
const int PASS_REGISTER = 9;
const int PASS_POPULATE = 10;
const int PASS_ALLOCATE_SECONDARY = 11;
const int PASS_REGISTER_SECONDARY = 12;
const int PASS_LIGHT_BOUNDS_RESET = 13;
const int PASS_LIGHT_BOUNDS = 14;
const int PASS_LIGHT_GRID = 15;
const int PASS_SHADE_HITS = 16;
const int PASS_UPDATE = 17;
const int PASS_RESERVOIR_SCAN = 18;
const int PASS_RESERVOIR_SCAN_BLOCKS = 19;
const int PASS_RESERVOIR_SCAN_TOP = 20;
const int PASS_RESERVOIR_COMPACT = 21;
const int PASS_MIP1 = 22;
const int PASS_MIP2 = 23;
const int PASS_MIP3 = 24;
const int PASS_UPDATE_INDIRECT = 25;
const int PASS_INDIRECT_MIP1 = 26;
const int PASS_INDIRECT_MIP2 = 27;
const int PASS_INDIRECT_MIP3 = 28;
const int PASS_SHADE_INDIRECT_HITS = 29;
const int PASS_RESOLVE = 30;
const int PASS_FILTER_X = 33;
const int PASS_FILTER_Y = 34;
const int PASS_PROJECT = 35;
const int PASS_ORDER_CACHED = 31;
const int PASS_STORE_CACHED = 32;
const int PASS_MASK = 36;
const int PASS_INTERPOLATE = 37;
const int PASS_TEMPORAL = 38;
const int PASS_BLUR_X = 39;
const int PASS_BLUR_Y = 40;
const int PASS_REFLECTION_CLASSIFY = 41;
const int PASS_REFLECTION_BUILD_DISPATCH = 42;
const int PASS_REFLECTION_TRACE = 43;
const int PASS_REFLECTION_MARK_FIREFLIES = 44;
const int PASS_REFLECTION_CLEAN_FIREFLIES = 45;
const int PASS_REFLECTION_FIRST = 46;
const int PASS_REFLECTION_ITER = 47;
const int PASS_REFLECTION_LAST = 48;
const int PASS_REFLECTION_TEMPORAL = 49;
const int PASS_REFLECTION_OUTPUT = 50;
#include "../oct_inc.glsl"
#define AMD_GI_REFERENCE_RANDOM
#include "amd_gi_cache_inc.glsl"
#include "amd_gi_sampling_inc.glsl"
#include "rt_gi_transport_inc.glsl"
layout(set = 0, binding = 37) uniform sampler2D sky_radiance;

layout(set = 0, binding = 31, std430) restrict readonly buffer BlueNoise {
	uint data[];
}
blue_noise;

// Independent world-space reservoir hash, double-buffered each frame.
// Logical arrays share a descriptor; see amd_gi_reservoirs_inc.glsl.
layout(set = 0, binding = 32, std430) restrict buffer PreviousLightReservoirs {
	uint data[];
}
previous_light_reservoirs;
layout(set = 0, binding = 48) uniform sampler2D previous_surface_position;
layout(set = 0, binding = 52) uniform sampler2D geometry_normal_buffer;
layout(set = 0, binding = 53) uniform sampler2D primary_material_buffer;

vec3 previous_surface(ivec2 pixel, vec3 current) {
	vec4 previous = texelFetch(previous_surface_position, pixel, 0);
	return previous.w > 0.0 ? previous.xyz : current;
}
layout(set = 0, binding = 44, std430) restrict buffer LightGrid {
	uint remap[263172];
	uvec4 minimum;
	uvec4 maximum;
	uvec4 data[]; // selected light, selected weight, total weight, reserved
}
light_grid;

layout(set = 0, binding = 33, std430) restrict buffer LightReservoirs {
	uint data[];
}
light_reservoirs;

// Capsaicin BlueNoiseSampler::rand2. Interpolation starts at dimension 1,
// glossy rays at dimension 2, and reflection filtering at dimension 0.
vec2 lookup_jitter(ivec2 pixel, uint dimension) {
	uint index = uint((pixel.x & 127) + (pixel.y & 127) * 128);
	uint packed = blue_noise.data[index] >> (dimension * 8u);
	vec2 sample_value = (vec2(packed & 255u, (packed >> 8u) & 255u) + 0.5) / 256.0;
	return fract(sample_value + float(params.padding & 255u) * 1.61803398874989484820);
}

layout(set = 0, binding = 10, std140) uniform Frame {
	mat4 previous_view_projection;
	vec4 previous_eye;
	vec4 previous_forward;
	mat4 view_projection;
	uvec4 grid;
	vec4 settings;
	uvec4 flags;
	uvec4 tracing;
	mat3 world_to_sky;
	vec4 sky;
	vec4 ambient;
	vec4 reflections;
	uvec4 cache_config;
	vec4 glossy;
	uvec4 motion;
	uvec4 emitters;
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
	uvec4 dispatch; // group XYZ, active_index tile count
	Tile data[];
}
keys;
layout(set = 0, binding = 17, std430) buffer PreviousCache {
	uvec2 data[];
}
previous_cache;
layout(set = 0, binding = 18, std430) buffer Cache {
	uvec2 data[];
}
cache;
layout(set = 0, binding = 34, std430) coherent buffer PendingIndirectCache {
	uvec4 data[];
}
pending_indirect_cache;
layout(set = 0, binding = 35, std430) buffer IndirectCache {
	uvec2 data[];
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
layout(r16f, set = 0, binding = 49) uniform restrict image2D denoiser_blur_mask;
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
layout(set = 0, binding = 27, std430) buffer CachedProbes {
	CachedProbe data[];
}
cached_probes;
layout(set = 0, binding = 28, std430) buffer CachedState {
	uvec4 data[]; // unused, touched this frame, update owner, bin linked-list next
}
cached_state;
layout(set = 0, binding = 29, std430) buffer PreviousCachedOrder {
	uint data[];
}
previous_cached_order;
layout(set = 0, binding = 30, std430) restrict writeonly buffer CachedOrder {
	uint data[];
}
cached_order;
#define CACHED_PROBES (frame.grid.x * frame.grid.y)
const uint INVALID = 0xffffffffu;
#define TILE_COUNT (frame.cache_config.x * frame.cache_config.y)
const uint TILE_CELLS = 85u;
const uint MIP_OFFSET[4] = uint[](0u, 64u, 80u, 84u);

uint pcg(uint v) {
	v = v * 747796405u + 2891336453u;
	uint word = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	return (word >> 22u) ^ word;
}
uint gi_random(uint seed) {
	uint increment = (params.padding << 1u) | 1u;
	return (blue_noise.data[16385u + seed % blue_noise.data[16384u]] + increment) * 747796405u + increment;
}
vec3 clean_color(vec3 v) {
	return any(isnan(v)) || any(isinf(v)) ? vec3(0) : clamp(v, vec3(0), vec3(60000));
}
float luma(vec3 v) {
	return dot(v, vec3(0.2126, 0.7152, 0.0722));
}
mat3 basis(vec3 n) {
	// Capsaicin math/sampling.hlsl:GetOrthoVectors.
	bool select_z = abs(n.z) > 0.0;
	vec3 p = select_z ? n : n.zyx;
	float k = inversesqrt(p.z * p.z + n.y * n.y);
	vec3 b1 = vec3(0.0, -p.z * k, n.y * k);
	b1 = select_z ? b1 : b1.zyx;
	return mat3(b1, cross(n, b1), n);
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
bool shading_surface(ivec2 pixel, out vec3 position, out vec3 normal) {
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
bool surface(ivec2 pixel, out vec3 position, out vec3 normal) {
	if (!shading_surface(pixel, position, normal)) {
		return false;
	}
	normal = normalize(texelFetch(geometry_normal_buffer, pixel, 0).xyz);
	return true;
}
vec3 shading_normal(ivec2 pixel) {
	vec3 position, normal;
	shading_surface(pixel, position, normal);
	return normal;
}
float footprint(vec3 p) {
	return distance(p, params.camera_position.xyz) * tan(frame.settings.y * 8.0);
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
// Reference bucket/checksum collision search; keys are retained for diagnostics.
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
	uint bits = uint(key.w);
	uint level = uint(int(bits << 24u) >> 24);
	return max(1u, gi_cache_xxhash(level + gi_cache_xxhash(uint(key.x) + gi_cache_xxhash(uint(key.y) + gi_cache_xxhash(uint(key.z) + gi_cache_xxhash(((bits >> 8u) & 7u) + gi_cache_xxhash(((bits >> 11u) & 7u) + gi_cache_xxhash(((bits >> 14u) & 7u) + gi_cache_xxhash(bits >> 17u)))))))));
}
uint key_bucket(ivec4 key) {
	uint bits = uint(key.w);
	uint level = uint(int(bits << 24u) >> 24);
	return pcg(level + pcg(uint(key.x) + pcg(uint(key.y) + pcg(uint(key.z) + pcg(((bits >> 8u) & 7u) + pcg(((bits >> 11u) & 7u) + pcg(((bits >> 14u) & 7u) + pcg(bits >> 17u)))))))) % frame.cache_config.x;
}
uint find_tile(ivec4 key) {
	uint hash = key_hash(key), bucket = key_bucket(key) * frame.cache_config.y;
	for (uint i = 0u; i < frame.cache_config.y; i++) {
		uint t = bucket + i;
		if (keys.data[t].state.x == hash) {
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
		vec4 value = gi_cache_unpack(indirect ? indirect_cache.data[index] : (previous ? previous_cache.data[index] : cache.data[index]));
		// GI-1 chooses the finest mip with enough accumulated samples.
		// A merely nonempty fine cell still contains a noisy single estimate.
		if (value.w >= 16.0 || mip == 3u) {
			return vec4(value.rgb / max(value.w, 1.0), value.w);
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
	uint instance, primitive;
	bool front_face;
	vec3 position, uv, normal;
	if (trace(origin, direction, params.max_distance, 0u, instance, position, uv, normal, primitive, front_face)) {
		ray.position = vec4(position, length(position - origin));
		ray.normal_mask = vec4(faceforward(normal, direction, normal), uintBitsToFloat(hits.data[instance].z));
		// GI-1's GenerateReservoirs/GenerateMultibounceReservoirs force rough
		// diffuse secondary shading, including metallic hits, to avoid nested
		// specular sampling. Preserve base color here: multiplying by (1-metal)
		// would make every off-screen metal receiver a black energy sink.
		// The primary forward material still applies its native metalness/BRDF.
		ray.diffuse = vec4(textureLod(albedo_atlas, uv, 0).rgb, 0);
		ray.emission = front_face ? textureLod(emission_atlas, uv, 0) : vec4(0);
		uint emitter = hits.data[instance].y & 0x3fffffffu;
		ray.emission.w = emitter != 0u ? float(emitter + primitive) : 0.0;
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
struct HitSample {
	vec4 direct;
	vec4 indirect;
	uvec4 links; // next hit in this cell; remaining components reserved
};
layout(set = 0, binding = 46, std430) restrict buffer HitSamples {
	HitSample data[];
}
hit_samples;
uint cell_head(uint cell) {
	return owners.data[TILE_COUNT * TILE_CELLS + cell];
}

void reset_cache(uint lane) {
	uint tile = gl_WorkGroupID.x * 64u + lane;
	if (tile == 0u) {
		queues.counts = uvec4(0);
		keys.dispatch = uvec4(0, 1, 1, 0);
		if (frame.emitters.w != 0u) {
			queues.data[frame.emitters.z + 3u] = 0u;
		}
	}
	bool reset_tile = tile < TILE_COUNT && (frame.grid.w != 0u || (keys.data[tile].state.x != 0u && params.padding - keys.data[tile].state.y > 50u));
	if (reset_tile) {
		keys.data[tile].state = uvec4(0);
		for (uint local = 0u; local < TILE_CELLS; local++) {
			uint index = tile * TILE_CELLS + local;
			cache.data[index] = uvec2(0);
			if (params.bounces != 0u) {
				indirect_cache.data[index] = uvec2(0);
				if (local < 64u) {
					pending_indirect_cache.data[tile * 64u + local] = uvec4(0);
				}
			}
		}
	}
	uint cached = tile;
	if (frame.flags.w != 0u && cached < CACHED_PROBES) {
		cached_state.data[cached] = uvec4(0, 0, INVALID, INVALID);
		if (frame.grid.w != 0u) {
			previous_cached_order.data[cached] = cached;
			cached_probes.data[cached].probe.position.w = 0.0;
		}
	}
}
uint previous_probe(vec3 p, vec3 normal, ivec2 pixel) {
	vec3 lookup_position = previous_surface(pixel, p);
	if (frame.grid.w != 0u) {
		return INVALID;
	}
	vec4 clip = frame.previous_view_projection * vec4(lookup_position, 1);
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
	if (old.position.w == 0.0 || dot(old.normal.xyz, normal) < 0.95 || abs(dot(delta, normal)) >= footprint(p)) {
		return INVALID;
	}
	return other;
}
shared vec4 spawn_position;
shared vec4 spawn_normal;
shared uint reused_probe;
shared uint center_reuse_count;
// Reference ScreenProbes_QuantizeRadiance: uint atomics support every
// candidate in the cached-probe lists, without a fixed candidate-array limit.
shared uvec4 bin_sum[64];
shared uint bin_count[64];
shared vec4 bin_value[64];
shared uint cached_match;
shared float sampling_cdf[64];
shared float sampling_total;
shared vec4 radiance_backup;
void clear_bins(uint lane) {
	bin_sum[lane] = uvec4(0);
	bin_count[lane] = 0u;
	barrier();
}
void insert_bin(uint cell, uint lane, vec4 value) {
	uvec4 quantized = uvec4(round(value * 10000.0));
	atomicAdd(bin_sum[cell].x, quantized.x);
	atomicAdd(bin_sum[cell].y, quantized.y);
	atomicAdd(bin_sum[cell].z, quantized.z);
	atomicAdd(bin_sum[cell].w, quantized.w);
	atomicAdd(bin_count[cell], 1u);
}
vec4 sum_bin(uint cell, out uint count) {
	count = bin_count[cell];
	return vec4(bin_sum[cell]) / 10000.0;
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
	uint previous = valid ? previous_probe(position, normal, ivec2(pixel)) : INVALID;
	candidate_position[lane] = vec4(position, valid ? 1.0 : 0.0);
	candidate_normal[lane] = vec4(normal, 0);
	previous_index[lane] = previous;
	if (lane == 0u) {
		candidate_score = INVALID;
		candidate_lane = INVALID;
	}
	barrier();
	if (valid && previous != INVALID) {
		uint score = ((packHalf2x16(vec2(distance(position, previous_probes.data[previous].position.xyz) / footprint(position), 0.0)) & 0xffffu) << 16u) | lane;
		atomicMin(candidate_score, score);
	}
	barrier();
	if (lane == 0u) {
		candidate_lane = candidate_score == INVALID ? INVALID : candidate_score & 0xffffu;
		vec4 p = candidate_position[candidate_lane == INVALID ? 0u : candidate_lane];
		vec4 n = candidate_normal[candidate_lane == INVALID ? 0u : candidate_lane];
		reused_probe = candidate_lane == INVALID ? INVALID : previous_index[candidate_lane];
		spawn_position = p;
		spawn_normal = n;
		probes.data[probe].position = vec4(p.xyz, reused_probe != INVALID ? 1.0 : 0.0);
		probes.data[probe].normal = n;
		queues.data[cached_heads_offset() + probe] = INVALID;
		queues.data[eviction_owners_offset() + probe] = INVALID;
		probes.data[probe].state = uvec4(tile * 8u + (candidate_lane == INVALID ? uvec2(0) : uvec2(candidate_lane % 8u, candidate_lane / 8u)), reused_probe == INVALID ? 0u : previous_probes.data[reused_probe].state.z, reused_probe);
	}
	barrier();
	clear_bins(lane);
	if (reused_probe != INVALID) {
		vec4 old = previous_radiance.data[reused_probe * 64u + lane];
		vec3 direction = basis(previous_probes.data[reused_probe].normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		vec3 delta = previous_probes.data[reused_probe].position.xyz + direction * old.w - spawn_position.xyz;
		float d = length(delta);
		if (old.w > 0.0 && d > 0.0001 && dot(delta, spawn_normal.xyz) > 0.0) {
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
	if (lane < 9u && reused_probe != INVALID) {
		probes.data[probe].sh[lane] = previous_probes.data[reused_probe].sh[lane];
	}
	vec4 backup = vec4(total.rgb / (max(total.w, 1.0) * max(64.0 - total.w, 1.0)), params.max_distance);
	radiance.data[probe * 64u + lane] = gi_cache_unpack(gi_cache_pack(count > 0u ? sum / float(count) : backup));
}

// Bin cached world positions into the current screen grid for bounded
// neighborhood lookup. Entries outside the screen remain resident until eviction.
void bin_cached_probe(uint index) {
	if (index >= CACHED_PROBES || cached_probes.data[index].probe.position.w == 0.0) {
		return;
	}
	vec4 clip = frame.view_projection * vec4(cached_probes.data[index].probe.position.xyz, 1);
	vec2 uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	if (clip.w <= 0.0 || clip.z <= 0.0 || clip.z >= clip.w || any(lessThanEqual(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
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
				if (dot(candidate.normal.xyz, n) > 0.95 && abs(dot(delta, n)) < footprint(p) && distance < best) {
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
	uvec2 jitter = min(uvec2(vec2(radical_inverse((params.padding & 255u) + 1u, 2u), radical_inverse((params.padding & 255u) + 1u, 3u)) * float(frame.grid.z)), uvec2(frame.grid.z - 1u));
	uvec2 seed = min(region * frame.grid.z + jitter, params.size - 1u);
	uint selected = probe_index(ivec2(seed / 8u));
	vec3 p, n;
	bool found = surface(ivec2(seed), p, n);
	uint span = frame.grid.z / 8u;
	spawn.data[slot] = uvec4(found ? selected : INVALID, seed, INVALID);
	bool reusable = found && probes.data[selected].position.w > 0.0;
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
	if (frame.tracing.z == 0u || index >= queues.counts.x || queues.counts.y == 0u) {
		return;
	}
	uint hole = queues.data[index];
	uvec2 jitter = min(uvec2(vec2(radical_inverse((params.padding & 255u) + 1u, 2u), radical_inverse((params.padding & 255u) + 1u, 3u)) * 8.0), uvec2(7));
	uvec2 seed = min(uvec2(hole % frame.grid.x, hole / frame.grid.x) * 8u + jitter, params.size - 1u);
	vec3 p, n;
	if (!surface(ivec2(seed), p, n)) {
		return;
	}
	uint rng = gi_random(index);
	uint slot = queues.data[frame.grid.x * frame.grid.y + random_bits(rng) % queues.counts.y];
	// Reference atomic exchange permits competing holes to overwrite one slot.
	// Publish one packed seed so competing invocations cannot tear the pair.
	atomicExchange(spawn.data[slot].w, seed.x | (seed.y << 16u));
}

void prepare_probe(uint slot, uint lane) {
	if (lane == 0u && spawn.data[slot].w != INVALID) {
		uvec2 seed = uvec2(spawn.data[slot].w & 0xffffu, spawn.data[slot].w >> 16u);
		spawn.data[slot] = uvec4(probe_index(ivec2(seed / 8u)), seed, INVALID);
	}
	memoryBarrierBuffer();
	barrier();
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
		center_reuse_count = 0u;
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
				if (old_probe.position.w == 0.0 || abs(dot(old_probe.position.xyz - spawn_position.xyz, spawn_normal.xyz)) > footprint(spawn_position.xyz)) {
					continue;
				}
				vec4 old = radiance.data[previous * 64u + lane];
				vec3 direction = basis(old_probe.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
				vec3 delta = old_probe.position.xyz + direction * old.w - spawn_position.xyz;
				float d = length(delta);
				if (old.w > 0.0 && d > 0.0001 && dot(delta, spawn_normal.xyz) > 0.0) {
					uint sample_index = uint(x + 1 + (y + 1) * 3) * 64u + lane;
					insert_bin(angular_index(delta / d, spawn_normal.xyz), sample_index, vec4(old.rgb, d));
				}
			}
		}
	}
	if (frame.flags.w != 0u && spawn_position.w > 0.0) {
		ivec2 center = ivec2(spawn.data[slot].yz / 8u);
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				uint cell = probe_index(center + ivec2(x, y));
				if (cell == INVALID) {
					continue;
				}
				for (uint index = queues.data[cached_heads_offset() + cell]; index != INVALID; index = cached_state.data[index].w) {
					Probe cached = cached_probes.data[index].probe;
					if (abs(dot(cached.position.xyz - spawn_position.xyz, spawn_normal.xyz)) >= footprint(spawn_position.xyz)) {
						continue;
					}
					vec4 old = cached_probes.data[index].radiance[lane];
					vec3 direction = basis(cached.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
					vec3 delta = cached.position.xyz + direction * old.w - spawn_position.xyz;
					float d = length(delta);
					if (old.w > 0.0 && d > 0.0 && dot(delta, spawn_normal.xyz) > 0.0) {
						insert_bin(angular_index(delta / d, spawn_normal.xyz), lane, vec4(old.rgb, d));
					}
				}
			}
		}
	}
	barrier();
	if (frame.flags.w != 0u && spawn_position.w > 0.0) {
		if (lane == 0u) {
			Probe old = probes.data[probe];
			if (center_reuse_count == 0u && old.position.w > 0.0) {
				uint cached = find_cached_probe(old.position.xyz, old.normal.xyz, ivec2(spawn.data[slot].yz));
				if (cached == INVALID) {
					uint index = atomicAdd(queues.counts.z, 1u);
					queues.data[eviction_queue_offset() + index] = slot;
					spawn.data[slot].w = probe;
				} else if (atomicCompSwap(cached_state.data[cached].z, INVALID, 0x40000000u | slot) == INVALID) {
					cached_state.data[cached].y = 1u;
					spawn.data[slot].w = probe;
				}
			}
			cached_match = find_cached_probe(spawn_position.xyz, spawn_normal.xyz, ivec2(spawn.data[slot].yz));
			if (cached_match != INVALID) {
				atomicCompSwap(cached_state.data[cached_match].z, INVALID, slot);
			}
		}
		memoryBarrierBuffer();
		barrier();
		if (spawn.data[slot].w != INVALID) {
			if (lane == 0u) {
				cached_probes.data[CACHED_PROBES + slot].probe = probes.data[probe];
			}
			cached_probes.data[CACHED_PROBES + slot].radiance[lane] = radiance.data[probe * 64u + lane];
		}
	}
	uint reused_count;
	vec4 history = sum_bin(lane, reused_count);
	history = reused_count > 0u ? history / float(reused_count) : vec4(0, 0, 0, -1);
	uint id = probe * 64u + lane;
	scratch.data[id] = history;
}

// Shared with the separate glossy path below. Probe guiding changes angular
// allocation only; radiance reconstruction still stores incident radiance.
float reflection_kernel(vec3 n, vec3 v, vec3 l, float roughness);
void trace_probe(uint slot, uint lane) {
	uint ray_id = slot * 64u + lane;
	if (frame.motion.y != 0u) {
		hit_samples.data[ray_id].direct = vec4(0);
		hit_samples.data[ray_id].links.y = 0u;
		hit_samples.data[ray_id].indirect = vec4(0);
		if (params.bounces != 0u) {
			hit_samples.data[ray_id + primary_ray_count()].direct = vec4(0);
		}
	}
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
		uint state = gi_random(ray_id);
		vec2 samples = vec2(random_float(state), random_float(state));
		ivec2 pixel = ivec2(spawn.data[slot].yz);
		vec4 material = texelFetch(primary_material_buffer, pixel, 0);
		float metalness = material.a;
		float roughness = texelFetch(normal_buffer, pixel, 0).w;
		roughness = clamp((roughness > 0.5 ? 1.0 - roughness : roughness) * (255.0 / 127.0), 0.0, 1.0);
		vec3 view = normalize(params.camera_position.xyz - spawn_position.xyz);
		vec3 shading = shading_normal(pixel);
		float smoothness = clamp(1.0 - roughness, 0.0, 1.0);
		vec3 specular_direction = normalize(mix(shading, reflect(-view, shading), smoothness * (sqrt(smoothness) + roughness)));
		float hv = clamp(dot(normalize(view + specular_direction), view), 0.0, 1.0);
		vec3 f0 = mix(vec3(0.04), material.rgb, metalness);
		vec3 fresnel = f0 + (vec3(1) - f0) * pow(1.0 - hv, 5.0);
		vec3 diffuse = material.rgb * (1.0 - metalness) * (vec3(1) - fresnel) * 1.05 * (1.0 - pow(1.0 - hv, 5.0));
		float probability = luma(fresnel) / max(luma(fresnel + diffuse), 1e-20);
		vec3 dir;
		if ((uint(frame.sky.w) & 2u) != 0u && random_float(state) < probability) {
			vec4 rotation = gi_rotation_z(spawn_normal.xyz);
			vec3 local_view = gi_rotate(rotation, view);
			vec3 microfacet = gi_sample_ggx_bounded(max(roughness * roughness, 1e-6), local_view, samples);
			rotation.xyz = -rotation.xyz;
			dir = normalize(gi_rotate(rotation, reflect(-local_view, microfacet)));
		} else {
			uint cell = lane;
			if (frame.flags.y != 0u && history.w > 0.0 && sampling_total > 0.0) {
				cell = sample_cell(random_float(state));
			}
			vec2 jitter = vec2(random_float(state), random_float(state));
			dir = basis(spawn_normal.xyz) * hemi_direction((vec2(cell % 8u, cell / 8u) + jitter) / 8.0);
		}
		vec3 origin = gi_offset_position(spawn_position.xyz, spawn_normal.xyz);
		dir = gi_cache_unpack(gi_cache_pack(vec4(dir, 0))).xyz;
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
	uint hash = key_hash(key), bucket = key_bucket(key) * frame.cache_config.y;
	for (uint i = 0u; i < frame.cache_config.y; i++) {
		uint t = bucket + i;
		uint old = atomicCompSwap(keys.data[t].state.x, 0u, hash);
		if (old == 0u) {
			keys.data[t].key = key;
		}
		if (old == 0u || old == hash) {
			uint last_frame = atomicExchange(keys.data[t].state.y, params.padding);
			if (last_frame != params.padding) {
				// First touch clears update ownership before the following
				// register dispatch. No work scales with unused radiance cells.
				for (uint local = 0u; local < 64u; local++) {
					uint index = t * TILE_CELLS + local;
					owners.data[index] = INVALID;
					if (frame.motion.y != 0u) {
						owners.data[TILE_COUNT * TILE_CELLS + index] = INVALID;
					}
				}
				uint active_index = atomicAdd(keys.dispatch.w, 1u);
				keys.data[TILE_COUNT + active_index].state.x = t;
				atomicMax(keys.dispatch.x, min(active_index + 1u, 256u));
				atomicMax(keys.dispatch.y, (active_index + 256u) / 256u);
			}
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
		uint hit_id = secondary ? id + primary_ray_count() : id;
		atomicMin(owners.data[cell], hit_id);
		if (frame.motion.y != 0u) {
			hit_samples.data[hit_id].links.x = atomicExchange(owners.data[TILE_COUNT * TILE_CELLS + cell], hit_id);
		}
		atomicMax(keys.data[cell / TILE_CELLS].state.y, params.padding);
	}
}

#include "amd_gi_denoiser_inc.glsl"
// Prefix-scan passes are mutually exclusive; share their workgroup scratch
// to keep the complete shader within the 32 KiB shared-memory requirement.
shared uint prefix_scan[4096];
#include "amd_gi_reservoirs_inc.glsl"

// Light sampling calls the reservoir hash helpers above.
#include "amd_gi_lights_inc.glsl"
layout(set = 0, binding = 45) uniform sampler2D previous_lighting;

bool screen_lighting(RayHit hit, bool glossy, out vec3 outgoing) {
	outgoing = vec3(0);
	if (frame.grid.w != 0u || frame.settings.w <= 0.0) {
		return false;
	}
	vec4 clip = frame.view_projection * vec4(hit.position.xyz, 1);
	vec2 current_uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	if (clip.w <= 0.0 || any(lessThanEqual(current_uv, vec2(0))) || any(greaterThanEqual(current_uv, vec2(1)))) {
		return false;
	}
	ivec2 current_pixel = ivec2(current_uv * vec2(params.size));
	vec3 visible_position, visible_normal;
	if (!surface(current_pixel, visible_position, visible_normal)) {
		return false;
	}
	// Equivalent to current UV minus AMD's velocity. Native previous-surface
	// positions retain deformation and let us include both projections' jitter;
	// Godot's RG velocity excludes jitter and uses the opposite sign convention.
	vec4 visible_clip = frame.view_projection * vec4(visible_position, 1);
	vec4 previous_clip = frame.previous_view_projection * vec4(previous_surface(current_pixel, visible_position), 1);
	if (previous_clip.w <= 0.0) {
		return false;
	}
	vec2 uv = current_uv + (previous_clip.xy / previous_clip.w - visible_clip.xy / visible_clip.w) * 0.5;
	if (any(lessThanEqual(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
		return false;
	}
	ivec2 pixel = ivec2(uv * vec2(params.size));
	Pixel old = previous_pixels.data[uint(pixel.x) + uint(pixel.y) * params.size.x];
	float expected_depth = dot(hit.position.xyz - frame.previous_eye.xyz, frame.previous_forward.xyz);
	float previous_depth = dot(old.position.xyz - frame.previous_eye.xyz, frame.previous_forward.xyz);
	float normal_threshold = glossy ? 0.95 : 0.5;
	float depth_threshold = glossy ? 0.01 : 0.05;
	if (old.position.w != 1.0 || expected_depth <= 0.0 || dot(old.normal_delta.xyz, hit.normal_mask.xyz) <= normal_threshold || abs(previous_depth - expected_depth) / expected_depth >= depth_threshold) {
		return false;
	}
	vec4 value = texelFetch(previous_lighting, pixel, 0);
	if (value.a < 0.5) {
		return false;
	}
	if (frame.reflections.w > 0.0) {
		atomicAdd(queues.counts.w, 1u);
	}
	outgoing = clean_color(value.rgb / frame.settings.w);
	return true;
}

// Unregistered/short connections retain uncached evaluation. The normal cached
// path populates and shades secondary cells in explicit ordered stages below.
vec3 shade_transport(RayHit ray, uint state, uint cell) {
	// Cache misses and short primary connections use the same direct-light
	// estimator. Continuations are exclusively scheduled by PopulateCells;
	// retracing them here changed both the ray budget and path accounting.
	return clean_color(shade_direct(ray, state, cell));
}

void populate_secondary(uint id) {
	uint owner;
	if (frame.motion.y != 0u) {
		owner = id;
		if (owner >= primary_ray_count() || floatBitsToUint(rays.data[owner].direction_cache.w) == INVALID) {
			return;
		}
	} else {
		if (id >= TILE_COUNT * TILE_CELLS || id % TILE_CELLS >= 64u) {
			return;
		}
		owner = owners.data[id];
		if (owner >= primary_ray_count()) {
			return;
		}
	}
	uint state = gi_random(owner);
	if (random_float(state) >= frame.settings.z) {
		return;
	}
	RayHit source = rays.data[owner];
	vec2 samples = vec2(random_float(state), random_float(state));
	float radius = sqrt(samples.x), angle = 2.0 * PI * samples.y;
	vec4 rotation = gi_rotation_z(source.normal_mask.xyz);
	rotation.xyz = -rotation.xyz;
	vec3 direction = normalize(gi_rotate(rotation, vec3(radius * cos(angle), radius * sin(angle), sqrt(1.0 - samples.x))));
	secondary_rays.data[owner] = trace_hit(gi_offset_position(source.position.xyz, source.normal_mask.xyz), direction);
}
RayHit owned_hit(uint owner) {
	if (owner < primary_ray_count()) {
		return rays.data[owner];
	}
	return secondary_rays.data[owner - primary_ray_count()];
}
// Every registered hit shades independently. Only the stable cell owner
// publishes a light reservoir; other hits use the same estimator without writes.
void shade_hit(uint id) {
	if (id >= primary_ray_count() * (params.bounces != 0u ? 2u : 1u)) {
		return;
	}
	RayHit hit = owned_hit(id);
	uint cell = floatBitsToUint(hit.direction_cache.w);
	if (hit.position.w <= 0.0 || cell == INVALID) {
		return;
	}
	vec3 feedback;
	if (id < primary_ray_count() && dot(hit.emission.rgb, hit.emission.rgb) == 0.0 && screen_lighting(hit, false, feedback)) {
		hit_samples.data[id].direct = vec4(feedback, 1);
		hit_samples.data[id].links.y = 1u;
		return;
	}
	uint state = gi_random(id);
	hit_samples.data[id].direct = id < primary_ray_count() && dot(hit.emission.rgb, hit.emission.rgb) > 0.0 ? vec4(0) : vec4(clean_color(shade_direct(hit, state, id)), 1);
}
vec3 indirect_hit(uint hit) {
	RayHit secondary = secondary_rays.data[hit];
	uint target = floatBitsToUint(secondary.direction_cache.w);
	if (secondary.position.w <= 0.0 || target == INVALID) {
		return vec3(0);
	}
	// UpdateMultibounceCells consumes the freshly updated direct cache only.
	// Emission and sky at this vertex are already included by NEE at its parent.
	vec3 outgoing = read_component(target, false, false).rgb;
	RayHit source = rays.data[hit];
	return clean_color(gi_rough_brdf(source.diffuse.rgb, source.normal_mask.xyz, -source.direction_cache.xyz, secondary.direction_cache.xyz) * outgoing / max(dot(source.normal_mask.xyz, secondary.direction_cache.xyz) / PI * frame.settings.z, 1e-20));
}
void shade_indirect_hit(uint id) {
	if (id >= primary_ray_count()) {
		return;
	}
	uint cell = floatBitsToUint(rays.data[id].direction_cache.w);
	RayHit secondary = secondary_rays.data[id];
	bool valid = cell != INVALID && secondary.position.w > 0.0 && floatBitsToUint(secondary.direction_cache.w) != INVALID;
	vec3 value = valid ? indirect_hit(id) : vec3(0);
	if (frame.motion.y != 0u) {
		hit_samples.data[id].indirect = vec4(value, valid ? 1.0 : 0.0);
	}
	if (!valid || (frame.motion.y == 0u && owners.data[cell] != id)) {
		return;
	}
	uint index = (cell / TILE_CELLS) * 64u + cell % TILE_CELLS;
	uvec3 quantized = gi_cache_quantize(value);
	atomicAdd(pending_indirect_cache.data[index].x, quantized.x);
	atomicAdd(pending_indirect_cache.data[index].y, quantized.y);
	atomicAdd(pending_indirect_cache.data[index].z, quantized.z);
	atomicAdd(pending_indirect_cache.data[index].w, 1u);
}
uvec2 blend_hit_samples(uvec2 old, uvec3 sum, uint count) {
	return gi_cache_pack(gi_cache_accumulate(gi_cache_unpack(old), vec4(vec3(sum) / 1000.0, float(count)), 16.0));
}

void update_indirect(uint cell) {
	uint local = cell % TILE_CELLS;
	if (cell >= TILE_COUNT * TILE_CELLS || local >= 64u) {
		return;
	}
	uint index = (cell / TILE_CELLS) * 64u + local;
	uvec4 pending = pending_indirect_cache.data[index];
	indirect_cache.data[cell] = blend_hit_samples(indirect_cache.data[cell], pending.xyz, pending.w);
	pending_indirect_cache.data[index] = uvec4(0);
}
void update_cell(uint cell) {
	if (cell >= TILE_COUNT * TILE_CELLS || cell % TILE_CELLS >= 64u) {
		return;
	}
	if (frame.motion.y != 0u) {
		uvec3 sum = uvec3(0);
		uint count = 0u;
		for (uint hit = cell_head(cell); hit != INVALID; hit = hit_samples.data[hit].links.x) {
			sum += gi_cache_quantize(hit_samples.data[hit].direct.rgb);
			count += uint(hit_samples.data[hit].direct.w);
		}
		if (keys.data[cell / TILE_CELLS].state.y == params.padding) {
			cache.data[cell] = blend_hit_samples(previous_cache.data[cell], sum, count);
		}
		return;
	}
	uint owner = owners.data[cell];
	if (owner == INVALID) {
		if (keys.data[cell / TILE_CELLS].state.y == params.padding) {
			cache.data[cell] = blend_hit_samples(previous_cache.data[cell], uvec3(0), 0u);
		}
		return;
	}
	uint state = gi_random(owner);
	vec3 value = shade_direct(owned_hit(owner), state, owner);
	cache.data[cell] = blend_hit_samples(previous_cache.data[cell], gi_cache_quantize(value), 1u);
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
			vec4 value = gi_cache_unpack(indirect ? indirect_cache.data[index] : cache.data[index]);
			sum += value;
		}
	}
	// Mips carry the sum of their children's evidence, not a second capped
	// temporal history. Preserve it for both mip selection and parent weights.
	uvec2 value = gi_cache_pack(sum);
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
		uint ray_id = slot * 64u + lane;
		bool feedback = frame.motion.y != 0u && hit_samples.data[ray_id].links.y != 0u;
		value = dot(ray.emission.rgb, ray.emission.rgb) > 0.0 ? ray.emission.rgb : (feedback ? hit_samples.data[ray_id].direct.rgb : (c.w > 0.0 ? c.rgb : (frame.motion.y != 0u ? hit_samples.data[ray_id].direct.rgb : shade_transport(ray, gi_random(ray_id), INVALID))));
		if (params.bounces != 0u && !feedback && dot(ray.emission.rgb, ray.emission.rgb) == 0.0) {
			RayHit secondary = secondary_rays.data[ray_id];
			if (secondary.position.w > 0.0 && secondary.position.w < cache_cell_size(secondary.position.xyz)) {
				value += frame.motion.y != 0u ? hit_samples.data[ray_id].indirect.rgb : indirect_hit(ray_id);
			}
		}
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
	radiance.data[id] = gi_cache_unpack(gi_cache_pack(vec4(clean_color(result.rgb), result.w)));
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
		scratch.data[id] = gi_cache_unpack(gi_cache_pack(value / weight));
	} else {
		radiance.data[id] = gi_cache_unpack(gi_cache_pack(value / weight));
	}
}
void project_probe(uint probe, uint lane) {
	if (lane == 0u) {
		probe_mask.data[probe] = probes.data[probe].position.w > 0.0 ? probe : INVALID;
	}
	if (lane >= 9u || probes.data[probe].state.z != params.padding) {
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
	probes.data[probe].sh[lane] = gi_cache_unpack(gi_cache_pack(vec4(value, 0)));
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
// Stable LRU partition over the reference screen-sized cached-probe pool.
// A chunked exclusive scan retains bounded workgroup scratch at every resolution.
shared uint lru_used;
shared uint lru_chunk_count;
void order_cached_probes(uint lane) {
	if (lane == 0u) {
		lru_used = 0u;
	}
	barrier();
	for (uint base = 0u; base < CACHED_PROBES; base += 4096u) {
		for (uint index = lane; index < 4096u; index += 64u) {
			prefix_scan[index] = base + index < CACHED_PROBES ? cached_state.data[previous_cached_order.data[base + index]].y : 0u;
		}
		barrier();
		for (uint stride = 1u; stride < 4096u; stride <<= 1u) {
			for (uint index = lane; index < 4096u / (2u * stride); index += 64u) {
				prefix_scan[2u * (index + 1u) * stride - 1u] += prefix_scan[(2u * index + 1u) * stride - 1u];
			}
			barrier();
		}
		if (lane == 0u) {
			lru_chunk_count = prefix_scan[4095];
			prefix_scan[4095] = 0u;
		}
		barrier();
		for (uint stride = 2048u; stride > 0u; stride >>= 1u) {
			for (uint index = lane; index < 4096u / (2u * stride); index += 64u) {
				uint a = (2u * index + 1u) * stride - 1u, b = 2u * (index + 1u) * stride - 1u;
				uint value = prefix_scan[a];
				prefix_scan[a] = prefix_scan[b];
				prefix_scan[b] += value;
			}
			barrier();
		}
		for (uint index = lane; index < min(4096u, CACHED_PROBES - base); index += 64u) {
			cached_state.data[previous_cached_order.data[base + index]].x = lru_used + prefix_scan[index];
		}
		barrier();
		if (lane == 0u) {
			lru_used += lru_chunk_count;
		}
		barrier();
	}
	memoryBarrierBuffer();
	barrier();
	uint unused = CACHED_PROBES - lru_used;
	uint allocated = min(queues.counts.z, unused);
	for (uint index = lane; index < CACHED_PROBES; index += 64u) {
		uint cached = previous_cached_order.data[index];
		uint prefix = cached_state.data[cached].x;
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
	if (cached >= CACHED_PROBES) {
		return;
	}
	uint owner = cached_state.data[cached].z;
	if (owner == INVALID) {
		return;
	}
	bool allocated = (owner & 0x80000000u) != 0u;
	bool evicted = (owner & 0xc0000000u) != 0u;
	uint slot = allocated ? queues.data[eviction_queue_offset() + (owner & 0x7fffffffu)] : owner & 0x3fffffffu;
	if (evicted) {
		if (lane == 0u) {
			cached_probes.data[cached].probe = cached_probes.data[CACHED_PROBES + slot].probe;
		}
		cached_probes.data[cached].radiance[lane] = cached_probes.data[CACHED_PROBES + slot].radiance[lane];
	} else {
		cached_probes.data[cached].radiance[lane] = radiance.data[spawn.data[slot].x * 64u + lane];
	}
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
	result.normal_delta = vec4(valid ? shading_normal(pixel) : vec3(0), 0);
	result.color = vec4(0, 0, 0, 1);
	if (valid) {
		// GI-1 jitters the lookup only when the new point remains on the
		// original surface plane. The source BRDF still uses the original pixel.
		ivec2 jitter = ivec2((lookup_jitter(pixel, 1u) * 2.0 - 1.0) * float(frame.grid.z));
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
					sum += weights[i] * probe_irradiance(indices[i], result.normal_delta.xyz);
				}
			}
			result.color = vec4(sum, result.position.w == 2.0 ? 0.0 : 1.0);
		}
	}
	pixels.data[id] = result;
}
void reproject_pixel(ivec2 pixel, uint id) {
	Pixel current = pixels.data[id];
	if (frame.flags.x == 0u) {
		imageStore(denoiser_blur_mask, pixel, vec4(0));
		return;
	}
	bool sky = current.position.w == 0.0;
	vec4 lighting = vec4(0);
	float delta = 0.0, weight = 0.0;
	// Native previous-surface data supplies Godot's velocity-based previous UV.
	// AMD's world-space history rejection below compares CURRENT world position.
	vec3 previous_position = previous_surface(pixel, current.position.xyz);
	vec4 clip = frame.previous_view_projection * vec4(previous_position, 1);
	vec2 uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	bool previous_uv_valid = !sky && frame.grid.w == 0u && clip.w > 0.0 && all(greaterThan(uv, vec2(0))) && all(lessThan(uv, vec2(1)));
	if (previous_uv_valid) {
		float cell_size = distance(params.camera_position.xyz, current.position.xyz) * tan(frame.settings.y * 8.0);
		float grazing = 1.0 - max(dot(normalize(params.camera_position.xyz - current.position.xyz), current.normal_delta.xyz), 0.0);
		cell_size *= mix(1.0, 5.0, pow(grazing, 6.0));
		ivec2 center = ivec2(uv * vec2(params.size));
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				// Reference uses a nearest clamp sampler at previous_uv + offset.
				ivec2 tap = center + ivec2(x, y);
				ivec2 p = clamp(tap, ivec2(0), ivec2(params.size) - 1);
				Pixel old = previous_pixels.data[uint(p.x) + uint(p.y) * params.size.x];
				if (old.position.w == 0.0 || old.color.w < 1.0) {
					continue;
				}
				if (distance(current.position.xyz, old.position.xyz) < cell_size && dot(current.normal_delta.xyz, old.normal_delta.xyz) > 0.95) {
					float w = clamp(1.0 - length(vec2(tap) + 0.5 - uv * vec2(params.size)) * 0.707107, 0.0, 1.0);
					lighting += old.color * w;
					delta += old.normal_delta.w * w;
					weight += w;
				}
			}
		}
		if (weight > 0.0) {
			float delta_sign = sign(delta);
			delta = gi_denoiser_remove_nans(vec4(abs(delta) / weight)).x * delta_sign;
			lighting = gi_denoiser_remove_nans(lighting / weight);
		}
	}
	float blur_mask;
	vec2 current_uv = (vec2(pixel) + 0.5) / vec2(params.size);
	current.color = gi_denoiser_accumulate(current.color, lighting, current_uv, sky, previous_uv_valid, delta, blur_mask);
	current.normal_delta.w = delta;
	pixels.data[id] = current;
	imageStore(denoiser_blur_mask, pixel, vec4(blur_mask / 8.0));
}

float gi_view_depth(vec3 position) {
	vec3 forward = vec3(0, 0, -1);
	forward += 2.0 * cross(params.camera_rotation.xyz, cross(params.camera_rotation.xyz, forward) + params.camera_rotation.w * forward);
	return dot(position - params.camera_position.xyz, forward);
}

void filter_pixel(ivec2 pixel, uint id) {
	Pixel center = pixels.data[id];
	vec4 lighting = pass_id == PASS_BLUR_X ? center.color : imageLoad(filter_image, pixel);
	float blur_mask = imageLoad(denoiser_blur_mask, pixel).x * 8.0;
	int radius = blur_mask > 0.0 ? int(max(blur_mask, 1.0) + 0.5) : 0;
	if (radius > 0) {
		float weight = 1.0;
		vec3 color = lighting.rgb / max(lighting.w, 1.0);
		float center_depth = gi_view_depth(center.position.xyz);
		for (int r = -radius; r <= radius; r++) {
			ivec2 p = clamp(pixel + (pass_id == PASS_BLUR_X ? ivec2(r, 0) : ivec2(0, r)), ivec2(0), ivec2(params.size) - 1);
			uint other = uint(p.x) + uint(p.y) * params.size.x;
			vec4 c = pass_id == PASS_BLUR_X ? pixels.data[other].color : imageLoad(filter_image, p);
			if (c.w > 0.0) {
				Pixel neighbor = pixels.data[other];
				// Reversed-Z sky has infinite linear view depth in Godot.
				float depth = neighbor.position.w > 0.0 ? gi_view_depth(neighbor.position.xyz) : 1e30;
				float w = gi_denoiser_filter_weight(lighting.w, center_depth, depth, center.normal_delta.xyz, neighbor.normal_delta.xyz);
				color += w * (c.rgb / max(c.w, 1.0));
				weight += w;
			}
		}
		lighting.rgb = (color / weight) * max(lighting.w, 1.0);
	}
	if (pass_id == PASS_BLUR_X) {
		imageStore(filter_image, pixel, lighting);
	} else {
		pixels.data[id].color = lighting;
		vec3 irradiance = lighting.rgb / max(lighting.w, 1.0);
		imageStore(output_diffuse, pixel, vec4((irradiance + frame.ambient.rgb) * params.exposure, center.position.w > 0.0 ? frame.ambient.a : 0.0));
	}
}
#include "amd_gi_reflections_inc.glsl"
void main() {
	uint lane = gl_LocalInvocationIndex;
	uint probe = gl_WorkGroupID.x;
	uint id = probe * 64u + lane;
	if (pass_id == PASS_UPDATE || pass_id == PASS_UPDATE_INDIRECT || (pass_id == PASS_POPULATE && frame.motion.y == 0u) || (pass_id >= PASS_MIP1 && pass_id <= PASS_MIP3) || (pass_id >= PASS_INDIRECT_MIP1 && pass_id <= PASS_INDIRECT_MIP3)) {
		uint active_index = gl_WorkGroupID.y * 256u + gl_WorkGroupID.x;
		if (active_index >= keys.dispatch.w) {
			return;
		}
		probe = keys.data[TILE_COUNT + active_index].state.x;
		id = probe * TILE_CELLS + lane;
	}
	if (pass_id == PASS_LIGHT_BOUNDS_RESET) {
		if (id == 0u) {
			light_grid.minimum = uvec4(0xffffffffu);
			light_grid.maximum = uvec4(0u);
		}
		return;
	}
	if (pass_id == PASS_LIGHT_BOUNDS) {
		light_grid_bounds(id);
		return;
	}
	if (pass_id == PASS_LIGHT_GRID) {
		build_light_grid(probe, lane);
		return;
	}
	if (pass_id == PASS_RESERVOIR_RESET) {
		reservoir_reset((gl_WorkGroupID.y * gl_NumWorkGroups.x + probe) * 64u + lane);
		return;
	}
	if (pass_id >= PASS_RESERVOIR_SCAN && pass_id <= PASS_RESERVOIR_SCAN_TOP) {
		reservoir_scan(probe, lane, uint(pass_id - PASS_RESERVOIR_SCAN));
		return;
	}
	if (pass_id == PASS_RESERVOIR_COMPACT) {
		reservoir_compact((gl_WorkGroupID.y * gl_NumWorkGroups.x + probe) * 64u + lane);
		return;
	}
	if (pass_id == PASS_REFLECTION_BUILD_DISPATCH) {
		if (lane == 0u) {
			uint groups = (queues.data[frame.emitters.z + 3u] + 63u) / 64u;
			queues.data[frame.emitters.z] = min(groups, 65535u);
			queues.data[frame.emitters.z + 1u] = max((groups + 65534u) / 65535u, 1u);
			queues.data[frame.emitters.z + 2u] = 1u;
		}
		return;
	}
	if (pass_id == PASS_REFLECTION_TRACE && frame.emitters.w != 0u) {
		id = (gl_WorkGroupID.y * 65535u + gl_WorkGroupID.x) * 64u + lane;
		if (id < queues.data[frame.emitters.z + 3u]) {
			uint sample_id = queues.data[frame.emitters.z + 4u + id];
			ivec2 pixel = ivec2(sample_id % uint(reflection_size().x), sample_id / uint(reflection_size().x));
			trace_reflection(pixel, sample_id);
		}
		return;
	}
	if (pass_id >= PASS_REFLECTION_CLASSIFY) {
		ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = pass_id >= PASS_REFLECTION_LAST ? ivec2(params.size) : reflection_size();
		if (any(greaterThanEqual(pixel, size))) {
			return;
		}
		uint reflection_id = pass_id >= PASS_REFLECTION_LAST ? uint(pixel.x) + uint(pixel.y) * params.size.x : reflection_index(pixel);
		if (pass_id == PASS_REFLECTION_CLASSIFY) {
			classify_reflection(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_TRACE) {
			trace_reflection(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_MARK_FIREFLIES) {
			mark_reflection_fireflies(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_CLEAN_FIREFLIES) {
			clean_reflection_fireflies(pixel, reflection_id);
		} else if (pass_id >= PASS_REFLECTION_FIRST && pass_id <= PASS_REFLECTION_LAST) {
			resolve_reflection(pixel, reflection_id);
		} else if (pass_id == PASS_REFLECTION_TEMPORAL) {
			temporal_reflection(pixel, reflection_id);
		} else {
			output_reflection_pixel(pixel, reflection_id);
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
	} else if (pass_id == PASS_SHADE_HITS) {
		shade_hit(id);
	} else if (pass_id == PASS_SHADE_INDIRECT_HITS) {
		shade_indirect_hit(id);
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
		store_cached_probe(gl_WorkGroupID.y * 65535u + probe, lane);
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
		} else if (pass_id == PASS_TEMPORAL) {
			reproject_pixel(pixel, pixel_id);
		} else {
			filter_pixel(pixel, pixel_id);
		}
	}
}
