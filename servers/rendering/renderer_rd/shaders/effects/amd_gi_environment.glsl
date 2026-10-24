#[compute]
#version 450
#VERSION_DEFINES

#include "../oct_inc.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#ifdef CONVERT_OCTMAP
layout(set = 0, binding = 0) uniform sampler2D source_radiance;
#else
layout(set = 0, binding = 0) uniform sampler2DArray source_radiance;
#endif
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2DArray destination;
layout(push_constant, std430) uniform Params {
	uint size;
	float border;
	uvec2 padding;
}
params;

void main() {
	uvec3 pixel = gl_GlobalInvocationID;
	if (any(greaterThanEqual(pixel.xy, uvec2(params.size))) || pixel.z >= 6u) {
		return;
	}
	vec2 uv = (vec2(pixel.xy) + 0.5) / float(params.size);
#ifdef CONVERT_OCTMAP
	vec2 p = uv * 2.0 - 1.0;
	vec3 direction;
	// Vulkan cube image face order and orientation, in native sky space.
	switch (pixel.z) {
		case 0u:
			direction = vec3(1, -p.y, -p.x);
			break;
		case 1u:
			direction = vec3(-1, -p.y, p.x);
			break;
		case 2u:
			direction = vec3(p.x, 1, p.y);
			break;
		case 3u:
			direction = vec3(p.x, -1, -p.y);
			break;
		case 4u:
			direction = vec3(p.x, -p.y, 1);
			break;
		default:
			direction = vec3(-p.x, -p.y, -1);
			break;
	}
	uv = vec3_to_oct_with_border(normalize(direction), vec2(params.border, 1.0 - 2.0 * params.border));
	vec3 radiance = textureLod(source_radiance, uv, 0.0).rgb;
#else
	// At a half-sized texel center, bilinear filtering is the 2x2 box mean.
	vec3 radiance = textureLod(source_radiance, vec3(uv, pixel.z), 0.0).rgb;
#endif
	imageStore(destination, ivec3(pixel), vec4(radiance, 1));
}
