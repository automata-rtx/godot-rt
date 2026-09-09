/**************************************************************************/
/*  screen_space_shadows.h                                                */
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
#include "core/math/vector3.h"
#include "servers/rendering/renderer_rd/shaders/effects/screen_space_shadow.glsl.gen.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Screen space shadows for one directional light, marched over the depth
// pre-pass buffer.
//
// This exists because geometry that is deliberately absent from the ray tracing
// acceleration structure still needs to shadow itself. Grass is the case it was
// built for: a field of blades is cheap to draw and ruinous to keep in the
// structure, since every blade is a per-frame CPU cost in the caster gather, so
// it is taken out and its contact shadows come from here instead.
//
// The technique is Bend Studio's. Rather than each pixel marching its own ray,
// a workgroup of WAVE_SIZE threads is laid out ALONG one light ray, reads the
// depths on that line once into shared memory, and then every thread on the
// line tests itself against all of them. The CPU half decides how many such
// wavefronts a light needs and where each starts, and is vendored at
// thirdparty/bend_sss with no changes but the line endings and trailing
// whitespace this repository normalizes; the shader is a port to RD GLSL.
//
// What it can and cannot do follows from being screen space, and neither is a
// bug to be fixed:
//
//  - It only shadows from occluders that are on screen and in front. Grass just
//    off the top of the viewport casts nothing, so shadows appear as the camera
//    turns toward their caster.
//  - Shadow length is bounded in PIXELS by the quality tier's sample count, not
//    in world units. A low sun wants shadows far longer than any affordable
//    sample count reaches, which is what the tier's fade-out samples are for.
//
// Single view only, like the rest of the fork's shadow work: a stereo pair would
// need a dispatch and a target per eye.
class ScreenSpaceShadows {
public:
	// Sample count per pixel, which is what sets both the cost and the maximum
	// shadow length. One compiled variant each; the sample loops are unrolled, so
	// the count cannot be a uniform.
	enum Quality {
		QUALITY_LOW,
		QUALITY_MEDIUM,
		QUALITY_HIGH,
		QUALITY_MAX,
	};

	// Bend's own visualizations, which are the intended way to bring the pass up
	// on new hardware or a new projection convention. The wave index is the one
	// to reach for first: it draws the wavefront layout, and if the light
	// coordinate is wrong the pattern will not converge on the light.
	enum DebugView {
		DEBUG_VIEW_DISABLED,
		DEBUG_VIEW_EDGE_MASK,
		DEBUG_VIEW_THREAD_INDEX,
		DEBUG_VIEW_WAVE_INDEX,
		DEBUG_VIEW_MAX,
	};

	struct Settings {
		// Defaults are Bend's recommended starting values, so a reader here and
		// the inspector agree.
		Quality quality = QUALITY_MEDIUM;
		// Assumed thickness of each pixel for casting, as a fraction of the
		// non-linear depth remaining between the sample and the far plane. Scale
		// it in multiples of two, and scale bilinear_threshold with it.
		float surface_thickness = 0.005f;
		// How different two neighboring depths must be to count as an edge and
		// suppress interpolation. Tune with DEBUG_VIEW_EDGE_MASK.
		float bilinear_threshold = 0.02f;
		// Boost applied to the transition in and out of shadow. Values below one
		// are meaningless; the shader clamps the result either way.
		float contrast = 4.0f;
		// Whether a detected edge is excluded from casting. Off by default, and it
		// should probably stay off for foliage: Bend note that it thins otherwise
		// valid shadows exactly at foliage edges, which is the geometry this pass
		// exists to serve.
		bool ignore_edge_pixels = false;
		DebugView debug_view = DEBUG_VIEW_DISABLED;
	};

	ScreenSpaceShadows();
	~ScreenSpaceShadows();

	bool is_valid() const { return valid; }

	// The single channel target this writes needs to be a storage image, which is
	// not guaranteed for eight bit formats without shaderStorageImageExtendedFormats.
	static bool is_target_format_supported();
	static RD::DataFormat get_target_format() { return RD::DATA_FORMAT_R8_UNORM; }

	// Writes visibility for one directional light into p_output.
	//
	// p_light_direction_view is the direction TOWARD the light, in view space --
	// exactly the vector LightStorage puts in DirectionalLightData::direction for
	// a directional light. Note that a directional light's stored direction is
	// not the one omni and spot lights store: it is built from the light basis's
	// +Z rather than its -Z (light_storage.cpp, the LIGHT_DIRECTIONAL case),
	// so it already points back at the sun and must not be negated again.
	//
	// p_camera_projection must be the corrected, jittered projection the depth
	// buffer was actually rasterized with, not the raw camera one.
	//
	// Returns false without touching p_output if there is nothing to do.
	bool render(RID p_depth_texture, RID p_output, const Size2i &p_size,
			const Projection &p_camera_projection, const Vector3 &p_light_direction_view,
			const Settings &p_settings);

private:
	// Must be exactly the size screen_space_shadow.glsl's push constant block
	// reflects to. Under DEBUG_ENABLED, which is every editor build,
	// RenderingDevice rejects a push constant whose size differs from the
	// reflected block and then refuses the dispatch for having none -- so the
	// pass silently stops running and shows whatever its target already held.
	// Without DEBUG_ENABLED neither check is compiled and the difference is
	// simply never read, which is why this can be invisible in a shipped game and
	// fatal in the editor it was built in. See the note in rt_shadows.h for how
	// to read a block's reflected size back out of glslang.
	struct PushConstant {
		float light_coordinate[4];

		int32_t wave_offset[2];
		int32_t screen_size[2];

		float inv_depth_texture_size[2];
		float depth_bounds[2];

		float surface_thickness;
		float bilinear_threshold;
		float shadow_contrast;
		float far_depth_value;

		float near_depth_value;
		uint32_t flags;
	};
	static_assert(sizeof(PushConstant) == 72, "PushConstant must match screen_space_shadow.glsl");

	// Must match the FLAG_ defines in screen_space_shadow.glsl.
	enum Flags : uint32_t {
		FLAG_IGNORE_EDGE_PIXELS = 1 << 0,
		FLAG_USE_PRECISION_OFFSET = 1 << 1,
		FLAG_BILINEAR_SAMPLING_OFFSET_MODE = 1 << 2,
		FLAG_USE_EARLY_OUT = 1 << 3,
		FLAG_DEBUG_EDGE_MASK = 1 << 4,
		FLAG_DEBUG_THREAD_INDEX = 1 << 5,
		FLAG_DEBUG_WAVE_INDEX = 1 << 6,
	};

	ScreenSpaceShadowShaderRD shader;
	RID shader_version;
	RID pipelines[QUALITY_MAX];

	// Point sampled and clamped to a border of the far depth value. The march
	// reads off screen deliberately and those reads have to come back as "nothing
	// here"; an edge-clamped sampler smears the border texel outward instead and
	// produces shadows that stream in from the sides of the screen.
	RID depth_sampler;

	bool valid = false;
};

} //namespace RendererRD
