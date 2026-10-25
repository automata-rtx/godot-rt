// Shared native-material hit shading and Vulkan visibility queries.
layout(set = 0, binding = 0) uniform accelerationStructureEXT scene;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_buffer;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D output_diffuse;
struct GIHitData {
	uvec4 material;
	uvec2 vertex_address;
	uvec2 index_address;
	uvec4 geometry;
	uvec2 normal_address;
	uvec2 padding;
	mat3x4 object_to_world;
	mat3 normal_to_world;
};
layout(set = 0, binding = 4, std430) restrict readonly buffer Hits {
	GIHitData data[]; // first material tile, flags/emitter base, full render layer mask, shadow caster layers
}
hits;
struct Light {
	vec3 position;
	float range;
	vec3 direction;
	uint type;
	vec3 color;
	float decay;
	float cos_angle;
	float spot_attenuation;
	uint mask;
	uint shadows;
	float shadow_opacity;
	uint shadow_mask;
	uvec2 padding;
};
struct Emitter {
	vec4 position_area;
	vec4 edge1_power;
	vec4 edge2;
	vec4 emission_tile;
};
layout(set = 0, binding = 5, std430) restrict readonly buffer Lights {
	uvec4 data[];
}
lights;
layout(set = 0, binding = 6) uniform sampler2DArray albedo_atlas;
layout(set = 0, binding = 7) uniform sampler2DArray normal_atlas;
layout(set = 0, binding = 8) uniform sampler2DArray orm_atlas;
layout(set = 0, binding = 9) uniform sampler2DArray emission_atlas;
layout(push_constant, std430) uniform Params {
	mat4 inv_view_projection;
	vec4 camera_rotation;
	vec4 camera_position;
	uvec2 size;
	uint samples;
	uint bounces;
	float max_distance;
	uint light_count;
	float exposure;
	uint padding;
}
params;

const float PI = 3.14159265358979323846;

Light gi_light(uint index) {
	uint first = index * 5u;
	uvec4 a = lights.data[first], b = lights.data[first + 1u], c = lights.data[first + 2u], d = lights.data[first + 3u], e = lights.data[first + 4u];
	return Light(uintBitsToFloat(a.xyz), uintBitsToFloat(a.w), uintBitsToFloat(b.xyz), b.w,
			uintBitsToFloat(c.xyz), uintBitsToFloat(c.w), uintBitsToFloat(d.x), uintBitsToFloat(d.y), d.z, d.w,
			uintBitsToFloat(e.x), e.y, e.zw);
}
#ifdef AMD_GI_EMITTER_STORAGE_OFFSET
uint gi_emitter_storage_offset();
#else
uint gi_emitter_storage_offset() {
	return params.light_count * 5u;
}
#endif
Emitter gi_emitter(uint index) {
	uint first = gi_emitter_storage_offset() + index * 4u;
	return Emitter(uintBitsToFloat(lights.data[first]), uintBitsToFloat(lights.data[first + 1u]), uintBitsToFloat(lights.data[first + 2u]), uintBitsToFloat(lights.data[first + 3u]));
}

