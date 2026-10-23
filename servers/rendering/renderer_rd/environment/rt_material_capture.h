/**************************************************************************/
/*  rt_material_capture.h                                                 */
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

#include "core/io/image.h"
#include "core/math/transform_3d.h"
#include "core/variant/typed_array.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// Explicit, bounded, GPU material capture. No resources exist until capture().
// A page represents a contiguous triangle range, independent of source UV layout.
// Capture runs on the rendering thread before scene render lists are prepared.
class RaytracingMaterialCapture {
	RID mesh;
	bool uses_expansion = false;
	RID source_mesh;
	int source_surface = -1;
	RID capture_buffer;
	RID framebuffer;
	Vector<RID> textures;
	Size2i size;
	uint32_t triangle_count = 0;
	uint64_t memory_usage = 0;
	struct CaptureInfo {
		uint32_t layout_info[4] = {};
		float color[4] = { 1, 1, 1, 1 };
		float custom[4] = {};
		uint32_t instance_info[4] = {};
	} capture_info;
	static_assert(sizeof(CaptureInfo) == 64);

public:
	static constexpr int MAX_TRIANGLES = 1024;
	static constexpr int MAX_TILE_SIZE = 64;
	RaytracingMaterialCapture() = default;
	RaytracingMaterialCapture(const RaytracingMaterialCapture &) = delete;
	RaytracingMaterialCapture &operator=(const RaytracingMaterialCapture &) = delete;
	Error capture(RID p_mesh, int p_surface, int p_first_triangle, int p_triangle_count, int p_tile_size, const Transform3D &p_transform, RID p_material_override, int32_t p_instance_uniforms_offset = -1);
	// Retain immutable expanded geometry and render current material state into it.
	// The caller must re-prepare after source geometry changes.
	Error prepare(RID p_mesh, int p_surface, int p_first_triangle, int p_triangle_count, int p_tile_size);
	Error render(const Transform3D &p_transform, RID p_material_override, int32_t p_instance_uniforms_offset = -1, RID p_mesh_instance = RID(), const Color &p_color = Color(1, 1, 1, 1), const Color &p_custom = Color(0, 0, 0, 0), uint32_t p_element = 0);
	RID get_texture(int p_index) const;
	Size2i get_size() const { return size; }
	uint64_t get_memory_usage() const { return memory_usage; }
	uint32_t get_triangle_count() const { return triangle_count; }
	TypedArray<Image> readback() const;
	void clear();
	~RaytracingMaterialCapture() { clear(); }
};

} // namespace RendererRD
