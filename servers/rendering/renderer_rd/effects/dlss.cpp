/**************************************************************************/
/*  dlss.cpp                                                              */
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

#include "dlss.h"

#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#ifdef STREAMLINE_ENABLED

using namespace RendererRD;

DLSSEffect::DLSSEffect() {
	Vector<String> single;
	single.push_back("");
	reactive_shader.initialize(single);
	reactive_shader_version = reactive_shader.version_create();
	RID compiled = reactive_shader.version_get_shader(reactive_shader_version, 0);
	if (compiled.is_valid()) {
		reactive_pipeline = RD::get_singleton()->compute_pipeline_create(compiled);
	}
}

DLSSEffect::~DLSSEffect() {
	if (reactive_shader_version.is_valid()) {
		reactive_shader.version_free(reactive_shader_version);
	}
}

bool DLSSEffect::build_reactive_mask(RID p_color, RID p_dest, const Size2i &p_size, float p_scale) {
	if (!reactive_pipeline.is_valid() || p_color.is_null() || p_dest.is_null() || p_size.x <= 0 || p_size.y <= 0) {
		return false;
	}

	RendererRD::MaterialStorage *material_storage = RendererRD::MaterialStorage::get_singleton();
	RID nearest = material_storage->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);

	RD::Uniform source;
	source.uniform_type = RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE;
	source.binding = 0;
	source.append_id(nearest);
	source.append_id(p_color);

	RD::Uniform dest;
	dest.uniform_type = RD::UNIFORM_TYPE_IMAGE;
	dest.binding = 1;
	dest.append_id(p_dest);

	RID compiled = reactive_shader.version_get_shader(reactive_shader_version, 0);
	RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache(compiled, 0, source, dest);

	ReactivePushConstant push = {};
	push.size[0] = p_size.x;
	push.size[1] = p_size.y;
	push.scale = p_scale;

	RD::ComputeListID list = RD::get_singleton()->compute_list_begin();
	RD::get_singleton()->compute_list_bind_compute_pipeline(list, reactive_pipeline);
	RD::get_singleton()->compute_list_bind_uniform_set(list, uniform_set, 0);
	RD::get_singleton()->compute_list_set_push_constant(list, &push, sizeof(push));
	RD::get_singleton()->compute_list_dispatch_threads(list, p_size.x, p_size.y, 1);
	RD::get_singleton()->compute_list_end();
	return true;
}

bool DLSSEffect::is_available() {
	StreamlineVK *streamline = StreamlineVK::get_singleton();
	return streamline != nullptr && streamline->is_supported(StreamlineVK::FEATURE_DLSS_SUPER_RESOLUTION);
}