uint random_bits(inout uint state) {
#ifdef AMD_GI_REFERENCE_RANDOM
	uint previous = state;
	state = state * 747796405u + 2891336453u;
	uint word = ((previous >> ((previous >> 28u) + 4u)) ^ previous) * 277803737u;
#else
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
#endif
	return (word >> 22u) ^ word;
}
float random_float(inout uint state) {
	return float(random_bits(state) >> 8u) * (1.0 / 16777216.0);
}
vec3 cosine_direction(vec3 normal, inout uint state) {
	float r = sqrt(random_float(state));
	float angle = 2.0 * PI * random_float(state);
	vec3 tangent = normalize(cross(abs(normal.z) < 0.99 ? vec3(0, 0, 1) : vec3(0, 1, 0), normal));
	return tangent * (r * cos(angle)) + cross(normal, tangent) * (r * sin(angle)) + normal * sqrt(max(0.0, 1.0 - r * r));
}
vec3 atlas_tile_position(uint material_tile, vec2 bary) {
	uint page = material_tile / 1024u;
	uint local_triangle = material_tile % 1024u;
	const uint columns = 32u;
	// Use a covered texel within this triangle, never another triangle's data or
	// an uncovered border. This small validation tile intentionally limits detail.
	uint tile_size = uint(textureSize(albedo_atlas, 0).x) / columns;
	if (tile_size == 2u) {
		uvec2 tile = uvec2(local_triangle % columns, local_triangle / columns);
		return vec3((vec2(tile * tile_size) + 0.5) / float(tile_size * columns), float(page));
	}
	int interior = int(tile_size) - 2;
	ivec2 sample_pixel = clamp(ivec2(floor(vec2(1.0) + bary * float(interior))), ivec2(1), ivec2(interior));
	int excess = max(sample_pixel.x + sample_pixel.y - interior, 0);
	if (sample_pixel.x > sample_pixel.y) {
		sample_pixel.x -= excess;
	} else {
		sample_pixel.y -= excess;
	}
	uvec2 tile = uvec2(local_triangle % columns, local_triangle / columns);
	return vec3((vec2(tile * tile_size) + vec2(sample_pixel) + 0.5) / float(tile_size * columns), float(page));
}

vec3 atlas_position(uint instance, uint triangle, vec2 bary) {
	return atlas_tile_position(hits.data[instance].material.x + triangle, bary);
}

