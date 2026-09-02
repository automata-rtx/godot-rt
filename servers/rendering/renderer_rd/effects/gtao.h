/**************************************************************************/
/*  gtao.h                                                                */
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
#include "servers/rendering/renderer_rd/shaders/effects/gtao_filter.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/effects/gtao_gather.glsl.gen.h"
#include "servers/rendering/renderer_rd/shaders/effects/gtao_prefilter.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Ground truth ambient occlusion with a visibility bitmask, as an alternative to
// the Intel screen space occlusion the engine has always shipped.
//
// It writes into the same buffer that one does, so everything downstream --
// the occlusion channel the forward shader multiplies ambient light by, the
// near field bounce approximation applied on top of it, light affect, specular
// occlusion -- keeps working without knowing which method produced the value.
//
// Three passes. A depth prefilter builds a linear view depth pyramid; the
// gather marches slices against it and resolves each one from a 32 sector
// occupancy mask; a filter pass denoises and, when the gather ran at reduced
// resolution, weights the result back up to full resolution against the depth
// each texel was computed on.
//
// The gather resolution changes how many pixels get their own answer and
// nothing else: the march reach, its first step and the fade are all derived
// from the full resolution pixel footprint, so halving the resolution thins the
// far field rather than pulling the near field apart.
class GTAO {
public:
	// Levels in the linear depth pyramid. A march only reaches a coarser level
	// once its step is far enough out that the full resolution texels it skips
	// could not have mattered, so five covers the widest radius worth marching.
	static constexpr uint32_t DEPTH_MIP_COUNT = 5;

	struct Settings {
		float radius = 1.0f;
		// Fraction of the effect radius a sample's back face sits behind it.
		float thickness = 0.3f;
		float intensity = 2.0f;
		float power = 1.5f;
		float fade_from = 50.0f;
		float fade_to = 300.0f;
		int slice_count = 4;
		int steps_per_slice = 8;
		// Hold the march to a fixed share of the screen at every depth rather
		// than to a fixed distance in the world. Without it the on-screen span
		// shrinks with distance until the steps land on the same texel and the
		// occlusion quietly disappears.
		bool scale_radius_with_distance = true;
		float screen_radius = 0.05f;
		bool use_bitmask = true;
		bool half_resolution = true;
	};

	struct Buffers {
		// Full internal resolution, five mips, not deinterleaved.
		RID depth_pyramid;
		RID depth_mips[DEPTH_MIP_COUNT];
		// Gather resolution, (occlusion, view depth).
		RID ao_a;
		RID ao_b;
		Size2i gather_size;
	};

	GTAO();
	~GTAO();

	bool is_valid() const { return valid; }

	static Size2i gather_size_for(const Size2i &p_full_size, bool p_half_resolution);

	void render(const Buffers &p_buffers, RID p_depth_texture, RID p_normal_roughness,
			RID p_dest_ao, const Size2i &p_full_size, const Projection &p_projection,
			const Settings &p_settings);

private:
	struct PrefilterPushConstant {
		int32_t screen_size[2];

		float linearize_mul;
		float linearize_add;

		float falloff_mul;
		float falloff_add;

		uint32_t orthogonal;
		uint32_t pad;
	};

	struct GatherPushConstant {
		int32_t gather_size[2];
		int32_t full_size[2];

		float uv_to_view_mul[2];
		float uv_to_view_add[2];

		float radius;
		float thickness;
		float power;
		float intensity;

		float fade_from;
		float fade_inv_span;
		int32_t slice_count;
		int32_t steps_per_slice;

		uint32_t scale_radius_with_distance;
		float screen_radius;
		uint32_t orthogonal;
		uint32_t use_bitmask;

		// Full resolution pixels per gather texel, per axis. Passed rather than
		// recovered in the shader: gather_size_for rounds UP and an integer
		// division rounds DOWN, so at an odd width the two disagree.
		int32_t gather_stride[2];
		uint32_t pad0;
		uint32_t pad1;
	};

	struct FilterPushConstant {
		int32_t source_size[2];
		int32_t dest_size[2];

		float depth_tolerance;
		float weight_floor;
		// Full resolution pixels per gather texel, per axis; the upsample needs it
		// to invert the gather's sampling position without half a pixel of error.
		int32_t gather_stride[2];
	};

	enum FilterMode {
		FILTER_MODE_DENOISE,
		FILTER_MODE_UPSAMPLE,
		FILTER_MODE_MAX,
	};

	GtaoPrefilterShaderRD prefilter_shader;
	RID prefilter_shader_version;
	RID prefilter_pipeline;

	GtaoGatherShaderRD gather_shader;
	RID gather_shader_version;
	RID gather_pipeline;

	GtaoFilterShaderRD filter_shader;
	RID filter_shader_version;
	RID filter_pipeline[FILTER_MODE_MAX];

	bool valid = false;
};

} // namespace RendererRD
