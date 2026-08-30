/**************************************************************************/
/*  rt_shadows.h                                                          */
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

#include "core/math/projection.h"
#include "core/math/transform_3d.h"
#include "core/templates/local_vector.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_shadow_atrous.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_shadow_temporal.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_shadow_trace.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Traces shadow rays for the raytraced lights that reach each pixel and
// denoises the result into a screen-space mask. The forward shader samples that
// mask instead of the shadow atlas.
//
// The mask is not a channel per light in the scene. Each pixel keeps the few
// raytraced lights that actually reach it, tile-culled and ranked by
// contribution inside the trace shader, and a companion index texture records
// which lights those are. Cost therefore scales with how many raytraced lights
// overlap a pixel rather than with how many the scene contains.
//
// Everything here is single view: a stereo pair would need a trace and a full
// set of denoiser history per eye, so multiview keeps its shadow maps instead.
//
// The denoiser keeps its own temporal history rather than relying on the
// image's temporal antialiasing, so the result is usable with SMAA or with no
// antialiasing at all.
class RTShadows {
public:
	// Absolute ceiling on raytraced lights in a frame. LightData carries the
	// light's index as a float with 255 reserved to mean "not raytraced", so the
	// indices have to stay below that.
	static constexpr uint32_t MAX_RT_LIGHTS = 255;
	// Raytraced lights kept per pixel, one per channel of the mask. Must match
	// LIGHTS_PER_PIXEL in rt_shadow_trace.glsl.
	static constexpr uint32_t LIGHTS_PER_PIXEL = 4;

	// CPU-side mirror of the shader's RTLight struct. std430 layout.
	struct LightParams {
		float position[3];
		float radius;

		float direction[3];
		float cos_spot_angle;

		float size;
		uint32_t is_spot;
		uint32_t mask;
		float energy;

		// Where the ray starts, in meters. Both come from the light's own shadow
		// bias properties: a raytraced shadow needs far less offset than a shadow
		// map, which has to clear a depth texel, so the properties are scaled
		// down rather than used raw.
		float bias;
		float normal_bias;
		float pad[2];
	};

	// The textures the trace and the denoiser work through. Owned by the render
	// buffers so they follow the viewport's size and lifetime.
	struct Buffers {
		// The mask the forward pass samples, and the light index each of its
		// channels carries.
		RID output_mask;
		RID output_index;
		RID raw_hit_distance;
		RID denoise_a;
		RID denoise_b;
		RID history_visibility;
		RID history_index;
		RID history_meta;
		RID history_length;
	};

	struct Settings {
		uint32_t sample_count = 4;
		float max_ray_distance = 0.0f;
		bool denoise = true;
		uint32_t atrous_iterations = 3;
		float max_history = 32.0f;
	};

private:
	struct TracePushConstant {
		float inv_view_projection[16];

		// Rotates a view space normal into world space. A quaternion because the
		// camera's basis would not fit here alongside the inverse view
		// projection, and the push constant is limited to 128 bytes.
		float camera_rotation[4];

		float camera_position[3];
		float max_ray_distance;

		int32_t screen_size[2];
		uint32_t light_count;
		// Sample count in the low eight bits, frame index above them. Packed for
		// the same reason the rotation is a quaternion.
		uint32_t samples_and_frame;

		// Pixels a one meter object covers at one meter from the camera. Lets the
		// trace report each penumbra's width in pixels, which is the unit the
		// denoiser sizes its filter in.
		float focal_pixels;
		float pad;
	};

	struct TemporalPushConstant {
		float reprojection[16];

		float depth_unproject[4];

		int32_t screen_size[2];
		float depth_tolerance;
		float max_history;
	};

	struct AtrousPushConstant {
		float depth_unproject[4];

		int32_t screen_size[2];
		int32_t step_size;
		uint32_t write_history;

		float depth_sigma;
		float normal_sigma;
		float min_filter_pixels;
		float pad;
	};

	RtShadowTraceShaderRD trace_shader;
	RID trace_shader_version;
	RID trace_pipeline;

	RtShadowTemporalShaderRD temporal_shader;
	RID temporal_shader_version;
	RID temporal_pipeline;

	RtShadowAtrousShaderRD atrous_shader;
	RID atrous_shader_version;
	RID atrous_pipeline;

	RID light_buffer;
	uint32_t light_buffer_capacity = 0;

	bool valid = false;
	uint32_t frame_index = 0;

	void _ensure_light_buffer(uint32_t p_light_count);
	void _trace(RID p_tlas, RID p_depth_texture, RID p_normal_roughness, const Buffers &p_buffers,
			const Size2i &p_size, const Projection &p_inv_view_projection,
			const Transform3D &p_camera_transform, float p_focal_pixels, uint32_t p_light_count,
			const Settings &p_settings);
	void _temporal(RID p_depth_texture, const Buffers &p_buffers, const Size2i &p_size,
			const Projection &p_reprojection, const Projection &p_inv_projection,
			const Settings &p_settings);
	void _atrous(RID p_source, RID p_dest, RID p_depth_texture, RID p_normal_roughness,
			const Buffers &p_buffers, const Size2i &p_size, const Projection &p_inv_projection,
			int p_step_size, bool p_write_history);

public:
	bool is_valid() const { return valid; }

	// The previous camera is what the denoiser reprojects its history with. Motion
	// vectors would be the obvious source, but they are written by the opaque
	// pass, which runs after the mask is needed.
	void render(RID p_tlas, RID p_depth_texture, RID p_normal_roughness,
			const Buffers &p_buffers, const Size2i &p_screen_size,
			const Projection &p_camera_projection, const Transform3D &p_camera_transform,
			const Projection &p_prev_camera_projection, const Transform3D &p_prev_camera_transform,
			const LocalVector<LightParams> &p_lights, const Settings &p_settings);

	RTShadows();
	~RTShadows();
};

} //namespace RendererRD
