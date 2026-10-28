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
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference_uvec2 : require
#extension GL_EXT_shader_16bit_storage : require
#extension GL_EXT_shader_explicit_arithmetic_types_int16 : require
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
const int pass_id = AMD_GI_PASS;
// Keep in the same order as AMDGI::Pass.
#define PASS_RESERVOIR_RESET 0
#define PASS_RESET 1
#define PASS_PURGE 2
#define PASS_REPROJECT 3
#define PASS_BIN_CACHED 4
#define PASS_SELECT 5
#define PASS_PATCH 6
#define PASS_COMPACT_PROBES 7
#define PASS_GATHER_PROBES 8
#define PASS_PREPARE 9
#define PASS_TRACE 10
#define PASS_ALLOCATE 11
#define PASS_REGISTER 12
#define PASS_POPULATE 13
#define PASS_ALLOCATE_SECONDARY 14
#define PASS_REGISTER_SECONDARY 15
#define PASS_LIGHT_GRID_DISPATCH 16
#define PASS_LIGHT_GRID 17
#define PASS_SHADE_HITS 18
#define PASS_UPDATE 19
#define PASS_RESERVOIR_SCAN 20
#define PASS_RESERVOIR_SCAN_BLOCKS 21
#define PASS_RESERVOIR_SCAN_TOP 22
#define PASS_RESERVOIR_COMPACT 23
#define PASS_MIP1 24
#define PASS_MIP2 25
#define PASS_MIP3 26
#define PASS_UPDATE_INDIRECT 27
#define PASS_INDIRECT_MIP1 28
#define PASS_INDIRECT_MIP2 29
#define PASS_INDIRECT_MIP3 30
#define PASS_SHADE_INDIRECT_HITS 31
#define PASS_RESOLVE 32
#define PASS_STORE_CACHED 33
#define PASS_ORDER_CACHED 34
#define PASS_MASK 35
#define PASS_FILTER_X 36
#define PASS_FILTER_Y 37
#define PASS_PROJECT 38
#define PASS_NEAR_FIELD 39
#define PASS_INTERPOLATE 40
#define PASS_TEMPORAL 41
#define PASS_BLUR_X 42
#define PASS_BLUR_Y 43
#define PASS_REFLECTION_CLASSIFY 44
#define PASS_REFLECTION_BUILD_DISPATCH 45
#define PASS_REFLECTION_TRACE 46
#define PASS_REFLECTION_MARK_FIREFLIES 47
#define PASS_REFLECTION_CLEAN_FIREFLIES 48
#define PASS_REFLECTION_FIRST 49
#define PASS_REFLECTION_ITER 50
#define PASS_REFLECTION_LAST 51
#define PASS_REFLECTION_TEMPORAL 52
#define PASS_REFLECTION_OUTPUT 53
#define PASS_VALIDATE_SOURCE 54
#define PASS_PREPARE_LIGHTS 55
#define PASS_PREPARE_LIGHT_MASKS 56
#define PASS_DEBUG_VIEW 57
#define PASS_DEBUG_STATS 58
#include "../oct_inc.glsl"
#define AMD_GI_REFERENCE_RANDOM
#define AMD_GI_EMITTER_STORAGE_OFFSET
#include "amd_gi_cache_inc.glsl"
#include "amd_gi_sampling_inc.glsl"
#include "rt_gi_transport_inc.glsl"
layout(set = 0, binding = 37) uniform samplerCube sky_radiance;

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
layout(set = 0, binding = 54, rgb10_a2) uniform image2D history_geometry_normal;
layout(set = 0, binding = 55) uniform sampler2D previous_geometry_normal;
layout(set = 0, binding = 58) uniform sampler2D temporal_auto_exposure;
layout(set = 0, binding = 60) uniform sampler2D primary_shading_normal;
layout(set = 0, binding = 61) uniform sampler2D primary_roughness;
layout(set = 0, binding = 59, std430) restrict buffer Work {
	uvec4 counts;
	uvec4 probe_dispatch;
	uvec4 primary_dispatch;
	uvec4 secondary_dispatch;
	uvec4 grid_dispatch;
	uint hit_indices[];
}
work;

