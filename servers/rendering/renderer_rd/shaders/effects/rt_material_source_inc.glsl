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

// Native source-material evaluator. Source vertex attributes and material uniforms
// retain Godot layouts; transport and hit-normal consumers remain in AMD GI.
struct GISourceMaterial {
	vec4 albedo;
	vec4 emission;
	vec4 orm;
};
struct GISourceContext {
	uvec2 uniform_address;
	uvec2 texture_address;
	uvec2 attribute_address;
	uvec2 reserved;
	uvec4 attributes;
	uvec4 custom_offsets;
	uvec4 custom_formats;
	vec4 uv_scale;
	vec4 color;
	vec4 custom;
	uvec4 info;
};
layout(set = 1, binding = 0, std430) readonly buffer GISources {
	vec4 header;
	GISourceContext data[];
}
gi_sources;
layout(set = 1, binding = 1, std430) readonly buffer GISourceGlobalUniforms {
	vec4 data[];
}
gi_global_uniforms;
// clang-format off
layout(buffer_reference,std430,buffer_reference_align=4) readonly buffer GISourceIndices { uint data[]; };
// clang-format on
layout(set = 1, binding = 2) uniform sampler SAMPLER_NEAREST_CLAMP;
layout(set = 1, binding = 3) uniform sampler SAMPLER_LINEAR_CLAMP;
layout(set = 1, binding = 4) uniform sampler SAMPLER_NEAREST_WITH_MIPMAPS_CLAMP;
layout(set = 1, binding = 5) uniform sampler SAMPLER_LINEAR_WITH_MIPMAPS_CLAMP;
layout(set = 1, binding = 6) uniform sampler SAMPLER_NEAREST_WITH_MIPMAPS_ANISOTROPIC_CLAMP;
layout(set = 1, binding = 7) uniform sampler SAMPLER_LINEAR_WITH_MIPMAPS_ANISOTROPIC_CLAMP;
layout(set = 1, binding = 8) uniform sampler SAMPLER_NEAREST_REPEAT;
layout(set = 1, binding = 9) uniform sampler SAMPLER_LINEAR_REPEAT;
layout(set = 1, binding = 10) uniform sampler SAMPLER_NEAREST_WITH_MIPMAPS_REPEAT;
layout(set = 1, binding = 11) uniform sampler SAMPLER_LINEAR_WITH_MIPMAPS_REPEAT;
layout(set = 1, binding = 12) uniform sampler SAMPLER_NEAREST_WITH_MIPMAPS_ANISOTROPIC_REPEAT;
layout(set = 1, binding = 13) uniform sampler SAMPLER_LINEAR_WITH_MIPMAPS_ANISOTROPIC_REPEAT;

GISourceContext gi_source_context;
struct GISourceFrame {
	float time;
	float exposure;
	uint layer_mask;
};
GISourceFrame gi_source_frame;
uint gi_source_vertex_index;
float gi_source_lod;
float gi_source_uv_area;
bool gi_source_filtered;
float gi_source_texture_lod(vec2 dimensions) {
	return gi_source_filtered ? 0.5 * log2(dimensions.x * dimensions.y * gi_source_uv_area) + gi_source_lod : gi_source_lod;
}
bool gi_source_front_face, gi_source_discarded;
vec4 gi_source_fragcoord;
float gi_source_depth;
mat4 read_model_matrix, read_view_matrix, inv_view_matrix, projection_matrix, inv_projection_matrix, modelview;
mat3 model_normal_matrix, modelview_normal;
vec2 read_viewport_size;
vec3 vertex, normal_highp, tangent, binormal, light_vertex, view_highp;
vec4 position, color_interp, instance_custom;
vec2 uv_interp, uv2_interp, point_coord, screen_uv;
vec3 eye_offset;
float point_size, z_clip_scale;
uvec4 bone_attrib;
vec4 weight_attrib, custom0_attrib, custom1_attrib, custom2_attrib, custom3_attrib;
vec3 albedo_highp, emission, normal_map, bent_normal_map;
float alpha_highp, metallic_highp, roughness_highp, specular, normal_map_depth;
float rim, rim_tint, clearcoat, clearcoat_roughness, anisotropy, sss_strength, transmittance_depth, transmittance_boost, ao, ao_light_affect, premul_alpha;
float alpha_scissor_threshold, alpha_hash_scale, alpha_antialiasing_edge;
vec2 alpha_texture_coordinate, anisotropy_flow;
vec3 backlight;
vec4 transmittance_color, fog, custom_radiance, custom_irradiance;
struct GIVertex {
	vec3 position;
	vec3 normal;
	vec3 tangent;
	vec3 binormal;
	vec2 uv;
	vec2 uv2;
	vec4 color;
};

