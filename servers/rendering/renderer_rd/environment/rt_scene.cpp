/**************************************************************************/
/*  rt_scene.cpp                                                          */
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

#include "rt_scene.h"

#include "core/config/project_settings.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_server_globals.h"

using namespace RendererRD;

RaytracingScene *RaytracingScene::singleton = nullptr;

bool RaytracingScene::settings_registered = false;
bool RaytracingScene::setting_enabled = false;
int RaytracingScene::setting_samples = 4;
float RaytracingScene::setting_max_distance = 0.0f;

void RaytracingScene::register_settings() {
	if (settings_registered) {
		return;
	}
	settings_registered = true;

	// The settings themselves are registered in ProjectSettings so that they exist
	// before the rendering device is created; here we only resolve them once.
	setting_enabled = GLOBAL_GET("rendering/lights_and_shadows/raytraced_shadows/enabled");
	setting_samples = GLOBAL_GET("rendering/lights_and_shadows/raytraced_shadows/samples_per_light");
	setting_max_distance = GLOBAL_GET("rendering/lights_and_shadows/raytraced_shadows/max_ray_distance");
}

bool RaytracingScene::is_enabled() {
	register_settings();
	return setting_enabled;
}

int RaytracingScene::get_sample_count() {
	register_settings();
	return MAX(1, setting_samples);
}

float RaytracingScene::get_max_distance() {
	register_settings();
	return setting_max_distance;
}

RaytracingScene::RaytracingScene() {
	singleton = this;

	register_settings();

	supported = RD::get_singleton()->has_feature(RD::SUPPORTS_RAY_QUERY);

	if (!setting_enabled) {
		// Nothing else is needed; the feature is off for this project.
		return;
	}

	if (!supported) {
		WARN_PRINT("Raytraced shadows are enabled in the project settings, but this device does not support hardware ray queries. Falling back to shadow maps.");
		return;
	}

	Vector<String> dequantize_modes;
	dequantize_modes.push_back("");
	dequantize_shader.initialize(dequantize_modes);
	dequantize_shader_version = dequantize_shader.version_create();
	dequantize_pipeline = RD::get_singleton()->compute_pipeline_create(dequantize_shader.version_get_shader(dequantize_shader_version, 0));
}

RaytracingScene::~RaytracingScene() {
	free_all();

	if (dequantize_shader_version.is_valid()) {
		dequantize_shader.version_free(dequantize_shader_version);
	}

	if (singleton == this) {
		singleton = nullptr;
	}
}

void RaytracingScene::free_all() {
	for (KeyValue<SurfaceKey, BlasEntry> &E : blas_cache) {
		// The BLAS may already be gone: RenderingDevice frees an acceleration
		// structure along with the vertex buffer it was built from, and the mesh
		// that owns that buffer can be destroyed before this cache is torn down.
		if (E.value.blas.is_valid() && RD::get_singleton()->acceleration_structure_is_valid(E.value.blas)) {
			RD::get_singleton()->free_rid(E.value.blas);
		}
		if (E.value.position_buffer.is_valid()) {
			RD::get_singleton()->free_rid(E.value.position_buffer);
		}
	}
	blas_cache.clear();

	if (tlas.is_valid()) {
		RD::get_singleton()->free_rid(tlas);
		tlas = RID();
	}
	tlas_capacity = 0;
	tlas_valid = false;
}

void RaytracingScene::_dequantize_positions(RID p_source_buffer, RID p_dest_buffer, uint32_t p_vertex_count, uint32_t p_source_stride, const AABB &p_aabb) {
	LocalVector<RD::Uniform> uniforms;
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.binding = 0;
		u.append_id(p_source_buffer);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.binding = 1;
		u.append_id(p_dest_buffer);
		uniforms.push_back(u);
	}

	RID shader = dequantize_shader.version_get_shader(dequantize_shader_version, 0);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(shader, 0, uniforms);

	DequantizePushConstant push_constant = {};
	push_constant.aabb_position[0] = p_aabb.position.x;
	push_constant.aabb_position[1] = p_aabb.position.y;
	push_constant.aabb_position[2] = p_aabb.position.z;
	push_constant.vertex_count = p_vertex_count;
	push_constant.aabb_size[0] = p_aabb.size.x;
	push_constant.aabb_size[1] = p_aabb.size.y;
	push_constant.aabb_size[2] = p_aabb.size.z;
	push_constant.source_stride_in_words = p_source_stride / 4;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, dequantize_pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(DequantizePushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_vertex_count, 1, 1);
	RD::get_singleton()->compute_list_end();
}

