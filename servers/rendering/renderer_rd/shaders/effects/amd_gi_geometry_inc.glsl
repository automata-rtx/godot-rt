/**********************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

// Read the exact position/index buffers used by the shared BLAS. No duplicate
// triangle atlas and no CPU geometry readback. RD declares these BDA reads.
// clang-format treats these type-only GLSL buffer declarations as functions
// and removes their required semicolons.
// clang-format off
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer GIVertices {
	float data[];
};
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer GIIndices32 {
	uint data[];
};
layout(buffer_reference, std430, buffer_reference_align = 2) readonly buffer GIIndices16 {
	uint16_t data[];
};
// clang-format on
uvec3 gi_triangle_indices(uint instance, uint primitive) {
	GIHitData hit = hits.data[instance];
	uvec3 indices = primitive * 3u + uvec3(0, 1, 2);
	if (hit.geometry.x == 2u) {
		GIIndices16 source = GIIndices16(hit.index_address);
		indices = uvec3(source.data[indices.x], source.data[indices.y], source.data[indices.z]);
	} else if (hit.geometry.x == 4u) {
		GIIndices32 source = GIIndices32(hit.index_address);
		indices = uvec3(source.data[indices.x], source.data[indices.y], source.data[indices.z]);
	}
	return indices;
}
void gi_triangle_vertices(uint instance, uint primitive, out vec3 v0, out vec3 v1, out vec3 v2) {
	GIHitData hit = hits.data[instance];
	uvec3 indices = gi_triangle_indices(instance, primitive);
	GIVertices source = GIVertices(hit.vertex_address);
	indices *= 3u;
	v0 = vec3(source.data[indices.x], source.data[indices.x + 1u], source.data[indices.x + 2u]);
	v1 = vec3(source.data[indices.y], source.data[indices.y + 1u], source.data[indices.y + 2u]);
	v2 = vec3(source.data[indices.z], source.data[indices.z + 1u], source.data[indices.z + 2u]);
}
vec3 gi_decode_vertex_normal(GIHitData hit, uint vertex) {
	GIIndices32 source = GIIndices32(hit.normal_address);
	vec2 oct = unpackUnorm2x16(source.data[hit.geometry.z + vertex * hit.geometry.w]) * 2.0 - 1.0;
	vec3 normal = vec3(oct, 1.0 - abs(oct.x) - abs(oct.y));
	vec2 sign_not_zero = mix(vec2(-1), vec2(1), greaterThanEqual(normal.xy, vec2(0)));
	normal.xy += sign_not_zero * -clamp(-normal.z, 0.0, 1.0);
	normal = normalize(normal);
	if ((hit.geometry.y & 8u) != 0u) {
		// Same axis-angle reconstruction as Forward+'s _unpack_vertex_attributes.
		float angle = abs(unpackUnorm2x16(source.data[vertex * 2u + 1u]).y * 2.0 - 1.0) * PI;
		float c = cos(angle), s = sin(angle);
		normal = (1.0 - c) * normal.z * normal + vec3(-s * normal.y, s * normal.x, c);
	}
	return normal;
}
vec3 gi_triangle_normal(uint instance, uint primitive, vec2 barycentrics, vec3 geometry_normal) {
	GIHitData hit = hits.data[instance];
	if (hit.geometry.w == 0u) {
		return geometry_normal;
	}
	uvec3 indices = gi_triangle_indices(instance, primitive);
	return (1.0 - barycentrics.x - barycentrics.y) * gi_decode_vertex_normal(hit, indices.x) +
			barycentrics.x * gi_decode_vertex_normal(hit, indices.y) + barycentrics.y * gi_decode_vertex_normal(hit, indices.z);
}
// Capsaicin math/hash.hlsl::xxHash(uint4), including float(frame) bit pattern.
uint gi_alpha_hash(uvec4 values) {
	uint result = values.w + 374761393u + values.x * 3266489917u;
	result = 668265263u * ((result << 17u) | (result >> 15u));
	result += values.y * 3266489917u;
	result = 668265263u * ((result << 17u) | (result >> 15u));
	result += values.z * 3266489917u;
	result = 668265263u * ((result << 17u) | (result >> 15u));
	result = 2246822519u * (result ^ (result >> 15u));
	result = 3266489917u * (result ^ (result >> 13u));
	return result ^ (result >> 16u);
}
