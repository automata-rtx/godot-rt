// Shared native-material hit shading and Vulkan visibility queries.
layout(set = 0, binding = 0) uniform accelerationStructureEXT scene;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_buffer;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D output_diffuse;
layout(set = 0, binding = 4, std430) restrict readonly buffer Hits {
	uvec4 data[]; // first material tile, flags/emitter base, full render layer mask, shadow caster layers
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
	Light data[1024];
	Emitter emitters[];
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

uint random_bits(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
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
	return atlas_tile_position(hits.data[instance].x + triangle, bary);
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal, out uint primitive) {
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
	if (distance <= 0.001) {
		return false;
	}
	rayQueryEXT query;
	// Force candidate processing even though the shared shadow BLAS is opaque.
	// This retains geometry sharing while alpha tests belong to this consumer.
	rayQueryInitializeEXT(query, scene, gl_RayFlagsNoOpaqueEXT, 0xFF, origin, 0.001, direction, distance);
	while (rayQueryProceedEXT(query)) {
		if (rayQueryGetIntersectionTypeEXT(query, false) == gl_RayQueryCandidateIntersectionTriangleEXT) {
			uint candidate = rayQueryGetIntersectionInstanceCustomIndexEXT(query, false);
			if (shadow_mask != 0u && (hits.data[candidate].w & shadow_mask) == 0u) {
				continue;
			}
			uint triangle = rayQueryGetIntersectionPrimitiveIndexEXT(query, false);
			vec3 candidate_uv = atlas_position(candidate, triangle, rayQueryGetIntersectionBarycentricsEXT(query, false));
			float opacity = clamp(textureLod(albedo_atlas, candidate_uv, 0.0).a, 0.0, 1.0);
			bool covered = opacity >= 0.5;
			if ((hits.data[candidate].y & 0x40000000u) != 0u) {
				// Depth-writing blend materials retain their opaque texels. Fractional
				// alpha samples straight-through coverage, not refraction. Hash each
				// candidate independently so traversal ordering cannot change its test.
				uvec3 o = floatBitsToUint(origin);
				uvec3 d = floatBitsToUint(direction);
				uint state = o.x * 1597334677u ^ o.y * 3812015801u ^ o.z * 2798796415u;
				state ^= d.x * 197830471u ^ d.y * 295559667u ^ d.z * 269805325u;
				state ^= candidate * 747796405u ^ triangle * 2891336453u ^ params.padding * 277803737u;
				covered = opacity > random_float(state);
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
	uv = atlas_position(instance, rayQueryGetIntersectionPrimitiveIndexEXT(query, true), rayQueryGetIntersectionBarycentricsEXT(query, true));
	position = origin + direction * rayQueryGetIntersectionTEXT(query, true);
	normal = vec3(0);
	if (shadow_mask == 0u) {
		normal = normalize(textureLod(normal_atlas, uv, 0.0).xyz * 2.0 - 1.0);
		if ((hits.data[instance].y & 0x80000000u) != 0u) {
			normal = normalize(transpose(mat3(rayQueryGetIntersectionWorldToObjectEXT(query, true))) * normal);
		}
	}
	return true;
}

bool trace(vec3 origin, vec3 direction, float distance, uint shadow_mask, out uint instance, out vec3 position, out vec3 uv, out vec3 normal) {
	uint primitive;
	return trace(origin, direction, distance, shadow_mask, instance, position, uv, normal, primitive);
}

// Keep proposal evaluation separate from visibility so resampled lighting can
// evaluate several inexpensive candidates and trace only the selected light.
vec3 unshadowed_irradiance(uint index, vec3 position, vec3 normal, uint mask, out vec3 direction, out float distance) {
	Light light = lights.data[index];
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
	Light light = lights.data[index];
	uint blocker;
	vec3 blocker_position, blocker_uv, blocker_normal;
	if (light.shadows != 0u && light.shadow_mask != 0u && trace(position + normal * 0.002, direction, max(distance - 0.004, 0.001), light.shadow_mask, blocker, blocker_position, blocker_uv, blocker_normal)) {
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
