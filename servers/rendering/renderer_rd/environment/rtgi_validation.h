/**************************************************************************/
/*  rtgi_validation.h                                                     */
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
#include "servers/rendering/renderer_rd/environment/rt_gi_scene.h"
#include "servers/rendering/renderer_rd/shaders/effects/rtgi_validation.glsl.gen.h"
#include "servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.h"
#include "servers/rendering/renderer_scene_render.h"

#define RB_SCOPE_RTGI_VALIDATION SNAME("rtgi_validation")

namespace RendererRD {

// Deliberately uncached, diffuse transport reference for validating the GI port.
// This is not AMD GI-1.x and must not be exposed as a shipping quality preset.
// No temporal history: moving materials/lights cannot leave stale illumination.
class RTGIValidation {
	struct PushConstant {
		float inv_view_projection[16];
		float camera_rotation[4];
		float camera_position[4];
		uint32_t size[2];
		uint32_t samples;
		uint32_t bounces;
		float max_distance;
		uint32_t light_count;
		float exposure;
		uint32_t padding = 0;
	};
	static_assert(sizeof(PushConstant) == 128);

	RtgiValidationShaderRD shader;
	RID version;
	RID pipeline;

public:
	static bool is_enabled();
	bool render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure);
	RTGIValidation();
	~RTGIValidation();
};

} // namespace RendererRD
