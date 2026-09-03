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
#include "core/os/os.h"
#include "core/string/print_string.h"
#include "core/templates/hashfuncs.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"
#include "servers/rendering/rendering_server_globals.h"

using namespace RendererRD;

RaytracingScene *RaytracingScene::singleton = nullptr;

// Opt-in tracing for diagnosing why raytraced shadows are not appearing.
// Cached so the hot path does not query the environment every frame.
bool RaytracingScene::debug_enabled() {
	static const bool enabled = !OS::get_singleton()->get_environment("GODOT_RT_DEBUG").is_empty();
	return enabled;
}

bool RaytracingScene::settings_registered = false;
bool RaytracingScene::setting_enabled = false;
bool RaytracingScene::setting_directional_enabled = false;
int RaytracingScene::frame_demoted_mode = 2;
int RaytracingScene::frame_demoted_size = 1024;

void RaytracingScene::register_settings() {
	if (settings_registered) {
		return;
	}
	settings_registered = true;

	// The settings themselves are registered in ProjectSettings so that they
	// exist before the rendering device is created; here we only take the first
	// copy of the two flags that are not read live at every use.
	//
	// `enabled` decides, in MeshStorage::mesh_add_surface, whether a vertex
	// buffer is created with acceleration structure usage. That happens at
	// upload time, before this object exists, so a mesh loaded while the setting
	// was off has nothing an acceleration structure could be built from. Reading
	// a later value would only produce build failures against buffers that can
	// never satisfy it.
	//
	// `directional/enabled` has no such constraint -- it only picks which of two
	// shadowing paths a sun takes, and both are rebuilt every frame -- so it is
	// live too, but refreshed once per frame by update_frame_settings() rather
	// than read wherever it is wanted. See there for why.
	//
	// Everything else is read live below.
	setting_enabled = GLOBAL_GET("rendering/lights_and_shadows/raytraced_shadows/enabled");
	setting_directional_enabled = GLOBAL_GET("rendering/lights_and_shadows/raytraced_shadows/directional/enabled");
}

// Refreshed from the frame's own start, before any viewport draws.
//
// The other live settings are tuning knobs: a frame that read one of them twice
// and got two answers would look very slightly wrong for one frame and no more.
// This one is not like that. Whether a sun is raytraced decides how many
// cascades it gets, and that has to be the same answer for the culler, for the
// shadow atlas layout and for the light buffer, which run at three different
// points in a frame. A value that changed between them would put cascades in
// the wrong atlas rects. Snapshotting it here, where Godot snapshots its own
// per-frame rendering settings, is what makes it safe to change while running.
void RaytracingScene::update_frame_settings() {
	register_settings();
	setting_directional_enabled = GLOBAL_GET_CACHED(bool, "rendering/lights_and_shadows/raytraced_shadows/directional/enabled");
	// The two demotion settings answer the same question from the other side --
	// how many cascades the sun's leftover map gets, and how large the atlas
	// holding it is -- so they are fixed for the frame for the same reason.
	frame_demoted_mode = CLAMP(GLOBAL_GET_CACHED(int, "rendering/lights_and_shadows/raytraced_shadows/directional/demoted_shadow_mode"), 0, 2);
	frame_demoted_size = MAX(0, GLOBAL_GET_CACHED(int, "rendering/lights_and_shadows/raytraced_shadows/directional/demoted_shadow_size"));
}

bool RaytracingScene::is_enabled() {
	register_settings();
	return setting_enabled;
}

bool RaytracingScene::is_directional_enabled() {
	register_settings();
	return setting_directional_enabled;
}

// The remaining settings are tuning knobs, and tuning them by restarting the
// editor is miserable. GLOBAL_GET_CACHED keeps a typed copy and only re-reads it
// when ProjectSettings bumps its version, so the steady state costs an integer
// compare rather than a string lookup, and a change in the inspector reaches the
// renderer on the next frame that asks.
//
// Each is clamped here rather than trusted, because a live value arrives
// straight from the inspector with no validation beyond the property hint, and
// the hints allow `or_greater` in places.

int RaytracingScene::get_sample_count() {
	return MAX(1, GLOBAL_GET_CACHED(int, "rendering/lights_and_shadows/raytraced_shadows/samples_per_light"));
}

