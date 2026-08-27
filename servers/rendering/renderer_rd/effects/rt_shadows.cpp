/**************************************************************************/
/*  rt_shadows.cpp                                                        */
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

#include "rt_shadows.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

namespace {

void store_projection(const Projection &p_projection, float *r_dest) {
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++) {
			r_dest[i * 4 + j] = p_projection.columns[i][j];
		}
	}
}

void store_vector3(const Vector3 &p_vector, float *r_dest) {
	r_dest[0] = p_vector.x;
	r_dest[1] = p_vector.y;
	r_dest[2] = p_vector.z;
}

} //namespace

RTShadows::RTShadows() {
	if (!RD::get_singleton()->has_feature(RD::SUPPORTS_RAY_QUERY)) {
		return;
	}

	Vector<String> modes;
	modes.push_back("");

	trace_shader.initialize(modes);
	trace_shader_version = trace_shader.version_create();

	RID compiled = trace_shader.version_get_shader(trace_shader_version, 0);
	if (compiled.is_null()) {
		// The ray query shader failed to compile. Leave the effect invalid so the
		// renderer keeps using shadow maps rather than rendering nothing.
		ERR_PRINT("Raytraced shadows: ray query shader failed to compile; falling back to shadow maps.");
		trace_shader.version_free(trace_shader_version);
		trace_shader_version = RID();
		return;
	}

	trace_pipeline = RD::get_singleton()->compute_pipeline_create(compiled);
	if (trace_pipeline.is_null()) {
		trace_shader.version_free(trace_shader_version);
		trace_shader_version = RID();
		return;
	}

	temporal_shader.initialize(modes);
	temporal_shader_version = temporal_shader.version_create();
	RID temporal_compiled = temporal_shader.version_get_shader(temporal_shader_version, 0);
	if (temporal_compiled.is_valid()) {
		temporal_pipeline = RD::get_singleton()->compute_pipeline_create(temporal_compiled);
	}

	atrous_shader.initialize(modes);
	atrous_shader_version = atrous_shader.version_create();
	RID atrous_compiled = atrous_shader.version_get_shader(atrous_shader_version, 0);
	if (atrous_compiled.is_valid()) {
		atrous_pipeline = RD::get_singleton()->compute_pipeline_create(atrous_compiled);
	}

	if (temporal_pipeline.is_null() || atrous_pipeline.is_null()) {
		// Tracing still works without them; the mask is simply the raw result.
		ERR_PRINT_ONCE("Raytraced shadows: denoiser shaders failed to compile; shadows will be noisy.");
	}

	valid = true;
}

void RTShadows::_ensure_light_buffer(uint32_t p_light_count) {
	// Grown in powers of two so a scene whose light count wobbles does not
	// reallocate every frame.
	uint32_t required = MAX(16u, p_light_count);
	if (light_buffer.is_valid() && light_buffer_capacity >= required) {
		return;
	}

	uint32_t capacity = 16;
	while (capacity < required) {
		capacity *= 2;
	}

	if (light_buffer.is_valid()) {
		RD::get_singleton()->free_rid(light_buffer);
	}
	light_buffer = RD::get_singleton()->storage_buffer_create(sizeof(LightParams) * capacity);
	light_buffer_capacity = light_buffer.is_valid() ? capacity : 0;
}

RTShadows::~RTShadows() {
	if (light_buffer.is_valid()) {
		RD::get_singleton()->free_rid(light_buffer);
	}
	if (trace_shader_version.is_valid()) {
		trace_shader.version_free(trace_shader_version);
	}
	if (temporal_shader_version.is_valid()) {
		temporal_shader.version_free(temporal_shader_version);
	}
	if (atrous_shader_version.is_valid()) {
		atrous_shader.version_free(atrous_shader_version);
	}
}

