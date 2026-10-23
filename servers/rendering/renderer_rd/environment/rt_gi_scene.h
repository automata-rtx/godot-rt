/**************************************************************************/
/*  rt_gi_scene.h                                                         */
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
#include "servers/rendering/renderer_rd/environment/rt_geometry.h"
#include "servers/rendering/renderer_rd/environment/rt_material_capture.h"
#include "servers/rendering/renderer_scene_render.h"

namespace RendererRD {
// Shared hit-material and light adapter for the reference and cached GI paths.
class RaytracingGIScene {
public:
	struct LightData {
		float position[3];
		float range;
		float direction[3];
		uint32_t type;
		float color[3];
		float decay;
		float cos_angle;
		float spot_attenuation;
		uint32_t mask;
		uint32_t shadows;
		float shadow_opacity;
		uint32_t shadow_mask;
		uint32_t padding[2] = {};
	};
	const LocalVector<LightData> &get_lights() const { return previous_lights; }

private:
	// Tile layout must match atlas_position() in rt_gi_transport_inc.glsl.
	static constexpr uint32_t PAGE_TRIANGLES = 1024;
	static constexpr uint32_t TILE_SIZE = 8;
	static constexpr uint32_t PAGE_SIZE = 256;
	// Collection keeps one overflow entry beyond these limits to signal failure.
	static constexpr uint32_t MAX_LIGHTS = RendererSceneRender::MAX_RT_GI_LIGHTS;
	static constexpr uint32_t MAX_INSTANCES = RendererSceneRender::MAX_RT_GI_INSTANCES;
	struct HitData {
		uint32_t first_tile;
		uint32_t triangles;
		uint32_t mask;
		uint32_t shadow_mask = 0;
	};

	static_assert(sizeof(HitData) == 16);
	static_assert(sizeof(LightData) == 80);
	LocalVector<LightData> previous_lights;
	static bool light_history_compatible(const LightData &p_current, const LightData &p_previous);
	struct MaterialPage {
		RaytracingMaterialCapture *capture = nullptr;
		RID mesh;
		RID source_vertices;
		RID mesh_instance;
		uint64_t pose_revision = 0;
		uint64_t data_revision = 0;
		uint32_t surface = 0;
		uint32_t first_triangle = 0;
		uint32_t triangle_count = 0;
		uint32_t atlas_tile = UINT32_MAX;
		RID material;
		uint64_t material_revision = 0;
		Vector<Pair<RID, uint64_t>> texture_revisions;
		Transform3D transform;
		Color instance_color = Color(1, 1, 1, 1);
		Color instance_custom = Color(0, 0, 0, 0);
		bool pixels_valid = false;
	};
	struct MaterialKey {
		RID mesh;
		RID material;
		RID mesh_instance;
		RID context;
		uint32_t element = 0;
		uint32_t surface = 0;
		bool operator==(const MaterialKey &p_other) const {
			return mesh == p_other.mesh && material == p_other.material && mesh_instance == p_other.mesh_instance && context == p_other.context && element == p_other.element && surface == p_other.surface;
		}
	};
	struct MaterialKeyHasher {
		static uint32_t hash(const MaterialKey &p_key) {
			uint32_t h = hash_murmur3_one_64(p_key.mesh.get_id());
			h = hash_murmur3_one_64(p_key.material.get_id(), h);
			h = hash_murmur3_one_64(p_key.mesh_instance.get_id(), h);
			h = hash_murmur3_one_64(p_key.context.get_id(), h);
			h = hash_murmur3_one_32(p_key.element, h);
			return hash_fmix32(hash_murmur3_one_32(p_key.surface, h));
		}
	};
	struct SurfaceMaterial {
		LocalVector<MaterialPage> pages;
		uint32_t first_tile = 0;
		uint64_t last_used = 0;
	};
	HashMap<MaterialKey, SurfaceMaterial *, MaterialKeyHasher> material_cache;
	uint64_t material_frame = 0;
	void prune_materials(uint64_t p_minimum_frame);
	struct InstanceState {
		RID instance;
		uint32_t element = 0;
		Transform3D transform;
		AABB bounds;
		uint32_t pose_signature = HASH_MURMUR3_SEED;
	};
	LocalVector<InstanceState> previous_instances;
	LocalVector<AABB> motion_bounds;

	bool resize_atlas(uint32_t p_layers);
	bool ensure_scene_buffers(uint32_t p_instances, uint32_t p_lights);
	uint32_t atlas_layers = 0;
	uint32_t instance_capacity = 0;
	uint32_t light_capacity = 0;
	RID tlas;
	RID atlas[4];
	RID hit_buffer;
	RID light_buffer;
	uint32_t light_count = 0;
	uint32_t signature = 0;
	uint64_t revision = 1;
	bool ready = false;

public:
	static constexpr uint32_t MAX_MOTION_BOUNDS = 8;
	const LocalVector<AABB> &get_motion_bounds() const { return motion_bounds; }
	bool is_ready() const { return ready; }
	uint32_t get_light_count() const { return light_count; }
	uint64_t get_revision() const { return revision; }
	void append_uniforms(LocalVector<RD::Uniform> &r_uniforms, RID p_sampler) const;
	void update_scene(RaytracingGeometry &p_geometry, const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, const LocalVector<RID> &p_lights);
	RaytracingGIScene();
	~RaytracingGIScene();
};
} // namespace RendererRD
