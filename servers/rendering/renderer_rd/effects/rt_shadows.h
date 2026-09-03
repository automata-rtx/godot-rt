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

	// What a record's type-dependent fields mean. Must match the LIGHT_TYPE_
	// defines in rt_shadow_trace.glsl.
	enum LightType : uint32_t {
		LIGHT_TYPE_OMNI = 0,
		LIGHT_TYPE_SPOT = 1,
		LIGHT_TYPE_DIRECTIONAL = 2,
	};

	// CPU-side mirror of the shader's RTLight struct. std430 layout.
	//
	// A directional light shares this record, and the same per pixel competition
	// for the mask's four channels, with every lamp. It has no position and no
	// metric range, so it reinterprets four fields rather than needing its own;
	// `light_type` says which reading applies. Keeping one record means the trace
	// keeps one cull, one selection and one ray loop.
	struct LightParams {
		// Omni and spot: the light's world position. Directional: the camera's,
		// which is what the sun's receiver range is measured from.
		float position[3];
		// Omni and spot: the light's world range. Directional: the furthest view
		// depth at which the culler still gathered casters, which is where the
		// shadow has to have faded out. Positive for any live light either way,
		// which is what lets the trace treat a zero radius as an unused slot.
		float radius;

		// Omni and spot: the direction the light points, away from it.
		// Directional: the direction TOWARD the light, which is the ray's own.
		// World space in both cases.
		float direction[3];
		float cos_spot_angle;

		// Omni and spot: the emitter's radius in meters. Directional: the tangent
		// of the angular radius, which is the same thing per unit of distance.
		float size;
		uint32_t light_type;
		uint32_t mask;
		float energy;

		// Where the ray starts, in meters. Both come from the light's own shadow
		// bias properties: a raytraced shadow needs far less offset than a shadow
		// map, which has to clear a depth texel, so the properties are scaled
		// down rather than used raw.
		float bias;
		float normal_bias;

		// Directional only, and both in view depth. Where the shadow starts fading
		// out, and how long a ray may be. The fade matches the one the cascade
		// path applies, so a sun that gives up its shadow map hands over at the
		// same distance it always did.
		float fade_from;
		float max_ray_length;
	};
	static_assert(sizeof(LightParams) == 64, "RTLight and LightParams must agree.");

	// The textures the trace and the denoiser work through. Owned by the render
	// buffers so they follow the viewport's size and lifetime.
	struct Buffers {
		// The mask the forward pass samples, and the light index each of its
		// channels carries.
		RID output_mask;
		RID output_index;
		// Per light penumbra width in pixels, divided by MAX_PENUMBRA_PIXELS so it
		// fits eight bits. Named for the mean blocker distance it is derived from.
		RID raw_hit_distance;
		RID denoise_a;
		RID denoise_b;
		RID history_visibility;
		RID history_index;
		RID history_meta;
		RID history_length;
	};

	struct Settings {
		// Every field here is overwritten from the project settings before a
		// frame uses it. The values are the shipped defaults, so that a reader
		// and the inspector agree.
		uint32_t sample_count = 1;
		float max_ray_distance = 0.0f;
		bool denoise = true;
		uint32_t atrous_iterations = 3;
		float max_history = 32.0f;
		// Narrowest the spatial filter is allowed to reach where a penumbra was
		// measured, in pixels. At or below one pixel the floor lets no neighbor
		// contribute, because the nearest tap already sits a pixel away, which is
		// what keeps a contact shadow crisp.
		float min_filter_pixels = 1.0f;
		// How far outside the current frame's local spread a reprojected history
		// sample may sit before it is pulled back in, in standard deviations.
		// Zero disables the test and restores the old, freely trailing behavior.
		float history_clamp_sigma = 2.0f;
		// How much of the clamp's own correction sets the blend weight directly.
		// Zero leaves only the window shortening, which is what shipped before.
		float lag_response = 1.0f;
		// Whether a shadow ray must find the CLOSEST occluder rather than stopping
		// at the first one traversal reaches. Visibility is the same either way;
		// the distance, which is what sizes the penumbra, is not.
		bool accurate_occluder_distance = true;
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
		// Traversal flags for the shadow rays. Runtime rather than baked in so the
		// accuracy of the occluder distance can be traded for traversal speed
		// without a second pipeline.
		uint32_t ray_flags;
	};

	struct TemporalPushConstant {
		float reprojection[16];

		float depth_unproject[4];

		int32_t screen_size[2];
		float depth_tolerance;
		float max_history;

		float clamp_sigma;
		float lag_response;
		float sample_count;
		uint32_t frame_index;
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

	// Each of these must be exactly the size its shader's push constant block
	// reflects to, and a mismatch is not a partial one: RenderingDevice compares
	// the pushed size against the reflected size and rejects the whole push
	// constant when they differ (rendering_device.cpp, compute_list_set_push
	// _constant), so the dispatch then runs with no parameters at all -- or, in a
	// debug build, does not run. That failure is silent in the frame and shows up
	// only as whatever the unwritten target already held.
	//
	// The assertions below catch a field added or removed on THIS side. Nothing
	// can catch it on the shader side, so when a field is added there, add it
	// here and update the size:
	//   TracePushConstant    <-> shaders/effects/rt_shadow_trace.glsl
	//   TemporalPushConstant <-> shaders/effects/rt_shadow_temporal.glsl
	//   AtrousPushConstant   <-> shaders/effects/rt_shadow_atrous.glsl
	// glslangValidator -V <shader> -q prints "Params: ... size N" for the block.
	static_assert(sizeof(TracePushConstant) == 120, "TracePushConstant must match rt_shadow_trace.glsl");
	static_assert(sizeof(TemporalPushConstant) == 112, "TemporalPushConstant must match rt_shadow_temporal.glsl");
	static_assert(sizeof(AtrousPushConstant) == 48, "AtrousPushConstant must match rt_shadow_atrous.glsl");

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
			int p_step_size, bool p_write_history, float p_min_filter_pixels);

public:
	bool is_valid() const { return valid; }

	// The previous camera is what the denoiser reprojects its history with. Motion
	// vectors would be the obvious source, but they are written by the opaque
	// pass, which runs after the mask is needed.
	// False when nothing was written to the mask, which obliges the caller to
	// put a fully lit one there: an untouched mask is a fully occluded one.
	bool render(RID p_tlas, RID p_depth_texture, RID p_normal_roughness,
			const Buffers &p_buffers, const Size2i &p_screen_size,
			const Projection &p_camera_projection, const Transform3D &p_camera_transform,
			const Projection &p_prev_camera_projection, const Transform3D &p_prev_camera_transform,
			const LocalVector<LightParams> &p_lights, const Settings &p_settings);

	RTShadows();
	~RTShadows();
};

} //namespace RendererRD
