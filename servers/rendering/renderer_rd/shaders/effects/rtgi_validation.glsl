#[compute]

#version 460

#VERSION_DEFINES

#extension GL_EXT_ray_query : require

// Uncached diffuse path integration for checking transport before the AMD cache
// is connected. Deterministic independent samples; no temporal history or denoiser.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#include "rt_gi_transport_inc.glsl"

void main() {
	uvec2 pixel = gl_GlobalInvocationID.xy;
	if (any(greaterThanEqual(pixel, params.size))) {
		return;
	}
	float depth = texelFetch(depth_buffer, ivec2(pixel), 0).r;
	vec3 view_normal = texelFetch(normal_buffer, ivec2(pixel), 0).xyz * 2.0 - 1.0;
	if (depth <= 0.0 || dot(view_normal, view_normal) < 0.01) {
		imageStore(output_diffuse, ivec2(pixel), vec4(0.0));
		return;
	}
	vec2 screen_uv = (vec2(pixel) + 0.5) / vec2(params.size);
	vec4 world = params.inv_view_projection * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	vec3 primary_position = world.xyz / world.w;
	vec3 normal = normalize(view_normal);
	vec4 q = params.camera_rotation;
	vec3 primary_normal = normal + 2.0 * cross(q.xyz, cross(q.xyz, normal) + q.w * normal);
	vec3 radiance = vec3(0.0);
	uint state = pixel.x + pixel.y * params.size.x + 0x9e3779b9u;
	for (uint sample_index = 0u; sample_index < params.samples; sample_index++) {
		vec3 origin = primary_position + primary_normal * 0.002;
		vec3 direction = cosine_direction(primary_normal, state);
		vec3 throughput = vec3(1.0);
		for (uint bounce = 0u; bounce < params.bounces; bounce++) {
			uint instance;
			vec3 position, uv, hit_normal;
			if (!trace(origin, direction, params.max_distance, 0u, instance, position, uv, hit_normal)) {
				break; // No sky/environment sampling in this initial validation integrator.
			}
			hit_normal = faceforward(hit_normal, direction, hit_normal);
			vec3 albedo = textureLod(albedo_atlas, uv, 0.0).rgb;
			float metallic = textureLod(orm_atlas, uv, 0.0).b;
			vec3 diffuse = albedo * (1.0 - metallic);
			vec3 outgoing = textureLod(emission_atlas, uv, 0.0).rgb;
			outgoing += diffuse * direct_irradiance(position, hit_normal, hits.data[instance].material.z) / PI;
			radiance += throughput * outgoing;
			throughput *= diffuse;
			if (max(throughput.r, max(throughput.g, throughput.b)) < 0.00001) {
				break;
			}
			origin = position + hit_normal * 0.002;
			direction = cosine_direction(hit_normal, state);
		}
	}
	// The Forward+ indirect-diffuse input applies the visible material's albedo
	// and metallic term. No first-surface BRDF is applied twice here.
	imageStore(output_diffuse, ivec2(pixel), vec4(radiance * (params.exposure / float(params.samples)), 0.0));
}
