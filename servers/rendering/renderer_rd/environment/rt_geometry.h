/**************************************************************************/
/*  rt_geometry.h                                                         */
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
#include "core/templates/hash_map.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_dequantize.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Render-thread geometry storage, independent of visibility, materials, and lighting.
// Clients share BLASes but construct their own TLAS and instance metadata.
// Construction allocates no GPU resources; initialize() is explicitly opt-in.
class RaytracingGeometry {
public:
	struct Surface {
		RID blas;
		RID vertex_buffer; // float32x3 positions, including dequantization/skinning.
		RID index_buffer; // Null for non-indexed triangle lists.
		uint32_t vertex_count = 0;
		uint32_t index_count = 0; // Zero when the BLAS uses non-indexed geometry.
		uint32_t index_stride = 0; // 0 (non-indexed), 2, or 4 bytes.
		// Successful BLAS builds advance this even when the RID stays the same.
		uint64_t revision = 0;
	};

private:
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
		Surface surface;
		// Only allocated when the source positions are compressed and have to be
		// expanded into float32x3 for the acceleration structure build.
		RID position_buffer;
		uint64_t last_used_frame = 0;
		uint64_t last_shadow_frame = 0;
		bool used_by_gi = false;
		BlasState state = BLAS_UNBUILT;

		// Skinned surfaces are rebuilt whenever the skeleton pass has written a
		// new pose; skin_version tracks the value that was last built from.
		bool skinned = false;
		bool compressed = false;
		uint64_t skin_version = 0;
		uint32_t source_stride = 0;
		AABB source_aabb;
		RID source_buffer;
		uint64_t source_revision = 0;
	};

	HashMap<SurfaceKey, BlasEntry, SurfaceKeyHasher> blas_cache;

	// Dequantization of compressed vertex positions.
	struct DequantizePushConstant {
		float aabb_position[3];
		uint32_t vertex_count;
		float aabb_size[3];
		uint32_t source_stride_in_words;
	};
	// See the explanation above RTShadows' assertions in effects/rt_shadows.h.
	static_assert(sizeof(DequantizePushConstant) == 32, "DequantizePushConstant must match rt_dequantize.glsl");

	RtDequantizeShaderRD dequantize_shader;
	RID dequantize_shader_version;
	RID dequantize_pipeline;

	uint64_t frame = 0;
	uint64_t revision = 0;
	bool changed_this_update = false;
	uint32_t built_surface_count = 0;
	uint32_t skipped_surface_count = 0;
	uint32_t deferred_surface_count = 0;

	// Shared by every client in one update; requesting another surface does not
	// replenish the budget. Skinned refreshes preserve the existing shadow policy.
	static constexpr uint32_t MAX_BLAS_BUILDS_PER_FRAME = 64;
	static constexpr uint32_t MAX_BLAS_BUILD_TRIANGLES_PER_FRAME = 1 << 20;
	uint32_t blas_builds_remaining = 0;
	uint32_t blas_build_triangles_remaining = 0;

	BlasEntry *_get_or_create_blas(RID p_mesh, RID p_mesh_instance, uint32_t p_surface);
	bool _build_blas_geometry(RID p_mesh, RID p_mesh_instance, uint32_t p_surface, BlasEntry &r_entry);
	// What a surface would build from right now, so that a cached entry can tell
	// whether the buffers under it have been replaced.
	RID _get_surface_source_buffer(RID p_mesh, RID p_mesh_instance, uint32_t p_surface) const;
	void _release_blas(BlasEntry &r_entry);
	void _refresh_skinned_blas(BlasEntry &r_entry);
	void _evict_stale_blas();
	void _dequantize_positions(RID p_source_buffer, RID p_dest_buffer, uint32_t p_vertex_count, uint32_t p_source_stride, const AABB &p_aabb);

public:
	RaytracingGeometry() = default;
	RaytracingGeometry(const RaytracingGeometry &) = delete;
	RaytracingGeometry &operator=(const RaytracingGeometry &) = delete;

	void initialize();
	// The scene coordinator calls these once around all clients' surface requests.
	// begin_update() resets the shared build budget; end_update() evicts unused data.
	// They do not select instances or build a TLAS.
	void begin_update();
	void end_update();
	// A null result means deferred or unsupported geometry, never permission to use
	// an old snapshot. The pointer expires at the next cache mutation; copy Surface
	// before another request. GPU handles are borrowed and must never be freed by a
	// client. Request every surface again before using a retained TLAS: source mesh
	// destruction/replacement can invalidate the handles without a cache callback.
	const Surface *get_surface(RID p_mesh, RID p_mesh_instance, uint32_t p_surface, bool p_gi = false);
	void release_gi_only();
	bool has_changed() const { return changed_this_update; }
	uint32_t get_cached_count() const { return blas_cache.size(); }
	uint32_t get_built_count() const { return built_surface_count; }
	uint32_t get_skipped_count() const { return skipped_surface_count; }
	uint32_t get_deferred_count() const { return deferred_surface_count; }
	void clear();
	~RaytracingGeometry();
};

} // namespace RendererRD
