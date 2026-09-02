/**************************************************************************/
/*  gtao.cpp                                                              */
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

#include "gtao.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

GTAO::GTAO() {
	Vector<String> single;
	single.push_back("");

	prefilter_shader.initialize(single);
	prefilter_shader_version = prefilter_shader.version_create();
	RID prefilter_compiled = prefilter_shader.version_get_shader(prefilter_shader_version, 0);
	if (prefilter_compiled.is_valid()) {
		prefilter_pipeline = RD::get_singleton()->compute_pipeline_create(prefilter_compiled);
	}

	gather_shader.initialize(single);
	gather_shader_version = gather_shader.version_create();
	RID gather_compiled = gather_shader.version_get_shader(gather_shader_version, 0);
	if (gather_compiled.is_valid()) {
		gather_pipeline = RD::get_singleton()->compute_pipeline_create(gather_compiled);
	}

	Vector<String> filter_modes;
	filter_modes.push_back("\n#define MODE_DENOISE\n");
	filter_modes.push_back("\n#define MODE_UPSAMPLE\n");

	filter_shader.initialize(filter_modes);
	filter_shader_version = filter_shader.version_create();
	for (int i = 0; i < FILTER_MODE_MAX; i++) {
		RID compiled = filter_shader.version_get_shader(filter_shader_version, i);
		if (compiled.is_valid()) {
			filter_pipeline[i] = RD::get_singleton()->compute_pipeline_create(compiled);
		}
	}

	if (prefilter_pipeline.is_null() || gather_pipeline.is_null() ||
			filter_pipeline[FILTER_MODE_DENOISE].is_null() || filter_pipeline[FILTER_MODE_UPSAMPLE].is_null()) {
		// Leave the effect invalid rather than half working; the renderer then
		// keeps using the screen space occlusion it has always had.
		ERR_PRINT("GTAO: shaders failed to compile; falling back to the existing screen space occlusion.");
		return;
	}

	valid = true;
}

GTAO::~GTAO() {
	if (prefilter_shader_version.is_valid()) {
		prefilter_shader.version_free(prefilter_shader_version);
	}
	if (gather_shader_version.is_valid()) {
		gather_shader.version_free(gather_shader_version);
	}
	if (filter_shader_version.is_valid()) {
		filter_shader.version_free(filter_shader_version);
	}
}

int GTAO::filter_radius_for(const Settings &p_settings) {
	// The march's on-screen reach relative to the slice count, normalized so the
	// shipped four slices at the shipped screen radius come out at one -- a three
	// by three, which is what measured best there. At the top of the radius range
	// the same expression asks for three, a seven tap pass on each axis, which is
	// where the noise actually needs it.
	const float reach = p_settings.scale_radius_with_distance
			? p_settings.screen_radius * MAX(p_settings.radius, 0.0f)
			: 0.05f;
	const float noise = reach * 4.0f / float(MAX(p_settings.slice_count, 1));
	return CLAMP(int(Math::round(noise / 0.06f)), 1, 3);
}

Size2i GTAO::gather_size_for(const Size2i &p_full_size, bool p_half_resolution) {
	if (!p_half_resolution) {
		return p_full_size;
	}
	// Rounded up so a resolution with an odd dimension still covers every pixel
	// once the result is weighted back up.
	return Size2i(MAX((p_full_size.x + 1) / 2, 1), MAX((p_full_size.y + 1) / 2, 1));
}