vec3 previous_surface(ivec2 pixel, vec3 current) {
	vec4 previous = texelFetch(previous_surface_position, pixel, 0);
	return previous.w > 0.0 ? previous.xyz : current;
}
layout(set = 0, binding = 44, std430) restrict buffer LightGrid {
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
	mat4 previous_inverse_view_projection;
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
	vec4 near_field;
	vec4 glossy;
	uvec4 motion;
	uvec4 emitters;
	uvec4 options;
	uvec4 reflection_options;
	uvec4 debug_options;
	vec4 debug_settings;
	vec4 tuning;
}
frame;
#include "amd_gi_debug_counters_inc.glsl"
uint gi_emitter_storage_offset() {
	return frame.emitters.y;
}
struct Probe {
	vec4 position;
	vec4 normal;
	uvec2 sh[9];
	uvec4 state; // seed pixel, last traced frame, previous probe / scheduled update slot
};
// Persist the query hit and AMD's compact cached visibility separately. Cache
// placement/bounds use the unrounded query position; shading decodes half barycentrics.
struct RayRecord {
	vec4 position;
	vec4 direction_cache;
	uvec4 visibility; // instance/front-face, geometry, primitive, half barycentrics
};
struct RayHit {
	vec4 position;
	vec4 direction_cache;
	vec4 normal_mask;
	vec4 diffuse;
	vec4 emission;
	vec4 geometry_normal;
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
struct StoredPixel {
	vec4 position;
	uint normal;
	uint delta;
	uvec2 color;
};
StoredPixel pack_pixel(Pixel value) {
	uvec3 n = uvec3(round(clamp(value.normal_delta.xyz * 0.5 + 0.5, 0.0, 1.0) * 1023.0));
	return StoredPixel(value.position, n.x | (n.y << 10u) | (n.z << 20u), packHalf2x16(vec2(value.normal_delta.w, 0)), gi_cache_pack(value.color));
}
Pixel unpack_pixel(StoredPixel value) {
	vec3 normal = value.position.w > 0.0 ? vec3(uvec3(value.normal, value.normal >> 10u, value.normal >> 20u) & 1023u) / 1023.0 * 2.0 - 1.0 : vec3(0);
	return Pixel(value.position, vec4(normal, unpackHalf2x16(value.delta).x), gi_cache_unpack(value.color));
}

layout(set = 0, binding = 11, std430) restrict buffer Probes {
	Probe data[];
}
probes;
layout(set = 0, binding = 12, std430) restrict readonly buffer PreviousProbes {
	Probe data[];
}
previous_probes;
layout(set = 0, binding = 13, std430) restrict buffer Rays {
	RayRecord data[];
}
rays;
layout(set = 0, binding = 36, std430) restrict buffer SecondaryRays {
	RayRecord data[];
}
secondary_rays;
layout(set = 0, binding = 14, std430) restrict buffer Radiance {
	uvec2 data[];
}
radiance;
layout(set = 0, binding = 15, std430) restrict readonly buffer PreviousRadiance {
	uvec2 data[];
}
previous_radiance;
layout(set = 0, binding = 16, std430) coherent restrict buffer Keys {
	uvec4 dispatch; // group XYZ, active_index tile count
	uvec4 purge_dispatch;
	uvec4 occupied; // Ping-pong packed tile counts; lists share unused active-record lanes.
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
layout(set = 0, binding = 62, std430) coherent buffer PendingDirectCache {
	uvec4 data[];
}
pending_direct_cache;
layout(set = 0, binding = 35, std430) buffer IndirectCache {
	uvec2 data[];
}
indirect_cache;
layout(set = 0, binding = 19, std430) restrict buffer Owners {
	uint data[];
}
owners;
layout(set = 0, binding = 20, std430) restrict buffer Scratch {
	uvec2 data[];
}
scratch;
layout(set = 0, binding = 21, std430) restrict readonly buffer PreviousPixels {
	StoredPixel data[];
}
previous_pixels;
layout(set = 0, binding = 22, std430) restrict buffer Pixels {
	StoredPixel data[];
}
pixels;
layout(rgba16f, set = 0, binding = 23) uniform restrict image2D filter_image;
layout(r8_snorm, set = 0, binding = 49) uniform restrict image2D denoiser_blur_mask;
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
	uvec2 radiance[64];
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
	vec3 n = texelFetch(primary_shading_normal, pixel, 0).xyz * 2.0 - 1.0;
	if (d <= 0.0 || dot(n, n) < 0.01) {
		return false;
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.size);
	vec4 p = params.inv_view_projection * vec4(uv * 2.0 - 1.0, d, 1);
	position = p.xyz / p.w;
	normal = normalize(n);
	return true;
}
bool surface(ivec2 pixel, out vec3 position, out vec3 normal) {
	if (!shading_surface(pixel, position, normal)) {
		return false;
	}
	normal = normalize(texelFetch(geometry_normal_buffer, pixel, 0).xyz * 2.0 - 1.0);
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
	float desired = max(distance(params.camera_position.xyz, position) * tan(frame.settings.y * (32.0 * frame.tuning.z)), frame.settings.x);
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
	uvec3 e = uvec3(floor(position / cell_size) - floor(position / tile_size) * 8.0);
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
		if (keys.data[t].state.x == 0u) {
			break;
		}
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
		if (value.w >= frame.tuning.x || mip == 3u) {
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
vec3 environment_radiance_lod(vec3 direction, bool reflection, float lod) {
	float energy = reflection ? frame.sky.y : frame.sky.x;
	if (energy <= 0.0 || dot(direction, direction) < 0.5) {
		return vec3(0);
	}
	return textureLod(sky_radiance, frame.world_to_sky * direction, lod).rgb * energy;
}
vec3 environment_radiance(vec3 direction, bool reflection) {
	return environment_radiance_lod(direction, reflection, 0.0);
}
vec3 environment_radiance_cone(vec3 direction, float solid_angle) {
	return environment_radiance_lod(direction, false, gi_environment_lod(solid_angle, float(textureQueryLevels(sky_radiance))));
}
uint primary_ray_count() {
	return frame.tracing.x * frame.tracing.y * 64u;
}
RayRecord empty_ray() {
	RayRecord ray;
	ray.position = vec4(0, 0, 0, -1);
	ray.direction_cache = vec4(0, 0, 0, uintBitsToFloat(INVALID));
	ray.visibility = uvec4(INVALID);
	return ray;
}
RayRecord trace_record(vec3 origin, vec3 direction, out vec2 barycentrics) {
	RayRecord ray = empty_ray();
	ray.direction_cache.xyz = direction;
	uint instance, primitive;
	bool front_face;
	float hit_distance;
	vec3 position, uv, normal, geometry_normal;
	if (trace(origin, direction, params.max_distance, 0u, instance, position, uv, normal, primitive, front_face, hit_distance, geometry_normal, barycentrics)) {
		ray.position = vec4(origin + direction * hit_distance, hit_distance);
		// HashGridCache_PackVisibility stores x in the upper half, y in the lower.
		ray.visibility = uvec4(instance | (front_face ? 0u : 0x80000000u), 0, primitive, packHalf2x16(barycentrics.yx));
	}
	return ray;
}
RayHit decode_hit(RayRecord record, vec2 barycentrics) {
	RayHit ray;
	ray.position = record.position;
	ray.direction_cache = record.direction_cache;
	ray.normal_mask = vec4(0);
	ray.diffuse = vec4(0);
	ray.emission = vec4(0);
	ray.geometry_normal = vec4(0);
	if (record.position.w >= 0.0) {
		uint instance = record.visibility.x & 0x7fffffffu;
		bool front_face = (record.visibility.x & 0x80000000u) == 0u;
		uint primitive = record.visibility.z;
		GIHitData hit = hits.data[instance];
		vec3 v0, v1, v2;
		gi_triangle_vertices(instance, primitive, v0, v1, v2);
		vec3 local_geometry_normal = cross(v2 - v0, v1 - v0);
		vec3 local_normal = gi_triangle_normal(instance, primitive, barycentrics, local_geometry_normal);
		float orientation = front_face ? 1.0 : -1.0;
		ray.normal_mask = vec4(orientation * normalize(hit.normal_to_world * local_normal), uintBitsToFloat(hit.material.z));
		ray.geometry_normal = vec4(orientation * normalize(hit.normal_to_world * local_geometry_normal), 0);
		mat4x3 transform = transpose(hit.object_to_world);
		v0 = transform * vec4(v0, 1);
		v1 = transform * vec4(v1, 1);
		v2 = transform * vec4(v2, 1);
		ray.position.xyz = (1.0 - barycentrics.x - barycentrics.y) * v0 + barycentrics.x * v1 + barycentrics.y * v2;
		vec3 uv = atlas_position(instance, primitive, barycentrics);
		// GenerateReservoirs uses the source base color even for metallic hits;
		// the primary forward material retains its native metalness/BRDF.
		GISourceMaterial material = gi_source_material(instance, primitive, barycentrics, front_face, 0.0);
		ray.diffuse = vec4(material.albedo.rgb, 0);
		ray.emission = front_face ? material.emission : vec4(0);
		// Base-emissivity classification is separate from evaluated RGB.
		ray.emission.w = front_face && (hit.geometry.y & 16u) != 0u ? 1.0 : 0.0;
	}
	return ray;
}

RayRecord trace_record(vec3 origin, vec3 direction) {
	vec2 barycentrics;
	return trace_record(origin, direction, barycentrics);
}
RayHit trace_hit(vec3 origin, vec3 direction) {
	// The glossy path shades the original intersection, without the cache's
	// visibility-buffer handoff or barycentric rounding.
	vec2 barycentrics;
	RayRecord record = trace_record(origin, direction, barycentrics);
	return decode_hit(record, barycentrics);
}
RayHit load_hit(RayRecord record, vec3 origin) {
	RayHit ray = decode_hit(record, unpackHalf2x16(record.visibility.w).yx);
	if (record.position.w >= 0.0) {
		vec3 delta = ray.position.xyz - origin;
		ray.position.w = length(delta);
		ray.direction_cache.xyz = normalize(delta);
	}
	return ray;
}
RayHit primary_hit(uint id) {
	uint probe = spawn.data[id / 64u].x;
	vec3 origin = probe != INVALID ? probes.data[probe].position.xyz : vec3(0);
	return load_hit(rays.data[id], origin);
}
RayHit secondary_hit(uint id) {
	return load_hit(secondary_rays.data[id], primary_hit(id).position.xyz);
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
	uvec4 links; // next cell hit, feedback/emissive flags, compact hit ID, secondary bypass
};
layout(set = 0, binding = 46, std430) restrict buffer HitSamples {
	HitSample data[];
}
hit_samples;

void reset_light_bounds();
void register_light_bounds(vec3 position);

void reset_cache(uint lane) {
	uint tile = gl_WorkGroupID.x * 64u + lane;
	if (tile == 0u) {
		queues.counts = uvec4(0);
		work.counts = uvec4(0);
		work.probe_dispatch = uvec4(0, 1, 1, 0);
		work.primary_dispatch = uvec4(0, 1, 1, 0);
		work.secondary_dispatch = uvec4(0, 1, 1, 0);
		work.grid_dispatch = uvec4(0, 1, 1, 0);
		reset_light_bounds();
		keys.dispatch = uvec4(0, 1, 1, 0);
		if (frame.grid.w != 0u) {
			keys.occupied = uvec4(0);
		}
		uint previous_count = keys.occupied[(params.padding + 1u) & 1u];
		uint groups = (previous_count + 63u) / 64u;
		keys.purge_dispatch = uvec4(min(groups, 65535u), max((groups + 65534u) / 65535u, 1u), 1u, 0u);
		keys.occupied[params.padding & 1u] = 0u;
		if (frame.emitters.w != 0u) {
			queues.data[frame.emitters.z + 3u] = 0u;
		}
	}
	if (frame.grid.w != 0u && tile < TILE_COUNT) {
		keys.data[tile].state = uvec4(0);
	}
	uint cached = tile;
	if (frame.flags.w != 0u && cached < CACHED_PROBES) {
		cached_state.data[cached] = uvec4(0, 1, INVALID, INVALID);
		if (frame.grid.w != 0u) {
			previous_cached_order.data[cached] = cached;
			cached_probes.data[cached].probe.position.w = 0.0;
		}
	}
}
// PurgeHashGridCache visits occupied tiles, not the unused hash capacity.
// The two persistent index lists use key.x/key.y in the active-record tail;
// the frame-local active list separately uses state.x in those same records.
void purge_cache(uint id) {
	uint old_list = (params.padding + 1u) & 1u, new_list = params.padding & 1u;
	if (id >= keys.occupied[old_list]) {
		return;
	}
	uint tile = uint(keys.data[TILE_COUNT + id].key[old_list]);
	if (params.padding - keys.data[tile].state.y >= 50u) {
		keys.data[tile].state = uvec4(0);
		return;
	}
	keys.data[tile].state.z = 0u;
	uint slot = atomicAdd(keys.occupied[new_list], 1u);
	keys.data[TILE_COUNT + slot].key[new_list] = int(tile);
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
shared uint bin_distance_high[64];
shared uint bin_count[64];
shared vec4 bin_value[64];
shared uint cached_match;
shared uint prefix_scan[4096];
shared float sampling_cdf[64];
shared float sampling_total;
shared vec4 radiance_backup;
uvec2 pack_probe_radiance(vec4 value) {
	// Only screen-probe reprojection distance is bounded. World hit positions,
	// ray extents, RGB, sample counts and estimator weights stay unchanged.
	value.w = min(value.w, 65504.0);
	return gi_cache_pack(value);
}
void clear_bins(uint lane) {
	bin_sum[lane] = uvec4(0);
	bin_distance_high[lane] = 0u;
	bin_count[lane] = 0u;
	barrier();
}
void insert_bin(uint cell, uint lane, vec4 value) {
	uvec4 quantized = uvec4(round(vec4(value.rgb, min(value.w, 65504.0)) * 10000.0));
	atomicAdd(bin_sum[cell].x, quantized.x);
	atomicAdd(bin_sum[cell].y, quantized.y);
	atomicAdd(bin_sum[cell].z, quantized.z);
	// The approved distance-only overflow correction keeps RGB uint sums intact.
	uint previous = atomicAdd(bin_sum[cell].w, quantized.w);
	if (previous > 0xffffffffu - quantized.w) {
		atomicAdd(bin_distance_high[cell], 1u);
	}
	atomicAdd(bin_count[cell], 1u);
}
vec4 sum_bin(uint cell, out uint count) {
	count = bin_count[cell];
	return vec4(vec3(bin_sum[cell].xyz), float(bin_distance_high[cell]) * 4294967296.0 + float(bin_sum[cell].w)) / 10000.0;
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
	float target = sample_value * max(sampling_total, 1e-5);
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
		probe_mask.data[probe] = reused_probe != INVALID ? probe : INVALID;
		probes.data[probe].normal = n;
		queues.data[cached_heads_offset() + probe] = INVALID;
		queues.data[eviction_owners_offset() + probe] = 0u;
		probes.data[probe].state = uvec4(tile * 8u + (candidate_lane == INVALID ? uvec2(0) : uvec2(candidate_lane % 8u, candidate_lane / 8u)), reused_probe == INVALID ? 0u : previous_probes.data[reused_probe].state.z, reused_probe);
	}
	barrier();
	clear_bins(lane);
	if (reused_probe != INVALID) {
		vec4 old = gi_cache_unpack(previous_radiance.data[reused_probe * 64u + lane]);
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
	radiance.data[probe * 64u + lane] = pack_probe_radiance(count > 0u ? sum / float(count) : backup);
}

// Bin cached world positions into the current screen grid for bounded
// neighborhood lookup. Entries outside the screen remain resident until eviction.
void bin_cached_probe(uint rank) {
	if (rank >= CACHED_PROBES) {
		return;
	}
	uint index = previous_cached_order.data[rank];
	cached_state.data[index].x = rank;
	if (cached_probes.data[index].probe.position.w == 0.0) {
		return;
	}
	vec4 clip = frame.view_projection * vec4(cached_probes.data[index].probe.position.xyz, 1);
	vec2 uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	if (clip.w <= 0.0 || clip.z <= 0.0 || clip.z >= clip.w || any(lessThanEqual(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
		return;
	}
	uint cell = probe_index(ivec2(uv * vec2(frame.grid.xy)));
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

// Compact live spawn slots before assigning the reference per-ray RNG IDs.
// The scan is stable in tile order, as CompactScreenProbes' prefix scan is.
void compact_probes(uint lane) {
	uint capacity = frame.tracing.x * frame.tracing.y;
	for (uint base = 0u; base < capacity; base += 64u) {
		uint slot = base + lane;
		uint live = slot < capacity && (spawn.data[slot].x != INVALID || spawn.data[slot].w != INVALID) ? 1u : 0u;
		prefix_scan[lane] = live;
		barrier();
		for (uint stride = 1u; stride < 64u; stride <<= 1u) {
			uint value = lane >= stride ? prefix_scan[lane - stride] : 0u;
			barrier();
			prefix_scan[lane] += value;
			barrier();
		}
		if (live != 0u) {
			uvec4 source = spawn.data[slot];
			uint seed = source.w != INVALID ? source.w : source.y | (source.z << 16u);
			queues.data[eviction_queue_offset() + work.counts.x + prefix_scan[lane] - 1u] = seed;
		}
		memoryBarrierBuffer();
		barrier();
		if (lane == 0u) {
			work.counts.x += prefix_scan[63];
		}
		memoryBarrierBuffer();
		barrier();
	}
	if (lane == 0u) {
		work.probe_dispatch = uvec4(min(work.counts.x, 65535u), max((work.counts.x + 65534u) / 65535u, 1u), 1u, 0u);
	}
}
void gather_probe(uint slot) {
	if (slot >= work.counts.x) {
		spawn.data[slot] = uvec4(INVALID);
		return;
	}
	uint packed = queues.data[eviction_queue_offset() + slot];
	uvec2 seed = uvec2(packed & 0xffffu, packed >> 16u);
	spawn.data[slot] = uvec4(probe_index(ivec2(seed / 8u)), seed, INVALID);
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
				vec4 old = gi_cache_unpack(radiance.data[previous * 64u + lane]);
				vec3 direction = basis(old_probe.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
				vec3 delta = old_probe.position.xyz + direction * old.w - spawn_position.xyz;
				float d = length(delta);
				if (old.w > 0.0 && d > 0.0001 && dot(delta, spawn_normal.xyz) > 0.0) {
					if (x == 0 && y == 0) {
						atomicAdd(center_reuse_count, 1u);
					}
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
					vec4 old = gi_cache_unpack(cached_probes.data[index].radiance[lane]);
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
	scratch.data[id] = pack_probe_radiance(history);
}

// Shared with the separate glossy path below. Probe guiding changes angular
// allocation only; radiance reconstruction still stores incident radiance.
float reflection_kernel(vec3 n, vec3 v, vec3 l, float roughness);
void trace_probe(uint slot, uint lane) {
	uint ray_id = slot * 64u + lane;
	if (frame.motion.y != 0u) {
		hit_samples.data[ray_id].direct = vec4(0);
		hit_samples.data[ray_id].indirect = vec4(0);
		hit_samples.data[ray_id].links.y = 0u;
		if (params.bounces != 0u) {
			hit_samples.data[ray_id + primary_ray_count()].direct = vec4(0);
			hit_samples.data[ray_id + primary_ray_count()].links.w = 0u;
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
		probe_mask.data[probe] = spawn_position.w > 0.0 ? probe : INVALID;
		probes.data[probe].normal = spawn_normal;
		probes.data[probe].state = uvec4(spawn.data[slot].yz, params.padding, slot);
	}
	barrier();
	vec4 history = gi_cache_unpack(scratch.data[probe * 64u + lane]);
	if (frame.flags.y != 0u) {
		vec3 local_direction = hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		scan_radiance(lane, luma(history.rgb) * max(local_direction.z, 0.0));
	}
	RayRecord ray = empty_ray();
	if (spawn_position.w > 0.0) {
		uint state = gi_random(ray_id);
		vec2 samples = vec2(random_float(state), random_float(state));
		ivec2 pixel = ivec2(spawn.data[slot].yz);
		vec4 material = texelFetch(primary_material_buffer, pixel, 0);
		float metalness = material.a;
		float roughness = texelFetch(primary_roughness, pixel, 0).r;
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
			float cdf_sample = random_float(state);
			if (frame.flags.y != 0u && history.w > 0.0) {
				cell = sample_cell(cdf_sample);
			}
			vec2 jitter = vec2(random_float(state), random_float(state));
			dir = basis(spawn_normal.xyz) * hemi_direction((vec2(cell % 8u, cell / 8u) + jitter) / 8.0);
		}
		vec3 origin = gi_offset_position(spawn_position.xyz, spawn_normal.xyz);
		dir = gi_cache_unpack(gi_cache_pack(vec4(dir, 0))).xyz;
		ray = trace_record(origin, dir);
	}
	rays.data[ray_id] = ray;
}
void allocate_tile(uint id) {
	RayRecord ray = pass_id == PASS_ALLOCATE_SECONDARY ? secondary_rays.data[id] : rays.data[id];
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
			uint packed_index = atomicAdd(keys.occupied[params.padding & 1u], 1u);
			keys.data[TILE_COUNT + packed_index].key[params.padding & 1u] = int(t);
			// New tiles initialize mip zero; the subsequent mip passes rebuild
			// every parent. Retired/unused tiles need no radiance clear.
			for (uint local = 0u; local < 64u; local++) {
				cache.data[t * TILE_CELLS + local] = uvec2(0);
				if (params.bounces != 0u) {
					indirect_cache.data[t * TILE_CELLS + local] = uvec2(0);
					pending_indirect_cache.data[t * 64u + local] = uvec4(0);
				}
			}
		}
		if (old == 0u || old == hash) {
			atomicExchange(keys.data[t].state.y, params.padding);
			if (atomicExchange(keys.data[t].state.z, 1u) == 0u) {
				// First touch clears update ownership before the following
				// register dispatch. No work scales with unused radiance cells.
				for (uint local = 0u; local < 64u; local++) {
					uint index = t * TILE_CELLS + local;
					owners.data[index] = INVALID;
					if (frame.motion.y != 0u) {
#ifdef AMD_GI_DIAGNOSTIC_HITS
						owners.data[TILE_COUNT * TILE_CELLS + index] = INVALID;
#endif
						pending_direct_cache.data[t * 64u + local] = uvec4(0);
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
	debug_cache_overflow(bucket / frame.cache_config.y);
}
void register_ray(uint id) {
	bool secondary = pass_id == PASS_REGISTER_SECONDARY;
	RayRecord ray = secondary ? secondary_rays.data[id] : rays.data[id];
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
		register_light_bounds(ray.position.xyz);
		uint hit_id = secondary ? id + primary_ray_count() : id;
		atomicMin(owners.data[cell], hit_id);
		if (frame.motion.y != 0u) {
			uint compact_index = secondary ? atomicAdd(work.counts.z, 1u) : atomicAdd(work.counts.y, 1u);
			work.hit_indices[(secondary ? primary_ray_count() : 0u) + compact_index] = hit_id;
			hit_samples.data[hit_id].links.z = compact_index + (secondary ? work.counts.y : 0u);
			uint groups = (compact_index + 64u) / 64u;
			if (secondary) {
				atomicMax(work.secondary_dispatch.x, min(groups, 65535u));
				atomicMax(work.secondary_dispatch.y, (groups + 65534u) / 65535u);
			} else {
				atomicMax(work.primary_dispatch.x, min(groups, 65535u));
				atomicMax(work.primary_dispatch.y, (groups + 65534u) / 65535u);
			}
#ifdef AMD_GI_DIAGNOSTIC_HITS
			hit_samples.data[hit_id].links.x = atomicExchange(owners.data[TILE_COUNT * TILE_CELLS + cell], hit_id);
#endif
		}
		atomicMax(keys.data[cell / TILE_CELLS].state.y, params.padding);
	}
}

#include "amd_gi_denoiser_inc.glsl"
// Prefix-scan passes are mutually exclusive; share their workgroup scratch
// to keep the complete shader within the 32 KiB shared-memory requirement.

#include "amd_gi_reservoirs_inc.glsl"

// Light sampling calls the reservoir hash helpers above.
#include "amd_gi_lights_inc.glsl"
layout(set = 0, binding = 45) uniform sampler2D previous_lighting;

bool screen_lighting(RayHit hit, bool glossy, out vec3 outgoing) {
	outgoing = vec3(0);
	if (frame.grid.w != 0u || frame.settings.w <= 0.0 || (!glossy && (params.bounces != 0u || frame.motion.z == 0u))) {
		return false;
	}
	vec4 clip = frame.view_projection * vec4(hit.position.xyz, 1);
	vec2 current_uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	if (clip.w <= 0.0 || clip.z <= 0.0 || any(lessThanEqual(current_uv, vec2(0))) || any(greaterThanEqual(current_uv, vec2(1)))) {
		return false;
	}
	ivec2 current_pixel = ivec2(current_uv * vec2(params.size));
	vec3 visible_position, visible_normal;
	bool current_surface_valid = surface(current_pixel, visible_position, visible_normal);
	// Equivalent to current UV minus AMD's velocity. Native previous-surface
	// positions retain deformation and let us include both projections' jitter;
	// Godot's RG velocity excludes jitter and uses the opposite sign convention.
	vec2 uv = current_uv;
	if (current_surface_valid) {
		vec4 visible_clip = frame.view_projection * vec4(visible_position, 1);
		vec4 previous_clip = frame.previous_view_projection * vec4(previous_surface(current_pixel, visible_position), 1);
		if (previous_clip.w <= 0.0) {
			return false;
		}
		uv += (previous_clip.xy / previous_clip.w - visible_clip.xy / visible_clip.w) * 0.5;
	}
	if (any(lessThanEqual(uv, vec2(0))) || any(greaterThanEqual(uv, vec2(1)))) {
		return false;
	}
	ivec2 pixel = ivec2(uv * vec2(params.size));
	Pixel old = unpack_pixel(previous_pixels.data[uint(pixel.x) + uint(pixel.y) * params.size.x]);
	float expected_depth = dot(hit.position.xyz - frame.previous_eye.xyz, frame.previous_forward.xyz);
	float previous_depth = dot(old.position.xyz - frame.previous_eye.xyz, frame.previous_forward.xyz);
	float normal_threshold = glossy ? 0.95 : 0.5;
	float depth_threshold = glossy ? 0.01 : 0.05;
	if (old.position.w == 0.0 || expected_depth <= 0.0 || dot(normalize(texelFetch(previous_geometry_normal, pixel, 0).xyz * 2.0 - 1.0), hit.normal_mask.xyz) <= normal_threshold || abs(previous_depth - expected_depth) / expected_depth >= depth_threshold) {
		return false;
	}
	vec4 value = texelFetch(previous_lighting, pixel, 0);
	if (frame.reflections.w > 0.0) {
		atomicAdd(queues.counts.w, 1u);
	}
	outgoing = (value.rgb / frame.settings.w);
	return true;
}

// Unregistered/short connections retain uncached evaluation. The normal cached
// path populates and shades secondary cells in explicit ordered stages below.
vec3 shade_transport(RayHit ray, uint state, uint cell) {
	// Cache misses and short primary connections use the same direct-light
	// estimator. Continuations are exclusively scheduled by PopulateCells;
	// retracing them here changed both the ray budget and path accounting.
	return shade_direct(ray, state, cell);
}

void populate_secondary(uint id) {
	uint owner;
	if (frame.motion.y != 0u) {
		if (id >= work.counts.y) {
			return;
		}
		owner = work.hit_indices[id];
	} else {
		if (id >= TILE_COUNT * TILE_CELLS || id % TILE_CELLS >= 64u) {
			return;
		}
		owner = owners.data[id];
		if (owner >= primary_ray_count()) {
			return;
		}
	}
	uint state = gi_random(frame.motion.y != 0u ? hit_samples.data[owner].links.z : owner);
	if (random_float(state) <= 1.0 - frame.settings.z) {
		return;
	}
	RayHit source = primary_hit(owner);
	vec2 samples = vec2(random_float(state), random_float(state));
	float radius = sqrt(samples.x), angle = 2.0 * PI * samples.y;
	vec4 rotation = gi_rotation_z(source.normal_mask.xyz);
	rotation.xyz = -rotation.xyz;
	vec3 direction = normalize(gi_rotate(rotation, vec3(radius * cos(angle), radius * sin(angle), sqrt(1.0 - samples.x))));
	secondary_rays.data[owner] = trace_record(gi_offset_position(source.position.xyz, source.normal_mask.xyz), direction);
}
RayHit owned_hit(uint owner) {
	if (owner < primary_ray_count()) {
		return primary_hit(owner);
	}
	return secondary_hit(owner - primary_ray_count());
}
// AMD's per-hit integer atomics preserve every accepted contribution while
// eliminating the serial walk through all hits that share a cache cell.
void accumulate_direct(uint cell, vec4 value) {
	if (value.w == 0.0) {
		return;
	}
	uint index = (cell / TILE_CELLS) * 64u + cell % TILE_CELLS;
	uvec3 quantized = gi_cache_quantize(value.rgb);
	if (dot(value.rgb, value.rgb) > 0.0) {
		atomicAdd(pending_direct_cache.data[index].x, quantized.x);
		atomicAdd(pending_direct_cache.data[index].y, quantized.y);
		atomicAdd(pending_direct_cache.data[index].z, quantized.z);
	}
	atomicAdd(pending_direct_cache.data[index].w, uint(value.w));
}
void shade_hit(uint id) {
	if (id >= (params.samples == 0u ? work.counts.y : work.counts.z)) {
		return;
	}
	id = work.hit_indices[id + params.samples * primary_ray_count()];
	RayHit hit = owned_hit(id);
	uint cell = floatBitsToUint(hit.direction_cache.w);
	if (hit.position.w < 0.0 || cell == INVALID) {
		return;
	}
	vec3 feedback;
	if (id < primary_ray_count() && hit.emission.w == 0.0 && screen_lighting(hit, false, feedback)) {
		hit_samples.data[id].direct = vec4(feedback, 1);
		hit_samples.data[id].links.y = 1u | 4u;
		accumulate_direct(cell, vec4(feedback, 1));
		return;
	}
	uint state = gi_random(hit_samples.data[id].links.z);
	bool emissive = id < primary_ray_count() && hit.emission.w > 0.0;
	hit_samples.data[id].links.y = emissive ? 2u : 0u;
	bool valid_update = false;
	vec3 value = emissive ? vec3(0) : shade_direct(hit, state, id, valid_update);
	hit_samples.data[id].links.y |= valid_update ? 4u : 0u;
	vec4 direct = vec4(value, valid_update ? 1.0 : 0.0);
	hit_samples.data[id].direct = direct;
	accumulate_direct(cell, direct);
}
vec3 indirect_hit(uint hit) {
	RayHit secondary = secondary_hit(hit);
	uint target = floatBitsToUint(secondary.direction_cache.w);
	if (secondary.position.w < 0.0 || target == INVALID) {
		return vec3(0);
	}
	// UpdateMultibounceCells consumes the freshly updated direct cache only.
	// Emission and sky at this vertex are already included by NEE at its parent.
	vec3 outgoing = read_component(target, false, false).rgb;
	RayHit source = primary_hit(hit);
	// HashGridCache_MultibounceInfo is evaluated when the continuation is
	// sampled, before its intersection is packed. Reconstructed hit positions
	// must not change that sampled direction or its PDF.
	vec3 sampled_direction = secondary_rays.data[hit].direction_cache.xyz;
	vec4 brdf_pdf = gi_cache_unpack(gi_cache_pack(vec4(gi_rough_brdf(source.diffuse.rgb, source.normal_mask.xyz, -source.direction_cache.xyz, sampled_direction), max(dot(source.normal_mask.xyz, sampled_direction), 0.0) / PI)));
	return ((outgoing * brdf_pdf.rgb) / brdf_pdf.w) / frame.settings.z;
}
void shade_indirect_hit(uint id) {
	if (id >= (frame.motion.y != 0u ? work.counts.y : primary_ray_count())) {
		return;
	}
	if (frame.motion.y != 0u) {
		id = work.hit_indices[id];
	}
	uint cell = floatBitsToUint(rays.data[id].direction_cache.w);
	RayHit secondary = secondary_hit(id);
	bool valid = cell != INVALID && secondary.position.w >= 0.0 && floatBitsToUint(secondary.direction_cache.w) != INVALID;
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
	return gi_cache_pack(gi_cache_accumulate(gi_cache_unpack(old), vec4(vec3(sum) / 1000.0, float(count)), frame.tuning.x));
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
		uint index = (cell / TILE_CELLS) * 64u + cell % TILE_CELLS;
		uvec4 pending = pending_direct_cache.data[index];
		if (keys.data[cell / TILE_CELLS].state.y == params.padding) {
			cache.data[cell] = blend_hit_samples(previous_cache.data[cell], pending.xyz, pending.w);
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
	bool valid_update;
	vec3 value = shade_direct(owned_hit(owner), state, owner, valid_update);
	cache.data[cell] = blend_hit_samples(previous_cache.data[cell], gi_cache_quantize(value), valid_update ? 1u : 0u);
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
vec3 accumulate_probe_radiance(vec3 value, vec3 contribution) {
	// ScreenProbes_AccumulateRadiance skips zero and NaN-length inputs.
	return dot(contribution, contribution) > 0.0 ? gi_cache_unpack(gi_cache_pack(vec4(value + contribution, 0))).rgb : value;
}
void resolve_probe(uint slot, uint lane) {
	uint probe = spawn.data[slot].x;
	if (probe == INVALID) {
		return;
	}
	uint id = probe * 64u + lane;
	RayHit ray = primary_hit(slot * 64u + lane);
	RayRecord traced = rays.data[slot * 64u + lane];
	vec3 value = environment_radiance(traced.direction_cache.xyz, false);
	float hit_distance = traced.position.w < 0.0 ? params.max_distance : traced.position.w;
	if (ray.position.w >= 0.0) {
		uint ray_id = slot * 64u + lane;
		bool feedback = frame.motion.y != 0u && (hit_samples.data[ray_id].links.y & 1u) != 0u;
		bool emissive = ray.emission.w > 0.0;
		bool primary_bypass = ray.position.w < cache_cell_size(ray.position.xyz);
		if (emissive || feedback) {
			value = accumulate_probe_radiance(vec3(0), emissive ? ray.emission.rgb : hit_samples.data[ray_id].direct.rgb);
		} else {
			// Match the separate ScreenProbes_AccumulateRadiance handoffs:
			// PopulateCells, UpdateMultibounceCells, then ResolveCells. Each
			// nonzero injection rounds independently through the half buffer.
			value = vec3(0);
			if (primary_bypass) {
				vec3 direct = frame.motion.y != 0u ? hit_samples.data[ray_id].direct.rgb : shade_transport(ray, gi_random(ray_id), INVALID);
				value = accumulate_probe_radiance(value, gi_denoiser_remove_nans(vec4(direct, 0)).rgb);
			}
			if (params.bounces != 0u) {
				RayHit secondary = secondary_hit(ray_id);
				bool bypass = frame.motion.y != 0u ? hit_samples.data[ray_id + primary_ray_count()].links.w != 0u : secondary.position.w >= 0.0 && secondary.position.w < cache_cell_size(secondary.position.xyz);
				if (bypass) {
					vec3 contribution = frame.motion.y != 0u ? hit_samples.data[ray_id].indirect.rgb : indirect_hit(ray_id);
					contribution = gi_denoiser_remove_nans(vec4(contribution, 0)).rgb;
					value = accumulate_probe_radiance(value, contribution);
				}
			}
			if (!primary_bypass) {
				vec4 cached = read_cache(floatBitsToUint(ray.direction_cache.w), false);
				value = accumulate_probe_radiance(value, cached.w > 0.0 ? cached.rgb : vec3(0));
			}
		}
	}
	clear_bins(lane);
	if (probes.data[probe].position.w > 0.0) {
		uint cell = angular_index(traced.direction_cache.xyz, probes.data[probe].normal.xyz);
		insert_bin(cell, lane, gi_cache_unpack(pack_probe_radiance(vec4(value, hit_distance))));
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
	vec4 history = gi_cache_unpack(scratch.data[id]);
	if (history.w > 0.0) {
		// AMD's shadow-preserving temporal hysteresis suppresses abrupt bright
		// outliers without dragging old bright values into newly dark cells.
		float a = luma(result.rgb), b = luma(history.rgb);
		float blend = clamp(max(a - b - min(a, b), 0.0) / max(max(a, b), 0.0001), 0.0, 0.95);
		result = mix(result, history, blend * blend);
	}
	radiance.data[id] = pack_probe_radiance(result);
}
vec4 filter_source(uint id) {
	return gi_cache_unpack(pass_id == PASS_FILTER_X ? radiance.data[id] : scratch.data[id]);
}
uint closest_probe(ivec2 pixel, ivec2 offset);
float gi_view_depth(vec3 position);
void filter_probe(uint probe, uint lane) {
	uint id = probe * 64u + lane;
	Probe center = probes.data[probe];
	vec4 value = filter_source(id);
	float weight = 1.0;
	if (center.position.w > 0.0 && center.state.z == params.padding) {
		vec3 direction = basis(center.normal.xyz) * hemi_direction((vec2(lane % 8u, lane / 8u) + 0.5) / 8.0);
		ivec2 seed = ivec2(center.state.xy);
		for (int i = 0; i < 6; i++) {
			int step = (((i & 1) << 1) - 1) * ((i >> 1) + 1);
			uint other = closest_probe(seed, pass_id == PASS_FILTER_X ? ivec2(step, 0) : ivec2(0, step));
			if (other == INVALID) {
				continue;
			}
			Probe neighbor = probes.data[other];
			if (neighbor.position.w == 0.0 || dot(direction, neighbor.normal.xyz) < 0.0) {
				continue;
			}
			if (abs(dot(neighbor.position.xyz - center.position.xyz, center.normal.xyz)) > footprint(center.position.xyz)) {
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
			float w = pow(clamp(1.0 - abs(gi_view_depth(neighbor.position.xyz) - gi_view_depth(center.position.xyz)) / gi_view_depth(center.position.xyz), 0.0, 1.0), 8.0);
			value += vec4(gi_denoiser_remove_nans(vec4(sample_value.rgb, 0)).rgb, hit_distance) * w;
			weight += w;
		}
	}
	if (pass_id == PASS_FILTER_X) {
		scratch.data[id] = pack_probe_radiance(value / weight);
	} else {
		radiance.data[id] = pack_probe_radiance(value / weight);
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
			value += gi_cache_unpack(radiance.data[probe * 64u + cell]).rgb * sh[lane] / 8.0;
		}
	}
	probes.data[probe].sh[lane] = gi_cache_pack(vec4(value, 0));
}
vec3 probe_irradiance(uint probe, vec3 normal) {
	float sh[9];
	sh_coefficients(normal, sh);
	vec3 value = vec3(0);
	// Keep AMD irradiance units throughout reconstruction and denoising.
	// Lambert normalization belongs only at final Forward+ composition.
	for (uint i = 0u; i < 9u; i++) {
		value += gi_cache_unpack(probes.data[probe].sh[i]).rgb * sh[i] * (i == 0u ? PI : (i < 4u ? 2.0 * PI / 3.0 : PI * 0.25));
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
	for (uint index = lane; index < CACHED_PROBES; index += 64u) {
		uint cached = previous_cached_order.data[index];
		uint destination = cached_state.data[cached].y != 0u ? cached_state.data[cached].x : lru_used + cached_state.data[cached].w;
		cached_order.data[destination] = cached;
	}
}
void store_cached_probe(uint rank, uint lane) {
	if (rank >= CACHED_PROBES) {
		return;
	}
	uint cached = previous_cached_order.data[rank];
	// New allocations own the first LRU ranks, even when those ranks were
	// claimed during sampling. AMD invalidates those existing claims.
	uint owner = rank < queues.counts.z ? (0x80000000u | rank) : cached_state.data[cached].z;
	if (owner == INVALID) {
		return;
	}
	if (lane == 0u) {
		cached_state.data[cached].z = owner;
	}
	bool allocated = (owner & 0x80000000u) != 0u;
	bool evicted = (owner & 0xc0000000u) != 0u;
	uint slot = allocated ? queues.data[eviction_queue_offset() + (owner & 0x7fffffffu)] : owner & 0x3fffffffu;
	if (evicted) {
		if (lane == 0u) {
			cached_probes.data[cached].probe = cached_probes.data[CACHED_PROBES + slot].probe;
			cached_probes.data[cached].probe.normal.xyz = normalize(unpack_reservoir_normal(pack_reservoir_normal(cached_probes.data[cached].probe.normal.xyz)));
			cached_state.data[cached].y = 0u;
			cached_state.data[cached].w = atomicAdd(queues.data[eviction_owners_offset()], 1u);
		}
		cached_probes.data[cached].radiance[lane] = cached_probes.data[CACHED_PROBES + slot].radiance[lane];
	} else {
		cached_probes.data[cached].radiance[lane] = radiance.data[spawn.data[slot].x * 64u + lane];
	}
}

uvec2 mask_dimensions(uint level) {
	return max(frame.grid.xy >> level, uvec2(1));
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
	ivec2 pos = min(pixel / 8, ivec2(frame.grid.xy) - 1);
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
		pos = min(pos / 2, ivec2(mask_dimensions(mip + 1u)) - 1);
	}
	return INVALID;
}
#include "amd_gi_near_field_inc.glsl"
void interpolate_pixel(ivec2 pixel, uint id) {
	Pixel result;
	vec3 p, n;
	bool valid = surface(pixel, p, n);
	imageStore(history_geometry_normal, pixel, texelFetch(geometry_normal_buffer, pixel, 0));
	result.position = vec4(p, valid ? 1.0 : 0.0);
	result.normal_delta = vec4(valid ? texelFetch(primary_shading_normal, pixel, 0).xyz * 2.0 - 1.0 : vec3(0), 0);
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
					weights[i] = pow(clamp(1.0 - abs(probe_depth - depth) / depth, 0.0, 1.0) * max(dot(n, other.normal.xyz), 0.0), 8.0);
				}
			}
			if (dot(weights, weights) == 0.0) {
				// AMD's relaxed fallback keeps uncovered surfaces from going
				// black. Mark it low confidence so it cannot grow temporal history.
				weights = vec4(1.0, indices.y != INVALID ? 1.0 : 0.0, indices.z != INVALID ? 1.0 : 0.0, indices.w != INVALID ? 1.0 : 0.0);
				result.position.w = 2.0;
			}
			weights /= dot(weights, vec4(1));
			vec4 visibility_cone = imageLoad(near_field_occlusion, pixel);
			vec3 bent_normal = normalize(visibility_cone.xyz * 2.0 - 1.0);
			vec3 sum = imageLoad(near_field_lighting, pixel).rgb;
			for (uint i = 0u; i < 4u; i++) {
				if (indices[i] != INVALID) {
					sum += weights[i] * probe_bent_irradiance(indices[i], bent_normal, visibility_cone.w);
				}
			}
			result.color = vec4(sum, result.position.w == 2.0 ? 0.0 : 1.0);
		}
	}
	result.color = gi_cache_unpack(gi_cache_pack(result.color));
	pixels.data[id] = pack_pixel(result);
}
void reproject_pixel(ivec2 pixel, uint id) {
	Pixel current = unpack_pixel(pixels.data[id]);
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
		float grazing = 1.0 - max(dot(normalize(params.camera_position.xyz - current.position.xyz), normalize(current.normal_delta.xyz)), 0.0);
		cell_size *= mix(1.0, 5.0, pow(grazing, 6.0));
		ivec2 center = ivec2(uv * vec2(params.size));
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				// Reference uses a nearest clamp sampler at previous_uv + offset.
				ivec2 tap = center + ivec2(x, y);
				ivec2 p = clamp(tap, ivec2(0), ivec2(params.size) - 1);
				Pixel old = unpack_pixel(previous_pixels.data[uint(p.x) + uint(p.y) * params.size.x]);
				if (old.position.w == 0.0 || old.color.w < 1.0) {
					continue;
				}
				vec4 old_clip = frame.previous_view_projection * vec4(old.position.xyz, 1);
				vec2 tap_uv = uv + vec2(x, y) / vec2(params.size);
				vec4 old_world = frame.previous_inverse_view_projection * vec4(tap_uv * 2.0 - 1.0, old_clip.z / old_clip.w, 1);
				if (distance(current.position.xyz, old_world.xyz / old_world.w) < cell_size && dot(current.normal_delta.xyz, old.normal_delta.xyz) > 0.95) {
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
	current.color = gi_cache_unpack(gi_cache_pack(current.color));
	current.normal_delta.w = unpackHalf2x16(packHalf2x16(vec2(delta, 0))).x;
	pixels.data[id] = pack_pixel(current);
	imageStore(denoiser_blur_mask, pixel, vec4(blur_mask / 8.0));
}

float gi_view_depth(vec3 position) {
	vec3 forward = vec3(0, 0, -1);
	forward += 2.0 * cross(params.camera_rotation.xyz, cross(params.camera_rotation.xyz, forward) + params.camera_rotation.w * forward);
	return dot(position - params.camera_position.xyz, forward);
}

void filter_pixel(ivec2 pixel, uint id) {
	Pixel center = unpack_pixel(pixels.data[id]);
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
			vec4 c = pass_id == PASS_BLUR_X ? gi_cache_unpack(pixels.data[other].color) : imageLoad(filter_image, p);
			if (c.w > 0.0) {
				Pixel neighbor = unpack_pixel(pixels.data[other]);
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
		pixels.data[id].color = gi_cache_pack(lighting);
		vec3 irradiance = lighting.rgb / max(lighting.w, 1.0);
		imageStore(output_diffuse, pixel, vec4((irradiance / PI + frame.ambient.rgb) * params.exposure, center.position.w > 0.0 ? frame.ambient.a : 0.0));
	}
}
#if defined(AMD_GI_DIAGNOSTIC_REFLECTION) && AMD_GI_PASS == PASS_REFLECTION_TRACE
#define AMD_GI_REFLECTION_TRACE_RECORDING
#endif
#if defined(AMD_GI_DIAGNOSTIC_REFLECTION) && (AMD_GI_PASS == PASS_REFLECTION_CLASSIFY || AMD_GI_PASS == PASS_REFLECTION_MARK_FIREFLIES || AMD_GI_PASS == PASS_REFLECTION_FIRST || AMD_GI_PASS == PASS_REFLECTION_TEMPORAL || AMD_GI_PASS == PASS_REFLECTION_OUTPUT)
#define AMD_GI_REFLECTION_RECORDING
#endif
#if defined(AMD_GI_DIAGNOSTIC_SOURCE) || defined(AMD_GI_REFLECTION_RECORDING)
layout(set = 0, binding = 63, std430) buffer SourceValidation {
	vec4 values[];
}
source_validation;
#endif
#ifdef AMD_GI_REFLECTION_RECORDING
uint reflection_diagnostic_base(ivec2 pixel) {
	uvec4 roi = floatBitsToUint(source_validation.values[33]);
	if (floatBitsToUint(source_validation.values[34]).x == 0u || any(lessThan(pixel, ivec2(roi.xy))) || any(greaterThanEqual(pixel, ivec2(roi.xy + roi.zw)))) {
		return INVALID;
	}
	uvec2 local = uvec2(pixel) - roi.xy;
	return 37u + (local.x + local.y * roi.z) * 48u;
}
void reflection_diagnostic_write(ivec2 pixel, uint slot, vec4 value) {
	uint base = reflection_diagnostic_base(pixel);
	if (base != INVALID) {
		source_validation.values[base + slot] = value;
	}
}
#endif
// clang-format off
#include "amd_gi_reflections_inc.glsl"
#include "amd_gi_debug_inc.glsl"
// clang-format on
#ifdef AMD_GI_DIAGNOSTIC_SOURCE
void validate_source(uint id) {
	if (id == 0u) {
		RayRecord hit = empty_ray();
		hit.position.w = 1.0;
		hit.visibility = uvec4(0);
		RayHit decoded = decode_hit(hit, vec2(0.25));
		source_validation.values[0] = vec4(gi_sources.header.y, params.padding, decoded.emission.w, dot(decoded.emission.rgb, decoded.emission.rgb));
	}
	if (id >= 16u) {
		return;
	}
	vec2 bary = vec2(0.0625 + float(id % 8u) * 0.1, 0.125);
	GISourceMaterial material = gi_source_material_filtered(0u, 0u, bary, true, id >= 12u ? -2.0 : 0.0, id >= 8u);
	source_validation.values[1u + id * 2u] = material.albedo;
	vec3 v0, v1, v2;
	gi_triangle_vertices(0u, 0u, v0, v1, v2);
	mat4x3 transform = transpose(hits.data[0].object_to_world);
	v0 = transform * vec4(v0, 1);
	v1 = transform * vec4(v1, 1);
	v2 = transform * vec4(v2, 1);
	vec3 point = v0 * (1.0 - bary.x - bary.y) + v1 * bary.x + v2 * bary.y;
	vec3 normal = normalize(cross(v2 - v0, v1 - v0));
	RayRecord query = trace_record(point + normal, -normal);
	source_validation.values[2u + id * 2u] = vec4(material.emission.rgb, query.position.w >= 0.0 ? 1.0 : 0.0);
}
#endif
void main() {
#if defined(AMD_GI_DIAGNOSTIC_SOURCE) && AMD_GI_PASS == PASS_VALIDATE_SOURCE
	{
		validate_source(gl_LocalInvocationIndex);
		return;
	}
#endif
	uint lane = gl_LocalInvocationIndex;
	uint probe = gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x;
	uint id = probe * 64u + lane;
#if AMD_GI_PASS == PASS_PREPARE || AMD_GI_PASS == PASS_ALLOCATE || AMD_GI_PASS == PASS_REGISTER || AMD_GI_PASS == PASS_ALLOCATE_SECONDARY || AMD_GI_PASS == PASS_REGISTER_SECONDARY || AMD_GI_PASS == PASS_RESOLVE
	if (probe >= work.counts.x) {
		return;
	}
#endif
	if (pass_id == PASS_UPDATE || pass_id == PASS_UPDATE_INDIRECT || (pass_id == PASS_POPULATE && frame.motion.y == 0u) || (pass_id >= PASS_MIP1 && pass_id <= PASS_MIP3) || (pass_id >= PASS_INDIRECT_MIP1 && pass_id <= PASS_INDIRECT_MIP3)) {
		uint active_index = gl_WorkGroupID.y * 256u + gl_WorkGroupID.x;
		if (active_index >= keys.dispatch.w) {
			return;
		}
		probe = keys.data[TILE_COUNT + active_index].state.x;
		id = probe * TILE_CELLS + lane;
	}
#if AMD_GI_PASS == PASS_DEBUG_VIEW
	debug_view(ivec2(gl_GlobalInvocationID.xy));
	return;
#elif AMD_GI_PASS == PASS_DEBUG_STATS
	debug_stats(id);
	return;
#elif AMD_GI_PASS == PASS_PREPARE_LIGHTS
	prepare_light(id);
	return;
#elif AMD_GI_PASS == PASS_PREPARE_LIGHT_MASKS
	prepare_light_mask(id);
	return;
#elif AMD_GI_PASS == PASS_LIGHT_GRID_DISPATCH
	if (lane == 0u && light_grid.minimum.x != INVALID && gi_light_count() > 0u) {
		vec3 minimum, cell_size;
		uvec3 dimensions;
		light_grid_configuration(minimum, cell_size, dimensions);
		work.grid_dispatch = uvec4(dimensions.x * dimensions.y * dimensions.z, 1, 1, 0);
	}
	return;
#elif AMD_GI_PASS == PASS_LIGHT_GRID
	build_light_grid(probe, lane);
	return;
#elif AMD_GI_PASS == PASS_RESERVOIR_RESET
	reservoir_reset(id);
	return;
#elif AMD_GI_PASS >= PASS_RESERVOIR_SCAN && AMD_GI_PASS <= PASS_RESERVOIR_SCAN_TOP
	reservoir_scan(probe, lane, uint(pass_id - PASS_RESERVOIR_SCAN));
	return;
#elif AMD_GI_PASS == PASS_RESERVOIR_COMPACT
	if (frame.motion.y != 0u) {
		if (id >= (params.samples == 0u ? work.counts.y : work.counts.z)) {
			return;
		}
		id = work.hit_indices[id + params.samples * primary_ray_count()];
	}
	reservoir_compact(id);
	return;
#elif AMD_GI_PASS == PASS_REFLECTION_BUILD_DISPATCH
	if (lane == 0u) {
		uint groups = (queues.data[frame.emitters.z + 3u] + 63u) / 64u;
		queues.data[frame.emitters.z] = min(groups, 65535u);
		queues.data[frame.emitters.z + 1u] = max((groups + 65534u) / 65535u, 1u);
		queues.data[frame.emitters.z + 2u] = 1u;
	}
	return;
#elif AMD_GI_PASS >= PASS_REFLECTION_CLASSIFY
#if AMD_GI_PASS == PASS_REFLECTION_TRACE
	if (frame.emitters.w != 0u) {
		id = (gl_WorkGroupID.y * 65535u + gl_WorkGroupID.x) * 64u + lane;
		if (id < queues.data[frame.emitters.z + 3u]) {
			uint sample_id = queues.data[frame.emitters.z + 4u + id];
			ivec2 pixel = ivec2(sample_id % uint(reflection_size().x), sample_id / uint(reflection_size().x));
			trace_reflection(pixel, sample_id);
		}
		return;
	}
#endif

	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = pass_id >= PASS_REFLECTION_LAST ? ivec2(params.size) : reflection_size();
	if (pass_id == PASS_REFLECTION_FIRST && frame.reflection_options.x == 0u) {
		size.x = int(params.size.x);
	}
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	uint reflection_id = pass_id >= PASS_REFLECTION_LAST ? uint(pixel.x) + uint(pixel.y) * params.size.x : reflection_index(pixel);
#if AMD_GI_PASS == PASS_REFLECTION_CLASSIFY
	classify_reflection(pixel, reflection_id);
#elif AMD_GI_PASS == PASS_REFLECTION_TRACE
	trace_reflection(pixel, reflection_id);
#elif AMD_GI_PASS == PASS_REFLECTION_MARK_FIREFLIES
	mark_reflection_fireflies(pixel, reflection_id);
#elif AMD_GI_PASS == PASS_REFLECTION_CLEAN_FIREFLIES
	clean_reflection_fireflies(pixel, reflection_id);
#elif AMD_GI_PASS >= PASS_REFLECTION_FIRST && AMD_GI_PASS <= PASS_REFLECTION_LAST
	resolve_reflection(pixel, reflection_id);
#elif AMD_GI_PASS == PASS_REFLECTION_TEMPORAL
	temporal_reflection(pixel, reflection_id);
#else
	output_reflection_pixel(pixel, reflection_id);
#endif
#elif AMD_GI_PASS == PASS_PURGE
	purge_cache(id);
#elif AMD_GI_PASS == PASS_RESET
	reset_cache(lane);
#elif AMD_GI_PASS == PASS_REPROJECT
	reproject_probe(probe, lane);
#elif AMD_GI_PASS == PASS_BIN_CACHED
	bin_cached_probe(id);
#elif AMD_GI_PASS == PASS_SELECT
	if (lane == 0u) {
		select_probe(probe);
	}
#elif AMD_GI_PASS == PASS_PATCH
	if (lane == 0u) {
		patch_probe(probe);
	}
#elif AMD_GI_PASS == PASS_COMPACT_PROBES
	compact_probes(lane);
#elif AMD_GI_PASS == PASS_GATHER_PROBES
	if (lane == 0u) {
		gather_probe(probe);
	}
#elif AMD_GI_PASS == PASS_PREPARE
	prepare_probe(probe, lane);
#elif AMD_GI_PASS == PASS_TRACE
	trace_probe(probe, lane);
#elif AMD_GI_PASS == PASS_ALLOCATE || AMD_GI_PASS == PASS_ALLOCATE_SECONDARY
	allocate_tile(id);
#elif AMD_GI_PASS == PASS_REGISTER || AMD_GI_PASS == PASS_REGISTER_SECONDARY
	register_ray(id);
#elif AMD_GI_PASS == PASS_POPULATE
	populate_secondary(id);
#elif AMD_GI_PASS == PASS_SHADE_HITS
	shade_hit(id);
#elif AMD_GI_PASS == PASS_SHADE_INDIRECT_HITS
	shade_indirect_hit(id);
#elif AMD_GI_PASS == PASS_UPDATE_INDIRECT
	update_indirect(id);
#elif AMD_GI_PASS == PASS_UPDATE
	update_cell(id);
#elif AMD_GI_PASS >= PASS_MIP1 && AMD_GI_PASS <= PASS_MIP3
	build_mip(probe, lane, uint(pass_id - PASS_MIP1 + 1));
#elif AMD_GI_PASS >= PASS_INDIRECT_MIP1 && AMD_GI_PASS <= PASS_INDIRECT_MIP3
	build_mip(probe, lane, uint(pass_id - PASS_INDIRECT_MIP1 + 1));
#elif AMD_GI_PASS == PASS_RESOLVE
	resolve_probe(probe, lane);
#elif AMD_GI_PASS == PASS_FILTER_X || AMD_GI_PASS == PASS_FILTER_Y
	filter_probe(probe, lane);
#elif AMD_GI_PASS == PASS_PROJECT
	project_probe(probe, lane);
#elif AMD_GI_PASS == PASS_ORDER_CACHED
	order_cached_probes(lane);
#elif AMD_GI_PASS == PASS_STORE_CACHED
	store_cached_probe(probe, lane);
#elif AMD_GI_PASS == PASS_MASK
	filter_mask(gl_GlobalInvocationID.xy);
#else
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(params.size)))) {
		return;
	}
	uint pixel_id = uint(pixel.x) + uint(pixel.y) * params.size.x;
#if AMD_GI_PASS == PASS_NEAR_FIELD
	integrate_near_field(pixel);
#elif AMD_GI_PASS == PASS_INTERPOLATE
	interpolate_pixel(pixel, pixel_id);
#elif AMD_GI_PASS == PASS_TEMPORAL
	reproject_pixel(pixel, pixel_id);
#else
	filter_pixel(pixel, pixel_id);
#endif
#endif
}
