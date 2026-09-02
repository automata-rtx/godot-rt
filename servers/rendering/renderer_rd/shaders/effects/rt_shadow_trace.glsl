#[compute]

// Ray query requires GLSL 460: glslang gates the rayQueryEXT keyword and every
// rayQuery*EXT builtin on version >= 460. This is the only shader in the tree
// that is not #version 450.
#version 460

#VERSION_DEFINES

#extension GL_EXT_ray_query : enable

#define TILE_SIZE 8
#define TILE_THREADS (TILE_SIZE * TILE_SIZE)

// Lights kept per pixel. The mask is one RGBA8 texel per pixel, so this is
// four; it bounds how many raytraced lights can overlap a single pixel, not
// how many the scene may contain.
#define LIGHTS_PER_PIXEL 4

// Lights kept per screen tile after the coarse cull. Overflow drops lights
// from the tile, which can only happen where more than this many raytraced
// lights reach one 8x8 block of pixels.
#define MAX_TILE_LIGHTS 128

// Widest penumbra the hit distance channel can describe, in pixels. Anything
// wider saturates, which is harmless: the denoiser's filter is already at its
// full width by then. Must match MAX_PENUMBRA_PIXELS in rt_shadow_atrous.glsl.
#define MAX_PENUMBRA_PIXELS 32.0

// Slot value meaning "this channel carries no light". Matches RT_SLOT_NONE in
// light_data_inc.glsl.
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

// Which reading of the type-dependent fields above applies. Matches
// RTShadows::LightType.
#define LIGHT_TYPE_OMNI 0u
#define LIGHT_TYPE_SPOT 1u
#define LIGHT_TYPE_DIRECTIONAL 2u

layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;

layout(set = 0, binding = 1) uniform sampler2D source_depth;

// Visibility in [0, 1] for the four lights this pixel selected.
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D dest_visibility;

// Which light each of those four channels belongs to, as an index into the
// light buffer. SLOT_NONE marks an unused channel.
layout(rgba8ui, set = 0, binding = 3) uniform restrict writeonly uimage2D dest_index;

// How wide this pixel's penumbra should be, in pixels, divided by
// MAX_PENUMBRA_PIXELS so that it fits eight bits. The denoiser sizes its filter
// from it: penumbra width grows with the distance between receiver and blocker,
// which is what makes a raytraced shadow harden at contact.
layout(rgba8, set = 0, binding = 4) uniform restrict writeonly image2D dest_hit_distance;

// A directional light shares this record, and the same per pixel competition for
// the mask's four channels, with every lamp; it reinterprets four fields rather
// than needing its own. Must match RTShadows::LightParams.
struct RTLight {
	// Omni and spot: world position and world range. Directional: the camera's
	// position, and the furthest view DEPTH at which the culler gathered casters,
	// which is where the shadow must have faded out. Both types keep a positive
	// radius while live, so the gap test in the tile cull stays a single test.
	vec3 position;
	float radius;

	// Omni and spot: the direction the light points, away from it. Directional:
	// the direction TOWARD the light. World space either way.
	vec3 direction;
	float cos_spot_angle;

	// Omni and spot: emitter radius in meters. Directional: the tangent of the
	// angular radius, which is the same quantity per unit of distance.
	float size;
	uint light_type;
	uint mask;
	float energy;

	float bias;
	float normal_bias;

	// Directional only, both in view depth: where the shadow starts fading out,
	// and how long a ray may be.
	float fade_from;
	float max_ray_length;
};

layout(set = 0, binding = 5, std430) restrict readonly buffer RTLights {
	RTLight data[];
}
rt_lights;

// View space surface normals from the depth pre-pass, which raytraced shadows
// force on. Reconstructing a normal from neighboring depth taps instead would
// span the discontinuity at every silhouette and offset those rays into the
// surface, fringing the outline of every object.
layout(set = 0, binding = 6) uniform sampler2D source_normal_roughness;