void GTAO::render(const Buffers &p_buffers, RID p_depth_texture, RID p_normal_roughness,
		RID p_dest_ao, const Size2i &p_full_size, const Projection &p_projection,
		const Settings &p_settings) {
	if (!valid || p_buffers.depth_pyramid.is_null() || p_dest_ao.is_null()) {
		return;
	}

	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	RID nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RID nearest_mips = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	auto make_texture = [](uint32_t p_binding, RID p_sampler, RID p_texture) {
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
		u.binding = p_binding;
		u.append_id(p_sampler);
		u.append_id(p_texture);
		return u;
	};
	auto make_image = [](uint32_t p_binding, RID p_texture) {
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = p_binding;
		u.append_id(p_texture);
		return u;
	};

	// The same two terms the other screen space effects fold out of the
	// projection, so both depth pyramids describe identical distances.
	Projection correction;
	correction.set_depth_correction(false);
	Projection corrected = correction * p_projection;

	float linearize_mul = -corrected.columns[3][2];
	float linearize_add = corrected.columns[2][2];
	if (linearize_mul * linearize_add < 0) {
		linearize_add = -linearize_add;
	}

	// Turns a screen UV into a view space ray. Derived from the raw projection,
	// not the depth corrected one, and expressed for a UV in zero to one --
	// exactly the form the other screen space effects use. Both the gather and
	// the filter reconstruct view positions with it, so it lives out here.
	const float tan_half_fov_x = 1.0f / p_projection.columns[0][0];
	const float tan_half_fov_y = 1.0f / p_projection.columns[1][1];

	const bool orthogonal = p_projection.is_orthogonal();
	if (orthogonal) {
		linearize_mul = p_projection.get_z_near();
		linearize_add = p_projection.get_z_far();
	}

	RD::get_singleton()->draw_command_begin_label("GTAO");

	// Pass 1: the depth pyramid.
	{
		LocalVector<RD::Uniform> source;
		source.push_back(make_texture(0, nearest, p_depth_texture));

		LocalVector<RD::Uniform> dest;
		for (uint32_t i = 0; i < DEPTH_MIP_COUNT; i++) {
			dest.push_back(make_image(i, p_buffers.depth_mips[i]));
		}

		RID compiled = prefilter_shader.version_get_shader(prefilter_shader_version, 0);
		RID source_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, source);
		RID dest_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 1, dest);

		PrefilterPushConstant push = {};
		push.screen_size[0] = p_full_size.x;
		push.screen_size[1] = p_full_size.y;
		push.linearize_mul = linearize_mul;
		push.linearize_add = linearize_add;
		// A sample more than the effect radius behind the farthest of its four
		// belongs to a surface the march could never have reached anyway.
		const float falloff_range = MAX(p_settings.radius, 0.0001f);
		push.falloff_mul = -1.0f / falloff_range;
		push.falloff_add = 1.0f;
		push.orthogonal = orthogonal ? 1 : 0;

		RD::ComputeListID list = RD::get_singleton()->compute_list_begin();
		RD::get_singleton()->compute_list_bind_compute_pipeline(list, prefilter_pipeline);
		RD::get_singleton()->compute_list_bind_uniform_set(list, source_set, 0);
		RD::get_singleton()->compute_list_bind_uniform_set(list, dest_set, 1);
		RD::get_singleton()->compute_list_set_push_constant(list, &push, sizeof(PrefilterPushConstant));
		// One thread per 2x2 of full resolution pixels.
		RD::get_singleton()->compute_list_dispatch_threads(list, (p_full_size.x + 1) / 2, (p_full_size.y + 1) / 2, 1);
		RD::get_singleton()->compute_list_end();
	}

	// Pass 2: the gather.
	{
		LocalVector<RD::Uniform> uniforms;
		uniforms.push_back(make_texture(0, nearest_mips, p_buffers.depth_pyramid));
		uniforms.push_back(make_image(1, p_normal_roughness));
		uniforms.push_back(make_image(2, p_buffers.ao_a));

		RID compiled = gather_shader.version_get_shader(gather_shader_version, 0);
		RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

		GatherPushConstant push = {};
		push.gather_size[0] = p_buffers.gather_size.x;
		push.gather_size[1] = p_buffers.gather_size.y;
		push.full_size[0] = p_full_size.x;
		push.full_size[1] = p_full_size.y;

		push.uv_to_view_mul[0] = tan_half_fov_x * 2.0f;
		push.uv_to_view_mul[1] = tan_half_fov_y * -2.0f;
		push.uv_to_view_add[0] = tan_half_fov_x * -1.0f;
		push.uv_to_view_add[1] = tan_half_fov_y;

		push.radius = MAX(p_settings.radius, 0.0001f);
		push.thickness = MAX(p_settings.thickness, 0.0f);
		push.power = MAX(p_settings.power, 0.0f);
		push.intensity = MAX(p_settings.intensity, 0.0f);
		push.fade_from = p_settings.fade_from;
		push.fade_inv_span = 1.0f / MAX(p_settings.fade_to - p_settings.fade_from, 0.0001f);
		push.slice_count = CLAMP(p_settings.slice_count, 1, 8);
		push.steps_per_slice = CLAMP(p_settings.steps_per_slice, 1, 16);
		push.scale_radius_with_distance = p_settings.scale_radius_with_distance ? 1 : 0;
		push.screen_radius = CLAMP(p_settings.screen_radius, 0.001f, 0.5f);
		push.orthogonal = orthogonal ? 1 : 0;
		push.use_bitmask = p_settings.use_bitmask ? 1 : 0;
		push.gather_stride[0] = p_settings.half_resolution ? 2 : 1;
		push.gather_stride[1] = p_settings.half_resolution ? 2 : 1;

		RD::ComputeListID list = RD::get_singleton()->compute_list_begin();
		RD::get_singleton()->compute_list_bind_compute_pipeline(list, gather_pipeline);
		RD::get_singleton()->compute_list_bind_uniform_set(list, uniform_set, 0);
		RD::get_singleton()->compute_list_set_push_constant(list, &push, sizeof(GatherPushConstant));
		RD::get_singleton()->compute_list_dispatch_threads(list, p_buffers.gather_size.x, p_buffers.gather_size.y, 1);
		RD::get_singleton()->compute_list_end();
	}

	// Passes 3 and 4: a separable edge-aware blur, across then down, at the
	// gather's own resolution. One pass of nine taps was the whole noise
	// reduction budget and could not absorb what a large effect radius hands it;
	// two passes of at most seven taps each cost four more taps and remove
	// roughly twice as much, because the width now follows the noise.
	//
	// Pass 5 weights the result up into the buffer the forward shader samples.
	// At matching resolutions every weight collapses onto the pixel's own texel,
	// so it is a straight copy rather than a filter.
	{
		const int filter_radius = filter_radius_for(p_settings);
		const int32_t stride = p_settings.half_resolution ? 2 : 1;

		auto fill_common = [&](FilterPushConstant &push) {
			push.full_size[0] = p_full_size.x;
			push.full_size[1] = p_full_size.y;
			push.uv_to_view_mul[0] = tan_half_fov_x * 2.0f;
			push.uv_to_view_mul[1] = tan_half_fov_y * -2.0f;
			push.uv_to_view_add[0] = tan_half_fov_x * -1.0f;
			push.uv_to_view_add[1] = tan_half_fov_y;
			// A neighbor two percent of its own depth off this pixel's plane is
			// taken to be another surface. Measured against a plane rather than
			// against raw depth, so a surface seen at a glancing angle keeps its
			// own neighbors and a shallow silhouette still separates.
			push.plane_tolerance = 0.02f;
			push.filter_radius = filter_radius;
		};

		struct Pass {
			FilterMode mode;
			RID source;
			RID dest;
			Size2i size;
			int32_t stride;
			int32_t dir_x;
			int32_t dir_y;
		};
		const Pass passes[3] = {
			{ FILTER_MODE_DENOISE, p_buffers.ao_a, p_buffers.ao_b, p_buffers.gather_size, stride, 1, 0 },
			{ FILTER_MODE_DENOISE, p_buffers.ao_b, p_buffers.ao_a, p_buffers.gather_size, stride, 0, 1 },
			{ FILTER_MODE_UPSAMPLE, p_buffers.ao_a, p_dest_ao, p_full_size, stride, 0, 0 },
		};

		for (const Pass &pass : passes) {
			LocalVector<RD::Uniform> uniforms;
			uniforms.push_back(make_texture(0, nearest, pass.source));
			uniforms.push_back(make_texture(1, nearest_mips, p_buffers.depth_pyramid));
			uniforms.push_back(make_image(2, p_normal_roughness));
			uniforms.push_back(make_image(3, pass.dest));

			RID compiled = filter_shader.version_get_shader(filter_shader_version, pass.mode);
			RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

			FilterPushConstant push = {};
			push.source_size[0] = p_buffers.gather_size.x;
			push.source_size[1] = p_buffers.gather_size.y;
			push.dest_size[0] = pass.size.x;
			push.dest_size[1] = pass.size.y;
			// The blur runs entirely inside the gather's own grid, so a gather
			// texel is one step; only the upsample crosses resolutions.
			push.gather_stride[0] = pass.mode == FILTER_MODE_UPSAMPLE ? pass.stride : 1;
			push.gather_stride[1] = pass.mode == FILTER_MODE_UPSAMPLE ? pass.stride : 1;
			fill_common(push);
			push.direction[0] = pass.dir_x;
			push.direction[1] = pass.dir_y;

			RD::ComputeListID list = RD::get_singleton()->compute_list_begin();
			RD::get_singleton()->compute_list_bind_compute_pipeline(list, filter_pipeline[pass.mode]);
			RD::get_singleton()->compute_list_bind_uniform_set(list, uniform_set, 0);
			RD::get_singleton()->compute_list_set_push_constant(list, &push, sizeof(FilterPushConstant));
			RD::get_singleton()->compute_list_dispatch_threads(list, pass.size.x, pass.size.y, 1);
			RD::get_singleton()->compute_list_end();
		}
	}

	RD::get_singleton()->draw_command_end_label();
}
