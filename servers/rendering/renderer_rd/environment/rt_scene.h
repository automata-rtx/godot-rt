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
// shadows. This is a first-draft implementation: static geometry only, one BLAS
// per mesh surface shared by every instance of that mesh, and a full TLAS
// rebuild each frame.
//
// The TLAS is built from a caller-supplied instance list which is NOT frustum
// culled, so geometry behind the camera still casts shadows.
class RaytracingScene {
public:
	using InstanceData = RendererSceneRender::RaytracingInstance;

private:
	static RaytracingScene *singleton;

	// Project settings, resolved once at startup.
	static bool settings_registered;
	static bool setting_enabled;
	static int setting_samples;
	static float setting_max_distance;

	enum BlasState {
		BLAS_UNBUILT,
		BLAS_READY,
		BLAS_INELIGIBLE,
	};

	// A BLAS is keyed on (mesh RID, surface index) so that every instance of the
	// same mesh shares one acceleration structure.
	struct SurfaceKey {
		RID mesh;
		uint32_t surface = 0;

		bool operator==(const SurfaceKey &p_other) const {
			return mesh == p_other.mesh && surface == p_other.surface;
		}
	};

	struct SurfaceKeyHasher {
		static _FORCE_INLINE_ uint32_t hash(const SurfaceKey &p_key) {
			return hash_murmur3_one_32(p_key.surface, p_key.mesh.get_id());
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
	bool warned_about_support = false;
	uint32_t skipped_surface_count = 0;
	bool warned_about_skipped = false;

	uint64_t frame = 0;

	// Per-frame scratch, kept as members to avoid reallocating every frame.
	LocalVector<RD::AccelerationStructureInstance> instance_scratch;

	BlasEntry *_get_or_create_blas(RID p_mesh, uint32_t p_surface);
	bool _build_blas_geometry(RID p_mesh, uint32_t p_surface, BlasEntry &r_entry);
	void _dequantize_positions(RID p_source_buffer, RID p_dest_buffer, uint32_t p_vertex_count, uint32_t p_source_stride, const AABB &p_aabb);
	void _ensure_tlas(uint32_t p_instance_count);

public:
	static RaytracingScene *get_singleton() { return singleton; }

	// Registers the project settings. Safe to call more than once.
	static void register_settings();
	// True when the project setting is on. Does not imply hardware support.
	static bool is_enabled();
	static int get_sample_count();
	static float get_max_distance();

	// True when the setting is on AND the device can actually trace rays.
	bool is_available() const { return supported && is_enabled(); }

	// Rebuilds the acceleration structures for this frame. p_instances must not
	// be frustum culled.
	void update(const LocalVector<InstanceData> &p_instances);

	RID get_tlas() const { return tlas_valid ? tlas : RID(); }

	uint32_t get_blas_count() const { return blas_cache.size(); }

	void free_all();

	RaytracingScene();
	~RaytracingScene();
};

} //namespace RendererRD
