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

#include "core/config/project_settings.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_material_expand.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_server.h"

using namespace RendererRD;

namespace {
// One lazy pipeline shared by resident capture pages. The last page releases it;
// a disabled GI backend retains neither this shader nor any expansion buffers.
RtMaterialExpandShaderRD *expansion_shader = nullptr;
RID expansion_version;
RID expansion_pipeline;
uint32_t expansion_users = 0;
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
	ERR_FAIL_COND_V(p_tile_size != 2 && (p_tile_size < 4 || p_tile_size > MAX_TILE_SIZE), ERR_INVALID_PARAMETER);
	RendererSceneRenderRD *renderer = RendererSceneRenderRD::get_singleton();
	ERR_FAIL_NULL_V(renderer, ERR_UNAVAILABLE);
	if (!renderer->supports_triangle_material_capture()) {
		return ERR_UNAVAILABLE;
	}
	MeshStorage *meshes = MeshStorage::get_singleton();
	ERR_FAIL_INDEX_V(p_surface, meshes->mesh_get_surface_count(p_mesh), ERR_INVALID_PARAMETER);
	void *surface = meshes->mesh_get_surface(p_mesh, uint32_t(p_surface));
	ERR_FAIL_NULL_V(surface, ERR_INVALID_PARAMETER);
	const uint64_t format = meshes->mesh_surface_get_format(surface);
	const uint32_t vertex_count = meshes->mesh_surface_get_vertex_count(surface);
	const uint32_t index_count = meshes->mesh_surface_get_index_count(surface);
	ERR_FAIL_COND_V(meshes->mesh_surface_get_primitive(surface) != RSE::PRIMITIVE_TRIANGLES || vertex_count == 0 || (format & RSE::ARRAY_FLAG_USE_2D_VERTICES), ERR_INVALID_PARAMETER);
	const uint32_t count = index_count ? index_count : vertex_count;
	ERR_FAIL_COND_V(count % 3 != 0 || uint32_t(p_first_triangle) >= count / 3, ERR_INVALID_PARAMETER);
	triangle_count = MIN(uint32_t(p_triangle_count), count / 3 - uint32_t(p_first_triangle));
	const uint32_t expanded_count = triangle_count * 3;
	RenderingServer *rs = RenderingServer::get_singleton();
	const uint32_t vertex_stride = rs->mesh_surface_get_format_vertex_stride(format, vertex_count);
	const uint32_t normal_stride = rs->mesh_surface_get_format_normal_tangent_stride(format, vertex_count);
	const uint32_t attribute_stride = rs->mesh_surface_get_format_attribute_stride(format, vertex_count);
	const uint32_t skin_stride = rs->mesh_surface_get_format_skin_stride(format, vertex_count);
	RenderingServerTypes::SurfaceData expanded_data;
	expanded_data.primitive = RSE::PRIMITIVE_TRIANGLES;
	expanded_data.format = (format & ~uint64_t(RSE::ARRAY_FORMAT_INDEX)) | RSE::ARRAY_FLAG_USE_STORAGE_BUFFER;
	expanded_data.vertex_count = expanded_count;
	expanded_data.aabb = meshes->mesh_surface_get_aabb(surface);
	expanded_data.uv_scale = meshes->mesh_surface_get_uv_scale(surface);
	expanded_data.vertex_data.resize_initialized(expanded_count * (vertex_stride + normal_stride));
	expanded_data.attribute_data.resize_initialized(expanded_count * attribute_stride);
	expanded_data.skin_data.resize_initialized(expanded_count * skin_stride);
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
	capture_data.resize_initialized(sizeof(CaptureInfo) + expanded_count * sizeof(uint32_t));
	capture_info.layout_info[0] = p_tile_size;
	capture_info.layout_info[1] = columns;
	capture_info.layout_info[2] = vertex_count;
	capture_info.layout_info[3] = ((format & RSE::ARRAY_FORMAT_NORMAL) ? 1u : 0u) | ((format & RSE::ARRAY_FORMAT_TANGENT) ? 2u : 0u);
	static_assert(sizeof(capture_info.layout_info) == 16, "MaterialCapture.capture_info.layout_info must occupy 16 bytes");
	memcpy(capture_data.ptrw(), &capture_info, sizeof(capture_info));

