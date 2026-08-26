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
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

RTShadows::RTShadows() {
	if (!RD::get_singleton()->has_feature(RD::SUPPORTS_RAY_QUERY)) {
		return;
	}

	Vector<String> modes;
	modes.push_back("");

	shader.initialize(modes);
	shader_version = shader.version_create();

	RID compiled = shader.version_get_shader(shader_version, 0);
	if (compiled.is_null()) {
		// The ray query shader failed to compile. Leave the effect invalid so the
		// renderer keeps using shadow maps rather than rendering nothing.
		ERR_PRINT("Raytraced shadows: ray query shader failed to compile; falling back to shadow maps.");
		shader.version_free(shader_version);
		shader_version = RID();
		return;
	}

	pipeline = RD::get_singleton()->compute_pipeline_create(compiled);
	if (pipeline.is_null()) {
		shader.version_free(shader_version);
		shader_version = RID();
		return;
	}

	light_buffer = RD::get_singleton()->uniform_buffer_create(sizeof(LightParams) * MAX_RT_LIGHTS);

	valid = light_buffer.is_valid();
}

RTShadows::~RTShadows() {
	if (light_buffer.is_valid()) {
		RD::get_singleton()->free_rid(light_buffer);
	}
	if (shader_version.is_valid()) {
		shader.version_free(shader_version);
	}
}

void RTShadows::render(RID p_tlas, RID p_depth_texture, RID p_dest_mask,
		const Size2i &p_screen_size, const Projection &p_camera_projection,
		const Transform3D &p_camera_transform, const LocalVector<LightParams> &p_lights,
		uint32_t p_sample_count, float p_max_ray_distance) {
	if (!valid || p_tlas.is_null() || p_lights.is_empty()) {
		return;
	}

	frame_index++;

	// Upload the light list. Unused slots are zeroed so a stale light cannot
	// leak into a channel that is no longer in use.
	LightParams packed[MAX_RT_LIGHTS] = {};
	const uint32_t light_count = MIN((uint32_t)p_lights.size(), MAX_RT_LIGHTS);
	for (uint32_t i = 0; i < light_count; i++) {
		packed[i] = p_lights[i];
	}
	RD::get_singleton()->buffer_update(light_buffer, 0, sizeof(LightParams) * MAX_RT_LIGHTS, packed);

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
		u.append_id(p_dest_mask);
		uniforms.push_back(u);
	}
	{
		RD::Uniform u;
		u.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		u.binding = 3;
		u.append_id(light_buffer);
		uniforms.push_back(u);
	}

	RID compiled = shader.version_get_shader(shader_version, 0);
	// Cached by content, so the set is reused across frames instead of a new one
	// being allocated every dispatch.
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(compiled, 0, uniforms);

	// The acceleration structure lives in world space, so rays are traced there.
	Projection view_projection = p_camera_projection * Projection(p_camera_transform.affine_inverse());
	Projection inv_view_projection = view_projection.inverse();

	PushConstant push_constant = {};
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++) {
			push_constant.inv_view_projection[i * 4 + j] = inv_view_projection.columns[i][j];
		}
	}
	push_constant.screen_size[0] = p_screen_size.x;
	push_constant.screen_size[1] = p_screen_size.y;
	push_constant.light_count = light_count;
	push_constant.sample_count = MAX(1u, p_sample_count);
	push_constant.camera_position[0] = p_camera_transform.origin.x;
	push_constant.camera_position[1] = p_camera_transform.origin.y;
	push_constant.camera_position[2] = p_camera_transform.origin.z;
	push_constant.max_ray_distance = p_max_ray_distance;
	// Rays start slightly off the surface to avoid self-intersection. These are
	// first-draft constants and want tuning against a stress scene.
	push_constant.bias = 0.005f;
	push_constant.normal_bias = 0.02f;
	push_constant.frame_index = frame_index;

	RD::ComputeListID compute_list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(compute_list, pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(compute_list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(compute_list, &push_constant, sizeof(PushConstant));
	RD::get_singleton()->compute_list_dispatch_threads(compute_list, p_screen_size.x, p_screen_size.y, 1);
	RD::get_singleton()->compute_list_end();
}
