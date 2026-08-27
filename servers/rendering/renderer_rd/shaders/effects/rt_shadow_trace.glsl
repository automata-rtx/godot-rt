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

// Per-light visibility in [0, 1], one channel per light.
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D dest_visibility;

// Mean distance to the occluders that were hit, normalized by the light's
// range. The denoiser needs this to size its filter: penumbra width grows with
// the distance between receiver and blocker, which is what makes a raytraced
// shadow harden at contact.
layout(rgba8, set = 0, binding = 3) uniform restrict writeonly image2D dest_hit_distance;

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

layout(set = 0, binding = 4, std140) uniform RTLights {
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

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.screen_size))) {
		return;
	}

	// Fully lit by default, so any early out leaves the pixel unshadowed rather
	// than black.
	vec4 visibility = vec4(1.0);
	vec4 hit_distance = vec4(0.0);

	float depth = texelFetch(source_depth, pos, 0).r;

	// Godot uses reverse-Z, so 0 is the far plane. Skip the sky entirely.
	if (depth <= 0.0) {
		imageStore(dest_visibility, pos, visibility);
		imageStore(dest_hit_distance, pos, hit_distance);
		return;
	}

	vec3 world_position = reconstruct_world_position(pos, depth);

	// Geometric normal from neighboring depth taps. The normal buffer holds
	// view space normals and converting them here would need the camera basis,
	// which does not fit in the 128 byte push constant alongside the inverse
	// view projection. The denoiser reads that buffer directly instead, where
	// view space comparisons between neighbors need no conversion at all.
	ivec2 max_pos = params.screen_size - ivec2(1);
	vec3 position_x = reconstruct_world_position(min(pos + ivec2(1, 0), max_pos), texelFetch(source_depth, min(pos + ivec2(1, 0), max_pos), 0).r);
	vec3 position_y = reconstruct_world_position(min(pos + ivec2(0, 1), max_pos), texelFetch(source_depth, min(pos + ivec2(0, 1), max_pos), 0).r);

	vec3 normal = cross(position_x - world_position, position_y - world_position);
	float normal_length = length(normal);
	if (normal_length < 1e-12) {
		normal = normalize(params.camera_position - world_position);
	} else {
		normal /= normal_length;
	}
	// The winding depends on the handedness of the projection; force the normal
	// to face the viewer, which holds for every visible surface.
	if (dot(normal, params.camera_position - world_position) < 0.0) {
		normal = -normal;
	}

	// One rotation per pixel, advanced every frame. The temporal filter then
	// integrates a different set of emitter samples each frame rather than
	// re-averaging the same ones.
	float phi = interleaved_gradient_noise(vec2(pos), params.frame_index) * 6.2831853;

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

		// Offset along the normal to avoid self-intersection, scaled by distance
		// because the reconstructed position is least precise far away.
		float offset_scale = params.normal_bias * (1.0 + distance_to_light * 0.01);
		vec3 origin = world_position + normal * offset_scale;

		vec3 tangent;
		vec3 bitangent;
		build_basis(light_dir, tangent, bitangent);

		uint sample_count = light.size > 0.0 ? max(params.sample_count, 1u) : 1u;
		float occluded = 0.0;
		float blocker_distance_sum = 0.0;

		for (uint s = 0u; s < sample_count; s++) {
			vec3 direction = light_dir;

			if (light.size > 0.0) {
				vec2 disk = vogel_disk_sample(s, sample_count, phi) * light.size;
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
				blocker_distance_sum += rayQueryGetIntersectionTEXT(ray_query, true);
			}
		}

		visibility[i] = 1.0 - (occluded / float(sample_count));

		if (occluded > 0.0) {
			// Mean blocker distance, normalized so it survives an 8 bit channel.
			float mean_blocker = blocker_distance_sum / occluded;
			hit_distance[i] = clamp(mean_blocker / max(light.radius, 0.0001), 0.0, 1.0);
		}
	}

	imageStore(dest_visibility, pos, visibility);
	imageStore(dest_hit_distance, pos, hit_distance);
}
