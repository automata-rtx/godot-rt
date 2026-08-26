#[compute]

// Ray query requires GLSL 460: glslang gates the rayQueryEXT keyword and every
// rayQuery*EXT builtin on version >= 460. This is the only shader in the tree
// that is not #version 450.
#version 460

#VERSION_DEFINES

#extension GL_EXT_ray_query : enable

#define MAX_RT_LIGHTS 4

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;

layout(set = 0, binding = 1) uniform sampler2D source_depth;

layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D dest_shadow_mask;

struct RTLight {
	vec3 position;
	float radius;

	vec3 direction;
	float cos_spot_angle;

	float size;
	uint is_spot;
	uint mask;
	float pad;
};

layout(set = 0, binding = 3, std140) uniform RTLights {
	RTLight data[MAX_RT_LIGHTS];
}
rt_lights;

layout(push_constant, std430) uniform Params {
	mat4 inv_view_projection;

	ivec2 screen_size;
	uint light_count;
	uint sample_count;

	vec3 camera_position;
	float max_ray_distance;

	float bias;
	float normal_bias;
	uint frame_index;
	float pad;
}
params;

// Cheap hash used to decorrelate the sampling pattern per pixel and per frame.
float quick_hash(vec2 pos, float seed) {
	const vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
	return fract(magic.z * fract(dot(vec3(pos, seed), magic)));
}

// Uniformly distributed point on a disk, used to sample the light's area.
vec2 sample_disk(float u1, float u2) {
	float r = sqrt(u1);
	float theta = u2 * 6.2831853;
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

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}

	// Fully lit by default, so any early out leaves the pixel unshadowed rather
	// than black.
	vec4 visibility = vec4(1.0);

	float depth = texelFetch(source_depth, pos, 0).r;

	// Godot uses reverse-Z, so 0 is the far plane. Skip the sky entirely.
	if (depth <= 0.0) {
		imageStore(dest_shadow_mask, pos, visibility);
		return;
	}

	vec2 uv = (vec2(pos) + 0.5) / vec2(params.screen_size);
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world = params.inv_view_projection * ndc;
	vec3 world_position = world.xyz / world.w;

	// Reconstruct a geometric normal from neighbouring depth taps. Derivatives
	// are not available in a compute shader, and this avoids a dependency on the
	// normal/roughness buffer, which Forward+ does not produce unless some other
	// effect asks for it.
	vec2 texel = 1.0 / vec2(params.screen_size);
	ivec2 max_pos = params.screen_size - ivec2(1);

	float depth_x = texelFetch(source_depth, min(pos + ivec2(1, 0), max_pos), 0).r;
	float depth_y = texelFetch(source_depth, min(pos + ivec2(0, 1), max_pos), 0).r;

	vec4 ndc_x = vec4((uv + vec2(texel.x, 0.0)) * 2.0 - 1.0, depth_x, 1.0);
	vec4 ndc_y = vec4((uv + vec2(0.0, texel.y)) * 2.0 - 1.0, depth_y, 1.0);
	vec4 world_x = params.inv_view_projection * ndc_x;
	vec4 world_y = params.inv_view_projection * ndc_y;

	vec3 position_x = world_x.xyz / world_x.w;
	vec3 position_y = world_y.xyz / world_y.w;

	vec3 normal = cross(position_x - world_position, position_y - world_position);
	float normal_length = length(normal);
	if (normal_length < 1e-12) {
		// Degenerate neighbourhood (a depth discontinuity); fall back to facing
		// the camera so the pixel stays lit rather than producing garbage rays.
		normal = normalize(params.camera_position - world_position);
	} else {
		normal /= normal_length;
	}

	uint light_count = min(params.light_count, uint(MAX_RT_LIGHTS));

	for (uint i = 0u; i < light_count; i++) {
		RTLight light = rt_lights.data[i];

		vec3 to_light = light.position - world_position;
		float distance_to_light = length(to_light);

		if (distance_to_light > light.radius || distance_to_light < 0.0001) {
			continue;
		}

		vec3 light_dir = to_light / distance_to_light;

		// Surfaces facing away from the light are fully shadowed and need no ray.
		float n_dot_l = dot(normal, light_dir);
		if (n_dot_l <= 0.0) {
			visibility[i] = 0.0;
			continue;
		}

		if (light.is_spot != 0u) {
			// Outside the cone the light contributes nothing, so leave it lit and
			// let the regular attenuation take care of it.
			if (dot(-light_dir, light.direction) < light.cos_spot_angle) {
				continue;
			}
		}

		float ray_length = distance_to_light;
		if (params.max_ray_distance > 0.0) {
			ray_length = min(ray_length, params.max_ray_distance);
		}

		// Offset along the geometric normal to avoid self-intersection. Scaled by
		// distance so that faraway surfaces, where the reconstructed position is
		// least precise, get a proportionally larger offset.
		float offset_scale = params.normal_bias * (1.0 + distance_to_light * 0.01);
		vec3 origin = world_position + normal * offset_scale;

		vec3 tangent;
		vec3 bitangent;
		build_basis(light_dir, tangent, bitangent);

		uint sample_count = max(params.sample_count, 1u);
		float occluded = 0.0;

		for (uint s = 0u; s < sample_count; s++) {
			vec3 direction = light_dir;

			if (light.size > 0.0) {
				// Cone sample across the light's emitter disk. The penumbra widens
				// with distance from the blocker because the cone does, which is
				// what produces contact hardening.
				float seed = float(params.frame_index * sample_count + s);
				float u1 = quick_hash(vec2(pos), seed);
				float u2 = quick_hash(vec2(pos) + vec2(17.0, 31.0), seed);

				vec2 disk = sample_disk(u1, u2) * light.size;
				vec3 target = light.position + tangent * disk.x + bitangent * disk.y;
				direction = normalize(target - origin);
			}

			rayQueryEXT ray_query;
			rayQueryInitializeEXT(ray_query, tlas,
					gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT,
					light.mask, origin, params.bias, direction, ray_length - params.bias);

			rayQueryProceedEXT(ray_query);

			if (rayQueryGetIntersectionTypeEXT(ray_query, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
				occluded += 1.0;
			}
		}

		visibility[i] = 1.0 - (occluded / float(sample_count));
	}

	imageStore(dest_shadow_mask, pos, visibility);
}
