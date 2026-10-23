/**************************************************************************/
/*  rt_geometry.cpp                                                       */
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

#include "rt_geometry.h"

#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

void RaytracingGeometry::initialize() {
	if (dequantize_shader_version.is_valid()) {
		return;
	}
	Vector<String> dequantize_modes;
	dequantize_modes.push_back("");
	dequantize_shader.initialize(dequantize_modes);
	dequantize_shader_version = dequantize_shader.version_create();
	dequantize_pipeline = RD::get_singleton()->compute_pipeline_create(dequantize_shader.version_get_shader(dequantize_shader_version, 0));
}

RaytracingGeometry::~RaytracingGeometry() {
	clear();
	if (dequantize_shader_version.is_valid()) {
		dequantize_shader.version_free(dequantize_shader_version);
	}
}

void RaytracingGeometry::clear() {
	for (KeyValue<SurfaceKey, BlasEntry> &entry : blas_cache) {
		_release_blas(entry.value);
	}
	blas_cache.clear();
}

void RaytracingGeometry::begin_update() {
	frame++;
	blas_builds_remaining = MAX_BLAS_BUILDS_PER_FRAME;
	blas_build_triangles_remaining = MAX_BLAS_BUILD_TRIANGLES_PER_FRAME;
	deferred_surface_count = 0;
	changed_this_update = false;
}

void RaytracingGeometry::end_update() {
	_evict_stale_blas();
}

const RaytracingGeometry::Surface *RaytracingGeometry::get_surface(RID p_mesh, RID p_mesh_instance, uint32_t p_surface, bool p_gi) {
	ERR_FAIL_COND_V(dequantize_pipeline.is_null(), nullptr);
	BlasEntry *entry = _get_or_create_blas(p_mesh, p_mesh_instance, p_surface);
	if (entry) {
		if (p_gi) {
			entry->used_by_gi = true;
		} else {
			entry->last_shadow_frame = frame;
		}
	}
	return entry && entry->state == BLAS_READY ? &entry->surface : nullptr;
}

void RaytracingGeometry::release_gi_only() {
	Vector<SurfaceKey> remove;
	for (KeyValue<SurfaceKey, BlasEntry> &entry : blas_cache) {
		if (entry.value.used_by_gi && entry.value.last_shadow_frame != frame) {
			_release_blas(entry.value);
			remove.push_back(entry.key);
		} else {
			entry.value.used_by_gi = false;
		}
	}
	for (const SurfaceKey &key : remove) {
		blas_cache.erase(key);
	}
}

