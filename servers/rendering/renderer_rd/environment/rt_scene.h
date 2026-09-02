/**************************************************************************/
/*  rt_scene.h                                                            */
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

#pragma once

#include "core/math/aabb.h"
#include "core/math/transform_3d.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_dequantize.glsl.gen.h"
#include "servers/rendering/renderer_scene_render.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Manages the hardware acceleration structures (BLAS/TLAS) used by raytraced
// shadows. Static geometry shares one BLAS per mesh surface across every
// instance of that mesh; skinned geometry gets one per skinned vertex buffer
// and is rebuilt whenever the skeleton pass has moved it. The TLAS is rebuilt
// only when the set of instances, their transforms or their structures have
// changed, and new structures are built under a per-frame budget.
//
// The TLAS is built from a caller-supplied instance list which is NOT frustum
// culled, so geometry behind the camera still casts shadows.
class RaytracingScene {
public:
	using InstanceData = RendererSceneRender::RaytracingInstance;

private:
	static RaytracingScene *singleton;

	// The master `enabled` flag is latched at first read and never re-read: a
	// mesh uploaded while it was off has no buffers an acceleration structure
	// could be built from. `directional/enabled` is live, but it is refreshed
	// once per frame rather than read wherever it is wanted, so that a frame sees
	// one answer for it, as do the two demotion values copied just below. Every
	// other setting is read live through GLOBAL_GET_CACHED in its accessor below.
	// See register_settings().
	static bool settings_registered;
	static bool setting_enabled;
	static bool setting_directional_enabled;
	// This frame's copies of the settings a frame has to see one value of.
	static int frame_demoted_mode;
	static int frame_demoted_size;

	enum BlasState {
		BLAS_UNBUILT,
		BLAS_READY,
		BLAS_INELIGIBLE,
	};

	// Static geometry is keyed on (mesh RID, surface index) so every instance of
	// the same mesh shares one acceleration structure.
	//
	// Skinned geometry cannot share: its vertices are deformed per instance. It
	// is keyed on the skinned vertex buffer instead, which is already unique per
	// (instance, surface). The skeleton pass double buffers that target when
	// motion vectors are enabled, so keying on the buffer gives each of the two
	// its own structure and they are rebuilt in place rather than recreated
	// every time the pair alternates.
	struct SurfaceKey {
		RID source;
		uint32_t surface = 0;

		bool operator==(const SurfaceKey &p_other) const {
			return source == p_other.source && surface == p_other.surface;
		}
	};

	struct SurfaceKeyHasher {
		static _FORCE_INLINE_ uint32_t hash(const SurfaceKey &p_key) {
			return hash_murmur3_one_32(p_key.surface, p_key.source.get_id());
		}
	};

	struct BlasEntry {
		RID blas;
		// Only allocated when the source positions are compressed and have to be
		// expanded into float32x3 for the acceleration structure build.
		RID position_buffer;
		uint32_t vertex_count = 0;
		uint32_t index_count = 0;
		uint64_t last_used_frame = 0;
		BlasState state = BLAS_UNBUILT;

		// Skinned surfaces are rebuilt whenever the skeleton pass has written a
		// new pose; skin_version tracks the value that was last built from.
		bool skinned = false;
		bool compressed = false;
		uint64_t skin_version = 0;
		uint32_t source_stride = 0;
		AABB source_aabb;
		RID source_buffer;
	};

	HashMap<SurfaceKey, BlasEntry, SurfaceKeyHasher> blas_cache;

	RID tlas;
	uint32_t tlas_capacity = 0;
	bool tlas_valid = false;

	// Dequantization of compressed vertex positions.
	struct DequantizePushConstant {
		float aabb_position[3];
		uint32_t vertex_count;
		float aabb_size[3];
		uint32_t source_stride_in_words;
	};

	RtDequantizeShaderRD dequantize_shader;
	RID dequantize_shader_version;
	RID dequantize_pipeline;

	bool supported = false;
	uint32_t skipped_surface_count = 0;
	uint32_t built_surface_count = 0;
	bool warned_about_skipped = false;

	uint64_t frame = 0;

	// Per-frame scratch, kept as members to avoid reallocating every frame.
	LocalVector<RD::AccelerationStructureInstance> instance_scratch;

