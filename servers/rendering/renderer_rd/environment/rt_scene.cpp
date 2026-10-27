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
#include "servers/rendering/renderer_rd/effects/rt_shadows.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
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

	if (setting_enabled && supported) {
		print_line("Raytraced shadows: enabled (device supports ray queries).");
	}

	if (!setting_enabled) {
		// Nothing else is needed; the feature is off for this project.
		return;
	}

	if (!supported) {
		WARN_PRINT("Raytraced shadows are enabled in the project settings, but this device does not support hardware ray queries. Falling back to shadow maps.");
		return;
	}

	geometry.initialize();
}

RaytracingScene::~RaytracingScene() {
	free_all();

	if (singleton == this) {
		singleton = nullptr;
	}
}

void RaytracingScene::free_all() {
	geometry.clear();
	prepared_surfaces.clear();
	prepared_instances.clear();
	instance_scratch.clear();

	if (tlas.is_valid()) {
		RD::get_singleton()->free_rid(tlas);
		tlas = RID();
	}
	tlas_capacity = 0;
	tlas_valid = false;
	tlas_built = false;
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

void RaytracingScene::_reconstruct_instances(const LocalVector<InstanceData> &p_instances, LocalVector<RD::AccelerationStructureInstance> &r_instances) {
	MeshStorage *mesh_storage = MeshStorage::get_singleton();
	r_instances.clear();

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
			const RaytracingGeometry::Surface *entry = geometry.get_surface(instance.mesh, instance.mesh_instance, surface);
			if (!entry) {
				continue;
			}

			if (r_instances.size() >= 65536) {
				// Hard ceiling so a pathological scene cannot exhaust memory in a
				// single frame. Anything past this simply does not cast this frame.
				break;
			}

			RD::AccelerationStructureInstance rd_instance;
			rd_instance.transform = instance.transform;
			rd_instance.id = r_instances.size();
			// Must fold exactly as the light side does, or a caster stops answering
			// a light with no diagnostic. RTShadows::fold_layer_mask owns the rule.
			rd_instance.mask = RTShadows::fold_layer_mask(instance.layer_mask);
			// Shadow rays do not need triangle facing, and per-light reverse cull
			// cannot be expressed on a shared TLAS, so culling is always disabled.
			rd_instance.flags = RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT;
			// tlas_build() rejects a zero hit shader binding table range even when
			// no ray pipeline is in use. Encode (offset 0, count 1); ray queries
			// never consult the shader binding table.
			rd_instance.hit_sbt_range = RD::HitShaderBindingTableRange(int64_t(1) << 32);
			rd_instance.blas = entry->blas;

			r_instances.push_back(rd_instance);
		}
	}
}

static uint32_t _rt_instance_hash(RID p_blas, uint32_t p_mask, const Transform3D &p_transform) {
	uint32_t hash = hash_murmur3_one_64(p_blas.get_id());
	hash = hash_murmur3_one_32(p_mask, hash);
	for (int row = 0; row < 3; row++) {
		for (int column = 0; column < 3; column++) {
			hash = hash_murmur3_one_real(p_transform.basis.rows[row][column], hash);
		}
	}
	hash = hash_murmur3_one_real(p_transform.origin.x, hash);
	hash = hash_murmur3_one_real(p_transform.origin.y, hash);
	hash = hash_murmur3_one_real(p_transform.origin.z, hash);
	return hash_fmix32(hash);
}

void RaytracingScene::_pack_prepared_instances() {
	instance_scratch.clear();
	for (const PreparedInstance &instance : prepared_instances) {
		for (const PreparedInstanceSurface &surface : instance.surfaces) {
			RD::AccelerationStructureInstance record;
			record.transform = instance.transform;
			record.id = instance_scratch.size();
			record.mask = instance.mask;
			record.flags = RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT;
			record.hit_sbt_range = RD::HitShaderBindingTableRange(int64_t(1) << 32);
			record.blas = surface.blas;
			instance_scratch.push_back(record);
		}
	}
}

