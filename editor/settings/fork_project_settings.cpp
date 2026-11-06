/**************************************************************************/
/*  fork_project_settings.cpp                                             */
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

#include "fork_project_settings.h"

#include "core/templates/hash_set.h"

bool ForkProjectSettings::is_advanced(const String &p_name) {
	// Editor presentation only. Keep canonical keys for scripts, saved projects,
	// feature overrides, documentation tooltips, revert and undo/redo.
	// Explicit membership also leaves unrelated/custom settings in General.
	static const HashSet<String> settings = {
		"rendering/anti_aliasing/quality/dlss_preset",
		"rendering/environment/ssao/ground_truth/intensity_scale",
		"rendering/environment/ssao/ground_truth/scale_radius_with_distance",
		"rendering/environment/ssao/ground_truth/screen_radius",
		"rendering/environment/ssao/ground_truth/slices",
		"rendering/environment/ssao/ground_truth/steps_per_slice",
		"rendering/environment/ssao/ground_truth/thickness",
		"rendering/environment/ssao/ground_truth/visibility_bitmask",
		"rendering/global_illumination/amd_gi/adaptive_sampling",
		"rendering/global_illumination/amd_gi/brdf_sampling",
		"rendering/global_illumination/amd_gi/cache_all_hits",
		"rendering/global_illumination/amd_gi/cache_bucket_exponent",
		"rendering/global_illumination/amd_gi/continuation_probability",
		"rendering/global_illumination/amd_gi/debug/atlas_page",
		"rendering/global_illumination/amd_gi/debug/exclusion_reports",
		"rendering/global_illumination/amd_gi/debug/exposure",
		"rendering/global_illumination/amd_gi/debug/indirect_cache",
		"rendering/global_illumination/amd_gi/debug/max_age",
		"rendering/global_illumination/amd_gi/debug/mip",
		"rendering/global_illumination/amd_gi/debug/readback_interval",
		"rendering/global_illumination/amd_gi/debug/sample_scale",
		"rendering/global_illumination/amd_gi/debug/statistics",
		"rendering/global_illumination/amd_gi/debug/view",
		"rendering/global_illumination/amd_gi/denoiser",
		"rendering/global_illumination/amd_gi/emissive_sampling",
		"rendering/global_illumination/amd_gi/importance_sampling",
		"rendering/global_illumination/amd_gi/improvements/cache_transitions",
		"rendering/global_illumination/amd_gi/improvements/demand_scheduling",
		"rendering/global_illumination/amd_gi/improvements/responsive_history",
		"rendering/global_illumination/amd_gi/improvements/retain_history_on_emitter_transitions",
		"rendering/global_illumination/amd_gi/light_resampling",
		"rendering/global_illumination/amd_gi/material_adaptive_resolution",
		"rendering/global_illumination/amd_gi/material_atlas_mb",
		"rendering/global_illumination/amd_gi/material_preparation_budget",
		"rendering/global_illumination/amd_gi/material_tile_size",
		"rendering/global_illumination/amd_gi/max_distance",
		"rendering/global_illumination/amd_gi/minimum_cell_size",
		"rendering/global_illumination/amd_gi/probe_cache",
		"rendering/global_illumination/amd_gi/reflections/denoiser",
		"rendering/global_illumination/amd_gi/reflections/filter_passes",
		"rendering/global_illumination/amd_gi/reflections/firefly_cleanup_radius_full",
		"rendering/global_illumination/amd_gi/reflections/firefly_cleanup_radius_half",
		"rendering/global_illumination/amd_gi/reflections/firefly_filter",
		"rendering/global_illumination/amd_gi/reflections/firefly_high_threshold",
		"rendering/global_illumination/amd_gi/reflections/firefly_low_threshold",
		"rendering/global_illumination/amd_gi/reflections/firefly_mark_radius_full",
		"rendering/global_illumination/amd_gi/reflections/firefly_mark_radius_half",
		"rendering/global_illumination/amd_gi/reflections/probe_roughness_threshold",
		"rendering/global_illumination/amd_gi/reflections/ray_compaction",
		"rendering/global_illumination/amd_gi/reflections/split_radius_full",
		"rendering/global_illumination/amd_gi/reflections/split_radius_half",
		"rendering/global_illumination/amd_gi/screen_feedback",
		"rendering/global_illumination/amd_gi/sky_sampling",
		"rendering/global_illumination/amd_gi/tuning/cache_history_updates",
		"rendering/global_illumination/amd_gi/tuning/denoiser_history_scale",
		"rendering/global_illumination/amd_gi/tuning/distant_cell_scale",
		"rendering/global_illumination/rt_validation/bounces",
		"rendering/global_illumination/rt_validation/enabled",
		"rendering/global_illumination/rt_validation/max_distance",
		"rendering/global_illumination/rt_validation/samples_per_pixel",
		"rendering/lights_and_shadows/raytraced_shadows/accurate_occluder_distance",
		"rendering/lights_and_shadows/raytraced_shadows/denoiser/enabled",
		"rendering/lights_and_shadows/raytraced_shadows/denoiser/history_clamp_sigma",
		"rendering/lights_and_shadows/raytraced_shadows/denoiser/min_filter_pixels",
		"rendering/lights_and_shadows/raytraced_shadows/denoiser/spatial_passes",
		"rendering/lights_and_shadows/raytraced_shadows/denoiser/temporal_frames",
		"rendering/lights_and_shadows/raytraced_shadows/directional/caster_distance_scale",
		"rendering/lights_and_shadows/raytraced_shadows/directional/demoted_shadow_mode",
		"rendering/lights_and_shadows/raytraced_shadows/directional/demoted_shadow_size",
		"rendering/lights_and_shadows/raytraced_shadows/max_ray_distance",
		"rendering/lights_and_shadows/screen_space_shadows/bilinear_threshold",
		"rendering/lights_and_shadows/screen_space_shadows/debug_view",
		"rendering/lights_and_shadows/screen_space_shadows/ignore_edge_pixels",
		"rendering/lights_and_shadows/screen_space_shadows/surface_thickness",
		"rendering/streamline/binary_path",
		"rendering/streamline/project_id",
		"rendering/streamline/reactive_mask",
		"rendering/streamline/verbose_logging",
	};
	// Project feature overrides append one or more dot-separated feature tags.
	return settings.has(p_name.get_slicec('.', 0));
}

bool ForkProjectSettings::is_general(const String &p_name) {
	return !is_advanced(p_name);
}