	// Building an acceleration structure allocates GPU memory and scratch space
	// and then does real work on the device. A level streaming in, or a camera
	// cut into a lit interior, can bring hundreds of new surfaces into range in
	// one frame; without a ceiling that is a visible stall. Surfaces past the
	// budget do not cast this frame and are picked up by the next, which shows
	// as a shadow arriving a frame or two late instead.
	static constexpr uint32_t MAX_BLAS_BUILDS_PER_FRAME = 64;
	static constexpr uint32_t MAX_BLAS_BUILD_TRIANGLES_PER_FRAME = 1 << 20;

	// The top level structure only has to be rebuilt when what it describes
	// changes. A frame where nothing moved and nothing was built rebuilds it for
	// the same answer, and that is a device buffer upload plus a real build.
	uint32_t tlas_contents_hash = 0;
	// Whether the structure currently holds a successful build, which outlives a
	// frame; tlas_valid says only whether this frame may trace against it.
	bool tlas_built = false;
	bool blas_changed_this_frame = false;

	uint32_t blas_builds_remaining = 0;
	uint32_t blas_build_triangles_remaining = 0;
	uint32_t deferred_surface_count = 0;

	BlasEntry *_get_or_create_blas(RID p_mesh, RID p_mesh_instance, uint32_t p_surface);
	bool _build_blas_geometry(RID p_mesh, RID p_mesh_instance, uint32_t p_surface, BlasEntry &r_entry);
	// What a surface would build from right now, so that a cached entry can tell
	// whether the buffers under it have been replaced.
	RID _get_surface_source_buffer(RID p_mesh, RID p_mesh_instance, uint32_t p_surface) const;
	void _release_blas(BlasEntry &r_entry);
	void _refresh_skinned_blas(BlasEntry &r_entry);
	void _evict_stale_blas();
	void _dequantize_positions(RID p_source_buffer, RID p_dest_buffer, uint32_t p_vertex_count, uint32_t p_source_stride, const AABB &p_aabb);
	void _ensure_tlas(uint32_t p_instance_count);

public:
	static RaytracingScene *get_singleton() { return singleton; }

	// Registers the project settings. Safe to call more than once.
	static void register_settings();
	// True when the directional setting is on. Like is_enabled() it does not imply
	// hardware support or a structure to trace against. This is the frame's
	// snapshot of the setting, taken by update_frame_settings(), not a live read.
	static bool is_directional_enabled();
	// Takes this frame's copy of the settings that have to stay fixed across it.
	static void update_frame_settings();
	// 0 keeps whatever the light was authored with, 1 Orthogonal, 2 two splits.
	static int get_directional_demoted_mode();
	// Zero keeps the project's own directional shadow atlas size.
	static int get_directional_demoted_size();
	// How far the camera's shadow-distance volume is swept towards a directional
	// light when gathering casters, as a multiple of that shadow distance. A sun
	// has no range to cull against, so this is what bounds its acceleration
	// structure.
	static float get_directional_caster_scale();
	// Disabled / Near Camera / Full Distance. A MultiMesh contributes one entry
	// per element, so a scattered field can flood the structure under a light
	// that reaches the whole level.
	enum DirectionalScatterMode {
		DIRECTIONAL_SCATTER_DISABLED,
		DIRECTIONAL_SCATTER_NEAR_CAMERA,
		DIRECTIONAL_SCATTER_FULL_DISTANCE,
	};
	static DirectionalScatterMode get_directional_scatter_mode();
	static float get_directional_scatter_distance();

	// True when GODOT_RT_DEBUG is set in the environment. Cached on first use.
	static bool debug_enabled();
	// True when the project setting is on. Does not imply hardware support.
	static bool is_enabled();
	static int get_sample_count();
	static float get_max_distance();
	static bool is_denoiser_enabled();
	static int get_denoiser_iterations();
	static float get_denoiser_max_history();
	static float get_denoiser_min_filter_pixels();
	static float get_denoiser_history_clamp_sigma();
	static bool is_accurate_occluder_distance();

	// True when the setting is on AND the device can actually trace rays.
	bool is_available() const { return supported && is_enabled(); }

	// Rebuilds the acceleration structures for this frame. p_instances must not
	// be frustum culled.
	void update(const LocalVector<InstanceData> &p_instances);

	RID get_tlas() const { return tlas_valid ? tlas : RID(); }

	// True only when there is a built acceleration structure to trace against
	// this frame. Lights must not claim a mask slot otherwise: the forward
	// shader skips the shadow atlas for any light that holds one, so a slot
	// without a structure behind it means the light casts no shadow at all.
	bool has_traceable_scene() const { return supported && tlas_valid; }

	uint32_t get_blas_count() const { return blas_cache.size(); }

	void free_all();

	RaytracingScene();
	~RaytracingScene();
};

} //namespace RendererRD
