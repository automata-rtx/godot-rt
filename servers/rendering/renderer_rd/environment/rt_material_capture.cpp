/**************************************************************************/
/*  rt_material_capture.cpp                                               */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "rt_material_capture.h"

#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/rendering_server.h"

using namespace RendererRD;

namespace {

template <typename T>
Variant expand_attribute(const Variant &p_source, uint32_t p_vertex_count, const Vector<uint32_t> &p_indices) {
	const Vector<T> source = p_source;
	ERR_FAIL_COND_V(source.size() % p_vertex_count != 0, Variant());
	const uint32_t stride = source.size() / p_vertex_count;
	Vector<T> expanded;
	expanded.resize(p_indices.size() * stride);
	T *dest = expanded.ptrw();
	for (uint32_t i = 0; i < p_indices.size(); i++) {
		memcpy(dest + i * stride, source.ptr() + p_indices[i] * stride, stride * sizeof(T));
	}
	return expanded;
}

} // namespace

Error RaytracingMaterialCapture::capture(RID p_mesh, int p_surface, int p_first_triangle, int p_triangle_count, int p_tile_size, const Transform3D &p_transform, RID p_material_override, int32_t p_instance_uniforms_offset) {
	Error err = prepare(p_mesh, p_surface, p_first_triangle, p_triangle_count, p_tile_size);
	if (err == OK) {
		err = render(p_transform, p_material_override, p_instance_uniforms_offset);
	}
	if (err != OK) {
		clear();
	}
	return err;
}