bool RaytracingScene::_build_blas_geometry(RID p_mesh, uint32_t p_surface, BlasEntry &r_entry) {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();

	void *surface = mesh_storage->mesh_get_surface(p_mesh, p_surface);
	ERR_FAIL_NULL_V(surface, false);

	// Only indexed and non-indexed triangle lists can become BLAS geometry.
	if (mesh_storage->mesh_surface_get_primitive(surface) != RSE::PRIMITIVE_TRIANGLES) {
		return false;
	}

	const uint32_t vertex_count = mesh_storage->mesh_surface_get_vertex_count(surface);
	if (vertex_count == 0) {
		return false;
	}

	const uint64_t format = mesh_storage->mesh_surface_get_format(surface);

	// 2D vertices would produce a degenerate, planar acceleration structure, and
	// surfaces without a vertex array have no positions at all.
	if (format & RSE::ARRAY_FLAG_USE_2D_VERTICES) {
		return false;
	}
	if (format & RSE::ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY) {
		return false;
	}

	RID vertex_buffer = mesh_storage->mesh_surface_get_vertex_buffer(surface);
	if (vertex_buffer.is_null()) {
		return false;
	}

	const bool compressed = format & RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES;

	RID position_buffer;
	uint32_t position_stride = 0;

	if (compressed) {
		// Compressed positions are R16G16B16A16_UNORM normalized into the surface
		// AABB, which is not a legal acceleration structure vertex format. Expand
		// them once into a dedicated float32x3 buffer.
		const uint32_t source_stride = sizeof(uint16_t) * 4;
		position_buffer = RD::get_singleton()->storage_buffer_create(vertex_count * sizeof(float) * 3, {}, 0,
				RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT | RD::BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT);
		ERR_FAIL_COND_V(position_buffer.is_null(), false);

		_dequantize_positions(vertex_buffer, position_buffer, vertex_count, source_stride, mesh_storage->mesh_surface_get_aabb(surface));

		r_entry.position_buffer = position_buffer;
		position_stride = sizeof(float) * 3;
	} else {
		// Uncompressed positions are already a tightly packed float32x3 block at
		// the start of the vertex buffer, so they can be used directly.
		position_buffer = vertex_buffer;
		position_stride = sizeof(float) * 3;
	}

	RD::AccelerationStructureGeometry geometry;
	geometry.flags = RD::ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT;
	geometry.vertex_buffer = position_buffer;
	geometry.vertex_offset = 0;
	geometry.vertex_stride = position_stride;
	geometry.vertex_count = vertex_count;
	geometry.vertex_format = RD::DATA_FORMAT_R32G32B32_SFLOAT;

	const uint32_t index_count = mesh_storage->mesh_surface_get_index_count(surface);
	if (index_count >= 3) {
		geometry.index_buffer = mesh_storage->mesh_surface_get_index_buffer(surface);
		geometry.index_offset = 0;
		geometry.index_count = index_count;
	} else if (vertex_count < 3) {
		return false;
	}

	RD::AccelerationStructureGeometry geometries[1] = { geometry };
	r_entry.blas = RD::get_singleton()->blas_create(geometries, RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
	if (r_entry.blas.is_null()) {
		return false;
	}

	if (RD::get_singleton()->blas_build(r_entry.blas) != OK) {
		RD::get_singleton()->free_rid(r_entry.blas);
		r_entry.blas = RID();
		return false;
	}

	r_entry.vertex_count = vertex_count;
	r_entry.index_count = index_count;
	return true;
}

RaytracingScene::BlasEntry *RaytracingScene::_get_or_create_blas(RID p_mesh, uint32_t p_surface) {
	SurfaceKey key;
	key.mesh = p_mesh;
	key.surface = p_surface;

	BlasEntry *existing = blas_cache.getptr(key);
	if (existing) {
		existing->last_used_frame = frame;
		return existing;
	}

	BlasEntry entry;
	entry.last_used_frame = frame;

	if (_build_blas_geometry(p_mesh, p_surface, entry)) {
		entry.state = BLAS_READY;
	} else {
		entry.state = BLAS_INELIGIBLE;
		skipped_surface_count++;
	}

	blas_cache.insert(key, entry);
	return blas_cache.getptr(key);
}

void RaytracingScene::_ensure_tlas(uint32_t p_instance_count) {
	// Grow in powers of two so the TLAS is not recreated every frame. The
	// capacity is fixed at creation time, so exceeding it means recreating.
	uint32_t required = MAX(64u, p_instance_count);
	if (tlas.is_valid() && tlas_capacity >= required) {
		return;
	}

	uint32_t new_capacity = 64;
	while (new_capacity < required) {
		new_capacity *= 2;
	}

	if (tlas.is_valid()) {
		RD::get_singleton()->free_rid(tlas);
		tlas = RID();
		tlas_valid = false;
	}

	tlas = RD::get_singleton()->tlas_create(new_capacity, RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
	tlas_capacity = tlas.is_valid() ? new_capacity : 0;
}

void RaytracingScene::update(const LocalVector<InstanceData> &p_instances) {
	frame++;
	tlas_valid = false;

	if (!is_available()) {
		return;
	}

	MeshStorage *mesh_storage = MeshStorage::get_singleton();

	instance_scratch.clear();

	for (const InstanceData &instance : p_instances) {
		if (instance.mesh.is_null()) {
			continue;
		}

		const int surface_count = mesh_storage->mesh_get_surface_count(instance.mesh);
		for (int surface = 0; surface < surface_count; surface++) {
			BlasEntry *entry = _get_or_create_blas(instance.mesh, surface);
			if (!entry || entry->state != BLAS_READY) {
				continue;
			}

			if (instance_scratch.size() >= 65536) {
				// Hard ceiling so a pathological scene cannot exhaust memory in a
				// single frame. Anything past this simply does not cast this frame.
				break;
			}

			RD::AccelerationStructureInstance rd_instance;
			rd_instance.transform = instance.transform;
			rd_instance.id = instance_scratch.size();
			// The 8-bit instance mask is an OR-fold of Godot's 32-bit layer mask.
			rd_instance.mask = uint8_t((instance.layer_mask & 0xFF) | ((instance.layer_mask >> 8) & 0xFF) |
					((instance.layer_mask >> 16) & 0xFF) | ((instance.layer_mask >> 24) & 0xFF));
			if (rd_instance.mask == 0) {
				rd_instance.mask = 0xFF;
			}
			// Shadow rays do not need triangle facing, and per-light reverse cull
			// cannot be expressed on a shared TLAS, so culling is always disabled.
			rd_instance.flags = RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT;
			// tlas_build() rejects a zero hit shader binding table range even when
			// no ray pipeline is in use. Encode (offset 0, count 1); ray queries
			// never consult the shader binding table.
			rd_instance.hit_sbt_range = RD::HitShaderBindingTableRange(int64_t(1) << 32);
			rd_instance.blas = entry->blas;

			instance_scratch.push_back(rd_instance);
		}
	}

	if (skipped_surface_count > 0 && !warned_about_skipped) {
		warned_about_skipped = true;
		WARN_PRINT(vformat("Raytraced shadows: %d mesh surface(s) cannot be raytraced and will not cast shadows (non-triangle geometry, 2D vertices, or empty vertex arrays).", skipped_surface_count));
	}

	if (instance_scratch.is_empty()) {
		return;
	}

	_ensure_tlas(instance_scratch.size());
	if (tlas.is_null()) {
		return;
	}

	Error err = RD::get_singleton()->tlas_build(tlas, instance_scratch);
	tlas_valid = (err == OK);
}
