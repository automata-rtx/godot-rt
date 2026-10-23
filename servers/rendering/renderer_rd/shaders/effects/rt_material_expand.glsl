#[compute]
#version 450
#VERSION_DEFINES
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict readonly buffer SourceVertices {
	uint data[];
}
source_vertices;
layout(set = 0, binding = 1, std430) restrict readonly buffer SourceAttributes {
	uint data[];
}
source_attributes;
layout(set = 0, binding = 2, std430) restrict readonly buffer SourceSkin {
	uint data[];
}
source_skin;
layout(set = 0, binding = 3, std430) restrict readonly buffer SourceIndices {
	uint data[];
}
source_indices;
layout(set = 0, binding = 4, std430) restrict writeonly buffer Vertices {
	uint data[];
}
vertices;
layout(set = 0, binding = 5, std430) restrict writeonly buffer Attributes {
	uint data[];
}
attributes;
layout(set = 0, binding = 6, std430) restrict writeonly buffer Skin {
	uint data[];
}
skin;
layout(set = 0, binding = 7, std430) restrict writeonly buffer Capture {
	uint data[];
}
capture;
layout(push_constant, std430) uniform Params {
	uint source_count;
	uint destination_count;
	uint first_index;
	uint index_bytes;
	uint vertex_stride;
	uint normal_stride;
	uint attribute_stride;
	uint skin_stride;
}
params;
void main() {
	uint vertex = gl_GlobalInvocationID.x;
	if (vertex >= params.destination_count) {
		return;
	}
	uint source = params.first_index + vertex;
	if (params.index_bytes == 2u) {
		source = (source_indices.data[source / 2u] >> ((source & 1u) * 16u)) & 65535u;
	} else if (params.index_bytes == 4u) {
		source = source_indices.data[source];
	}
	if (source >= params.source_count) {
		return; // Malformed source indices cannot read outside the input buffers.
	}
	capture.data[16u + vertex] = source;
	for (uint word = 0u; word < params.vertex_stride; word++) {
		vertices.data[vertex * params.vertex_stride + word] = source_vertices.data[source * params.vertex_stride + word];
	}
	for (uint word = 0u; word < params.normal_stride; word++) {
		vertices.data[params.destination_count * params.vertex_stride + vertex * params.normal_stride + word] = source_vertices.data[params.source_count * params.vertex_stride + source * params.normal_stride + word];
	}
	for (uint word = 0u; word < params.attribute_stride; word++) {
		attributes.data[vertex * params.attribute_stride + word] = source_attributes.data[source * params.attribute_stride + word];
	}
	for (uint word = 0u; word < params.skin_stride; word++) {
		skin.data[vertex * params.skin_stride + word] = source_skin.data[source * params.skin_stride + word];
	}
}