layout(push_constant, std430) uniform Params {
	mat4 inv_view_projection;

	// Rotates a view space normal into the world space the acceleration
	// structure lives in. A quaternion rather than the camera's basis because a
	// mat3 would not fit beside the inverse view projection in 128 bytes.
	vec4 camera_rotation;

	vec3 camera_position;
	float max_ray_distance;

	ivec2 screen_size;
	uint light_count;
	// Sample count in the low eight bits, frame index above them. Packed for the
	// same reason the rotation is a quaternion.
	uint samples_and_frame;

	// Pixels a one meter object covers one meter from the camera, so a penumbra
	// measured in world units can be reported in the units the denoiser filters
	// in.
	float focal_pixels;
	// Traversal flags for every shadow ray this dispatch casts.
	uint ray_flags;
}
params;

vec3 rotate_by_quaternion(vec4 q, vec3 v) {
	return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

// Coarse bounds of the geometry in this tile, so the light cull below runs once
// per tile instead of once per pixel.
shared uint tile_bounds_min[3];
shared uint tile_bounds_max[3];
shared uint tile_light_count;
shared uint tile_lights[MAX_TILE_LIGHTS];

// Maps a float onto a uint whose unsigned order matches the float's order, so
// that atomicMin and atomicMax can reduce world space coordinates.
uint order_preserving_bits(float value) {
	uint bits = floatBitsToUint(value);
	return (bits & 0x80000000u) != 0u ? ~bits : (bits | 0x80000000u);
}

float order_preserving_float(uint bits) {
	return uintBitsToFloat((bits & 0x80000000u) != 0u ? (bits & 0x7fffffffu) : ~bits);
}

// A 32x32 blue noise mask, four values to a word. Generated once by void and
// cluster (Ulichney) and baked in, so there is no texture to bind and no cost to
// produce it.
//
// Blue noise means the pattern's energy sits at high spatial frequencies and
// almost none at low ones. That is the whole point: the spatial filter
// downstream removes high frequency error well and low frequency error hardly
// at all, so pushing the error up the spectrum is what makes one ray per pixel
// resolve.
const uint BLUE_NOISE[256] = uint[](
		0x28b41e55u, 0x2c981365u, 0xbcff6720u, 0x6fde33a8u, 0xe67a2d53u, 0x15a2903du, 0x5de145b0u, 0xbc3e1734u,
		0xeece7ddbu, 0xd2f73dabu, 0x41149eb1u, 0x198ff223u, 0x049ad7a5u, 0xd550ca21u, 0x82c56cefu, 0x89af77f7u,
		0x90340f67u, 0x7789035au, 0x7b8edd48u, 0x3f0566ceu, 0xf363bb80u, 0x782cb66du, 0x0d219b39u, 0x2ded49a5u,
		0x7147fc97u, 0x33bae2c6u, 0x57e90c60u, 0xc5e39cb2u, 0xab4d25f8u, 0xe68711ddu, 0xdc56bf02u, 0xc3076eccu,
		0x15dea854u, 0xa71b4f9fu, 0x38c128f3u, 0x30744c1bu, 0x360a8c5cu, 0xa5425b92u, 0x318aff64u, 0xd5255f93u,
		0x82b80b3du, 0xcc6bf926u, 0xd2709881u, 0x0ea687fau, 0x74e5d0b3u, 0xd2b9f0c8u, 0x19ae4d27u, 0x7bb5e541u,
		0x3164f18cu, 0x099242d4u, 0x02aa533cu, 0xebd82963u, 0x169d446cu, 0x0f7e2052u, 0xbbea7795u, 0x1ca1f87fu,
		0x99ca57e0u, 0xbe5be874u, 0xb716d9efu, 0x54c14091u, 0xbef78021u, 0xf56c31a9u, 0x690cc93bu, 0x70380551u,
		0xc00146afu, 0x7a13aa1fu, 0xe349862eu, 0x94127af0u, 0x5d0239afu, 0xd949e78bu, 0xdf2e5ca3u, 0x2ac3d19au,
		0x85fd1894u, 0xb2dd4c37u, 0x6e249f65u, 0xfc30a359u, 0x28dc66c8u, 0xb40999cdu, 0xaafa8c1du, 0xed5d8813u,
		0xd6a17d67u, 0x058df26au, 0x38c0fed1u, 0x47d707cbu, 0x78eda088u, 0x81c36540u, 0x3ebd4e72u, 0xd8204a76u,
		0x5b0d2fbcu, 0x569d24b6u, 0x1a931041u, 0x7261b584u, 0xad4f0e1du, 0x3624fe16u, 0x26d300ecu, 0x3ba4b7f0u,
		0x40e852f6u, 0xe43275c9u, 0xe1af627fu, 0xe727f550u, 0x8335d1beu, 0xa058e1bau, 0x849760dbu, 0x8e06e26bu,
		0x8aacc41au, 0x1ca9fa17u, 0x4473f0c7u, 0x3f997ca6u, 0x96f6588du, 0x458f6f05u, 0x35c91baeu, 0x79cd5711u,
		0x036e9b46u, 0xbb4864dfu, 0xd0002b8eu, 0x04dc1231u, 0xd7662ab1u, 0x0dcf2f4au, 0xb35179f7u, 0x632b9efeu,
		0x34d323e0u, 0xda0a7c96u, 0xfb9d5c3cu, 0xee6d5fc2u, 0x1fc376a0u, 0x85b7f3a2u, 0x90e22d68u, 0xefae7e42u,
		0xf45983bau, 0xeea253b9u, 0x4b1fae6bu, 0x5223b787u, 0xe50a46cbu, 0x3e18607cu, 0xbd08a4c4u, 0x3a0bda1eu,
		0x44a76a17u, 0x8625ce1au, 0x73ead30fu, 0x82d63a93u, 0x3989fd14u, 0x9ae94eb1u, 0x6f49ed22u, 0x8d53c961u,
		0x2cec06d1u, 0x36f9628eu, 0x1456bc79u, 0x9bf408e2u, 0x9459ad2du, 0x74cb0fdeu, 0xf683d457u, 0xfb75a132u,
		0xc1739c4cu, 0xc74dace5u, 0x2fa74396u, 0x7148b0c7u, 0x22d5bf63u, 0x8fba306bu, 0x12b03804u, 0xac26e995u,
		0x10dd3660u, 0x046e187fu, 0x68ff23e3u, 0xcf1e5b7eu, 0xa4013fe9u, 0xf24484f9u, 0xc2de69a8u, 0xc43f015au,
		0x55b4881fu, 0xb2d89f3eu, 0x9d108d5eu, 0xa68c37dau, 0x75508013u, 0xcf5e15c5u, 0x471c7b29u, 0xe47eb48bu,
		0xfdcd960cu, 0x34f12869u, 0xb851cc84u, 0xf8c103f1u, 0xecdb922bu, 0x0c98b037u, 0xff9ce850u, 0xf468d62cu,
		0x03472e71u, 0x4ac591bbu, 0x2a71eb09u, 0x694e7845u, 0x1ea05ab6u, 0xd8f5684bu, 0x623bb886u, 0xa54e14cau,
		0xe6aa5de0u, 0x761d5881u, 0x1adf3ca9u, 0x10d597adu, 0x07cc33e4u, 0x3222bf7cu, 0xab06c66fu, 0xbf399778u,
		0x1579d022u, 0xf9d7a33au, 0x8f64c099u, 0x8626eccau, 0x8bfe7041u, 0x5991e6abu, 0xf14d19a3u, 0x8a0eea25u,
		0xef9840f8u, 0x276c0bc8u, 0x81320e55u, 0xb15f0852u, 0x61b9189au, 0x42d4113bu, 0x907fe0fau, 0x56b2da5cu,
		0x29b36a06u, 0x8843e161u, 0xfbe3b6ceu, 0xf6753ca7u, 0x24d94cc6u, 0x0276c754u, 0xd02eb566u, 0x809f436du,
		0x518b17c2u, 0xf3ac92beu, 0x6a48167au, 0x2fdcbd1cu, 0xf2a27d00u, 0x85a6ea95u, 0x093d9c20u, 0xeb301bc0u,
		0xfc35dfa8u, 0x01331d77u, 0x2a94a45eu, 0x588a9ecfu, 0x0b3767e7u, 0xbd4a2b6du, 0xa9e855cdu, 0x4bcb7bfdu,
		0x0ad35e72u, 0xb9d64ba1u, 0x73d93aebu, 0x21450deeu, 0x87d2ad93u, 0x35db19b3u, 0x118972f4u, 0x2791654fu,
		0x83439bf5u, 0x5470e7c4u, 0x4f07c685u, 0xc8b55f82u, 0xc24612fbu, 0x627dfc5au, 0xb8299508u, 0x00e49ed4u);

// One value from the blue noise mask, at an arbitrary offset into it. Two
// offsets far enough apart give two spatially well distributed values that are
// not copies of each other, which is what the two sampling dimensions need.
float blue_noise_at(ivec2 pos) {
	uint index = uint((pos.y & 31) * 32 + (pos.x & 31));
	uint packed = BLUE_NOISE[index >> 2u];
	return float((packed >> ((index & 3u) * 8u)) & 0xffu) / 255.0;
}

// Where on the emitter this pixel samples: x is the fraction of a turn, y is
// where inside the sample's radial stratum it lands.
//
// Space comes from the mask above. Time is a separate additive step per
// dimension rather than a shift of the sampling position: advancing the
// position re-rolls the pattern every frame and gives each pixel an independent
// sequence that can revisit nearly the same point, whereas adding an irrational
// increment spreads a single pixel's own sequence as evenly as any sequence can.
// The temporal accumulation is averaging exactly that sequence. The two
// increments are the R2 lattice constants, which stay evenly spread jointly and
// not merely one dimension at a time.
vec2 shadow_sample_offsets(ivec2 pos, uint frame) {
	vec2 spatial = vec2(blue_noise_at(pos), blue_noise_at(pos + ivec2(13, 7)));
	return fract(spatial + float(frame) * vec2(0.7548776662, 0.5698402910));
}

// Vogel disk, with the radius jittered inside each sample's stratum rather than
// pinned to its center.
//
// Pinning it matters most at the shipped default of one sample per light: a
// fixed 0.5 would put that single ray at sqrt(0.5) of the emitter's radius on
// every frame, and with only the angle moving the temporal average would be the
// shadow of a RING at 0.707r rather than of the disk. The width that costs is
// small, since a ring at 0.707r spans nearly the same 10-90 as the disk that
// contains it, but the shape across the penumbra is wrong: a ring's projection
// piles up at its two extremes where a disk's bulges in the middle, so the
// falloff comes out S-shaped where it should be smooth.
//
// Jittering the radius over frames makes that same one ray sweep the whole
// emitter with the correct area weighting. At higher counts it is ordinary
// jittered stratification and is still the better estimator.
vec2 vogel_disk_sample(uint index, uint count, float phi, float radial_jitter) {
	const float golden_angle = 2.39996323;
	float r = sqrt((float(index) + radial_jitter) / float(count));
	float theta = float(index) * golden_angle + phi;
	return vec2(r * cos(theta), r * sin(theta));
}

void build_basis(vec3 n, out vec3 t, out vec3 b) {
	// Duff et al., branchless orthonormal basis.
	float sign_n = n.z >= 0.0 ? 1.0 : -1.0;
	float a = -1.0 / (sign_n + n.z);
	float d = n.x * n.y * a;
	t = vec3(1.0 + sign_n * n.x * n.x * a, sign_n * d, -sign_n * n.x);
	b = vec3(d, sign_n + n.y * n.y * a, -n.y);
}

vec3 reconstruct_world_position(ivec2 pos, float depth) {
	vec2 uv = (vec2(pos) + 0.5) / vec2(params.screen_size);
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world = params.inv_view_projection * ndc;
	return world.xyz / world.w;
}

// Rough estimate of how much this light contributes here, used to keep the
// strongest few when more lights reach a pixel than the mask has channels.
// Dropping the weakest is what makes the per pixel limit hard to notice.
float light_importance(RTLight light, vec3 to_light_normalized, vec3 normal, float distance_to_light) {
	// A directional light does not attenuate: wherever it reaches it reaches at
	// full strength, right out to the edge of the range the culler gathered
	// casters for. Its shadow has already faded to nothing by then, so losing the
	// channel there costs nothing. In practice this means the sun outranks a lamp
	// on any surface the lamp is not close to, which is the right way round
	// outdoors.
	float falloff = light.light_type == LIGHT_TYPE_DIRECTIONAL
			? 1.0
			: max(1.0 - distance_to_light / max(light.radius, 0.0001), 0.0);
	// A light below the horizon of the surface is already fully shadowed by the
	// surface itself, so it must not take a channel from one that is not: with
	// lamps on every side of a room, that is most of them.
	float facing = max(dot(normal, to_light_normalized), 0.0);
	// Floored so that a light left at zero energy still ranks above an empty
	// channel rather than silently losing its shadow.
	return max(light.energy, 0.0001) * falloff * falloff * facing;
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	uint thread = gl_LocalInvocationIndex;

	// Threads outside the screen still take part in the barriers below, so no
	// invocation may return before the tile is culled.
	bool in_bounds = all(lessThan(pos, params.screen_size));
	float depth = in_bounds ? texelFetch(source_depth, pos, 0).r : 0.0;

	// Godot uses reverse-Z, so 0 is the far plane: a depth of 0 is sky.
	bool has_surface = in_bounds && depth > 0.0;

	vec3 world_position = has_surface ? reconstruct_world_position(pos, depth) : vec3(0.0);

	// Two different measures of how far away this surface is, both needed below.
	//
	// view_depth is along the camera's forward axis. That, not the radial
	// distance, is what Godot's directional shadow fade is keyed on, so keying a
	// raytraced sun's range on it makes the hand off land exactly where the
	// cascade path's own fade would have put it.
	//
	// view_distance is radial, which is what an angular size projects through, so
	// it is what the penumbra conversion needs.
	vec3 camera_forward = rotate_by_quaternion(params.camera_rotation, vec3(0.0, 0.0, -1.0));
	float view_depth = dot(world_position - params.camera_position, camera_forward);
	float view_distance = max(length(world_position - params.camera_position), 0.0001);

	if (thread < 3u) {
		tile_bounds_min[thread] = 0xffffffffu;
		tile_bounds_max[thread] = 0u;
	}
	if (thread == 0u) {
		tile_light_count = 0u;
	}

	barrier();

	if (has_surface) {
		for (int axis = 0; axis < 3; axis++) {
			uint bits = order_preserving_bits(world_position[axis]);
			atomicMin(tile_bounds_min[axis], bits);
			atomicMax(tile_bounds_max[axis], bits);
		}
	}

	barrier();

	// Uniform across the workgroup: every thread reads the same shared values.
	bool tile_has_surface = tile_bounds_min[0] <= tile_bounds_max[0];
	vec3 bounds_min = vec3(
			order_preserving_float(tile_bounds_min[0]),
			order_preserving_float(tile_bounds_min[1]),
			order_preserving_float(tile_bounds_min[2]));
	vec3 bounds_max = vec3(
			order_preserving_float(tile_bounds_max[0]),
			order_preserving_float(tile_bounds_max[1]),
			order_preserving_float(tile_bounds_max[2]));

	if (tile_has_surface) {
		// Directional lights are claimed first, in a pass of their own, so a tile
		// crowded with lamps drops lamps rather than the sun. Only the low
		// MAX_TILE_LIGHTS entries are ever read, so claiming early is what
		// guarantees inclusion. There can be at most eight directional lights, so
		// this pass cannot fill the array by itself.
		//
		// No geometric test: a directional light reaches every surface there is.
		// The only question is whether the surface is inside the range the culler
		// gathered casters for, and that is a per pixel question about view DEPTH.
		// A sphere around the camera would answer a different one — radial
		// distance is always at least the view depth, so such a test would reject
		// tiles the per pixel check accepts, and the corners of the frame would
		// lose the sun well before the fade was meant to start.
		for (uint i = thread; i < params.light_count; i += uint(TILE_THREADS)) {
			RTLight light = rt_lights.data[i];
			if (light.radius <= 0.0 || light.light_type != LIGHT_TYPE_DIRECTIONAL) {
				continue;
			}
			uint slot = atomicAdd(tile_light_count, 1u);
			if (slot < uint(MAX_TILE_LIGHTS)) {
				tile_lights[slot] = i;
			}
		}
	}

	barrier();

	if (tile_has_surface) {
		// Sphere against the tile's bounding box. Conservative for spot lights,
		// which is the right way to be wrong: an extra candidate costs a rejected
		// distance test, a missing one costs a shadow.
		for (uint i = thread; i < params.light_count; i += uint(TILE_THREADS)) {
			RTLight light = rt_lights.data[i];
			// A light keeps its index in this buffer for as long as it casts a
			// raytraced shadow, so the buffer can hold gaps where an index belongs
			// to a light that is not in this pass. A gap is zeroed, and a light of
			// no radius lights nothing.
			if (light.radius <= 0.0 || light.light_type == LIGHT_TYPE_DIRECTIONAL) {
				continue;
			}
			vec3 closest = clamp(light.position, bounds_min, bounds_max);
			vec3 offset = closest - light.position;
			if (dot(offset, offset) <= light.radius * light.radius) {
				uint slot = atomicAdd(tile_light_count, 1u);
				if (slot < uint(MAX_TILE_LIGHTS)) {
					tile_lights[slot] = i;
				}
			}
		}
	}

	barrier();

	uint tile_lights_used = min(tile_light_count, uint(MAX_TILE_LIGHTS));

	uint selected[LIGHTS_PER_PIXEL];
	float score[LIGHTS_PER_PIXEL];
	for (int k = 0; k < LIGHTS_PER_PIXEL; k++) {
		selected[k] = SLOT_NONE;
		score[k] = 0.0;
	}

	if (!in_bounds) {
		return;
	}

	vec3 normal = vec3(0.0, 1.0, 0.0);

	if (has_surface) {
		vec3 view_normal = texelFetch(source_normal_roughness, pos, 0).xyz * 2.0 - 1.0;
		float normal_length = length(view_normal);
		if (normal_length < 1e-6) {
			// Nothing wrote this pixel's normal. Facing the viewer is the only
			// assumption that cannot push a ray origin inside the surface.
			normal = normalize(params.camera_position - world_position);
		} else {
			normal = rotate_by_quaternion(params.camera_rotation, view_normal / normal_length);
		}

		// Keep the strongest few lights that actually reach this pixel.
		for (uint t = 0u; t < tile_lights_used; t++) {
			uint index = tile_lights[t];
			RTLight light = rt_lights.data[index];

			vec3 light_dir;
			float distance_to_light;
			if (light.light_type == LIGHT_TYPE_DIRECTIONAL) {
				// Nothing to run to: the ray direction is the light's own. What
				// bounds it is how far the culler gathered casters, measured the way
				// the cascade fade measures it, because past that the structure holds
				// nothing to hit and every ray would come back falsely lit.
				light_dir = light.direction;
				distance_to_light = view_depth;
				if (view_depth > light.radius) {
					continue;
				}
			} else {
				vec3 to_light = light.position - world_position;
				distance_to_light = length(to_light);
				if (distance_to_light > light.radius || distance_to_light < 0.0001) {
					continue;
				}
				light_dir = to_light / distance_to_light;
			}

			if (light.light_type == LIGHT_TYPE_SPOT) {
				// Outside the cone the light contributes nothing, so leave it lit
				// and let the regular attenuation take care of it.
				if (dot(-light_dir, light.direction) < light.cos_spot_angle) {
					continue;
				}
			}

			float candidate_score = light_importance(light, light_dir, normal, distance_to_light);
			if (candidate_score <= 0.0) {
				// Behind the surface. Nothing to trace, and the channel is worth
				// more to a light that does reach here.
				continue;
			}
			uint candidate_index = index;
			for (int k = 0; k < LIGHTS_PER_PIXEL; k++) {
				if (candidate_score > score[k]) {
					float moved_score = score[k];
					uint moved_index = selected[k];
					score[k] = candidate_score;
					selected[k] = candidate_index;
					candidate_score = moved_score;
					candidate_index = moved_index;
				}
			}
		}

		// Sort the survivors by light index so that two pixels lit by the same set
		// of lights end up with byte identical channel assignments. The denoiser
		// compares those assignments to decide whether a neighbor is filterable,
		// and an equality test is only meaningful if the order is canonical.
		for (int a = 0; a < LIGHTS_PER_PIXEL - 1; a++) {
			for (int b = 0; b < LIGHTS_PER_PIXEL - 1 - a; b++) {
				if (selected[b] > selected[b + 1]) {
					uint swap_index = selected[b];
					selected[b] = selected[b + 1];
					selected[b + 1] = swap_index;
				}
			}
		}
	}

	// One rotation per pixel, advanced every frame. The temporal filter then
	// integrates a different set of emitter samples each frame rather than
	// re-averaging the same ones.
	uint frame_index = params.samples_and_frame >> 8u;
	uint requested_samples = params.samples_and_frame & 0xffu;
	vec2 sample_offsets = shadow_sample_offsets(pos, frame_index);
	float phi = sample_offsets.x * 6.2831853;
	float radial_jitter = sample_offsets.y;

	vec4 visibility = vec4(1.0);
	vec4 hit_distance = vec4(0.0);
	uvec4 slots = uvec4(SLOT_NONE);

	for (int k = 0; k < LIGHTS_PER_PIXEL; k++) {
		slots[k] = selected[k];
		if (selected[k] == SLOT_NONE) {
			continue;
		}

		RTLight light = rt_lights.data[selected[k]];
		bool is_directional = light.light_type == LIGHT_TYPE_DIRECTIONAL;

		vec3 light_dir;
		float distance_to_light;
		float ray_length;
		// How far this surface is into the sun's fade, 0 before it starts and 1
		// past the end of the range the culler gathered casters for. Beyond that
		// the structure holds nothing to hit, so a traced answer would be a
		// confident, wrong "lit" and the landscape would show a hard seam at
		// exactly the shadow distance. Fading here rather than in the forward pass
		// keeps the mask itself continuous, which is what the denoiser filters and
		// reprojects.
		float range_fade = 0.0;

		if (is_directional) {
			light_dir = light.direction;
			distance_to_light = view_distance;
			ray_length = light.max_ray_length;
			range_fade = smoothstep(light.fade_from, max(light.radius, light.fade_from + 0.0001), view_depth);
		} else {
			vec3 to_light = light.position - world_position;
			distance_to_light = length(to_light);
			light_dir = to_light / distance_to_light;
			ray_length = distance_to_light;
		}

		// Surfaces facing away from the light are fully shadowed and need no ray.
		// The forward pass shades with the normal mapped normal, which can still
		// face the light, so the mask has to say so rather than rely on N dot L.
		if (dot(normal, light_dir) <= 0.0) {
			visibility[k] = 0.0;
			continue;
		}

		// Nothing left to resolve once the fade is complete, and no structure to
		// resolve it against.
		if (range_fade >= 1.0) {
			continue;
		}

		if (params.max_ray_distance > 0.0) {
			ray_length = min(ray_length, params.max_ray_distance);
		}

		// Offset along the normal to avoid self-intersection, scaled by
		// distance because the reconstructed position is least precise far
		// away. For the sun that distance is how far the surface is from the
		// camera, since there is no light to be far from.
		float offset_scale = light.normal_bias * (1.0 + distance_to_light * 0.01);
		vec3 origin = world_position + normal * offset_scale;

		vec3 tangent;
		vec3 bitangent;
		build_basis(light_dir, tangent, bitangent);

		uint sample_count = light.size > 0.0 ? max(requested_samples, 1u) : 1u;

		// Every sample is traced; there is no early out on a pair of probe rays
		// that agree. No pair can answer for a disk: two points on the rim,
		// opposite each other, still both read lit over the whole outer half of a
		// penumbra, and the binary answer they hand back pulls those pixels to
		// fully lit. The same happens on the umbra side, so the soft edge is
		// squeezed from both ends and the shadow hardens as the sample count
		// RISES, which is the opposite of what the setting is for. A cheaper path
		// has to know the penumbra is not here before it stops, and that cannot
		// come from the rays it is trying to avoid tracing.
		float occluded = 0.0;
		float blocker_distance_sum = 0.0;
		uint traced = 0u;

		for (uint s = 0u; s < sample_count; s++) {
			vec3 direction = light_dir;

			if (light.size > 0.0) {
				vec2 disk = vogel_disk_sample(s, sample_count, phi, radial_jitter) * light.size;
				if (is_directional) {
					// The sun is not a disk at a place, it is a disk of directions.
					// Offsetting a unit vector perpendicularly by tan(angle) and
					// renormalizing sweeps exactly the cone it subtends, wherever the
					// receiver happens to be.
					direction = normalize(light_dir + tangent * disk.x + bitangent * disk.y);
				} else {
					vec3 target = light.position + tangent * disk.x + bitangent * disk.y;
					direction = normalize(target - origin);
				}
			}

			rayQueryEXT ray_query;
			// Terminating on the first hit is the obvious optimization for a shadow
			// ray, and for a yes-or-no answer it is the right one. But the distance
			// it reports is then whichever occluder traversal happened to reach
			// first, not the nearest, and the penumbra estimate below is built
			// entirely on that distance: a far occluder found before a near one
			// makes the gap look larger than it is, and a shadow that should be
			// crisp gets filtered as though it were soft. Which of the two matters
			// more depends on the hardware, so it is a setting.
			rayQueryInitializeEXT(ray_query, tlas, params.ray_flags,
					light.mask, origin, light.bias, direction, ray_length - light.bias);

			// Every candidate is opaque, so traversal needs no help from us and
			// commits its hit on its own; the loop is the form the specification
			// asks for rather than extra work.
			while (rayQueryProceedEXT(ray_query)) {
			}

			traced++;

			if (rayQueryGetIntersectionTypeEXT(ray_query, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
				occluded += 1.0;
				blocker_distance_sum += rayQueryGetIntersectionTEXT(ray_query, true);
			}
		}

		visibility[k] = 1.0 - (occluded / float(traced));

		// Hand back to fully lit across the same window the cascade path uses, so
		// a sun that gave up its shadow map stops shadowing where it always did.
		visibility[k] = mix(visibility[k], 1.0, range_fade);

		if (occluded > 0.0) {
			float mean_blocker = blocker_distance_sum / occluded;

			// How wide this shadow's penumbra actually is. For a lamp, by similar
			// triangles: the emitter's own radius scaled by how much closer the
			// blocker sits to the receiver than to the light. A blocker resting on
			// the surface gives nearly zero; one right up against the light gives an
			// enormous smear. This is what makes a raytraced shadow harden at
			// contact, and the denoiser can only preserve it if it is told how wide
			// to filter. For the sun there is no "to the light" — the source
			// subtends a fixed angle, so its penumbra is just how far that angle has
			// spread over the gap. That is the same formula in the limit, with
			// light.size already holding the tangent instead of a radius.
			float penumbra_world;
			if (is_directional) {
				penumbra_world = mean_blocker * light.size;
			} else {
				float blocker_to_light = max(distance_to_light - mean_blocker, 0.0001);
				penumbra_world = light.size * (mean_blocker / blocker_to_light);
			}

			// Reported in pixels rather than meters, because pixels are the unit
			// the denoiser's kernel is measured in. Anything else leaves it
			// guessing, and guessing wide is what washes a contact shadow out.
			float penumbra_pixels = penumbra_world * params.focal_pixels / view_distance;
			hit_distance[k] = clamp(penumbra_pixels / MAX_PENUMBRA_PIXELS, 0.0, 1.0);
		}
	}

	imageStore(dest_visibility, pos, VIS_ENCODE(visibility));
	imageStore(dest_index, pos, slots);
	imageStore(dest_hit_distance, pos, hit_distance);
}
