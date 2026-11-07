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
#define RB_SCOPE_AMD_GI_BATCH SNAME("amd_gi_batch")
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
	struct RegionInput {
		Ref<RenderSceneBuffersRD> buffers;
		RID normals;
		Projection projection;
		Rect2 parent_uv_rect = Rect2(0, 0, 1, 1);
		uint64_t history_generation = 0;
		bool reset_history = false;
	};
	struct LogicalView {
		Size2i output_size;
		Projection projection;
		Transform3D camera;
		float exposure = 1.0f;
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
		BATCH_JOIN,
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
		uint32_t options[4]; // sky sampling, reflections enabled, improvement flags, reset previous light reservoirs
		uint32_t reflection_options[4]; // denoiser, split radius, mark radius, cleanup radius
		uint32_t debug_options[4]; // view, mip, counter flags, age scale
		float debug_settings[4]; // exposure, sample scale, atlas page, reserved
		float tuning[4]; // cache history limit, diffuse history scale, distant cell scale, reserved
	};
	static_assert(sizeof(PushConstant) == 128);
	static_assert(sizeof(FrameUniform) == 544);
	struct BatchUniform {
		uint32_t info[4]; // primary capacity, region, active regions, world reset
		float parent_rect[4];
		float angular[4]; // parent pixel footprint, output width/height, reserved
		float parent_view_projection[16];
		float parent_inverse_view_projection[16];
		float previous_parent_view_projection[16];
		float previous_parent_eye[4];
		float previous_parent_forward[4];
		float feedback_rect[2][4];
		float feedback_previous_rect[2][4];
		uint32_t feedback_size[2][4]; // width, height, valid previous frame, reserved
		float feedback_exposure[4];
	};
	static_assert(sizeof(BatchUniform) == 384);
	struct BindingReuse {
		LocalVector<RD::Uniform> uniforms;
		// Borrowed from UniformSetCacheRD; never free these handles ourselves.
		RID sets[PASS_COUNT];
		void clear();
		void update(const LocalVector<RD::Uniform> &p_uniforms);
		RID get_uniform_set(uint32_t p_pass, RID p_shader, uint32_t p_set, const LocalVector<RD::Uniform> &p_uniforms, bool p_validate);
	};
	// World-space transport belongs to the logical camera, not to a screen region.
	// Screen histories may release their reference without evicting another
	// region's cache. Scheduling still has to serialize one complete cache frame.
	struct WorldData : public RefCounted {
		GDCLASS(WorldData, RefCounted);

	public:
		RID keys, cache[2], owners, indirect_cache[2], direct_updates;
		RID light_reservoirs[2];
		RID light_grid;
		uint32_t light_grid_bytes = 0;
		uint32_t previous_analytic_count = 0;
		uint32_t previous_emitter_count = 0;
		uint32_t previous_environment_count = 0;
		struct AnalyticLightKey {
			uint64_t id;
			uint32_t type;
		};
		LocalVector<AnalyticLightKey> previous_analytic_order;
		bool previously_lit_by_analytic_light = false;
		enum class LightHistoryAction { KEEP,
			RESET_RESERVOIRS,
			RESET_VIEW };
		LightHistoryAction update_light_order(const RaytracingGIScene &p_scene, uint32_t p_environment_count, bool p_retain_on_emitter_transitions, bool p_light_resampling);
		bool ensure_light_grid(uint32_t p_emitters, uint32_t p_lights);
		RID environment_cube;
		RID environment_source;
		Vector<RID> environment_mips;
		uint64_t environment_revision = 0;
		float environment_border = 0;
		~WorldData();
	};
	struct ViewData : public RenderBufferCustomDataRD {
		GDCLASS(ViewData, RenderBufferCustomDataRD);

	public:
		Ref<WorldData> world;
		RID binding_version;
		BindingReuse bindings[4]; // Native uses2; batch screen and world ping-pongs are independent.
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
		RID rays, scratch;
		RID spawn, queues, probe_mask, work;
		RID cached_probes, cached_state, cached_order[2];
		RID secondary_rays;
		RID hit_samples, source_validation;
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
		uint32_t improvements = 0;
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
		Rect2 previous_parent_rect = Rect2(0, 0, 1, 1);
		uint64_t history_generation = 0;
		uint32_t last_batch_frame = UINT32_MAX;
		bool batch_screen = false;
		void configure(RenderSceneBuffersRD *p_buffers) override { free_data(); }
		void free_data() override;
		~ViewData() { free_data(); }
	};
	struct BatchData : public RenderBufferCustomDataRD {
		GDCLASS(BatchData, RenderBufferCustomDataRD);

	public:
		Ref<WorldData> world;
		RID rays, secondary_rays, hit_samples, work, origins;
		uint32_t capacity = 0;
		uint32_t cache_buckets = 0;
		uint32_t allocation_improvements = 0;
		bool reservoirs_valid = false;
		RID prepared_version;
		uint64_t prepared_layout = 0;
		uint32_t frame = 0;
		int64_t last_completed_frame = -1;
		uint32_t reservoir_index = 0;
		bool valid = false;
		bool multibounce = false;
		bool cache_all_hits = false;
		bool light_resampling = false;
		uint32_t world_configuration = 0;
		uint32_t world_improvements = 0;
		float cell_size = 0;
		float distant_cell_scale = 0;
		float continuation = 0;
		float max_distance = 0;
		Projection previous_view_projection;
		Transform3D previous_camera;
		void configure(RenderSceneBuffersRD *p_buffers) override { free_data(); }
		void free_data() override;
		~BatchData() { free_data(); }
	};
	const bool regional_batch = false;
	AmdGiShaderRD shader;
	AmdGiEnvironmentShaderRD environment_shader;
	RID environment_version;
	RID environment_pipelines[2];
	RID prepare_environment(WorldData &p_data, const Environment &p_environment);
	RID version;
	String published_source;
	// Render thread owns the version, its shader RIDs and all cleanup. The
	// worker only creates pipelines from pinned shaders. It never reads a scene.
	struct MaterialBuild {
		RID version;
		String source;
		const RaytracingGIScene *scene = nullptr; // Render-thread identity only.
		uint64_t revision = 0;
		uint64_t start_usec = 0;
		RID shaders[PASS_COUNT];
		RID pipelines[PASS_COUNT];
		Thread worker;
		SafeFlag cancel;
		SafeFlag finished;
		bool inject_failure = false;
		bool bytecode_cache_hit = false;
		uint32_t failed_pass = PASS_COUNT;
		SafeNumeric<uint32_t> completed_passes;
		SafeNumeric<uint32_t> next_pass;
		SafeFlag failed;
		uint32_t pass_order[PASS_COUNT] = {};
		uint32_t pass_count = 0;
		uint32_t worker_count = 1;
	};
	MaterialBuild *pending = nullptr;
	static void build_material_pipelines(void *p_data);
	static void build_material_passes(void *p_data);
	bool poll_material_build();
	void start_material_build(const RaytracingGIScene *p_scene, uint64_t p_revision, const String &p_source);
	void free_material_build();
	AMDGIPipelinePreparationState material_preparation;
	bool material_failure_injected = false;
	bool preparation_hold = false;
	bool preparation_failed = false;
	bool preparation_cache_hit = false;
	void update_material_pipelines(const RaytracingGIScene *p_scene);
	RID blue_noise;
	uint32_t random_seed_count = 0;
	void ensure_sampling_data(const Size2i &p_size);
	RID pipelines[PASS_COUNT];
	struct RenderContext;
	bool prepare_render_context(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment, RenderContext &r_context, const Ref<BatchData> &p_batch = Ref<BatchData>(), const RD::BufferReadGroup *p_shared_source_reads = nullptr);
	void configure_batch_contexts(RenderContext *p_contexts, const RegionInput *p_regions, uint32_t p_count, const LogicalView &p_parent, const Ref<BatchData> &p_batch, bool p_reset_world, bool p_reset_reservoirs);
	bool dispatch_render_passes(RenderContext &r_context, uint32_t p_first_pass, uint32_t p_end_pass, bool p_debug_passes);
	bool finish_render_context(RenderContext &r_context);
	RID get_render_uniform_set(RenderContext &r_context, uint32_t p_pass, RID p_shader, uint32_t p_set);
	Error add_render_source_reads(RenderContext &r_context, RD::ComputeListID p_list);

