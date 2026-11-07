/**************************************************************************/
/*  hybrid_pip.cpp                                                        */
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

#include "hybrid_pip.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

HybridPiP::HybridPiP() {
	RD *rd = RD::get_singleton();
	const uint32_t usage = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
	if (!rd->texture_is_format_supported_for_usage(RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage) ||
			!rd->texture_is_format_supported_for_usage(RD::DATA_FORMAT_R32_SFLOAT, usage)) {
		return;
	}
	Vector<String> modes;
	modes.push_back("\n#define MODE_COMPOSE\n");
	modes.push_back("\n#define MODE_BLUR\n");
	modes.push_back("\n#define MODE_DOWNSAMPLE\n");
	modes.push_back("\n#define MODE_BACKGROUND_FXAA\n");
	shader.initialize(modes);
	shader_version = shader.version_create();
	for (uint32_t mode = 0; mode < MODE_COUNT; mode++) {
		RID compiled = shader.version_get_shader(shader_version, mode);
		if (compiled.is_null()) {
			return;
		}
		pipelines[mode] = rd->compute_pipeline_create(compiled);
		if (pipelines[mode].is_null()) {
			return;
		}
	}
	valid = true;
}

HybridPiP::~HybridPiP() {
	if (shader_version.is_valid()) {
		shader.version_free(shader_version);
	}
}

HybridPiP::HybridPiPViewData::~HybridPiPViewData() {
	if (aperture_uniform.is_valid()) {
		RD::get_singleton()->free_rid(aperture_uniform);
	}
}

uint32_t HybridPiP::get_blur_mip_count(const Size2i &p_size) {
	uint32_t levels = 1;
	Size2i size = p_size;
	float footprint = Settings().far_radius * float(p_size.y) / (720.0f * 3.0f);
	while (footprint > 1.0f && (size.x > 1 || size.y > 1)) {
		size = Size2i(MAX(size.x / 2, 1), MAX(size.y / 2, 1));
		footprint *= 0.5f;
		levels++;
	}
	return levels;
}

bool HybridPiP::prepare(Ref<HybridPiPViewData> &r_data) {
	if (!valid) {
		return false;
	}
	if (r_data.is_null()) {
		r_data.instantiate();
	}
	if (r_data->aperture_uniform.is_valid()) {
		return true;
	}
	ApertureUniform uniform = {};
	// Four-point Gauss-Legendre quadrature over squared disk radius, with
	// fourfold angular symmetry. Match the dense kernel's energy and variance.
	static const float radii[] = { 0.0694318442f, 0.3300094782f, 0.6699905218f, 0.9305681558f };
	static const float weights[] = { 0.1739274226f, 0.3260725774f, 0.3260725774f, 0.1739274226f };
	for (uint32_t tap = 0; tap < BLUR_TAPS; tap++) {
		const uint32_t ring = tap / 4;
		const float fraction = radii[ring];
		const float radius = Math::sqrt(fraction);
		const float angle = float(ring) * 2.39996323f + float(tap & 3u) * float(Math::PI * 0.5);
		uniform.disk[tap][0] = Math::cos(angle) * radius;
		uniform.disk[tap][1] = Math::sin(angle) * radius;
		uniform.disk[tap][2] = Math::exp(-2.0f * fraction) * weights[ring] * 4.0f;
	}
	Vector<uint8_t> bytes;
	bytes.resize(sizeof(uniform));
	memcpy(bytes.ptrw(), &uniform, sizeof(uniform));
	r_data->aperture_uniform = RD::get_singleton()->uniform_buffer_create(sizeof(uniform), bytes);
	return r_data->aperture_uniform.is_valid();
}

bool HybridPiP::filter_fxaa(RID p_source, RID p_destination, const Size2i &p_size, float p_luma_scale) {
	ERR_FAIL_COND_V(!valid || p_source.is_null() || p_destination.is_null() || p_source == p_destination, false);
	RD *rd = RD::get_singleton();
	const RID linear = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	const RD::Uniform source(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>{ linear, p_source });
	const RD::Uniform destination(RD::UNIFORM_TYPE_IMAGE, 1, p_destination);
	const RID set = UniformSetCacheRD::get_singleton()->get_cache(shader.version_get_shader(shader_version, MODE_BACKGROUND_FXAA), 0, source, destination);
	ERR_FAIL_COND_V(set.is_null(), false);
	const RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, pipelines[MODE_BACKGROUND_FXAA]);
	rd->compute_list_bind_uniform_set(list, set, 0);
	rd->compute_list_set_push_constant(list, &p_luma_scale, sizeof(float));
	rd->compute_list_dispatch_threads(list, p_size.x, p_size.y, 1);
	rd->compute_list_end();
	return true;
}