void RTShadows::_trace(RID p_tlas, RID p_depth_texture, const Buffers &p_buffers,
		const Size2i &p_size, const Projection &p_inv_view_projection,
		const Transform3D &p_camera_transform, uint32_t p_light_count,
		const Settings &p_settings) {
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	RID sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	LocalVector<RD::Uniform> uniforms;
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_ACCELERATION_STRUCTURE;
		u.binding = 0;
		u.append_id(p_tlas);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
		u.binding = 1;
		u.append_id(sampler);
		u.append_id(p_depth_texture);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = 2;
		u.append_id(p_buffers.output_mask);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = 3;
		u.append_id(p_buffers.output_index);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = 4;
		u.append_id(p_buffers.raw_hit_distance);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		u.binding = 5;
		u.append_id(light_buffer);
		uniforms.push_back(u);
	}

	RID compiled = trace_shader.version_get_shader(trace_shader_version, 0);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

	TracePushConstant push_constant = {};
	store_projection(p_inv_view_projection, push_constant.inv_view_projection);
	push_constant.screen_size[0] = p_size.x;
	push_constant.screen_size[1] = p_size.y;
	push_constant.light_count = p_light_count;
	push_constant.sample_count = MAX(1u, p_settings.sample_count);
	store_vector3(p_camera_transform.origin, push_constant.camera_position);
	push_constant.max_ray_distance = p_settings.max_ray_distance;
	// Rays start slightly off the surface to avoid self-intersection. These are
	// first-draft constants and want tuning against a stress scene.
	push_constant.bias = 0.005f;
	push_constant.normal_bias = 0.02f;
	push_constant.frame_index = frame_index;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, trace_pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(TracePushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_size.x, p_size.y, 1);
	RD::get_singleton()->compute_list_end();
}

void RTShadows::_temporal(RID p_depth_texture, const Buffers &p_buffers, const Size2i &p_size,
		const Projection &p_reprojection, const Settings &p_settings) {
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	RID sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	LocalVector<RD::Uniform> uniforms;
	auto add_texture = [&](uint32_t p_binding, RID p_sampler, RID p_texture) {
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
		u.binding = p_binding;
		u.append_id(p_sampler);
		u.append_id(p_texture);
		uniforms.push_back(u);
	};
	auto add_image = [&](uint32_t p_binding, RID p_texture) {
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = p_binding;
		u.append_id(p_texture);
		uniforms.push_back(u);
	};

	add_texture(0, sampler, p_buffers.output_mask);
	add_texture(1, sampler, p_depth_texture);
	// The reprojected history is filtered in the shader rather than by the
	// sampler, because the channel assignment cannot be interpolated.
	add_texture(3, sampler, p_buffers.history_visibility);
	add_texture(4, sampler, p_buffers.history_meta);
	add_image(5, p_buffers.denoise_a);
	add_image(6, p_buffers.history_length);
	add_texture(7, sampler, p_buffers.output_index);
	add_texture(8, sampler, p_buffers.history_index);

	RID compiled = temporal_shader.version_get_shader(temporal_shader_version, 0);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

	TemporalPushConstant push_constant = {};
	store_projection(p_reprojection, push_constant.reprojection);
	push_constant.screen_size[0] = p_size.x;
	push_constant.screen_size[1] = p_size.y;
	// Relative tolerance on view distance when deciding whether the reprojected
	// sample is the same surface.
	push_constant.depth_tolerance = 0.02f;
	push_constant.max_history = MAX(1.0f, p_settings.max_history);

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, temporal_pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(TemporalPushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_size.x, p_size.y, 1);
	RD::get_singleton()->compute_list_end();
}

void RTShadows::_atrous(RID p_source, RID p_dest, RID p_depth_texture, RID p_normal_roughness,
		const Buffers &p_buffers, const Size2i &p_size, const Projection &p_inv_projection,
		int p_step_size, bool p_write_history) {
	MaterialStorage *material_storage = MaterialStorage::get_singleton();
	TextureStorage *texture_storage = TextureStorage::get_singleton();
	RID sampler = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	RID normal_texture = p_normal_roughness.is_valid() ? p_normal_roughness : texture_storage->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_NORMAL);

	LocalVector<RD::Uniform> uniforms;
	auto add_texture = [&](uint32_t p_binding, RID p_texture) {
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
		u.binding = p_binding;
		u.append_id(sampler);
		u.append_id(p_texture);
		uniforms.push_back(u);
	};
	auto add_image = [&](uint32_t p_binding, RID p_texture) {
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_IMAGE;
		u.binding = p_binding;
		u.append_id(p_texture);
		uniforms.push_back(u);
	};

	add_texture(0, p_source);
	add_texture(1, p_buffers.raw_hit_distance);
	add_texture(2, p_depth_texture);
	add_texture(3, normal_texture);
	add_texture(4, p_buffers.history_length);
	add_image(5, p_dest);
	// Bound unconditionally so the uniform set layout does not change between
	// iterations; only the first iteration actually writes them.
	add_image(6, p_buffers.history_visibility);
	add_image(7, p_buffers.history_meta);
	add_texture(8, p_buffers.output_index);
	add_image(9, p_buffers.history_index);

	RID compiled = atrous_shader.version_get_shader(atrous_shader_version, 0);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

	AtrousPushConstant push_constant = {};
	// Turns a depth buffer value into a distance along the camera's forward axis.
	// Only these four terms of the inverse projection matter: for a perspective
	// matrix its bottom two rows have no x or y dependency, which stays true
	// under both the depth correction and the temporal antialiasing jitter.
	push_constant.depth_unproject[0] = p_inv_projection.columns[2][2];
	push_constant.depth_unproject[1] = p_inv_projection.columns[3][2];
	push_constant.depth_unproject[2] = p_inv_projection.columns[2][3];
	push_constant.depth_unproject[3] = p_inv_projection.columns[3][3];
	push_constant.screen_size[0] = p_size.x;
	push_constant.screen_size[1] = p_size.y;
	push_constant.step_size = p_step_size;
	push_constant.write_history = p_write_history ? 1u : 0u;
	push_constant.depth_sigma = 0.02f;
	push_constant.normal_sigma = 64.0f;
	// Never collapse the kernel completely: even a contact shadow benefits from
	// a little filtering when the sample count is low.
	push_constant.min_filter_scale = 0.15f;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, atrous_pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(AtrousPushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_size.x, p_size.y, 1);
	RD::get_singleton()->compute_list_end();
}

