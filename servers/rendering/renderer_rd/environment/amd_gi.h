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

#include "servers/rendering/renderer_rd/environment/amd_gi_pipeline_preparation.h"
#include "servers/rendering/renderer_rd/environment/rt_gi_scene.h"
#include "servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/effects/amd_gi_environment.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"

#define RB_SCOPE_AMD_GI SNAME("amd_gi")
#define RB_SCOPE_AMD_GI_GEOMETRY SNAME("amd_gi_geometry")

namespace RendererRD {

// Vulkan GI-1.x adaptation. Resource/history ownership is per viewport.
class AMDGI {
public:
	struct Environment {
		RID radiance;
		RID auto_exposure;
		float temporal_exposure_scale = 1.0f;
		Basis world_to_sky;
		Color ambient = Color(0, 0, 0, 0);
		float diffuse_energy = 0;
		float reflection_energy = 0;
		float border = 0;
		uint64_t revision = 0;
	};

private:
	static constexpr uint32_t CACHE_CELLS_PER_TILE = 85;
	enum Pass {
		RESERVOIR_RESET,
		RESET,
		PURGE,
		REPROJECT,
		BIN_CACHED,
		SELECT,
		PATCH,
		COMPACT_PROBES,
		GATHER_PROBES,
		PREPARE,
		TRACE,
		ALLOCATE,
		REGISTER,
		POPULATE,
		ALLOCATE_SECONDARY,
		REGISTER_SECONDARY,
		LIGHT_GRID_DISPATCH,
		LIGHT_GRID,
		SHADE_HITS,
		UPDATE,
		RESERVOIR_SCAN,
		RESERVOIR_SCAN_BLOCKS,
		RESERVOIR_SCAN_TOP,
		RESERVOIR_COMPACT,
		MIP1,
		MIP2,
		MIP3,
		UPDATE_INDIRECT,
		INDIRECT_MIP1,
		INDIRECT_MIP2,
		INDIRECT_MIP3,
		SHADE_INDIRECT_HITS,
		RESOLVE,
		STORE_CACHED,
		ORDER_CACHED,
		MASK,
		FILTER_X,
		FILTER_Y,
		PROJECT,
		NEAR_FIELD,
		INTERPOLATE,
		TEMPORAL,
		BLUR_X,
		BLUR_Y,
		REFLECTION_CLASSIFY,
		REFLECTION_BUILD_DISPATCH,
		REFLECTION_TRACE,
		REFLECTION_MARK_FIREFLIES,
		REFLECTION_CLEAN_FIREFLIES,
		REFLECTION_FIRST,
		REFLECTION_ITER,
		REFLECTION_LAST,
		REFLECTION_TEMPORAL,
		REFLECTION_OUTPUT,
		VALIDATE_SOURCE,
		PREPARE_LIGHTS,
		PREPARE_LIGHT_MASKS,
		DEBUG_VIEW,
		DEBUG_STATS,
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
		float previous_inverse_view_projection[16];
		float previous_eye[4];
		float previous_forward[4];
		float view_projection[16];
		uint32_t grid[4]; // stored probe columns/rows, update stride, history reset
		float settings[4]; // minimum cache cell, angular pixel footprint, continuation probability, previous feedback exposure
		uint32_t flags[4]; // denoiser, importance sampling, mask mip count, cached probe reuse
		uint32_t tracing[4]; // update columns/rows, adaptive scheduling, light resampling
		float world_to_sky[12];
		float sky[4]; // diffuse and reflection energy, octahedral border, bit 0 firefly cleanup / bit 1 BRDF guiding
		float ambient[4]; // remaining ambient color, replace native ambient
		float reflections[4]; // sample stride, probe roughness threshold, filter iterations, unused
		uint32_t cache_config[4]; // bucket count, tiles/bucket, reserved
		float near_field[4]; // projected radius, native projection axis signs, auto exposure enabled
		float glossy[4]; // low roughness threshold, firefly low/high thresholds, exposure scale
		uint32_t motion[4]; // swept bound count, all-hit updates, diffuse feedback, reserved
		uint32_t emitters[4]; // emitter count, physical uvec4 offset, appended glossy queue offset, compact glossy dispatch
		uint32_t options[4]; // sky sampling, reserved
		uint32_t reflection_options[4]; // denoiser, split radius, mark radius, cleanup radius
		uint32_t debug_options[4]; // view, mip, counter flags, age scale
		float debug_settings[4]; // exposure, sample scale, atlas page, reserved
		float tuning[4]; // cache history limit, diffuse history scale, distant cell scale, reserved
	};
	static_assert(sizeof(PushConstant) == 128);
	static_assert(sizeof(FrameUniform) == 544);
	struct BindingReuse {
		LocalVector<RD::Uniform> uniforms;
		// Borrowed from UniformSetCacheRD; never free these handles ourselves.
		RID sets[PASS_COUNT];
		void clear();
		void update(const LocalVector<RD::Uniform> &p_uniforms);
		RID get_uniform_set(uint32_t p_pass, RID p_shader, uint32_t p_set, const LocalVector<RD::Uniform> &p_uniforms, bool p_validate);
	};
	struct ViewData : public RenderBufferCustomDataRD {
		GDCLASS(ViewData, RenderBufferCustomDataRD);

