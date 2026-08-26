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
#include "servers/rendering/renderer_rd/shaders/effects/rt_shadow_trace.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Traces one shadow ray set per pixel per raytraced light and writes the result
// into an RGBA8 screen-space mask, one channel per light. The forward shader
// samples that mask instead of the shadow atlas.
class RTShadows {
public:
	// Maximum number of lights that can be packed into the mask.
	static constexpr uint32_t MAX_RT_LIGHTS = 4;

	// CPU-side mirror of the shader's RTLight struct. std140 layout.
	struct LightParams {
		float position[3];
		float radius;

		float direction[3];
		float cos_spot_angle;

		float size;
		uint32_t is_spot;
		uint32_t mask;
		float pad;
	};

private:
	struct PushConstant {
		float inv_view_projection[16];

		int32_t screen_size[2];
		uint32_t light_count;
		uint32_t sample_count;

		float camera_position[3];
		float max_ray_distance;

		float bias;
		float normal_bias;
		uint32_t frame_index;
		float pad;
	};

	RtShadowTraceShaderRD shader;
	RID shader_version;
	RID pipeline;

	RID light_buffer;

	bool valid = false;
	uint32_t frame_index = 0;

public:
	bool is_valid() const { return valid; }

	void render(RID p_tlas, RID p_depth_texture, RID p_dest_mask,
			const Size2i &p_screen_size, const Projection &p_camera_projection,
			const Transform3D &p_camera_transform, const LocalVector<LightParams> &p_lights,
			uint32_t p_sample_count, float p_max_ray_distance);

	RTShadows();
	~RTShadows();
};

} //namespace RendererRD