bool HybridPiP::render(const Ref<HybridPiPViewData> &p_data, const Inputs &p_inputs, const Outputs &p_outputs,
		const HybridPiPLayout &p_layout, const Projection &p_inverse_parent_projection,
		const Vector<Vector2> &p_aperture, const Settings &p_settings) {
	if (!valid || p_data.is_null() || p_data->aperture_uniform.is_null() ||
			!p_layout.background.is_valid() || !p_layout.native.is_valid() ||
			p_layout.background.parent_size != p_layout.output_size || p_layout.native.parent_size != p_layout.output_size ||
			p_layout.background.output_rect != Rect2i(Point2i(), p_layout.output_size) ||
			p_layout.protected_rect.size.x <= 0 || p_layout.protected_rect.size.y <= 0 ||
			p_layout.protected_rect.position.x < 0 || p_layout.protected_rect.position.y < 0 ||
			int64_t(p_layout.protected_rect.position.x) + p_layout.protected_rect.size.x > p_layout.output_size.x ||
			int64_t(p_layout.protected_rect.position.y) + p_layout.protected_rect.size.y > p_layout.output_size.y ||
			!p_layout.native.output_rect.encloses(p_layout.protected_rect)) {
		return false;
	}
	if ((p_settings.blur_enabled && p_aperture.size() < 3) || p_aperture.size() > int(MAX_APERTURE_VERTICES) ||
			!Math::is_finite(p_settings.near_radius) || !Math::is_finite(p_settings.far_radius) ||
			!Math::is_finite(p_settings.near_distance) || !Math::is_finite(p_settings.far_distance) ||
			p_settings.near_radius < 0.0f || p_settings.far_radius < p_settings.near_radius ||
			p_settings.near_distance < 0.0f || p_settings.far_distance <= p_settings.near_distance) {
		return false;
	}
	const bool lens_only = p_settings.lens_only_coverage.has_area();
	if (lens_only && (!p_settings.magnify_aperture || p_aperture.size() < 3 || p_settings.lens_only_coverage.size != p_inputs.native_color_size)) {
		return false;
	}
	const Rect2i aperture_coverage = lens_only ? p_settings.lens_only_coverage : p_layout.protected_rect;
	float aperture[MAX_APERTURE_VERTICES][4] = {};
	real_t aperture_area = 0.0;
	for (int vertex = 0; vertex < p_aperture.size(); vertex++) {
		const Vector2 &position = p_aperture[vertex];
		const Vector2 pixel = position * Vector2(p_layout.output_size);
		if (!position.is_finite() || !pixel.is_finite() || !Math::is_finite(float(pixel.x)) || !Math::is_finite(float(pixel.y))) {
			return false;
		}
		const Vector2 &next = p_aperture[(vertex + 1) % p_aperture.size()];
		aperture_area += position.cross(next);
		// Clipping an offscreen vertex is only for this coverage check. Preserve
		// the actual polygon for distance/inside tests in the shader.
		for (int axis = 0; axis < 2; axis++) {
			const real_t visible = CLAMP(pixel[axis], real_t(0), real_t(p_layout.output_size[axis]));
			if (visible < aperture_coverage.position[axis] || visible > aperture_coverage.get_end()[axis]) {
				return false;
			}
		}
		aperture[vertex][0] = position.x;
		aperture[vertex][1] = position.y;
	}
	if (p_settings.blur_enabled && (!Math::is_finite(aperture_area) || Math::abs(aperture_area) <= real_t(1e-12))) {
		return false;
	}

	RD *rd = RD::get_singleton();
	if (p_outputs.color_pyramid.is_null() || !rd->texture_is_valid(p_outputs.color_pyramid) ||
			p_outputs.color_mips.is_empty() || p_outputs.color_mips[0] != p_outputs.composed_color) {
		return false;
	}
	const RD::TextureFormat pyramid_format = rd->texture_get_format(p_outputs.color_pyramid);
	if (pyramid_format.mipmaps != uint32_t(p_outputs.color_mips.size()) ||
			pyramid_format.width != uint32_t(p_layout.output_size.x) || pyramid_format.height != uint32_t(p_layout.output_size.y)) {
		return false;
	}
	Size2i mip_size = p_layout.output_size;
	for (RID mip : p_outputs.color_mips) {
		if (mip.is_null() || !rd->texture_is_valid(mip)) {
			return false;
		}
		const RD::TextureFormat format = rd->texture_get_format(mip);
		if (format.width != uint32_t(mip_size.x) || format.height != uint32_t(mip_size.y) || format.mipmaps != 1) {
			return false;
		}
		mip_size = Size2i(MAX(mip_size.x / 2, 1), MAX(mip_size.y / 2, 1));
	}
	const RID sources[] = { p_inputs.background_color, p_inputs.background_depth, p_inputs.native_color, p_inputs.native_depth };
	const Size2i source_sizes[] = { p_inputs.background_color_size, p_inputs.background_depth_size, p_inputs.native_color_size, p_inputs.native_depth_size };
	const RID destinations[] = { p_outputs.composed_color, p_outputs.composed_depth, p_outputs.blurred_color };
	for (uint32_t source = 0; source < 4; source++) {
		if (sources[source].is_null() || !rd->texture_is_valid(sources[source]) || source_sizes[source].x <= 0 || source_sizes[source].y <= 0) {
			return false;
		}
		const RD::TextureFormat format = rd->texture_get_format(sources[source]);
		if (format.texture_type != RD::TEXTURE_TYPE_2D || format.samples != RD::TEXTURE_SAMPLES_1 || format.width < uint32_t(source_sizes[source].x) || format.height < uint32_t(source_sizes[source].y) ||
				!(format.usage_bits & RD::TEXTURE_USAGE_SAMPLING_BIT)) {
			return false;
		}
		for (RID destination : destinations) {
			if (sources[source] == destination) {
				return false;
			}
		}
	}
	for (uint32_t destination = 0; destination < 3; destination++) {
		if (destinations[destination].is_null() || !rd->texture_is_valid(destinations[destination])) {
			return false;
		}
		for (uint32_t previous = 0; previous < destination; previous++) {
			if (destinations[destination] == destinations[previous]) {
				return false;
			}
		}
		const RD::TextureFormat format = rd->texture_get_format(destinations[destination]);
		const RD::DataFormat expected = destination == 1 ? RD::DATA_FORMAT_R32_SFLOAT : RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		if (format.format != expected || format.texture_type != RD::TEXTURE_TYPE_2D || format.samples != RD::TEXTURE_SAMPLES_1 ||
				format.width < uint32_t(p_layout.output_size.x) || format.height < uint32_t(p_layout.output_size.y) ||
				!(format.usage_bits & RD::TEXTURE_USAGE_STORAGE_BIT) || !(format.usage_bits & RD::TEXTURE_USAGE_SAMPLING_BIT)) {
			return false;
		}
	}

	ComposePushConstant compose = {};
	BlurPushConstant blur = {};
	const float depth_unproject[4] = { float(p_inverse_parent_projection[2][2]), float(p_inverse_parent_projection[3][2]),
		float(p_inverse_parent_projection[2][3]), float(p_inverse_parent_projection[3][3]) };
	for (uint32_t component = 0; component < 4; component++) {
		if (!Math::is_finite(depth_unproject[component])) {
			return false;
		}
		compose.depth_unproject[component] = depth_unproject[component];
		blur.depth_unproject[component] = depth_unproject[component];
	}
	// This four-coefficient reconstruction is for the plan's ordinary perspective
	// camera (including off-center crops). An oblique depth plane needs XY terms.
	if (!Math::is_zero_approx(p_inverse_parent_projection[0][2]) || !Math::is_zero_approx(p_inverse_parent_projection[1][2]) ||
			!Math::is_zero_approx(p_inverse_parent_projection[0][3]) || !Math::is_zero_approx(p_inverse_parent_projection[1][3])) {
		return false;
	}
	const float near_denominator = depth_unproject[2] + depth_unproject[3];
	if (near_denominator == 0.0f) {
		return false;
	}
	const float near_depth = -(depth_unproject[0] + depth_unproject[1]) / near_denominator;
	const float far_depth = depth_unproject[3] != 0.0f ? -depth_unproject[1] / depth_unproject[3] : float(Math::INF);
	if (!(near_depth > 0.0f) || !(far_depth > near_depth)) {
		return false;
	}
	for (uint32_t axis = 0; axis < 2; axis++) {
		compose.output_size[axis] = p_layout.output_size[axis];
		compose.background_color_size[axis] = p_inputs.background_color_size[axis];
		compose.background_depth_size[axis] = p_inputs.background_depth_size[axis];
		compose.native_color_size[axis] = p_inputs.native_color_size[axis];
		compose.native_depth_size[axis] = p_inputs.native_depth_size[axis];
		compose.crop_position[axis] = p_layout.native.output_rect.position[axis];
		compose.crop_size[axis] = p_layout.native.output_rect.size[axis];
		compose.protected_position[axis] = p_layout.protected_rect.position[axis];
		compose.protected_size[axis] = p_layout.protected_rect.size[axis];
		blur.output_size[axis] = p_layout.output_size[axis];
	}
	compose.preview_resolve = p_settings.preview_resolve;
	if (p_settings.magnify_aperture && p_aperture.size() >= 3) {
		Vector2 center;
		for (const Vector2 &uv : p_aperture) {
			center += uv * Vector2(p_layout.output_size);
		}
		center /= p_aperture.size();
		compose.lens_center[0] = center.x;
		compose.lens_center[1] = center.y;
		for (const Vector2 &uv : p_aperture) {
			compose.lens_radius = MAX(compose.lens_radius, float(center.distance_to(uv * Vector2(p_layout.output_size))));
		}
		compose.lens_vertex_count = p_aperture.size();
		// Keep the optical axis fixed even when the scope box is asymmetric.
		// One integer translation maps display texels onto reconstructed texels.
		const Vector2 local = center - Vector2(p_layout.native.output_rect.position);
		const Vector2 offset = local * (Vector2(p_inputs.native_color_size) / Vector2(p_layout.native.output_rect.size) - Vector2(1, 1));
		compose.source_offset[0] = Math::round(offset.x);
		compose.source_offset[1] = Math::round(offset.y);
		if (lens_only) {
			const Point2i translation = p_layout.native.output_rect.position - aperture_coverage.position;
			compose.source_offset[0] = translation.x;
			compose.source_offset[1] = translation.y;
			compose.lens_only = 1;
		}
	}
	const float output_scale = float(p_layout.output_size.y) / 720.0f;
	if (!Math::is_finite(p_settings.far_radius * output_scale)) {
		return false;
	}
	blur.aperture_count = p_aperture.size();
	blur.blur_enabled = p_settings.blur_enabled;
	blur.blur_range[0] = p_settings.near_radius * output_scale;
	blur.blur_range[1] = p_settings.far_radius * output_scale;
	blur.blur_range[2] = p_settings.near_distance;
	blur.blur_range[3] = p_settings.far_distance;
	blur.aperture_feather[0] = 0.5f * output_scale;
	blur.aperture_feather[1] = 3.5f * output_scale;

	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	const RID nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	const RID linear = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	const RID trilinear = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	LocalVector<RD::Uniform> compose_uniforms;
	for (uint32_t source = 0; source < 4; source++) {
		compose_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, source, Vector<RID>{ source == 2 ? linear : nearest, sources[source] }));
	}
	compose_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 4, p_outputs.composed_color));
	compose_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 5, p_outputs.composed_depth));
	compose_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 6, p_data->aperture_uniform));
	LocalVector<RD::Uniform> blur_uniforms;
	blur_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>{ trilinear, p_outputs.color_pyramid }));
	blur_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>{ nearest, p_outputs.composed_depth }));
	blur_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 2, p_outputs.blurred_color));
	blur_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 3, p_data->aperture_uniform));
	RID compose_set = UniformSetCacheRD::get_singleton()->get_cache_vec(shader.version_get_shader(shader_version, MODE_COMPOSE), 0, compose_uniforms);
	RID blur_set = UniformSetCacheRD::get_singleton()->get_cache_vec(shader.version_get_shader(shader_version, MODE_BLUR), 0, blur_uniforms);
	if (compose_set.is_null() || blur_set.is_null() || rd->buffer_update(p_data->aperture_uniform, 0, sizeof(aperture), aperture) != OK) {
		return false;
	}
	LocalVector<RID> downsample_sets;
	const bool build_pyramid = p_settings.blur_enabled || !p_data->pyramid_warmed;
	if (build_pyramid) {
		for (int mip = 1; mip < p_outputs.color_mips.size(); mip++) {
			RD::Uniform source(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>{ linear, p_outputs.color_mips[mip - 1] });
			RD::Uniform destination(RD::UNIFORM_TYPE_IMAGE, 1, p_outputs.color_mips[mip]);
			RID set = UniformSetCacheRD::get_singleton()->get_cache(shader.version_get_shader(shader_version, MODE_DOWNSAMPLE), 0, source, destination);
			if (set.is_null()) {
				return false;
			}
			downsample_sets.push_back(set);
		}
	}

	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, pipelines[MODE_COMPOSE]);
	rd->compute_list_bind_uniform_set(list, compose_set, 0);
	rd->compute_list_set_push_constant(list, &compose, sizeof(compose));
	rd->compute_list_dispatch_threads(list, p_layout.output_size.x, p_layout.output_size.y, 1);
	rd->compute_list_end();
	mip_size = p_layout.output_size;
	for (RID set : downsample_sets) {
		mip_size = Size2i(MAX(mip_size.x / 2, 1), MAX(mip_size.y / 2, 1));
		list = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(list, pipelines[MODE_DOWNSAMPLE]);
		rd->compute_list_bind_uniform_set(list, set, 0);
		rd->compute_list_dispatch_threads(list, mip_size.x, mip_size.y, 1);
		rd->compute_list_end();
	}
	list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, pipelines[MODE_BLUR]);
	rd->compute_list_bind_uniform_set(list, blur_set, 0);
	rd->compute_list_set_push_constant(list, &blur, sizeof(blur));
	rd->compute_list_dispatch_threads(list, p_layout.output_size.x, p_layout.output_size.y, 1);
	rd->compute_list_end();
	p_data->pyramid_warmed = true;
	return true;
}