	public:
		RID binding_version;
		BindingReuse bindings[2]; // Set 0 swaps history resources each frame.
		BindingReuse material_bindings;
		RID frame_uniform;
		RID debug_stats;
		uint32_t debug_stats_bytes = 0;
		Dictionary diagnostics;
		uint32_t reflection_mode = 1;
		uint32_t reflection_radii = 0;
		RID feedback_lights;
		uint32_t feedback_light_bytes = 0;
		RID probes[2];
		RID radiance[2];
		RID pixels[2];
		RID rays, keys, cache[2], owners, scratch;
		RID spawn, queues, probe_mask, work;
		RID cached_probes, cached_state, cached_order[2];
		RID light_reservoirs[2];
		RID light_grid;
		uint32_t light_grid_bytes = 0;
		uint32_t previous_analytic_count = 0;
		uint32_t previous_emitter_count = 0;
		uint32_t previous_environment_count = 0;
		bool update_light_order(const RaytracingGIScene &p_scene, uint32_t p_environment_count);
		bool ensure_light_grid(uint32_t p_emitters, uint32_t p_lights);
		RID indirect_cache[2], secondary_rays;
		RID hit_samples, direct_updates, source_validation;
		RID reflection_samples, reflection_history[2];
		uint32_t reflection_stride = 0;
		float reflection_roughness = 0;
		float reflection_trace_roughness = 0;
		float firefly_low = 0;
		float firefly_high = 1;
		uint32_t reflection_filter_passes = 0;
		Size2i size;
		uint32_t stride = 0;
		uint32_t frame = 0;
		uint32_t index = 0;
		uint32_t configuration = 0;
		uint32_t cache_buckets = 0;
		float cell_size = 0;
		float distant_cell_scale = 1.0f;
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
		RID environment_cube;
		RID environment_source;
		Vector<RID> environment_mips;
		uint64_t environment_revision = 0;
		float environment_border = 0;
		void configure(RenderSceneBuffersRD *p_buffers) override { free_data(); }
		void free_data() override;
		~ViewData() { free_data(); }
	};
	AmdGiShaderRD shader;
	AmdGiEnvironmentShaderRD environment_shader;
	RID environment_version;
	RID environment_pipelines[2];
	RID prepare_environment(ViewData &p_data, const Environment &p_environment);
	RID version;
	AMDGIPipelinePreparationState material_preparation;
	bool material_failure_injected = false;
	bool prepare_material_pipelines(const RaytracingGIScene &p_scene);
	RID blue_noise;
	uint32_t random_seed_count = 0;
	void ensure_sampling_data(const Size2i &p_size);
	RID pipelines[PASS_COUNT];

public:
	static Dictionary get_diagnostics(const Ref<RenderSceneBuffersRD> &p_buffers);
	static bool is_enabled();
	static bool is_supported();
	static void clear(const Ref<RenderSceneBuffersRD> &p_buffers);
	bool has_material_pipelines(const RaytracingGIScene &p_scene) const;
	void prepare_feedback_lights(const Ref<RenderSceneBuffersRD> &p_buffers, const PagedArray<RID> &p_lights);
	RID get_feedback_lights(const Ref<RenderSceneBuffersRD> &p_buffers) const;
	bool render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment);
	AMDGI();
	~AMDGI();
};
} // namespace RendererRD