void RaytracingGeometry::_dequantize_positions(RID p_source_buffer, RID p_dest_buffer, uint32_t p_vertex_count, uint32_t p_source_stride, const AABB &p_aabb) {
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

bool RaytracingGeometry::_build_blas_geometry(RID p_mesh, RID p_mesh_instance, uint32_t p_surface, BlasEntry &r_entry) {
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

	// A skinned surface traces against the skeleton pass's output rather than
	// the mesh's rest-pose vertices.
	const bool skinned = p_mesh_instance.is_valid();
	RID vertex_buffer = skinned ? mesh_storage->mesh_instance_get_vertex_buffer(p_mesh_instance, p_surface)
								: mesh_storage->mesh_surface_get_vertex_buffer(surface);
	if (vertex_buffer.is_null()) {
		if (skinned) {
			// A mesh instance exists but this surface is not deformed (no bones and
			// no blend shapes), so the mesh's own buffer is still correct.
			vertex_buffer = mesh_storage->mesh_surface_get_vertex_buffer(surface);
		}
		if (vertex_buffer.is_null()) {
			ERR_PRINT_ONCE("Raytraced shadows: mesh surface has no vertex buffer; it cannot cast shadows.");
			return false;
		}
	}

	r_entry.skinned = skinned && vertex_buffer != mesh_storage->mesh_surface_get_vertex_buffer(surface);
	r_entry.source_buffer = vertex_buffer;
	r_entry.source_revision = mesh_storage->mesh_surface_get_geometry_revision(surface);

	const bool compressed = format & RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES;

	RID position_buffer;
	uint32_t position_stride = 0;

	if (compressed) {
		// Compressed positions are R16G16B16A16_UNORM normalized into the surface
		// AABB, which is not a legal acceleration structure vertex format. Expand
		// them once into a dedicated float32x3 buffer.
		const uint32_t source_stride = sizeof(uint16_t) * 4;
		// A VERTEX buffer, not a storage buffer, and the distinction is the whole
		// bug this line used to carry. `blas_create` resolves a geometry's vertex
		// buffer through `vertex_buffer_owner` alone (rendering_device.cpp:323), so
		// an RID minted by `storage_buffer_create` -- which lands in
		// `storage_buffer_owner` (:1509) -- fails that lookup and the build errors
		// out with `Parameter "vertex_buffer" is null.` every frame, for every
		// compressed surface, forever. Nothing downstream is lost by switching:
		// `uniform_set_create` takes a vertex buffer for a storage binding too
		// (:4753), so the dequantize pass can still write into it. It does insist
		// that a vertex buffer carry the storage usage explicitly (:4756), where
		// `storage_buffer_create` set it unconditionally (:1465) -- that is what
		// BUFFER_CREATION_AS_STORAGE_BIT below is for. Drop it and the dequantize
		// pass's uniform set is refused, leaving the structure built from a buffer
		// nothing ever wrote.
		//
		// This never showed in the validation harness because every rig builds its
		// meshes procedurally and uncompressed. Imported meshes are compressed by
		// default, so in a real project it meant NO compressed mesh cast a
		// raytraced shadow at all.
		position_buffer = RD::get_singleton()->vertex_buffer_create(vertex_count * sizeof(float) * 3, {},
				RD::BUFFER_CREATION_AS_STORAGE_BIT | RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT |
						RD::BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT);
		ERR_FAIL_COND_V(position_buffer.is_null(), false);

		_dequantize_positions(vertex_buffer, position_buffer, vertex_count, source_stride, mesh_storage->mesh_surface_get_aabb(surface));

		r_entry.position_buffer = position_buffer;
		r_entry.compressed = true;
		r_entry.source_stride = source_stride;
		r_entry.source_aabb = mesh_storage->mesh_surface_get_aabb(surface);
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
	// Skinned geometry is rebuilt every frame the pose moves, so build speed
	// matters more than trace speed there; static geometry is built once.
	r_entry.surface.blas = RD::get_singleton()->blas_create(geometries,
			r_entry.skinned ? RD::ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT : RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
	if (r_entry.surface.blas.is_null()) {
		// Most often this means the source buffers were created without the
		// acceleration structure usage bits, which are only applied when the
		// project setting is already on at the time the mesh is uploaded.
		ERR_PRINT_ONCE("Raytraced shadows: blas_create() failed. The mesh buffers were probably created without the acceleration structure usage flags; the setting is restart-required for this reason.");
		return false;
	}

	if (RD::get_singleton()->blas_build(r_entry.surface.blas) != OK) {
		ERR_PRINT_ONCE("Raytraced shadows: blas_build() failed; this geometry will not cast shadows.");
		RD::get_singleton()->free_rid(r_entry.surface.blas);
		r_entry.surface.blas = RID();
		return false;
	}

	r_entry.surface.vertex_count = vertex_count;
	r_entry.surface.index_count = geometry.index_buffer.is_valid() ? index_count : 0;
	r_entry.surface.vertex_buffer = position_buffer;
	r_entry.surface.index_buffer = geometry.index_buffer;
	r_entry.surface.index_stride = geometry.index_buffer.is_valid() ? (vertex_count <= 65536 ? 2 : 4) : 0;
	r_entry.surface.revision = ++revision;
	return true;
}

RID RaytracingGeometry::_get_surface_source_buffer(RID p_mesh, RID p_mesh_instance, uint32_t p_surface) const {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();

	RID vertex_buffer;
	if (p_mesh_instance.is_valid()) {
		vertex_buffer = mesh_storage->mesh_instance_get_vertex_buffer(p_mesh_instance, p_surface);
	}
	if (vertex_buffer.is_null()) {
		void *surface = mesh_storage->mesh_get_surface(p_mesh, p_surface);
		if (surface != nullptr) {
			vertex_buffer = mesh_storage->mesh_surface_get_vertex_buffer(surface);
		}
	}
	return vertex_buffer;
}

RaytracingGeometry::BlasEntry *RaytracingGeometry::_get_or_create_blas(RID p_mesh, RID p_mesh_instance, uint32_t p_surface) {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();

	SurfaceKey key;
	key.surface = p_surface;

	if (p_mesh_instance.is_valid()) {
		// Key on the skinned buffer: it is unique per (instance, surface), and
		// the skeleton pass alternates between two of them when motion vectors
		// are on, so each gets its own structure to rebuild in place.
		key.source = mesh_storage->mesh_instance_get_vertex_buffer(p_mesh_instance, p_surface);
	}
	if (key.source.is_null()) {
		key.source = p_mesh;
	}

	BlasEntry *existing = blas_cache.getptr(key);
	if (existing) {
		existing->last_used_frame = frame;
		if (existing->state == BLAS_READY) {
			// A mesh can have its surfaces cleared and re-added on the same RID:
			// every PrimitiveMesh does exactly that when one of its properties
			// changes, and so does ArrayMesh.clear_surfaces(). That frees the
			// vertex buffer, and blas_create() registered this structure as a
			// dependency of that buffer, so the structure goes with it. Left
			// alone, the dead structure would be handed to every later TLAS build
			// and take the whole build down with it, so the entry is dropped and
			// rebuilt from whatever the surface holds now.
			//
			// Asking whether the buffer is still the one this was built from
			// detects replacement. Being
			// freed along with that buffer is the only way one of these
			// structures goes away without this cache doing it, and RID_Owner
			// bumps a generation counter when it reuses a slot, so a buffer RID
			// that still compares equal is the same buffer and its dependents are
			// therefore still alive. A surface that has gone away entirely gives
			// back a null RID, which also fails the comparison and drops the
			// entry -- correctly, since the loop above will not ask for that
			// surface again either.
			// The separate geometry revision also catches in-place vertex/index
			// edits, which change triangle data without replacing the buffer RID.
			//
			// Asking RenderingDevice whether the structure is still alive is the
			// obvious alternative, but it is a _THREAD_SAFE_METHOD_ and so takes
			// the device lock once per surface per frame, which costs far more
			// than this comparison in a scene with many casters.
			void *source_surface = mesh_storage->mesh_get_surface(p_mesh, p_surface);
			if (_get_surface_source_buffer(p_mesh, p_mesh_instance, p_surface) != existing->source_buffer || (source_surface && mesh_storage->mesh_surface_get_geometry_revision(source_surface) != existing->source_revision)) {
				_release_blas(*existing);
				blas_cache.erase(key);
				existing = nullptr;
			}
		}

		if (existing) {
			if (existing->state == BLAS_READY && existing->skinned) {
				const uint64_t version = mesh_storage->mesh_instance_get_last_change(p_mesh_instance, p_surface);
				if (version != existing->skin_version) {
					existing->skin_version = version;
					changed_this_update = true;
					_refresh_skinned_blas(*existing);
				}
			}
			return existing;
		}
	}

	// Nothing is cached for this surface, so it has to be built. Everything up
	// to here was free; past here it costs allocations and device work.
	if (blas_builds_remaining == 0 || blas_build_triangles_remaining == 0) {
		deferred_surface_count++;
		return nullptr;
	}
	blas_builds_remaining--;

	BlasEntry entry;
	entry.last_used_frame = frame;

	if (_build_blas_geometry(p_mesh, p_mesh_instance, p_surface, entry)) {
		entry.state = BLAS_READY;
		built_surface_count++;
		const uint32_t triangles = (entry.surface.index_count >= 3 ? entry.surface.index_count : entry.surface.vertex_count) / 3;
		blas_build_triangles_remaining = triangles >= blas_build_triangles_remaining ? 0 : blas_build_triangles_remaining - triangles;
		if (entry.skinned) {
			entry.skin_version = mesh_storage->mesh_instance_get_last_change(p_mesh_instance, p_surface);
		}
	} else {
		entry.state = BLAS_INELIGIBLE;
		skipped_surface_count++;
	}

	changed_this_update = true;
	blas_cache.insert(key, entry);
	return blas_cache.getptr(key);
}

void RaytracingGeometry::_refresh_skinned_blas(BlasEntry &r_entry) {
	if (r_entry.surface.blas.is_null()) {
		return;
	}

	// The geometry description was fixed when the structure was created and
	// still points at the same buffer, so the pose is picked up by rebuilding
	// in place. There is no refit entry point on RenderingDevice, but a rebuild
	// reuses the existing scratch allocation.
	if (r_entry.compressed && r_entry.position_buffer.is_valid()) {
		// Compressed skinned output has to be expanded again for the new pose.
		_dequantize_positions(r_entry.source_buffer, r_entry.position_buffer, r_entry.surface.vertex_count,
				r_entry.source_stride, r_entry.source_aabb);
	}

	if (RD::get_singleton()->blas_build(r_entry.surface.blas) != OK) {
		ERR_PRINT_ONCE("Raytraced shadows: rebuilding a skinned mesh's acceleration structure failed; its shadow will be stale.");
	} else {
		r_entry.surface.revision = ++revision;
	}
}

void RaytracingGeometry::_release_blas(BlasEntry &r_entry) {
	if (r_entry.surface.blas.is_valid() && RD::get_singleton()->acceleration_structure_is_valid(r_entry.surface.blas)) {
		RD::get_singleton()->free_rid(r_entry.surface.blas);
	}
	r_entry.surface.blas = RID();
	if (r_entry.position_buffer.is_valid()) {
		RD::get_singleton()->free_rid(r_entry.position_buffer);
		r_entry.position_buffer = RID();
	}
}

void RaytracingGeometry::_evict_stale_blas() {
	// Skinned structures are per instance, so without eviction every character
	// that ever existed would keep one alive. Static entries are cheap to keep
	// but follow the same rule for simplicity.
	constexpr uint64_t FRAMES_UNTIL_EVICTION = 60;
	// Sweeping the whole cache is the only way to find entries nothing asked for
	// this frame, and in a scene with many distinct meshes that walk is longer
	// than the work it saves. Since an entry is not eligible for sixty frames
	// anyway, doing the sweep every eighth costs it at most seven more.
	constexpr uint64_t FRAMES_BETWEEN_SWEEPS = 8;

	if (frame % FRAMES_BETWEEN_SWEEPS != 0) {
		return;
	}

	LocalVector<SurfaceKey> to_remove;
	for (const KeyValue<SurfaceKey, BlasEntry> &E : blas_cache) {
		if (frame - E.value.last_used_frame > FRAMES_UNTIL_EVICTION) {
			to_remove.push_back(E.key);
		}
	}

	for (const SurfaceKey &key : to_remove) {
		_release_blas(*blas_cache.getptr(key));
		blas_cache.erase(key);
	}
}