Error RaytracingMaterialCapture::prepare(RID p_mesh, int p_surface, int p_first_triangle, int p_triangle_count, int p_tile_size) {
	clear();
	ERR_FAIL_COND_V(p_first_triangle < 0 || p_triangle_count < 1 || p_triangle_count > MAX_TRIANGLES, ERR_INVALID_PARAMETER);
	ERR_FAIL_COND_V(p_tile_size < 4 || p_tile_size > MAX_TILE_SIZE, ERR_INVALID_PARAMETER);
	RendererSceneRenderRD *renderer = RendererSceneRenderRD::get_singleton();
	ERR_FAIL_NULL_V(renderer, ERR_UNAVAILABLE);
	if (!renderer->supports_triangle_material_capture()) {
		return ERR_UNAVAILABLE;
	}
	MeshStorage *meshes = MeshStorage::get_singleton();
	ERR_FAIL_INDEX_V(p_surface, meshes->mesh_get_surface_count(p_mesh), ERR_INVALID_PARAMETER);
	const MeshStorage *source_storage = meshes;
	const RenderingServerTypes::SurfaceData source = source_storage->mesh_get_surface(p_mesh, p_surface);
	ERR_FAIL_COND_V(source.primitive != RSE::PRIMITIVE_TRIANGLES || source.vertex_count == 0 || (source.format & RSE::ARRAY_FLAG_USE_2D_VERTICES), ERR_INVALID_PARAMETER);
	const Array arrays = RenderingServer::get_singleton()->mesh_create_arrays_from_surface_data(source);
	ERR_FAIL_COND_V(arrays.size() != RSE::ARRAY_MAX, ERR_INVALID_DATA);
	const Vector<int> indices = arrays[RSE::ARRAY_INDEX];
	const uint32_t count = indices.is_empty() ? source.vertex_count : indices.size();
	ERR_FAIL_COND_V(count % 3 != 0 || uint32_t(p_first_triangle) >= count / 3, ERR_INVALID_PARAMETER);
	triangle_count = MIN(uint32_t(p_triangle_count), count / 3 - uint32_t(p_first_triangle));
	Vector<uint32_t> source_indices;
	source_indices.resize(triangle_count * 3);
	for (uint32_t i = 0; i < source_indices.size(); i++) {
		uint32_t index = uint32_t(p_first_triangle) * 3 + i;
		index = indices.is_empty() ? index : uint32_t(indices[index]);
		ERR_FAIL_UNSIGNED_INDEX_V(index, source.vertex_count, ERR_INVALID_DATA);
		source_indices.write[i] = index;
	}
	Array expanded;
	expanded.resize(RSE::ARRAY_MAX);
	for (int channel = 0; channel < RSE::ARRAY_INDEX; channel++) {
		switch (arrays[channel].get_type()) {
			case Variant::NIL:
				continue;
			case Variant::PACKED_BYTE_ARRAY:
				expanded[channel] = expand_attribute<uint8_t>(arrays[channel], source.vertex_count, source_indices);
				break;
			case Variant::PACKED_INT32_ARRAY:
				expanded[channel] = expand_attribute<int>(arrays[channel], source.vertex_count, source_indices);
				break;
			case Variant::PACKED_FLOAT32_ARRAY:
				expanded[channel] = expand_attribute<float>(arrays[channel], source.vertex_count, source_indices);
				break;
			case Variant::PACKED_FLOAT64_ARRAY:
				expanded[channel] = expand_attribute<double>(arrays[channel], source.vertex_count, source_indices);
				break;
			case Variant::PACKED_VECTOR2_ARRAY:
				expanded[channel] = expand_attribute<Vector2>(arrays[channel], source.vertex_count, source_indices);
				break;
			case Variant::PACKED_VECTOR3_ARRAY:
				expanded[channel] = expand_attribute<Vector3>(arrays[channel], source.vertex_count, source_indices);
				break;
			case Variant::PACKED_COLOR_ARRAY:
				expanded[channel] = expand_attribute<Color>(arrays[channel], source.vertex_count, source_indices);
				break;
			default:
				ERR_FAIL_V(ERR_INVALID_DATA);
		}
		ERR_FAIL_COND_V(expanded[channel].get_type() == Variant::NIL, ERR_INVALID_DATA);
	}
	uint64_t flags = source.format & RSE::ARRAY_FLAG_USE_8_BONE_WEIGHTS;
	for (uint32_t custom = 0; custom < RSE::ARRAY_CUSTOM_COUNT; custom++) {
		flags |= source.format & (uint64_t(RSE::ARRAY_FORMAT_CUSTOM_MASK) << (RSE::ARRAY_FORMAT_CUSTOM_BASE + custom * RSE::ARRAY_FORMAT_CUSTOM_BITS));
	}
	RenderingServerTypes::SurfaceData expanded_data;
	Error err = RenderingServer::get_singleton()->mesh_create_surface_data_from_arrays(&expanded_data, RSE::PRIMITIVE_TRIANGLES, expanded, Array(), Dictionary(), flags);
	ERR_FAIL_COND_V(err != OK, err);
	mesh = meshes->mesh_allocate();
	meshes->mesh_initialize(mesh);
	meshes->mesh_add_surface(mesh, expanded_data);
	const uint32_t columns = MIN(triangle_count, 32u);
	size = Size2i(columns * p_tile_size, ((triangle_count + columns - 1) / columns) * p_tile_size);
	RD *rd = RD::get_singleton();
	if (uint32_t(MAX(size.x, size.y)) > rd->limit_get(RD::LIMIT_MAX_TEXTURE_SIZE_2D)) {
		clear();
		return ERR_UNAVAILABLE;
	}
	Vector<uint8_t> capture_data;
	capture_data.resize(sizeof(CaptureInfo) + source_indices.size() * sizeof(uint32_t));
	capture_info.layout_info[0] = p_tile_size;
	capture_info.layout_info[1] = columns;
	capture_info.layout_info[2] = source.vertex_count;
	capture_info.layout_info[3] = ((source.format & RSE::ARRAY_FORMAT_NORMAL) ? 1u : 0u) | ((source.format & RSE::ARRAY_FORMAT_TANGENT) ? 2u : 0u);
	static_assert(sizeof(capture_info.layout_info) == 16, "MaterialCapture.capture_info.layout_info must occupy 16 bytes");
	memcpy(capture_data.ptrw(), &capture_info, sizeof(capture_info));
	memcpy(capture_data.ptrw() + sizeof(capture_info), source_indices.ptr(), source_indices.size() * sizeof(uint32_t));
	capture_buffer = rd->storage_buffer_create(capture_data.size(), capture_data);
	RD::TextureFormat tf;
	tf.width = size.x;
	tf.height = size.y;
	tf.usage_bits = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	for (RD::DataFormat format : { RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::DATA_FORMAT_R32_SFLOAT }) {
		tf.format = format;
		textures.push_back(rd->texture_create(tf, RD::TextureView()));
	}
	tf.format = rd->texture_is_format_supported_for_usage(RD::DATA_FORMAT_D32_SFLOAT, RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) ? RD::DATA_FORMAT_D32_SFLOAT : RD::DATA_FORMAT_X8_D24_UNORM_PACK32;
	tf.usage_bits = RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
	textures.push_back(rd->texture_create(tf, RD::TextureView()));
	bool allocated = capture_buffer.is_valid();
	for (RID texture : textures) {
		allocated &= texture.is_valid();
	}
	if (!allocated) {
		clear();
		return ERR_OUT_OF_MEMORY;
	}
	framebuffer = rd->framebuffer_create(textures);
	if (framebuffer.is_null()) {
		clear();
		return ERR_CANT_CREATE;
	}
	source_mesh = p_mesh;
	source_surface = p_surface;
	return OK;
}

