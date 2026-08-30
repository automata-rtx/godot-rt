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

// Rays cast before the shader decides whether the rest can change the answer.
#define PROBE_SAMPLES 2u

// Widest penumbra the hit distance channel can describe, in pixels. Anything
// wider saturates, which is harmless: the denoiser's filter is already at its
// full width by then. Must match MAX_PENUMBRA_PIXELS in rt_shadow_atrous.glsl.
#define MAX_PENUMBRA_PIXELS 32.0

// Slot value meaning "this channel carries no light". Matches RT_SLOT_NONE in
// light_data_inc.glsl.
#define SLOT_NONE 255u

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

// Mean distance to the occluders that were hit, normalized by the light's
// range. The denoiser needs this to size its filter: penumbra width grows with
// the distance between receiver and blocker, which is what makes a raytraced
// shadow harden at contact.
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
	// in. The bias pair that used to sit here is now per light.
	float focal_pixels;
	float pad;
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

// Interleaved gradient noise. Cheap, and its spatial distribution is far better
// behaved than a plain hash, which matters because the spatial filter runs over
// whatever pattern this leaves behind.
float interleaved_gradient_noise(vec2 pos, uint frame) {
	pos += float(frame) * 5.588238;
	return fract(52.9829189 * fract(dot(pos, vec2(0.06711056, 0.00583715))));
}

// Vogel disk. For a handful of samples this covers the emitter far more evenly
// than independent random points, so the raw signal starts with much less
// variance for the denoiser to remove.
vec2 vogel_disk_sample(uint index, uint count, float phi) {
	const float golden_angle = 2.39996323;
	float r = sqrt((float(index) + 0.5) / float(count));
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
	float phi = interleaved_gradient_noise(vec2(pos), frame_index) * 6.2831853;

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
		float occluded = 0.0;
		float blocker_distance_sum = 0.0;
		uint traced = 0u;

		for (uint s = 0u; s < sample_count; s++) {
			// Take the innermost and outermost points of the disk first, so the
			// two probe rays span the emitter rather than clustering in its
			// middle. The rest follow in their original order; this is a
			// permutation of the same sample set, so nothing is weighted twice.
			uint sample_index = s == 0u ? 0u : (s == 1u ? sample_count - 1u : s - 1u);

			vec3 direction = light_dir;

			if (light.size > 0.0) {
				vec2 disk = vogel_disk_sample(sample_index, sample_count, phi) * light.size;
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
			rayQueryInitializeEXT(ray_query, tlas,
					gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT,
					light.mask, origin, light.bias, direction, ray_length - light.bias);

			rayQueryProceedEXT(ray_query);

			traced++;

			if (rayQueryGetIntersectionTypeEXT(ray_query, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
				occluded += 1.0;
				blocker_distance_sum += rayQueryGetIntersectionTEXT(ray_query, true);
			}

			// Two rays spanning the emitter that agree put this point wholly
			// inside the shadow or wholly outside it, and the emitter is small
			// enough on screen that the rays between them would agree too. Only
			// the penumbra, where they disagree, pays for the full set — which
			// is a small part of any frame and most of what the samples are for.
			if (traced == PROBE_SAMPLES && sample_count > PROBE_SAMPLES &&
					(occluded == 0.0 || occluded == float(PROBE_SAMPLES))) {
				break;
			}
		}

		visibility[k] = 1.0 - (occluded / float(traced));

		// Hand back to fully lit across the same window the cascade path uses, so
		// a sun that gave up its shadow map stops shadowing where it always did.
		visibility[k] = mix(visibility[k], 1.0, range_fade);

		if (occluded > 0.0) {
			float mean_blocker = blocker_distance_sum / occluded;

			// How wide this shadow's penumbra actually is, by similar triangles:
			// the emitter's own width scaled by how much closer the blocker sits
			// to the receiver than to the light. A blocker resting on the surface
			// gives nearly zero; one right up against the light gives an enormous
			// smear. This is what makes a raytraced shadow harden at contact, and
			// the denoiser can only preserve it if it is told how wide to filter.
			// For a lamp, similar triangles: the emitter's own radius scaled by how
			// much closer the blocker sits to the receiver than to the light. For
			// the sun there is no "to the light" — the source subtends a fixed
			// angle, so its penumbra is just how far that angle has spread over the
			// gap. That is the same formula in the limit, with light.size already
			// holding the tangent instead of a radius.
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

	imageStore(dest_visibility, pos, visibility);
	imageStore(dest_index, pos, slots);
	imageStore(dest_hit_distance, pos, hit_distance);
}
