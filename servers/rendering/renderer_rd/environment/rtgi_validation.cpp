/**************************************************************************/
/*  rtgi_validation.cpp                                                   */
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

#include "rtgi_validation.h"

#include "core/config/project_settings.h"
#include "servers/rendering/renderer_rd/environment/rt_material_capture.h"
#include "servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/light_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

bool RTGIValidation::is_enabled() {
	return GLOBAL_GET("rendering/global_illumination/rt_validation/enabled");
}

RTGIValidation::RTGIValidation() {
	Vector<String> modes;
	modes.push_back("");
	shader.initialize(modes);
	version = shader.version_create();
	RID compiled = shader.version_get_shader(version, 0);
	if (compiled.is_null()) {
		return;
	}
	pipeline = RD::get_singleton()->compute_pipeline_create(compiled);
}
RTGIValidation::~RTGIValidation() {
	if (pipeline.is_valid()) {
		RD::get_singleton()->free_rid(pipeline);
	}
	if (version.is_valid()) {
		shader.version_free(version);
	}
}
bool RTGIValidation::render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure) {
	if (!p_scene.is_ready() || pipeline.is_null() || p_normals.is_null()) {
		return false;
	}
	const Size2i size = p_buffers->get_internal_size();
	RID output = p_buffers->create_texture(RB_SCOPE_RTGI_VALIDATION, SNAME("diffuse"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT);
	if (output.is_null()) {
		return false;
	}
	RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	LocalVector<RD::Uniform> uniforms;
	p_scene.append_uniforms(uniforms, sampler);
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>{ sampler, p_buffers->get_depth_texture() }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>{ sampler, p_normals }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, output));
	RID set = UniformSetCacheRD::get_singleton()->get_cache_vec(shader.version_get_shader(version, 0), 0, uniforms);
	if (set.is_null()) {
		return false;
	}
	PushConstant push = {};
	MaterialStorage::store_camera((p_projection * Projection(p_camera.affine_inverse())).inverse(), push.inv_view_projection);
	Quaternion rotation = p_camera.basis.get_rotation_quaternion();
	push.camera_rotation[0] = rotation.x;
	push.camera_rotation[1] = rotation.y;
	push.camera_rotation[2] = rotation.z;
	push.camera_rotation[3] = rotation.w;
	for (int axis = 0; axis < 3; axis++) {
		push.camera_position[axis] = p_camera.origin[axis];
	}
	push.size[0] = size.x;
	push.size[1] = size.y;
	push.samples = CLAMP(int(GLOBAL_GET("rendering/global_illumination/rt_validation/samples_per_pixel")), 1, 4096);
	push.bounces = CLAMP(int(GLOBAL_GET("rendering/global_illumination/rt_validation/bounces")), 1, 8);
	push.max_distance = MAX(float(GLOBAL_GET("rendering/global_illumination/rt_validation/max_distance")), 1.0f);
	push.light_count = p_scene.get_light_count();
	push.exposure = p_exposure;
	RD *rd = RD::get_singleton();
	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, pipeline);
	rd->compute_list_bind_uniform_set(list, set, 0);
	rd->compute_list_set_push_constant(list, &push, sizeof(push));
	rd->compute_list_dispatch_threads(list, size.x, size.y, 1);
	rd->compute_list_end();
	return true;
}