#ifdef AMD_GI_REFERENCE_RANDOM
#include "amd_gi_geometry_inc.glsl"
#include "rt_material_source_inc.glsl"
#GLOBALS
vec3 gi_offset_position(vec3 position, vec3 normal);
#endif

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal, out uint primitive, out bool front_face, out float hit_distance, out vec3 geometry_normal, out vec2 barycentrics) {
#ifndef AMD_GI_REFERENCE_RANDOM
	// Stay inside the volume actually gathered by the CPU. Missing out-of-range
	// geometry must not be confused with a complete unbounded scene.
	vec3 local = origin - params.camera_position.xyz;
	if (any(greaterThan(abs(local), vec3(params.max_distance)))) {
		return false;
	}
	for (int axis = 0; axis < 3; axis++) {
		if (abs(direction[axis]) > 1e-8) {
			float boundary = direction[axis] > 0.0 ? params.max_distance : -params.max_distance;
			distance = min(distance, (boundary - local[axis]) / direction[axis]);
		}
	}

#endif
	if (distance <= 0.0) {
		return false;
	}
	rayQueryEXT query;
// Alpha-bearing TLAS instances override the shared BLAS's opacity. Full native
// shadow layer masks still require candidate filtering for shadow rays.
#ifdef AMD_GI_REFERENCE_RANDOM
	rayQueryInitializeEXT(query, scene, shadow_mask != 0u ? gl_RayFlagsNoOpaqueEXT : gl_RayFlagsNoneEXT, 0xFF, origin, 0.0, direction, distance);
#else
	rayQueryInitializeEXT(query, scene, gl_RayFlagsNoOpaqueEXT, 0xFF, origin, 0.001, direction, distance);
#endif
	while (rayQueryProceedEXT(query)) {
		if (rayQueryGetIntersectionTypeEXT(query, false) == gl_RayQueryCandidateIntersectionTriangleEXT) {
			uint candidate = rayQueryGetIntersectionInstanceCustomIndexEXT(query, false);
			if (shadow_mask != 0u && (hits.data[candidate].material.w & shadow_mask) == 0u) {
				continue;
			}
			uint triangle = rayQueryGetIntersectionPrimitiveIndexEXT(query, false);
#ifdef AMD_GI_REFERENCE_RANDOM
			uint material_flags = hits.data[candidate].geometry.y;
			bool candidate_front = rayQueryGetIntersectionFrontFaceEXT(query, false);
			// AMD only applies sidedness testing to nonopaque materials.
			if ((material_flags & 1u) != 0u && (((material_flags & 2u) != 0u && !candidate_front) || ((material_flags & 4u) != 0u && candidate_front))) {
				continue;
			}
#endif
			vec3 candidate_uv = atlas_position(candidate, triangle, rayQueryGetIntersectionBarycentricsEXT(query, false));
#ifdef AMD_GI_REFERENCE_RANDOM
			float opacity = (material_flags & 1u) != 0u ? gi_source_material(candidate, triangle, rayQueryGetIntersectionBarycentricsEXT(query, false), candidate_front, 0.0).albedo.a : 1.0;
#else
			float opacity = clamp(textureLod(albedo_atlas, candidate_uv, 0.0).a, 0.0, 1.0);
#endif
#ifdef AMD_GI_REFERENCE_RANDOM
			bool covered = (material_flags & 1u) == 0u || opacity > 0.5;
#else
			bool covered = opacity >= 0.5;
#endif
			if ((hits.data[candidate].material.y & 0x40000000u) != 0u) {
#ifdef AMD_GI_REFERENCE_RANDOM
				vec3 v0, v1, v2;
				gi_triangle_vertices(candidate, triangle, v0, v1, v2);
				vec2 barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, false);
				vec3 object_position = v0 * (1.0 - barycentrics.x - barycentrics.y) + v1 * barycentrics.x + v2 * barycentrics.y;
				float threshold = float(gi_alpha_hash(floatBitsToUint(vec4(object_position, float(params.padding)))) >> 8u) * (1.0 / 16777216.0);
				covered = opacity > threshold;
#else
				// Depth-writing blend materials retain their opaque texels. Fractional
				// alpha samples straight-through coverage, not refraction. Hash each
				// candidate independently so traversal ordering cannot change its test.
				uvec3 o = floatBitsToUint(origin);
				uvec3 d = floatBitsToUint(direction);
				uint state = o.x * 1597334677u ^ o.y * 3812015801u ^ o.z * 2798796415u;
				state ^= d.x * 197830471u ^ d.y * 295559667u ^ d.z * 269805325u;
				state ^= candidate * 747796405u ^ triangle * 2891336453u ^ params.padding * 277803737u;
				covered = opacity > random_float(state);
#endif
			}
			if (covered) {
				rayQueryConfirmIntersectionEXT(query);
			}
		}
	}
	if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
		return false;
	}
	instance = rayQueryGetIntersectionInstanceCustomIndexEXT(query, true);
	primitive = rayQueryGetIntersectionPrimitiveIndexEXT(query, true);
	front_face = rayQueryGetIntersectionFrontFaceEXT(query, true);
	barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, true);
	uv = atlas_position(instance, primitive, barycentrics);
	hit_distance = rayQueryGetIntersectionTEXT(query, true);
	position = origin + direction * hit_distance;
	normal = vec3(0);
	geometry_normal = vec3(0);
#ifdef AMD_GI_REFERENCE_RANDOM
	if (shadow_mask == 0u) {
		vec3 v0, v1, v2;
		gi_triangle_vertices(instance, primitive, v0, v1, v2);
		// Godot uses clockwise winding. Construct the local geometric normal
		// before applying the inverse transpose exactly once. The interpolated
		// vertex normal is a distinct input to reservoir/continuation shading.
		vec3 local_geometry_normal = cross(v2 - v0, v1 - v0);
		vec3 local_normal = gi_triangle_normal(instance, primitive, barycentrics, local_geometry_normal);
		mat3 normal_transform = transpose(mat3(rayQueryGetIntersectionWorldToObjectEXT(query, true)));
		geometry_normal = normalize(normal_transform * local_geometry_normal);
		normal = normalize(normal_transform * local_normal);
		mat4x3 transform = rayQueryGetIntersectionObjectToWorldEXT(query, true);
		v0 = transform * vec4(v0, 1);
		v1 = transform * vec4(v1, 1);
		v2 = transform * vec4(v2, 1);
		position = (1.0 - barycentrics.x - barycentrics.y) * v0 + barycentrics.x * v1 + barycentrics.y * v2;
	}