public:
	static Dictionary get_diagnostics(const Ref<RenderSceneBuffersRD> &p_buffers);
	static int64_t get_batch_completed_frame(const Ref<RenderSceneBuffersRD> &p_owner) {
		if (p_owner.is_null() || !p_owner->has_custom_data(RB_SCOPE_AMD_GI_BATCH)) {
			return -1;
		}
		const Ref<BatchData> data = p_owner->get_custom_data(RB_SCOPE_AMD_GI_BATCH);
		return data.is_valid() ? data->last_completed_frame : -1;
	}
	static bool is_enabled();
	static bool is_supported();
	static bool is_regional_supported();
	static uint32_t get_region_guard_pixels();
	static void clear(const Ref<RenderSceneBuffersRD> &p_buffers);
	bool has_material_pipelines(const RaytracingGIScene &p_scene) const;
	void prepare_scene_material_pipelines(const RaytracingGIScene &p_scene, bool p_hold);
	Dictionary get_preparation_status(const RaytracingGIScene &p_scene) const;
	bool suspend_material_pipelines();
	void prepare_feedback_lights(const Ref<RenderSceneBuffersRD> &p_buffers, const PagedArray<RID> &p_lights);
	RID get_feedback_lights(const Ref<RenderSceneBuffersRD> &p_buffers) const;
	bool render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment);
	bool prepare_regions(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_owner, const RegionInput &p_uniform, const RegionInput *p_scoped, uint32_t p_scoped_count, const LogicalView &p_parent, const Environment &p_environment);
	bool render_regions(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_owner, const RegionInput *p_regions, uint32_t p_count, const LogicalView &p_parent, const Environment &p_environment);
	explicit AMDGI(bool p_regional_batch = false);
	~AMDGI();
};
} // namespace RendererRD
