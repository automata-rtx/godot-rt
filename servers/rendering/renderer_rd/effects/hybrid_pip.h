/**************************************************************************/
/*  hybrid_pip.h                                                          */
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

#include "core/object/ref_counted.h"
#include "servers/rendering/renderer_rd/hybrid_pip_layout.h"
#include "servers/rendering/renderer_rd/shaders/effects/hybrid_pip.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Composes two already-lit regions, then applies the peripheral presentation
// blur. Neither output belongs in GI's unblurred outgoing-lighting feedback.
class HybridPiP {
public:
	static constexpr uint32_t MAX_APERTURE_VERTICES = 16;
	static constexpr uint32_t BLUR_TAPS = 16;

	// One owner per logical camera, retained across ADS transitions. In particular,
	// never share this mutable UBO between independently queued views.
	struct HybridPiPViewData : public RefCounted {
		GDCLASS(HybridPiPViewData, RefCounted);

	private:
		friend class HybridPiP;
		RID aperture_uniform;
		bool pyramid_warmed = false;

	public:
		~HybridPiPViewData();
	};

	struct Inputs {
		RID background_color;
		RID background_depth;
		RID native_color;
		RID native_depth;
		// Valid content begins at (0, 0); texture allocations may be larger.
		// A temporal upscaler can produce more color samples than depth samples.
		Size2i background_color_size;
		Size2i background_depth_size;
		Size2i native_color_size;
		Size2i native_depth_size;
	};

	struct Outputs {
		// The three outputs must not alias each other or any input. The pyramid
		// and its mip views deliberately share composed_color's allocation.
		RID composed_color; // RGBA16F, linear HDR.
		RID composed_depth; // R32F, the original reverse-Z device depth.
		RID blurred_color; // RGBA16F parent target, borrowed; never freed here.
		RID color_pyramid; // Full mip-chain view; mip zero is composed_color.
		Vector<RID> color_mips; // Prepared, single-level views, including mip zero.
	};

	struct Settings {
		bool blur_enabled = true;
		bool magnify_aperture = false;
		// Optional output footprint of the reconstructed image when only the
		// glass receives native-region samples. The housing uses the background.
		Rect2i lens_only_coverage;
		bool preview_resolve = false;
		// Output pixels at 720p, scaled proportionally with output height.
		float near_radius = 2.0f;
		float far_radius = 10.72f;
		float near_distance = 0.12f;
		float far_distance = 25.0f;
	};

	HybridPiP();
	~HybridPiP();
	bool is_valid() const { return valid; }
	static uint32_t get_blur_mip_count(const Size2i &p_size);

	// Call during preparation. render() never creates this buffer or output images.
	bool prepare(Ref<HybridPiPViewData> &r_data);
	bool filter_fxaa(RID p_source, RID p_destination, const Size2i &p_size, float p_luma_scale);
	// Parent inverse projection must include Vulkan reverse-Z/Y correction and
	// jitter, matching the source depths. Aperture vertices are ordered polygon
	// vertices in parent-output UV (top-left origin), without a repeated endpoint.
	// It may extend off screen. An empty polygon is allowed only with blur disabled.
	bool render(const Ref<HybridPiPViewData> &p_data, const Inputs &p_inputs, const Outputs &p_outputs,
			const HybridPiPLayout &p_layout, const Projection &p_inverse_parent_projection,
			const Vector<Vector2> &p_aperture, const Settings &p_settings);

private:
	enum Mode {
		MODE_COMPOSE,
		MODE_BLUR,
		MODE_DOWNSAMPLE,
		MODE_BACKGROUND_FXAA,
		MODE_COUNT,
	};
	struct ComposePushConstant {
		float depth_unproject[4];
		int32_t output_size[2];
		int32_t background_color_size[2];
		int32_t background_depth_size[2];
		int32_t native_color_size[2];
		int32_t native_depth_size[2];
		int32_t crop_position[2];
		int32_t crop_size[2];
		int32_t protected_position[2];
		int32_t protected_size[2];
		float lens_center[2];
		float lens_radius;
		uint32_t lens_vertex_count;
		int32_t source_offset[2];
		uint32_t preview_resolve;
		uint32_t lens_only;
	};
	struct BlurPushConstant {
		float depth_unproject[4];
		int32_t output_size[2];
		uint32_t aperture_count;
		uint32_t blur_enabled;
		float blur_range[4]; // Near/far radius, near/far view distance.
		float aperture_feather[2];
	};
	struct ApertureUniform {
		float vertices[MAX_APERTURE_VERTICES][4];
		float disk[BLUR_TAPS][4]; // Unit-disk XY and Gaussian weight.
	};
	static_assert(sizeof(ComposePushConstant) == 120);
	static_assert(sizeof(BlurPushConstant) == 56);
	static_assert(sizeof(ApertureUniform) == 512);

	HybridPipShaderRD shader;
	RID shader_version;
	RID pipelines[MODE_COUNT];
	bool valid = false;
};

} // namespace RendererRD