void DLSSEffect::upscale(const Parameters &p_params) {
	if (!is_available()) {
		return;
	}

	CallbackArgs *args = args_allocator.alloc();
	args->owner = this;
	args->viewport = p_params.viewport;
	args->output_size = p_params.target_size;
	args->quality = StreamlineVK::quality_from_scale(p_params.scale);
	args->preset = p_params.preset;
	args->upscale_alpha = p_params.transparent;

	args->camera.view_to_clip = p_params.view_to_clip;
	args->camera.clip_to_view = p_params.clip_to_view;
	args->camera.clip_to_prev_clip = p_params.clip_to_prev_clip;
	args->camera.prev_clip_to_clip = p_params.prev_clip_to_clip;
	args->camera.camera_transform = p_params.camera_transform;
	args->camera.jitter_pixels = p_params.jitter;
	args->camera.z_near = p_params.z_near;
	args->camera.z_far = p_params.z_far;
	args->camera.fov_y = p_params.fov_y;
	args->camera.aspect = p_params.aspect;
	args->camera.reset = p_params.reset_accumulation;
	args->camera.orthographic = p_params.orthographic;

	// The colour, depth and velocity buffers are allocated at the internal size, so this covers
	// the whole of each of them. It is stated rather than left implicit so that the resolution
	// Streamline upscales from stays tied to the renderer's internal size even if one of those
	// buffers is ever allocated larger than the region actually rendered. The output carries no
	// extent: it is the full upscaled image.
	const Rect2i internal_rect(Point2i(), p_params.internal_size);

	args->inputs.color = StreamlineVK::texture_from_rid(p_params.color, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.color.extent = internal_rect;
	args->inputs.depth = StreamlineVK::texture_from_rid(p_params.depth, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.depth.extent = internal_rect;
	args->inputs.motion_vectors = StreamlineVK::texture_from_rid(p_params.velocity, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.motion_vectors.extent = internal_rect;
	args->inputs.exposure = StreamlineVK::texture_from_rid(p_params.exposure, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.reactive = StreamlineVK::texture_from_rid(p_params.reactive, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.reactive.extent = internal_rect;
	args->inputs.output = StreamlineVK::texture_from_rid(p_params.output, StreamlineVK::TEXTURE_USE_STORAGE);

	// These usages are what put the images into the layouts `texture_from_rid` promised above;
	// the two lists have to agree.
	LocalVector<RD::CallbackResource> resources;
	resources.push_back({ p_params.color, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	resources.push_back({ p_params.depth, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	resources.push_back({ p_params.velocity, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	if (p_params.exposure.is_valid()) {
		resources.push_back({ p_params.exposure, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	}
	if (p_params.reactive.is_valid()) {
		resources.push_back({ p_params.reactive, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	}
	resources.push_back({ p_params.output, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_STORAGE_IMAGE_READ_WRITE });

	RD::get_singleton()->driver_callback_add((RDD::DriverCallback)DLSSEffect::callback, args, VectorView<RD::CallbackResource>(resources.ptr(), resources.size()));
}

void DLSSEffect::callback(RDD *p_driver, RDD::CommandBufferID p_command_buffer, CallbackArgs *p_userdata) {
	StreamlineVK *streamline = StreamlineVK::get_singleton();
	if (streamline != nullptr) {
		streamline->super_resolution_evaluate(p_command_buffer.id, p_userdata->viewport, p_userdata->output_size, p_userdata->quality, p_userdata->preset, p_userdata->upscale_alpha, p_userdata->camera, p_userdata->inputs);
	}
	p_userdata->owner->args_allocator.free(p_userdata);
}

bool DLSSFrameGeneration::is_available() {
	StreamlineVK *streamline = StreamlineVK::get_singleton();
	return streamline != nullptr && streamline->is_supported(StreamlineVK::FEATURE_DLSS_FRAME_GENERATION);
}

bool DLSSFrameGeneration::update(const Parameters &p_params) {
	StreamlineVK *streamline = StreamlineVK::get_singleton();
	if (streamline == nullptr) {
		return false;
	}

	if (!streamline->frame_generation_set_enabled(p_params.viewport, p_params.enabled, p_params.output_size, p_params.internal_size)) {
		return false;
	}

	// Ordered before the callback below by the render graph, so the copy has landed by the time
	// the tag is recorded. Only reached while frame generation is running, so a project that
	// leaves the feature off never allocates the target or pays for the copy.
	streamline->frame_generation_capture_hudless(p_params.viewport, p_params.hudless_source, p_params.output_size);

	const RID hudless = streamline->frame_generation_get_hudless(p_params.viewport);

	CallbackArgs *args = memnew(CallbackArgs);
	args->viewport = p_params.viewport;

	args->camera.view_to_clip = p_params.view_to_clip;
	args->camera.clip_to_view = p_params.clip_to_view;
	args->camera.clip_to_prev_clip = p_params.clip_to_prev_clip;
	args->camera.prev_clip_to_clip = p_params.prev_clip_to_clip;
	args->camera.camera_transform = p_params.camera_transform;
	args->camera.jitter_pixels = p_params.jitter;
	args->camera.z_near = p_params.z_near;
	args->camera.z_far = p_params.z_far;
	args->camera.fov_y = p_params.fov_y;
	args->camera.aspect = p_params.aspect;
	args->camera.reset = p_params.reset_accumulation;
	args->camera.orthographic = p_params.orthographic;

	const Rect2i internal_rect(Point2i(), p_params.internal_size);
	args->inputs.depth = StreamlineVK::texture_from_rid(p_params.depth, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.depth.extent = internal_rect;
	args->inputs.motion_vectors = StreamlineVK::texture_from_rid(p_params.velocity, StreamlineVK::TEXTURE_USE_SAMPLED);
	args->inputs.motion_vectors.extent = internal_rect;
	args->inputs.hudless_color = StreamlineVK::texture_from_rid(hudless, StreamlineVK::TEXTURE_USE_SAMPLED);

	// Declaring them here is what leaves all three in the layout the tags claim, and nothing
	// else touches them between now and the present that reads them.
	LocalVector<RD::CallbackResource> resources;
	resources.push_back({ p_params.depth, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	resources.push_back({ p_params.velocity, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	if (hudless.is_valid()) {
		resources.push_back({ hudless, RD::CALLBACK_RESOURCE_TYPE_TEXTURE, RD::CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE });
	}

	RD::get_singleton()->driver_callback_add((RDD::DriverCallback)DLSSFrameGeneration::callback, args, VectorView<RD::CallbackResource>(resources.ptr(), resources.size()));
	return true;
}

void DLSSFrameGeneration::callback(RDD *p_driver, RDD::CommandBufferID p_command_buffer, CallbackArgs *p_userdata) {
	StreamlineVK *streamline = StreamlineVK::get_singleton();
	if (streamline != nullptr) {
		streamline->frame_generation_tag(p_command_buffer.id, p_userdata->viewport, p_userdata->camera, p_userdata->inputs);
	}
	memdelete(p_userdata);
}

#endif // STREAMLINE_ENABLED