void RaytracingScene::update(const LocalVector<InstanceData> &p_instances) {
	const bool rtdbg = debug_enabled();
	static const bool disable_reuse = OS::get_singleton()->get_environment("GODOT_RT_DISABLE_SHADOW_REUSE") == "1";
	static const bool validate_reuse = OS::get_singleton()->get_environment("GODOT_RT_VALIDATE_SHADOW_REUSE") == "1";
	static const bool profile = OS::get_singleton()->get_environment("GODOT_RT_CPU_PROFILE") == "1";
	tlas_valid = false;

	if (!is_available()) {
		prepared_instances.clear();
		prepared_surfaces.clear();
		if (rtdbg) {
			print_line(vformat("RT_DEBUG update: NOT AVAILABLE (supported=%d enabled=%d)", int(supported), int(is_enabled())));
		}
		return;
	}

	const uint64_t started = profile ? OS::get_singleton()->get_ticks_usec() : 0;
	uint64_t surface_usec = 0;
	uint32_t surface_requests = 0, surface_reused = 0, hashes_reused = 0;
	uint32_t instance_count = 0, contents_hash = 0;
	if (disable_reuse) {
		_reconstruct_instances(p_instances, instance_scratch);
		instance_count = instance_scratch.size();
		for (const RD::AccelerationStructureInstance &instance : instance_scratch) {
			contents_hash += _rt_instance_hash(instance.blas, instance.mask, instance.transform);
		}
	} else {
		MeshStorage *mesh_storage = MeshStorage::get_singleton();
		preparation_update++;
		prepared_instances.resize(p_instances.size());
		for (uint32_t i = 0; i < p_instances.size(); i++) {
			const InstanceData &instance = p_instances[i];
			PreparedInstance &prepared = prepared_instances[i];
			const uint32_t mask = RTShadows::fold_layer_mask(instance.layer_mask);
			const bool same_transform = prepared.transform == instance.transform && prepared.mask == mask;
			uint32_t admitted = 0;
			const int surface_count = instance.mesh.is_valid() ? mesh_storage->mesh_get_surface_count(instance.mesh) : 0;
			for (int surface = 0; surface < surface_count; surface++) {
				if (surface < 32 && (instance.surface_mask & (uint32_t(1) << surface)) == 0) {
					continue;
				}
				PreparedSurfaceKey key{ instance.mesh, instance.mesh_instance, uint32_t(surface) };
				PreparedSurface *resolved = prepared_surfaces.getptr(key);
				RID blas;
				if (resolved && resolved->update == preparation_update) {
					blas = resolved->blas;
					surface_reused++;
				} else {
					const uint64_t before = profile ? OS::get_singleton()->get_ticks_usec() : 0;
					const RaytracingGeometry::Surface *entry = geometry.get_surface(instance.mesh, instance.mesh_instance, surface);
					if (profile) {
						surface_usec += OS::get_singleton()->get_ticks_usec() - before;
					}
					surface_requests++;
					if (!entry) {
						continue;
					}
					blas = entry->blas;
					// Copy before any subsequent geometry lookup can move its storage.
					prepared_surfaces.insert(key, PreparedSurface{ blas, preparation_update });
				}
				// Preserve the original first-excess surface request and build budget.
				if (instance_count >= 65536) {
					break;
				}
				if (admitted == prepared.surfaces.size()) {
					prepared.surfaces.push_back(PreparedInstanceSurface());
				}
				PreparedInstanceSurface &record = prepared.surfaces[admitted++];
				if (same_transform && record.blas == blas) {
					hashes_reused++;
				} else {
					record.blas = blas;
					record.hash = _rt_instance_hash(blas, mask, instance.transform);
				}
				contents_hash += record.hash;
				instance_count++;
			}
			prepared.transform = instance.transform;
			prepared.mask = mask;
			prepared.surfaces.resize(admitted);
		}
		// Bound retained source metadata when scenes or mesh resources change.
		if ((preparation_update & 63) == 0) {
			LocalVector<PreparedSurfaceKey> stale;
			for (const KeyValue<PreparedSurfaceKey, PreparedSurface> &entry : prepared_surfaces) {
				if (preparation_update - entry.value.update > 64) {
					stale.push_back(entry.key);
				}
			}
			for (const PreparedSurfaceKey &key : stale) {
				prepared_surfaces.erase(key);
			}
		}
	}
	contents_hash += hash_murmur3_one_64(instance_count);
	const uint64_t prepared_at = profile ? OS::get_singleton()->get_ticks_usec() : 0;

	if (validate_reuse && !disable_reuse) {
		_pack_prepared_instances();
		LocalVector<RD::AccelerationStructureInstance> reference;
		_reconstruct_instances(p_instances, reference);
		bool matches = reference.size() == instance_scratch.size();
		uint32_t reference_hash = hash_murmur3_one_64(reference.size());
		for (uint32_t i = 0; matches && i < reference.size(); i++) {
			const RD::AccelerationStructureInstance &a = instance_scratch[i];
			const RD::AccelerationStructureInstance &b = reference[i];
			matches = a.transform == b.transform && a.id == b.id && a.mask == b.mask && a.flags == b.flags && a.hit_sbt_range == b.hit_sbt_range && a.blas == b.blas;
			reference_hash += _rt_instance_hash(b.blas, b.mask, b.transform);
		}
		ERR_FAIL_COND_MSG(!matches || contents_hash != reference_hash, "RT shadow preparation cache differs from full reconstruction.");
		static bool reported = false;
		if (!reported && (surface_reused > 0 || hashes_reused > 0)) {
			print_line("RT shadow reuse oracle: checked=true");
			reported = true;
		}
	}

	if (geometry.get_skipped_count() > 0 && !warned_about_skipped) {
		warned_about_skipped = true;
		WARN_PRINT(vformat("Raytraced shadows: %d mesh surface(s) cannot be raytraced and will not cast shadows (non-triangle geometry, 2D vertices, or empty vertex arrays). %d surface(s) built successfully.", geometry.get_skipped_count(), geometry.get_built_count()));
	}

	if (instance_count == 0) {
		prepared_instances.clear();
		prepared_surfaces.clear();
		return;
	}

	_ensure_tlas(instance_count);
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
	const bool rebuild = !tlas_built || geometry.has_changed() || contents_hash != tlas_contents_hash;
	const uint64_t packing_started = profile ? OS::get_singleton()->get_ticks_usec() : 0;
	if (rebuild && !disable_reuse && !validate_reuse) {
		_pack_prepared_instances();
	}
	if (profile) {
		print_line(vformat("RT_CPU shadow_prepare: records=%d prepare_usec=%d surface_usec=%d pack_usec=%d source_requests=%d source_reused=%d hashes_reused=%d rebuild=%d", instance_count, prepared_at - started, surface_usec, OS::get_singleton()->get_ticks_usec() - packing_started, surface_requests, surface_reused, hashes_reused, int(rebuild)));
	}

	if (rtdbg) {
		static String last;
		String cur = vformat("RT_DEBUG update: in_instances=%d tlas_instances=%d blas_cache=%d skipped_surfaces=%d deferred_surfaces=%d rebuilt=%d",
				(int)p_instances.size(), (int)instance_count, (int)geometry.get_cached_count(), (int)geometry.get_skipped_count(),
				(int)geometry.get_deferred_count(), int(rebuild));
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
