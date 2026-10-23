#[compute]
#version 450
#VERSION_DEFINES
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict readonly buffer Vertices {
	float data[];
}
vertices;
layout(set = 0, binding = 1, std430) restrict readonly buffer Indices {
	uint data[];
}
indices;
struct Emitter {
	vec4 position_area;
	vec4 edge1_power;
	vec4 edge2;
	vec4 emission_tile;
};
layout(set = 0, binding = 2, std430) restrict buffer Lights {
	uvec4 analytic[5120]; // 1024 analytic lights, 80 bytes each.
	Emitter emitters[];
}
lights;
layout(set = 0, binding = 3) uniform sampler2DArray emission_atlas;
layout(set = 0, binding = 4) uniform sampler2DArray albedo_atlas;
layout(push_constant, std430) uniform Params {
	mat4 transform;
	uvec4 geometry;
}
params;
vec3 vertex(uint index) {
	if (params.geometry.z == 2u) {
		index = (indices.data[index / 2u] >> ((index & 1u) * 16u)) & 65535u;
	} else if (params.geometry.z == 4u) {
		index = indices.data[index];
	}
	return (params.transform * vec4(vertices.data[index * 3u], vertices.data[index * 3u + 1u], vertices.data[index * 3u + 2u], 1)).xyz;
}
vec3 atlas_uv(uint tile, vec2 bary) {
	uint side = uint(textureSize(emission_atlas, 0).x) / 32u;
	if (side == 2u) {
		uvec2 base = uvec2(tile % 32u, (tile % 1024u) / 32u) * side;
		return vec3((vec2(base) + 0.5) / float(side * 32u), float(tile / 1024u));
	}
	int interior = int(side) - 2;
	ivec2 pixel = clamp(ivec2(floor(vec2(1) + bary * float(interior))), ivec2(1), ivec2(interior));
	int excess = max(pixel.x + pixel.y - interior, 0);
	if (pixel.x > pixel.y) {
		pixel.x -= excess;
	} else {
		pixel.y -= excess;
	}
	uvec2 base = uvec2(tile % 32u, (tile % 1024u) / 32u) * side;
	return vec3((vec2(base) + vec2(pixel) + 0.5) / float(side * 32u), float(tile / 1024u));
}
void main() {
	uint id = gl_GlobalInvocationID.x;
	if (id >= params.geometry.y) {
		return;
	}
	Emitter emitter;
	emitter.position_area.xyz = vertex(id * 3u);
	emitter.edge1_power.xyz = vertex(id * 3u + 1u) - emitter.position_area.xyz;
	emitter.edge2 = vec4(vertex(id * 3u + 2u) - emitter.position_area.xyz, 0);
	emitter.position_area.w = 0.5 * length(cross(emitter.edge1_power.xyz, emitter.edge2.xyz));
	uint tile = params.geometry.x + id;
	vec3 emission = vec3(0);
	// Include every covered material texel. A few point samples could miss
	// a textured emitter entirely and give it zero selection probability.
	uint side = uint(textureSize(emission_atlas, 0).x) / 32u;
	uint interior = max(side, 4u) - 2u;
	uint count = 0u;
	for (uint y = 1u; y < interior; y++) {
		for (uint x = 1u; x + y <= interior; x++) {
			vec3 uv = atlas_uv(tile, (vec2(x, y) - 0.5) / float(interior));
			emission += max(textureLod(emission_atlas, uv, 0).rgb, vec3(0)) * textureLod(albedo_atlas, uv, 0).a;
			count++;
		}
	}
	emission /= float(max(count, 1u));
	emitter.emission_tile = vec4(emission, uintBitsToFloat(tile));
	emitter.edge1_power.w = emitter.position_area.w * max(dot(emission, vec3(0.2126, 0.7152, 0.0722)), 0.0);
	lights.emitters[params.geometry.w + id] = emitter;
}
