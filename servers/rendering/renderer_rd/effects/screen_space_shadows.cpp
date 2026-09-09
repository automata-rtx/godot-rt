/**************************************************************************/
/*  screen_space_shadows.cpp                                              */
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

#include "screen_space_shadows.h"

#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#include <thirdparty/bend_sss/bend_sss_cpu.h>

using namespace RendererRD;

ScreenSpaceShadows::ScreenSpaceShadows() {
	if (!is_target_format_supported()) {
		// A single channel eight bit storage image is not part of Vulkan's
		// guaranteed set. Rather than quietly spending four times the bandwidth on
		// a wider format, say so and leave the effect off.
		ERR_PRINT("Screen space shadows: R8_UNORM is not usable as a storage image on this device; screen space shadows are unavailable.");
		return;
	}

	// One variant per quality tier. The sample loops are unrolled and the shared
	// memory array is sized from the count, so it cannot be a uniform or a
	// specialization constant.
	//
	// HARD_SHADOW_SAMPLES stays at Bend's recommended 4 in every tier: it is what
	// grounds a blade against the surface it is standing on, and it is the last
	// thing that should be traded away for speed. FADE_OUT_SAMPLES scales with
	// the tier so the tail is a similar fraction of the march at each.
	Vector<String> modes;
	modes.push_back("\n#define SAMPLE_COUNT 32\n#define HARD_SHADOW_SAMPLES 4\n#define FADE_OUT_SAMPLES 5\n");
	modes.push_back("\n#define SAMPLE_COUNT 60\n#define HARD_SHADOW_SAMPLES 4\n#define FADE_OUT_SAMPLES 8\n");
	modes.push_back("\n#define SAMPLE_COUNT 96\n#define HARD_SHADOW_SAMPLES 4\n#define FADE_OUT_SAMPLES 12\n");

	shader.initialize(modes);
	shader_version = shader.version_create();

	for (int i = 0; i < QUALITY_MAX; i++) {
		RID compiled = shader.version_get_shader(shader_version, i);
		if (compiled.is_null()) {
			// The likely cause is the subgroup vote the early-out uses. It is
			// available on every Vulkan 1.1 device the rest of this fork requires,
			// but the D3D12 backend's SPIR-V to DXIL path has no explicit handling
			// for it. Failing the whole effect is the honest outcome: the alternative
			// is a shader that compiles and produces nothing.
			ERR_PRINT("Screen space shadows: shader failed to compile; screen space shadows are unavailable.");
			shader.version_free(shader_version);
			shader_version = RID();
			return;
		}
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(compiled);
		if (pipelines[i].is_null()) {
			ERR_PRINT("Screen space shadows: compute pipeline creation failed; screen space shadows are unavailable.");
			shader.version_free(shader_version);
			shader_version = RID();
			return;
		}
	}

	{
		RD::SamplerState sampler_state;
		sampler_state.mag_filter = RD::SAMPLER_FILTER_NEAREST;
		sampler_state.min_filter = RD::SAMPLER_FILTER_NEAREST;
		sampler_state.mip_filter = RD::SAMPLER_FILTER_NEAREST;
		sampler_state.repeat_u = RD::SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER;
		sampler_state.repeat_v = RD::SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER;
		sampler_state.repeat_w = RD::SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER;
		// Transparent black is (0, 0, 0, 0), so red reads back as 0.0 -- which
		// under this renderer's reverse-Z is the far plane, and therefore "no
		// occluder here". Without this the march sees the screen's edge texels
		// repeated outward and casts shadows in from off screen.
		sampler_state.border_color = RD::SAMPLER_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
		depth_sampler = RD::get_singleton()->sampler_create(sampler_state);
		if (depth_sampler.is_null()) {
			ERR_PRINT("Screen space shadows: border sampler creation failed; screen space shadows are unavailable.");
			shader.version_free(shader_version);
			shader_version = RID();
			return;
		}
	}

	valid = true;
}

ScreenSpaceShadows::~ScreenSpaceShadows() {
	if (depth_sampler.is_valid()) {
		RD::get_singleton()->free_rid(depth_sampler);
	}
	if (shader_version.is_valid()) {
		// Frees the pipelines built from it as well.
		shader.version_free(shader_version);
	}
}

bool ScreenSpaceShadows::is_target_format_supported() {
	return RD::get_singleton()->texture_is_format_supported_for_usage(
			get_target_format(),
			RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT);
}

