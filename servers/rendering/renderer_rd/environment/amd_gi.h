/**************************************************************************/
/*  amd_gi.h                                                              */
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

#include "servers/rendering/renderer_rd/environment/rt_gi_scene.h"
#include "servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

#define RB_SCOPE_AMD_GI SNAME("amd_gi")
#define RB_SCOPE_AMD_GI_GEOMETRY SNAME("amd_gi_geometry")

namespace RendererRD {

// Vulkan GI-1.x adaptation. Resource/history ownership is per viewport.
class AMDGI {
public:
	struct Environment {
		RID radiance;
		Basis world_to_sky;
		Color ambient = Color(0, 0, 0, 0);
		float diffuse_energy = 0;
		float reflection_energy = 0;
		float border = 0;
		uint64_t revision = 0;
		bool history_compatible(const Environment &p_previous) const;
	};

private:
	static constexpr uint32_t CACHE_TILES = 4096;
	static constexpr uint32_t CACHE_CELLS_PER_TILE = 85;
	static constexpr uint32_t CACHED_PROBES = 4096;
	enum Pass {
		RESET,
		REPROJECT,
		BIN_CACHED,
		SELECT,
		PATCH,
		PREPARE,
		TRACE,
		ALLOCATE,
		REGISTER,
		POPULATE,
		ALLOCATE_SECONDARY,
		REGISTER_SECONDARY,
		SHADE_HITS,
		UPDATE,
		MIP1,
		MIP2,
		MIP3,
		SHADE_INDIRECT_HITS,
		UPDATE_INDIRECT,
		INDIRECT_MIP1,
		INDIRECT_MIP2,
		INDIRECT_MIP3,
		RESOLVE,
		FILTER_X,
		FILTER_Y,
		PROJECT,
		ORDER_CACHED,
		STORE_CACHED,
		MASK,
		INTERPOLATE,
		TEMPORAL,
		BLUR_X,
		BLUR_Y,
		REFLECTION_CLASSIFY,
		REFLECTION_BUILD_DISPATCH,
		REFLECTION_TRACE,
		REFLECTION_MARK_FIREFLIES,
		REFLECTION_CLEAN_FIREFLIES,
		REFLECTION_RESOLVE,
		REFLECTION_TEMPORAL,
		REFLECTION_FILTER,
		REFLECTION_UPSAMPLE,
		PASS_COUNT
	};
	struct PushConstant {
		float inv_view_projection[16];
		float camera_rotation[4];
		float camera_position[4];
		uint32_t size[2];
		uint32_t samples = 0;
		uint32_t multibounce;
		float max_distance;
		uint32_t light_count;
		float exposure;
		uint32_t frame;
	};
	struct FrameUniform {
		float previous_view_projection[16];
		float view_projection[16];
		uint32_t grid[4]; // stored probe columns/rows, update stride, history reset
		float settings[4]; // minimum cache cell, angular pixel footprint, continuation probability, previous feedback exposure
		uint32_t flags[4]; // denoiser, importance sampling, mask mip count, cached probe reuse
		uint32_t tracing[4]; // update columns/rows, adaptive scheduling, light resampling
		float world_to_sky[12];
		float sky[4]; // diffuse and reflection energy, octahedral border, bit 0 firefly cleanup / bit 1 BRDF guiding
		float ambient[4]; // remaining ambient color, replace native ambient
		float reflections[4]; // sample stride, probe roughness threshold, filter iterations, unused
		uint32_t motion[4]; // swept bound count, all-hit updates, lighting change, previous light count
		uint32_t emitters[4]; // emitter count/capacity, appended glossy queue offset, compact glossy dispatch
		float motion_bounds[RaytracingGIScene::MAX_MOTION_BOUNDS][8]; // min/max, std140 vec4 pairs
	};
	static_assert(sizeof(PushConstant) == 128);
	static_assert(sizeof(FrameUniform) == 576);
	struct ViewData : public RenderBufferCustomDataRD {
		GDCLASS(ViewData, RenderBufferCustomDataRD);

	public:
		RID frame_uniform;
		RID probes[2];
		RID radiance[2];
		RID pixels[2];
		RID rays, keys, cache[2], owners, scratch;
		RID spawn, queues, probe_mask;
		RID cached_probes, cached_state, cached_order[2];
		RID light_reservoirs[2];
		RID light_tree;
		uint32_t previous_light_count = 0;
		LocalVector<uint64_t> light_identities;
		void update_light_remap(const RaytracingGIScene &p_scene);
		uint32_t light_tree_capacity = 0;
		LocalVector<RaytracingGIScene::LightData> sampling_lights;
		bool update_light_tree(const RaytracingGIScene &p_scene);
		RID indirect_cache[2], secondary_rays;
		RID hit_samples;
		RID reflection_samples, reflection_history[2];
		uint32_t reflection_stride = 0;
		float reflection_roughness = 0;
		uint32_t reflection_filter_passes = 0;
		Size2i size;
		uint32_t stride = 0;
		uint32_t frame = 0;
		uint32_t index = 0;
		uint64_t scene_revision = 0;
		uint64_t lighting_revision = 0;
		uint32_t lighting_reactive_frames = 0;
		uint32_t configuration = 0;
		float cell_size = 0;
		float continuation = 0;
		float max_distance = 0;
		bool valid = false;
		bool probe_cache = false;
		bool light_resampling = false;
		bool multibounce = false;
		bool screen_feedback = false;
		bool cache_all_hits = false;
		float previous_exposure = 0;
		Projection previous_view_projection;
		Transform3D previous_camera;
		Environment environment;
		void configure(RenderSceneBuffersRD *p_buffers) override { free_data(); }
		void free_data() override;
		~ViewData() { free_data(); }
	};
	AmdGiShaderRD shader;
	RID version;
	RID blue_noise;
	RID pipelines[PASS_COUNT];

public:
	static bool is_enabled();
	static bool is_supported();
	static void clear(const Ref<RenderSceneBuffersRD> &p_buffers);
	bool render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment);
	AMDGI();
	~AMDGI();
};
} // namespace RendererRD