Error RaytracingMaterialCapture::render(const Transform3D &p_transform, RID p_material_override, int32_t p_instance_uniforms_offset, RID p_mesh_instance, const Color &p_color, const Color &p_custom, uint32_t p_element) {
	ERR_FAIL_COND_V(framebuffer.is_null() || mesh.is_null(), ERR_UNCONFIGURED);
	ERR_FAIL_COND_V(!p_transform.is_finite() || p_transform.basis.determinant() == 0, ERR_INVALID_PARAMETER);
	RendererSceneRenderRD *renderer = RendererSceneRenderRD::get_singleton();
	ERR_FAIL_NULL_V(renderer, ERR_UNAVAILABLE);
	MeshStorage *meshes = MeshStorage::get_singleton();
	RID pose_buffer = p_mesh_instance.is_valid() ? meshes->mesh_instance_get_vertex_buffer(p_mesh_instance, source_surface) : RID();
	// Godot importers disable compression for skinned/morphed surfaces. Reject
	// manually constructed compressed poses rather than reading a wrong stride.
	ERR_FAIL_COND_V(pose_buffer.is_valid() && (meshes->mesh_surface_get_format(meshes->mesh_get_surface(source_mesh, uint32_t(source_surface))) & RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES), ERR_UNAVAILABLE);
	CaptureInfo updated = capture_info;
	updated.layout_info[3] = (updated.layout_info[3] & 3u) | (pose_buffer.is_valid() ? 4u : 0u);
	for (int i = 0; i < 4; i++) {
		updated.color[i] = p_color[i];
		updated.custom[i] = p_custom[i];
	}
	updated.instance_info[0] = p_element;
	if (memcmp(&updated, &capture_info, sizeof(CaptureInfo)) != 0) {
		capture_info = updated;
		RD::get_singleton()->buffer_update(capture_buffer, 0, sizeof(capture_info), &capture_info);
	}
	MaterialStorage::get_singleton()->_update_queued_materials();
	RenderGeometryInstance *instance = renderer->geometry_instance_create(mesh);
	if (!instance) {
		clear();
		return ERR_CANT_CREATE;
	}
	// mesh_get_surface() reads geometry only; SurfaceData.material is not filled.
	instance->set_material_override(p_material_override.is_valid() ? p_material_override : meshes->mesh_surface_get_material(source_mesh, source_surface));
	instance->set_instance_shader_uniforms_offset(p_instance_uniforms_offset);
	const AABB aabb = meshes->mesh_get_aabb(mesh);
	instance->set_transform(p_transform, aabb, p_transform.xform(aabb));
	{
		PagedArrayPool<RenderGeometryInstance *> pool;
		PagedArray<RenderGeometryInstance *> instances;
		instances.set_page_pool(&pool);
		instances.push_back(instance);
		renderer->render_triangle_material_capture(instances, framebuffer, Rect2i(Vector2i(), size), capture_buffer, pose_buffer);
	}
	renderer->geometry_instance_free(instance);
	return OK;
}

RID RaytracingMaterialCapture::get_texture(int p_index) const {
	ERR_FAIL_INDEX_V(p_index, MIN(4, textures.size()), RID());
	return textures[p_index];
}

TypedArray<Image> RaytracingMaterialCapture::readback() const {
	TypedArray<Image> result;
	if (textures.size() != 6 || framebuffer.is_null()) {
		return result;
	}
	for (int i = 0; i < 4; i++) {
		result.push_back(Image::create_from_data(size.x, size.y, false, i == 3 ? Image::FORMAT_RGBAH : Image::FORMAT_RGBA8, RD::get_singleton()->texture_get_data(textures[i], 0)));
	}
	return result;
}

void RaytracingMaterialCapture::clear() {
	RD *rd = RD::get_singleton();
	if (framebuffer.is_valid()) {
		rd->free_rid(framebuffer);
	}
	for (RID texture : textures) {
		if (texture.is_valid()) {
			rd->free_rid(texture);
		}
	}
	if (capture_buffer.is_valid()) {
		rd->free_rid(capture_buffer);
	}
	if (mesh.is_valid()) {
		MeshStorage::get_singleton()->free(mesh);
	}
	mesh = RID();
	source_mesh = RID();
	source_surface = -1;
	capture_buffer = RID();
	framebuffer = RID();
	textures.clear();
	size = Size2i();
	triangle_count = 0;
}