bool ScreenSpaceShadows::render(RID p_depth_texture, RID p_output, const Size2i &p_size,
		const Projection &p_camera_projection, const Vector3 &p_light_direction_view,
		const ScreenSpaceShadows::Settings &p_settings) {
	if (!valid || p_depth_texture.is_null() || p_output.is_null()) {
		return false;
	}
	if (p_size.x <= 0 || p_size.y <= 0) {
		return false;
	}

	// Ahead of every remaining early return, not just before the dispatches.
	// Two reasons. The early-out means a rejected pixel is a pixel no dispatch
	// writes, so the target has to start from a known value rather than whatever
	// the last frame left in it. And a frame that bails out below must not leave
	// the previous frame's shadows standing while the light is still marked as
	// carrying them -- the caller cannot tell the difference, because it has
	// already written sss_strength by the time this runs. White is fully lit,
	// which is the safe direction to fail in both cases.
	RD::get_singleton()->texture_clear(p_output, Color(1, 1, 1, 1), 0, 1, 0, 1);

	const Quality quality = CLAMP(p_settings.quality, QUALITY_LOW, Quality(QUALITY_MAX - 1));

	// The march runs from each pixel TOWARD the light, so the point it converges
	// on is the light's vanishing point: the direction pointing back at it. For a
	// directional light that is what DirectionalLightData::direction already
	// holds, so it is passed straight through.
	const Vector3 towards_light = p_light_direction_view;
	if (towards_light.length_squared() < CMP_EPSILON) {
		return false;
	}

	// A direction rather than a position, so w is zero going in. The dispatch
	// builder is written for that and reads the sign of the resulting clip w to
	// decide which way along the ray to march, which is how it copes with a sun
	// behind the camera.
	const Vector4 light_clip = p_camera_projection.xform(Vector4(towards_light.x, towards_light.y, towards_light.z, 0.0f));

	// Bend maps clip y to a pixel row with `* -0.5 + 0.5`, which is right for a
	// clip space whose +1 is the top row. Godot's projection carries a depth
	// correction that already negates y (Projection::set_depth_correction with
	// flip_y, against a positive height Vulkan viewport), so its -1 is the top
	// row and applying Bend's negation as well would flip the light to its own
	// vertical mirror. Negating the input instead leaves the vendored file alone
	// and is exactly equivalent: it is the only place y is read.
	float light_projection[4] = {
		float(light_clip.x),
		float(-light_clip.y),
		float(light_clip.z),
		float(light_clip.w),
	};

	int viewport_size[2] = { p_size.x, p_size.y };
	// Full screen, and inclusive. A directional light has no on screen volume to
	// bound, and bounding it to one would only cost dispatches without saving
	// any: the shader reads and writes up to 2 * WAVE_SIZE pixels outside
	// whatever it is given anyway.
	int min_bounds[2] = { 0, 0 };
	int max_bounds[2] = { p_size.x - 1, p_size.y - 1 };

	const Bend::DispatchList dispatch_list = Bend::BuildDispatchList(light_projection, viewport_size, min_bounds, max_bounds);
	if (dispatch_list.DispatchCount <= 0) {
		return false;
	}

	LocalVector<RD::Uniform> uniforms;
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
		u.binding = 0;
		u.append_id(depth_sampler);
		u.append_id(p_depth_texture);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = 1;
		u.append_id(p_output);
		uniforms.push_back(u);
	}

	RID compiled = shader.version_get_shader(shader_version, quality);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

	PushConstant push_constant = {};
	for (int i = 0; i < 4; i++) {
		push_constant.light_coordinate[i] = dispatch_list.LightCoordinate_Shader[i];
	}
	push_constant.screen_size[0] = p_size.x;
	push_constant.screen_size[1] = p_size.y;
	push_constant.inv_depth_texture_size[0] = 1.0f / float(p_size.x);
	push_constant.inv_depth_texture_size[1] = 1.0f / float(p_size.y);
	// Reverse-Z: this renderer clears depth to 0.0 and its corrected projection
	// puts the near plane at 1.0. The shader derives the sign of everything it
	// does from the relationship between these two, so it needs no other change.
	push_constant.far_depth_value = 0.0f;
	push_constant.near_depth_value = 1.0f;
	// Cull the sky, which is the whole point of the early-out for an outdoor
	// scene: those pixels sit exactly at the far value.
	push_constant.depth_bounds[0] = 0.0f;
	push_constant.depth_bounds[1] = 1.0f;
	push_constant.surface_thickness = MAX(p_settings.surface_thickness, 0.000001f);
	push_constant.bilinear_threshold = p_settings.bilinear_threshold;
	push_constant.shadow_contrast = MAX(p_settings.contrast, 1.0f);

	uint32_t flags = FLAG_USE_EARLY_OUT;
	if (p_settings.ignore_edge_pixels) {
		flags |= FLAG_IGNORE_EDGE_PIXELS;
	}
	switch (p_settings.debug_view) {
		case DEBUG_VIEW_EDGE_MASK: {
			flags |= FLAG_DEBUG_EDGE_MASK;
		} break;
		case DEBUG_VIEW_THREAD_INDEX: {
			flags |= FLAG_DEBUG_THREAD_INDEX;
		} break;
		case DEBUG_VIEW_WAVE_INDEX: {
			flags |= FLAG_DEBUG_WAVE_INDEX;
		} break;
		default: {
		} break;
	}
	push_constant.flags = flags;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipelines[quality]);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);

	for (int i = 0; i < dispatch_list.DispatchCount; i++) {
		const Bend::DispatchData &dispatch = dispatch_list.Dispatch[i];

		push_constant.wave_offset[0] = dispatch.WaveOffset_Shader[0];
		push_constant.wave_offset[1] = dispatch.WaveOffset_Shader[1];

		RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
		// Group counts, not thread counts: the X dimension is a count of
		// workgroups equal to the wave size, which is how the wavefronts are
		// stepped along their rays. Using compute_list_dispatch_threads here would
		// divide X by the local size and run a sixty-fourth of the work.
		//
		// The dispatches write disjoint pixels and read only the depth buffer, so
		// they need no barrier between them.
		RD::get_singleton()->compute_list_dispatch(compute_list,
				dispatch.WaveCount[0], dispatch.WaveCount[1], dispatch.WaveCount[2]);
	}

	RD::get_singleton()->compute_list_end();
	return true;
}