float RaytracingScene::get_max_distance() {
	return MAX(0.0f, GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/max_ray_distance"));
}

float RaytracingScene::get_softness_scale() {
	return CLAMP(GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/softness_scale"), 0.0f, 1.0f);
}

bool RaytracingScene::is_accurate_occluder_distance() {
	return GLOBAL_GET_CACHED(bool, "rendering/lights_and_shadows/raytraced_shadows/accurate_occluder_distance");
}

bool RaytracingScene::is_denoiser_enabled() {
	return GLOBAL_GET_CACHED(bool, "rendering/lights_and_shadows/raytraced_shadows/denoiser/enabled");
}

int RaytracingScene::get_denoiser_iterations() {
	return CLAMP(GLOBAL_GET_CACHED(int, "rendering/lights_and_shadows/raytraced_shadows/denoiser/spatial_passes"), 1, 5);
}

float RaytracingScene::get_denoiser_max_history() {
	return float(CLAMP(GLOBAL_GET_CACHED(int, "rendering/lights_and_shadows/raytraced_shadows/denoiser/temporal_frames"), 1, 64));
}

float RaytracingScene::get_denoiser_min_filter_pixels() {
	return CLAMP(GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/denoiser/min_filter_pixels"), 0.0f, 8.0f);
}

float RaytracingScene::get_denoiser_history_clamp_sigma() {
	return CLAMP(GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/denoiser/history_clamp_sigma"), 0.0f, 8.0f);
}

float RaytracingScene::get_denoiser_lag_response() {
	return CLAMP(GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/denoiser/lag_response"), 0.0f, 1.0f);
}

float RaytracingScene::get_directional_caster_scale() {
	return MAX(0.0f, GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/directional/caster_distance_scale"));
}

RaytracingScene::DirectionalScatterMode RaytracingScene::get_directional_scatter_mode() {
	return (DirectionalScatterMode)CLAMP(GLOBAL_GET_CACHED(int, "rendering/lights_and_shadows/raytraced_shadows/directional/scatter_casters"),
			(int)DIRECTIONAL_SCATTER_DISABLED, (int)DIRECTIONAL_SCATTER_FULL_DISTANCE);
}

float RaytracingScene::get_directional_scatter_distance() {
	return MAX(0.0f, GLOBAL_GET_CACHED(float, "rendering/lights_and_shadows/raytraced_shadows/directional/scatter_distance"));
}

int RaytracingScene::get_directional_demoted_mode() {
	return frame_demoted_mode;
}

int RaytracingScene::get_directional_demoted_size() {
	return frame_demoted_size;
}

RaytracingScene::RaytracingScene() {
	singleton = this;

	register_settings();

	supported = RD::get_singleton()->has_feature(RD::SUPPORTS_RAY_QUERY);

	if (setting_enabled) {
		if (supported) {
			print_line("Raytraced shadows: enabled (device supports ray queries).");
		} else {
			WARN_PRINT("Raytraced shadows are enabled in the project settings, but this rendering device does not support ray queries. Local lights will fall back to shadow maps.");
		}
	}

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
	tlas_built = false;
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

bool RaytracingScene::_build_blas_geometry(RID p_mesh, RID p_mesh_instance, uint32_t p_surface, BlasEntry &r_entry) {
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
	r_entry.blas = RD::get_singleton()->blas_create(geometries,
			r_entry.skinned ? RD::ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT : RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
	if (r_entry.blas.is_null()) {
		// Most often this means the source buffers were created without the
		// acceleration structure usage bits, which are only applied when the
		// project setting is already on at the time the mesh is uploaded.
		ERR_PRINT_ONCE("Raytraced shadows: blas_create() failed. The mesh buffers were probably created without the acceleration structure usage flags; the setting is restart-required for this reason.");
		return false;
	}

	if (RD::get_singleton()->blas_build(r_entry.blas) != OK) {
		ERR_PRINT_ONCE("Raytraced shadows: blas_build() failed; this geometry will not cast shadows.");
		RD::get_singleton()->free_rid(r_entry.blas);
		r_entry.blas = RID();
		return false;
	}

	r_entry.vertex_count = vertex_count;
	r_entry.index_count = index_count;
	return true;
}

RID RaytracingScene::_get_surface_source_buffer(RID p_mesh, RID p_mesh_instance, uint32_t p_surface) const {
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

RaytracingScene::BlasEntry *RaytracingScene::_get_or_create_blas(RID p_mesh, RID p_mesh_instance, uint32_t p_surface) {
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
			// Asking whether the buffer is still the one this was built from is
			// the whole test, and it is worth being precise about why. Being
			// freed along with that buffer is the only way one of these
			// structures goes away without this cache doing it, and RID_Owner
			// bumps a generation counter when it reuses a slot, so a buffer RID
			// that still compares equal is the same buffer and its dependents are
			// therefore still alive. A surface that has gone away entirely gives
			// back a null RID, which also fails the comparison and drops the
			// entry -- correctly, since the loop above will not ask for that
			// surface again either.
			//
			// Asking RenderingDevice whether the structure is still alive is the
			// obvious alternative, but it is a _THREAD_SAFE_METHOD_ and so takes
			// the device lock once per surface per frame, which costs far more
			// than this comparison in a scene with many casters.
			if (_get_surface_source_buffer(p_mesh, p_mesh_instance, p_surface) != existing->source_buffer) {
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
					blas_changed_this_frame = true;
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
		const uint32_t triangles = (entry.index_count >= 3 ? entry.index_count : entry.vertex_count) / 3;
		blas_build_triangles_remaining = triangles >= blas_build_triangles_remaining ? 0 : blas_build_triangles_remaining - triangles;
		if (entry.skinned) {
			entry.skin_version = mesh_storage->mesh_instance_get_last_change(p_mesh_instance, p_surface);
		}
	} else {
		entry.state = BLAS_INELIGIBLE;
		skipped_surface_count++;
	}

	blas_changed_this_frame = true;
	blas_cache.insert(key, entry);
	return blas_cache.getptr(key);
}

void RaytracingScene::_refresh_skinned_blas(BlasEntry &r_entry) {
	if (r_entry.blas.is_null()) {
		return;
	}

	// The geometry description was fixed when the structure was created and
	// still points at the same buffer, so the pose is picked up by rebuilding
	// in place. There is no refit entry point on RenderingDevice, but a rebuild
	// reuses the existing scratch allocation.
	if (r_entry.compressed && r_entry.position_buffer.is_valid()) {
		// Compressed skinned output has to be expanded again for the new pose.
		_dequantize_positions(r_entry.source_buffer, r_entry.position_buffer, r_entry.vertex_count,
				r_entry.source_stride, r_entry.source_aabb);
	}

	if (RD::get_singleton()->blas_build(r_entry.blas) != OK) {
		ERR_PRINT_ONCE("Raytraced shadows: rebuilding a skinned mesh's acceleration structure failed; its shadow will be stale.");
	}
}

void RaytracingScene::_release_blas(BlasEntry &r_entry) {
	if (r_entry.blas.is_valid() && RD::get_singleton()->acceleration_structure_is_valid(r_entry.blas)) {
		RD::get_singleton()->free_rid(r_entry.blas);
	}
	r_entry.blas = RID();
	if (r_entry.position_buffer.is_valid()) {
		RD::get_singleton()->free_rid(r_entry.position_buffer);
		r_entry.position_buffer = RID();
	}
}

void RaytracingScene::_evict_stale_blas() {
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

	// A fresh structure describes nothing yet, so the next build is mandatory
	// however little the scene changed.
	tlas_built = false;

	tlas = RD::get_singleton()->tlas_create(new_capacity, RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
	if (tlas.is_null()) {
		ERR_PRINT_ONCE(vformat("Raytraced shadows: tlas_create() failed for %d instances; no raytraced shadows will be cast.", new_capacity));
	}
	tlas_capacity = tlas.is_valid() ? new_capacity : 0;
}

void RaytracingScene::update(const LocalVector<InstanceData> &p_instances) {
	const bool rtdbg = debug_enabled();
	frame++;
	tlas_valid = false;

	if (!is_available()) {
		if (rtdbg) {
			print_line(vformat("RT_DEBUG update: NOT AVAILABLE (supported=%d enabled=%d)", int(supported), int(is_enabled())));
		}
		return;
	}

	MeshStorage *mesh_storage = MeshStorage::get_singleton();

	instance_scratch.clear();

	blas_builds_remaining = MAX_BLAS_BUILDS_PER_FRAME;
	blas_build_triangles_remaining = MAX_BLAS_BUILD_TRIANGLES_PER_FRAME;
	deferred_surface_count = 0;
	blas_changed_this_frame = false;

	for (const InstanceData &instance : p_instances) {
		if (instance.mesh.is_null()) {
			continue;
		}

		const int surface_count = mesh_storage->mesh_get_surface_count(instance.mesh);
		for (int surface = 0; surface < surface_count; surface++) {
			// A surface whose material cannot write a shadow map must not write a
			// traced one either, or every pane of glass in the scene would start
			// casting a solid shadow the moment its light became raytraced.
			if (surface < 32 && (instance.surface_mask & (uint32_t(1) << surface)) == 0) {
				continue;
			}
			BlasEntry *entry = _get_or_create_blas(instance.mesh, instance.mesh_instance, surface);
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
		WARN_PRINT(vformat("Raytraced shadows: %d mesh surface(s) cannot be raytraced and will not cast shadows (non-triangle geometry, 2D vertices, or empty vertex arrays). %d surface(s) built successfully.", skipped_surface_count, built_surface_count));
	}

	_evict_stale_blas();

	if (instance_scratch.is_empty()) {
		return;
	}

	_ensure_tlas(instance_scratch.size());
	if (tlas.is_null()) {
		return;
	}

	// A structure that describes the same geometry in the same places as last
	// frame does not need building again. Rebuilding a structure whose geometry
	// changed is not optional, though, so any build or refresh below forces it:
	// the bounds a top level structure caches for a mesh go stale the moment
	// that mesh's own structure is rebuilt.
	// Summed rather than chained, so that the order the casters came out of the
	// scene's spatial index in does not count as a change. Only the set matters:
	// a ray query reads nothing that depends on an instance's position in the
	// array, so two orderings of the same instances describe the same scene.
	uint32_t contents_hash = hash_murmur3_one_64(instance_scratch.size());
	for (const RD::AccelerationStructureInstance &rd_instance : instance_scratch) {
		uint32_t entry_hash = hash_murmur3_one_64(rd_instance.blas.get_id());
		entry_hash = hash_murmur3_one_32(rd_instance.mask, entry_hash);
		for (int row = 0; row < 3; row++) {
			for (int column = 0; column < 3; column++) {
				entry_hash = hash_murmur3_one_real(rd_instance.transform.basis.rows[row][column], entry_hash);
			}
		}
		entry_hash = hash_murmur3_one_real(rd_instance.transform.origin.x, entry_hash);
		entry_hash = hash_murmur3_one_real(rd_instance.transform.origin.y, entry_hash);
		entry_hash = hash_murmur3_one_real(rd_instance.transform.origin.z, entry_hash);
		contents_hash += hash_fmix32(entry_hash);
	}

	const bool rebuild = !tlas_built || blas_changed_this_frame || contents_hash != tlas_contents_hash;

	if (rtdbg) {
		static String last;
		String cur = vformat("RT_DEBUG update: in_instances=%d tlas_instances=%d blas_cache=%d skipped_surfaces=%d deferred_surfaces=%d rebuilt=%d",
				(int)p_instances.size(), (int)instance_scratch.size(), (int)blas_cache.size(), (int)skipped_surface_count,
				(int)deferred_surface_count, int(rebuild));
		if (cur != last) {
			last = cur;
			print_line(cur);
		}
	}

	if (!rebuild) {
		// The build from an earlier frame still describes this scene.
		tlas_valid = true;
		return;
	}
	tlas_contents_hash = contents_hash;

	Error err = RD::get_singleton()->tlas_build(tlas, instance_scratch);
	if (err != OK) {
		ERR_PRINT_ONCE(vformat("Raytraced shadows: tlas_build() failed with error %d; no raytraced shadows will be cast.", (int)err));
	}
	tlas_valid = (err == OK);
	tlas_built = tlas_valid;
}