#else
	if (shadow_mask == 0u) {
		normal = normalize(textureLod(normal_atlas, uv, 0.0).xyz * 2.0 - 1.0);
		if ((hits.data[instance].material.y & 0x80000000u) != 0u) {
			normal = normalize(transpose(mat3(rayQueryGetIntersectionWorldToObjectEXT(query, true))) * normal);
		}
		geometry_normal = normal;
	}
#endif
	return true;
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal, out uint primitive, out bool front_face, out float hit_distance, out vec3 geometry_normal) {
	vec2 barycentrics;
	return trace(origin, direction, distance, shadow_mask, instance, position, uv, normal, primitive, front_face, hit_distance, geometry_normal, barycentrics);
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal, out uint primitive, out bool front_face, out float hit_distance) {
	vec3 geometry_normal;
	return trace(origin, direction, distance, shadow_mask, instance, position, uv, normal, primitive, front_face, hit_distance, geometry_normal);
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal, out uint primitive, out bool front_face) {
	float hit_distance;
	return trace(origin, direction, distance, shadow_mask, instance, position, uv, normal, primitive, front_face, hit_distance);
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal, out uint primitive) {
	bool front_face;
	return trace(origin, direction, distance, shadow_mask, instance, position, uv, normal, primitive, front_face);
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal) {
	uint primitive;
	return trace(origin, direction, distance, shadow_mask, instance, position, uv, normal, primitive);
}

// Keep proposal evaluation separate from visibility so resampled lighting can
// evaluate several inexpensive candidates and trace only the selected light.
vec3 unshadowed_irradiance(uint index, vec3 position, vec3 normal, uint mask, out vec3 direction, out float distance) {
	Light light = gi_light(index);
	direction = light.direction;
	distance = params.max_distance;
	if ((mask & light.mask) == 0u) {
		return vec3(0);
	}
	float attenuation = 1.0;
	if (light.type != 0u) {
		direction = light.position - position;
		distance = length(direction);
		direction /= max(distance, 0.0001);
		float nd = distance / max(light.range, 0.0001);
		attenuation = pow(max(1.0 - nd * nd * nd * nd, 0.0), 2.0) * pow(max(distance, 0.0001), -light.decay);
		if (light.type == 2u) {
			float cosine = dot(direction, light.direction);
			float rim = max(0.0001, (1.0 - max(cosine, light.cos_angle)) / max(1.0 - light.cos_angle, 0.0001));
			attenuation *= 1.0 - pow(rim, 1.0 / max(light.spot_attenuation, 0.0001));
		}
	}
	return light.color * (attenuation * max(dot(normal, direction), 0.0));
}
float light_visibility(uint index, vec3 position, vec3 normal, vec3 direction, float distance) {
	Light light = gi_light(index);
	uint blocker;
	vec3 blocker_position, blocker_uv, blocker_normal;
#ifdef AMD_GI_REFERENCE_RANDOM
	vec3 origin = gi_offset_position(position, normal);
	if (light.type != 0u) {
		direction = light.position - origin;
		distance = 1.0 - 1.0 / 16384.0;
	}
#else
	vec3 origin = position + normal * 0.002;
	distance = max(distance - 0.004, 0.001);
#endif
	if (light.shadows != 0u && light.shadow_mask != 0u && trace(origin, direction, distance, light.shadow_mask, blocker, blocker_position, blocker_uv, blocker_normal)) {
		return 1.0 - light.shadow_opacity;
	}
	return 1.0;
}
vec3 direct_irradiance(vec3 position, vec3 normal, uint mask) {
	vec3 irradiance = vec3(0);
	for (uint i = 0u; i < params.light_count; i++) {
		vec3 direction;
		float distance;
		vec3 value = unshadowed_irradiance(i, position, normal, mask, direction, distance);
		if (any(notEqual(value, vec3(0)))) {
			irradiance += value * light_visibility(i, position, normal, direction, distance);
		}
	}
	return irradiance;
}