void RTShadows::render(RID p_tlas, RID p_depth_texture, RID p_normal_roughness,
		const Buffers &p_buffers, const Size2i &p_screen_size,
		const Projection &p_camera_projection, const Transform3D &p_camera_transform,
		const Projection &p_prev_camera_projection, const Transform3D &p_prev_camera_transform,
		const LocalVector<LightParams> &p_lights, const Settings &p_settings) {
	if (!valid || p_tlas.is_null() || p_lights.is_empty() ||
			p_buffers.output_mask.is_null() || p_buffers.output_index.is_null()) {
		return;
	}

	frame_index++;

	const uint32_t light_count = MIN((uint32_t)p_lights.size(), MAX_RT_LIGHTS);

	_ensure_light_buffer(light_count);
	if (light_buffer.is_null()) {
		return;
	}
	RD::get_singleton()->buffer_update(light_buffer, 0, sizeof(LightParams) * light_count, p_lights.ptr());

	ERR_FAIL_COND(p_buffers.raw_hit_distance.is_null());

	// The acceleration structure lives in world space, so rays are traced there.
	const Projection view_projection = p_camera_projection * Projection(p_camera_transform.affine_inverse());
	const Projection inv_view_projection = view_projection.inverse();

	_trace(p_tlas, p_depth_texture, p_buffers, p_screen_size, inv_view_projection,
			p_camera_transform, light_count, p_settings);

	const bool denoise = p_settings.denoise &&
			temporal_pipeline.is_valid() && atrous_pipeline.is_valid() &&
			p_buffers.denoise_a.is_valid() && p_buffers.denoise_b.is_valid() &&
			p_buffers.history_visibility.is_valid() && p_buffers.history_index.is_valid() &&
			p_buffers.history_meta.is_valid() && p_buffers.history_length.is_valid();

	if (!denoise) {
		return;
	}

	// Straight from this frame's clip space to the previous frame's, which is
	// exact for static geometry under any camera movement. On the first frame of
	// a viewport the previous camera is still the identity; the resulting history
	// lookups fail the surface test rather than producing a smear.
	const Projection prev_view_projection = p_prev_camera_projection * Projection(p_prev_camera_transform.affine_inverse());
	const Projection reprojection = prev_view_projection * inv_view_projection;

	// The denoiser works on the mask in place: the temporal pass reads it and the
	// last a-trous pass writes it back.
	_temporal(p_depth_texture, p_buffers, p_screen_size, reprojection, p_settings);

	// A-trous iterations with a doubling step. The first iteration's output is
	// what next frame reprojects: feeding back the once-filtered signal rather
	// than the raw accumulation is what keeps the history from locking in noise.
	const uint32_t iterations = CLAMP(p_settings.atrous_iterations, 1u, 5u);
	const Projection inv_projection = p_camera_projection.inverse();
	RID source = p_buffers.denoise_a;

	for (uint32_t i = 0; i < iterations; i++) {
		const bool last = (i == iterations - 1);
		RID dest = last ? p_buffers.output_mask : ((source == p_buffers.denoise_a) ? p_buffers.denoise_b : p_buffers.denoise_a);

		_atrous(source, dest, p_depth_texture, p_normal_roughness, p_buffers, p_screen_size,
				inv_projection, 1 << i, i == 0);

		source = dest;
	}
}