vec3 gi_source_rotate(vec3 v) {
	return v + 2.0 * cross(params.camera_rotation.xyz, cross(params.camera_rotation.xyz, v) + params.camera_rotation.w * v);
}
void gi_source_begin(uint instance, bool front_face) {
	gi_source_context = gi_sources.data[instance];
	gi_source_front_face = front_face;
	gi_source_discarded = false;
	gi_source_frame = GISourceFrame(gi_sources.header.x, params.exposure, 0xffffffffu);
	read_viewport_size = vec2(params.size);
	inv_view_matrix = mat4(vec4(gi_source_rotate(vec3(1, 0, 0)), 0), vec4(gi_source_rotate(vec3(0, 1, 0)), 0), vec4(gi_source_rotate(vec3(0, 0, 1)), 0), vec4(params.camera_position.xyz, 1));
	read_view_matrix = inverse(inv_view_matrix);
	projection_matrix = inverse(params.inv_view_projection) * inv_view_matrix;
	inv_projection_matrix = inverse(projection_matrix);
	read_model_matrix = mat4(transpose(hits.data[instance].object_to_world));
	model_normal_matrix = hits.data[instance].normal_to_world;
	modelview = read_view_matrix * read_model_matrix;
	modelview_normal = mat3(read_view_matrix) * model_normal_matrix;
	instance_custom = gi_source_context.custom;
	eye_offset = vec3(0);
}
vec4 gi_source_custom(uint vertex_id, uint index) {
	uint offset = gi_source_context.custom_offsets[index];
	if (offset == 0xffffffffu) {
		return vec4(0);
	}
	GISourceIndices source = GISourceIndices(gi_source_context.attribute_address);
	offset += vertex_id * gi_source_context.attributes.w;
	uint format = gi_source_context.custom_formats[index];
	uint v = source.data[offset];
	if (format == 0u) {
		return unpackUnorm4x8(v);
	}
	if (format == 1u) {
		return unpackSnorm4x8(v);
	}
	if (format == 2u) {
		return vec4(unpackHalf2x16(v), 0, 1);
	}
	if (format == 3u) {
		return vec4(unpackHalf2x16(v), unpackHalf2x16(source.data[offset + 1u]));
	}
	vec4 result = vec4(uintBitsToFloat(v), 0, 0, 1);
	if (format >= 5u) {
		result.y = uintBitsToFloat(source.data[offset + 1u]);
	}
	if (format >= 6u) {
		result.z = uintBitsToFloat(source.data[offset + 2u]);
	}
	if (format >= 7u) {
		result.w = uintBitsToFloat(source.data[offset + 3u]);
	}
	return result;
}
vec2 gi_source_uv(uint vertex_id, uint index) {
	uint offset = gi_source_context.attributes[index];
	if (offset == 0xffffffffu) {
		return vec2(0);
	}
	GISourceIndices source = GISourceIndices(gi_source_context.attribute_address);
	offset += vertex_id * gi_source_context.attributes.w;
	if ((gi_source_context.info.w & 2u) != 0u) {
		vec2 scale = index == 0u ? gi_source_context.uv_scale.xy : gi_source_context.uv_scale.zw;
		vec2 uv = unpackUnorm2x16(source.data[offset]);
		// Native vertex input preserves normalized UVs when no remapping was
		// required. The compression flag alone does not imply a nonzero scale.
		return gi_source_context.uv_scale == vec4(0) ? uv : (uv - .5) * scale;
	}
	return uintBitsToFloat(uvec2(source.data[offset], source.data[offset + 1u]));
}
void gi_source_vertex_begin(uint instance, uint vertex_id) {
	gi_source_vertex_index = vertex_id;
	GIHitData hit = hits.data[instance];
	GIVertices vertices = GIVertices(hit.vertex_address);
	vertex = vec3(vertices.data[vertex_id * 3u], vertices.data[vertex_id * 3u + 1u], vertices.data[vertex_id * 3u + 2u]);
	normal_highp = hit.geometry.w != 0u ? gi_decode_vertex_normal(hit, vertex_id) : vec3(0, 0, 1);
	tangent = vec3(1, 0, 0);
	binormal = vec3(0, 1, 0);
	if ((gi_source_context.info.w & 1u) != 0u && hit.geometry.w != 0u) {
		GISourceIndices source = GISourceIndices(hit.normal_address);
		if ((gi_source_context.info.w & 2u) != 0u) {
			vec3 axis = oct_to_vec3(unpackUnorm2x16(source.data[hit.geometry.z + vertex_id * hit.geometry.w]) * 2.0 - 1.0);
			float packed_angle = unpackUnorm2x16(source.data[vertex_id * 2u + 1u]).y;
			float angle = abs(packed_angle * 2.0 - 1.0) * PI;
			float c = cos(angle), s = sin(angle);
			tangent = (1.0 - c) * axis.x * axis + vec3(c, -s * axis.z, s * axis.y);
			binormal = ((1.0 - c) * axis.y * axis + vec3(s * axis.z, c, -s * axis.x)) * (packed_angle > .5 ? 1.0 : -1.0);
		} else {
			vec2 encoded = unpackUnorm2x16(source.data[hit.geometry.z + vertex_id * hit.geometry.w + 1u]) * 2.0 - 1.0;
			tangent = oct_to_vec3(vec2(encoded.x, abs(encoded.y) * 2.0 - 1.0));
			binormal = normalize(cross(normal_highp, tangent) * sign(encoded.y));
		}
	}
	uv_interp = gi_source_uv(vertex_id, 0u);
	uv2_interp = gi_source_uv(vertex_id, 1u);
	color_interp = vec4(1);
	if (gi_source_context.attributes.z != 0xffffffffu) {
		GISourceIndices source = GISourceIndices(gi_source_context.attribute_address);
		color_interp = unpackUnorm4x8(source.data[gi_source_context.attributes.z + vertex_id * gi_source_context.attributes.w]);
	}
	color_interp *= gi_source_context.color;
	custom0_attrib = gi_source_custom(vertex_id, 0u);
	custom1_attrib = gi_source_custom(vertex_id, 1u);
	custom2_attrib = gi_source_custom(vertex_id, 2u);
	custom3_attrib = gi_source_custom(vertex_id, 3u);
	bone_attrib = uvec4(0);
	weight_attrib = vec4(0);
	point_size = 1.;
	z_clip_scale = 1.;
	position = vec4(0);
	if ((gi_source_context.info.w & 4u) != 0u) {
		vertex = (read_model_matrix * vec4(vertex, 1)).xyz;
		normal_highp = normalize(model_normal_matrix * normal_highp);
		tangent = normalize(model_normal_matrix * tangent);
		binormal = normalize(model_normal_matrix * binormal);
	}
}
void gi_source_vertex_accumulate(inout GIVertex result, float w, bool first) {
	if (first) {
		result = GIVertex(vec3(0), vec3(0), vec3(0), vec3(0), vec2(0), vec2(0), vec4(0));
	}
	mat4 transform = (gi_source_context.info.w & 4u) != 0u ? read_view_matrix : modelview;
	mat3 normal_transform = (gi_source_context.info.w & 4u) != 0u ? mat3(read_view_matrix) : modelview_normal;
	result.position += (transform * vec4(vertex, 1)).xyz * w;
	result.normal += normalize(normal_transform * normal_highp) * w;
	result.tangent += normalize(normal_transform * tangent) * w;
	result.binormal += normalize(normal_transform * binormal) * w;
	result.uv += uv_interp * w;
	result.uv2 += uv2_interp * w;
	result.color += color_interp * w;
}
void gi_source_fragment_begin(GIVertex interpolated) {
	vertex = interpolated.position;
	normal_highp = normalize(interpolated.normal);
	tangent = normalize(interpolated.tangent);
	binormal = normalize(interpolated.binormal);
	uv_interp = interpolated.uv;
	uv2_interp = interpolated.uv2;
	color_interp = interpolated.color;
	view_highp = -normalize(vertex);
	light_vertex = vertex;
	vec4 clip = projection_matrix * vec4(vertex, 1);
	gi_source_fragcoord = vec4((clip.xy / clip.w * .5 + .5) * read_viewport_size, clip.z / clip.w, 1. / clip.w);
	gi_source_depth = gi_source_fragcoord.z;
	screen_uv = gi_source_fragcoord.xy / read_viewport_size;
	point_coord = vec2(0);
	albedo_highp = vec3(1);
	alpha_highp = 1.;
	metallic_highp = 0.;
	roughness_highp = 1.;
	specular = .5;
	emission = vec3(0);
	normal_map = vec3(.5, .5, 1);
	bent_normal_map = vec3(.5, .5, 1);
	normal_map_depth = 1.;
	rim = 0.;
	rim_tint = 0.;
	clearcoat = 0.;
	clearcoat_roughness = 0.;
	anisotropy = 0.;
	anisotropy_flow = vec2(1, 0);
	sss_strength = 0.;
	transmittance_color = vec4(0);
	transmittance_depth = 0.;
	transmittance_boost = 0.;
	backlight = vec3(0);
	ao = 1.;
	ao_light_affect = 0.;
	premul_alpha = 1.;
	alpha_scissor_threshold = 0.;
	alpha_hash_scale = 1.;
	alpha_antialiasing_edge = 0.;
	alpha_texture_coordinate = vec2(0);
	fog = vec4(0);
	custom_radiance = vec4(0);
	custom_irradiance = vec4(0);
}
GISourceMaterial gi_source_fragment_end(bool uses_normal_map) {
	// AMD's world-space hit paths use vertex/geometric normals. The screen
	// shading-normal path retains native normal maps independently.
	return GISourceMaterial(vec4(albedo_highp, gi_source_discarded ? 0.0 : alpha_highp), vec4(emission, 0), vec4(ao, roughness_highp, metallic_highp, sss_strength));
}
GISourceMaterial gi_source_material(uint instance, uint primitive, vec2 barycentrics, bool front_face, float lod);

GISourceMaterial gi_source_material_filtered(uint instance, uint primitive, vec2 barycentrics, bool front_face, float lod, bool filtered);
