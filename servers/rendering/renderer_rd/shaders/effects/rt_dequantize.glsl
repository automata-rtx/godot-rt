#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Source vertex buffer, read as raw words. Compressed positions are stored as
// R16G16B16A16_UNORM, i.e. two 32-bit words per vertex.
layout(set = 0, binding = 0, std430) restrict readonly buffer SourceVertices {
	uint data[];
}
src_vertices;

// Destination, tightly packed float32x3 suitable for acceleration structure
// build input.
layout(set = 0, binding = 1, std430) restrict writeonly buffer DestVertices {
	float data[];
}
dst_vertices;

layout(push_constant, std430) uniform Params {
	vec3 aabb_position;
	uint vertex_count;
	vec3 aabb_size;
	uint source_stride_in_words;
}
params;

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.vertex_count) {
		return;
	}

	uint base = index * params.source_stride_in_words;

	// Godot stores compressed positions normalized into the surface AABB; the
	// vertex shader decodes them as `position * aabb_size + aabb_position`.
	vec2 xy = unpackUnorm2x16(src_vertices.data[base]);
	vec2 zw = unpackUnorm2x16(src_vertices.data[base + 1]);

	vec3 position = vec3(xy.x, xy.y, zw.x) * params.aabb_size + params.aabb_position;

	dst_vertices.data[index * 3 + 0] = position.x;
	dst_vertices.data[index * 3 + 1] = position.y;
	dst_vertices.data[index * 3 + 2] = position.z;
}