	capture_buffer = rd->storage_buffer_create(capture_data.size(), capture_data);
	if (expansion_users == 0) {
		expansion_shader = memnew(RtMaterialExpandShaderRD);
		Vector<String> modes;
		modes.push_back("");
		expansion_shader->initialize(modes);
		expansion_version = expansion_shader->version_create();
		expansion_pipeline = rd->compute_pipeline_create(expansion_shader->version_get_shader(expansion_version, 0));
	}
	expansion_users++;
	uses_expansion = true;
	ERR_FAIL_COND_V(expansion_pipeline.is_null(), ERR_CANT_CREATE);
	LocalVector<RD::Uniform> uniforms;
	Vector<RID> temporary;
	const RID fallback = meshes->get_default_rd_storage_buffer();
	RID inputs[] = { meshes->mesh_surface_get_vertex_buffer_rd_rid(p_mesh, p_surface), meshes->mesh_surface_get_attribute_buffer_rd_rid(p_mesh, p_surface), meshes->mesh_surface_get_skin_buffer_rd_rid(p_mesh, p_surface), meshes->mesh_surface_get_index_buffer_rd_rid(p_mesh, p_surface) };
	const uint32_t input_sizes[] = { vertex_count * (vertex_stride + normal_stride), vertex_count * attribute_stride, vertex_count * skin_stride, index_count * (vertex_count <= 65536 ? 2u : 4u) };
	const bool storage_inputs = bool(GLOBAL_GET("rendering/lights_and_shadows/raytraced_shadows/enabled")) || (format & RSE::ARRAY_FLAG_USE_STORAGE_BUFFER);
	for (uint32_t i = 0; i < 4; i++) {
		if (inputs[i].is_valid() && (!storage_inputs || input_sizes[i] % 4 != 0)) {
			// Standalone material baking can receive ordinary vertex buffers. Copy
			// on the GPU, also padding an odd 16-bit index tail for word loads.
			RID copy = rd->storage_buffer_create((input_sizes[i] + 3u) & ~3u);
			rd->buffer_copy(inputs[i], copy, 0, 0, input_sizes[i]);
			inputs[i] = copy;
			temporary.push_back(copy);
		}
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, i, inputs[i].is_valid() ? inputs[i] : fallback));
	}
	const RID outputs[] = { meshes->mesh_surface_get_vertex_buffer_rd_rid(mesh, 0), meshes->mesh_surface_get_attribute_buffer_rd_rid(mesh, 0), meshes->mesh_surface_get_skin_buffer_rd_rid(mesh, 0), capture_buffer };
	for (uint32_t i = 0; i < 4; i++) {
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4 + i, outputs[i].is_valid() ? outputs[i] : fallback));
	}
	const uint32_t push[] = { vertex_count, expanded_count, uint32_t(p_first_triangle) * 3u, index_count ? (vertex_count <= 65536 ? 2u : 4u) : 0u, vertex_stride / 4u, normal_stride / 4u, attribute_stride / 4u, skin_stride / 4u };
	RID set = UniformSetCacheRD::get_singleton()->get_cache_vec(expansion_shader->version_get_shader(expansion_version, 0), 0, uniforms);
	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, expansion_pipeline);
	rd->compute_list_bind_uniform_set(list, set, 0);
	rd->compute_list_set_push_constant(list, push, sizeof(push));
	rd->compute_list_dispatch_threads(list, expanded_count, 1, 1);
	rd->compute_list_end();
	for (RID buffer : temporary) {
		rd->free_rid(buffer);
	}

	RD::TextureFormat tf;
	tf.width = size.x;
	tf.height = size.y;
	tf.usage_bits = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	for (RD::DataFormat texture_format : { RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R8G8B8A8_UNORM, RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::DATA_FORMAT_R32_SFLOAT }) {
		tf.format = texture_format;
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
	memory_usage = expanded_data.vertex_data.size() + expanded_data.attribute_data.size() + expanded_data.skin_data.size() + capture_data.size() + uint64_t(size.x) * size.y * 28u;
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
	// Query the default material separately from geometry metadata.
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
	if (uses_expansion) {
		uses_expansion = false;
		if (--expansion_users == 0) {
			if (expansion_pipeline.is_valid()) {
				rd->free_rid(expansion_pipeline);
			}
			expansion_shader->version_free(expansion_version);
			memdelete(expansion_shader);
			expansion_shader = nullptr;
			expansion_pipeline = RID();
			expansion_version = RID();
		}
	}
	mesh = RID();
	source_mesh = RID();
	source_surface = -1;
	capture_buffer = RID();
	framebuffer = RID();
	textures.clear();
	size = Size2i();
	triangle_count = 0;
	memory_usage = 0;
}
