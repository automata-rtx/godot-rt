/**************************************************************************/
/*  hybrid_pip_layout.h                                                   */
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
#include "core/math/rect2i.h"
#include "core/math/vector2.h"

#include <cstdint>

namespace RendererRD {

// Coordinate-only contract: this owns no rendering resources and does not
// decide whether any temporal sample remains valid after reprojection.
struct HybridPiPRegion {
	Size2i parent_size;
	Rect2i output_rect;
	Size2i render_size;
	Size2i allocation_size;

	bool is_valid() const {
		return parent_size.x > 0 && parent_size.y > 0 && output_rect.size.x > 0 && output_rect.size.y > 0 &&
				output_rect.position.x >= 0 && output_rect.position.y >= 0 &&
				int64_t(output_rect.position.x) + output_rect.size.x <= parent_size.x &&
				int64_t(output_rect.position.y) + output_rect.size.y <= parent_size.y &&
				render_size.x > 0 && render_size.y > 0 && allocation_size.x >= render_size.x && allocation_size.y >= render_size.y;
	}

	// Change the raster/depth resolution without changing coverage or the projection.
	// The reconstruction target remains output_rect.size.
	bool set_input_scale(float p_scale) {
		if (!Math::is_finite(p_scale) || p_scale < 0.25f || p_scale > 1.0f) {
			return false;
		}
		render_size = Size2i(MAX(1, int(output_rect.size.x * p_scale)), MAX(1, int(output_rect.size.y * p_scale)));
		allocation_size = render_size;
		return true;
	}

	// UVs and pixels use a top-left origin. Region UV spans the actively rendered
	// rectangle, not its possibly larger preallocated texture. Coordinates outside
	// [0, 1] remain outside; clamping here would accept unavailable history.
	Vector2 region_to_parent_uv(const Vector2 &p_uv) const {
		DEV_ASSERT(is_valid());
		return (Vector2(output_rect.position) + p_uv * Vector2(output_rect.size)) / Vector2(parent_size);
	}

	Vector2 parent_to_region_uv(const Vector2 &p_uv) const {
		DEV_ASSERT(is_valid());
		return (p_uv * Vector2(parent_size) - Vector2(output_rect.position)) / Vector2(output_rect.size);
	}

	Vector2 region_to_allocation_uv(const Vector2 &p_uv) const {
		DEV_ASSERT(is_valid());
		return p_uv * Vector2(render_size) / Vector2(allocation_size);
	}

	Vector2 allocation_to_region_uv(const Vector2 &p_uv) const {
		DEV_ASSERT(is_valid());
		return p_uv * Vector2(allocation_size) / Vector2(render_size);
	}

	// Sample positions are continuous texel coordinates: use (x + 0.5, y + 0.5)
	// for a sample center, or integers for texel boundaries.
	Vector2 sample_position_to_parent_pixel(const Vector2 &p_sample_position) const {
		DEV_ASSERT(is_valid());
		return Vector2(output_rect.position) + p_sample_position * Vector2(output_rect.size) / Vector2(render_size);
	}

	Vector2 parent_pixel_to_sample_position(const Vector2 &p_parent_pixel) const {
		DEV_ASSERT(is_valid());
		return (p_parent_pixel - Vector2(output_rect.position)) * Vector2(render_size) / Vector2(output_rect.size);
	}

	// Input/output are raw Godot camera projections, BEFORE Vulkan depth/Y
	// correction and jitter. Both depth rows remain unchanged. Applying the same
	// crop to an already Y-corrected projection would reverse the vertical offset.
	Projection crop_projection(const Projection &p_parent_projection) const {
		DEV_ASSERT(is_valid());
		Projection crop;
		crop[0][0] = real_t(parent_size.x) / output_rect.size.x;
		crop[1][1] = real_t(parent_size.y) / output_rect.size.y;
		crop[3][0] = (real_t(parent_size.x) - real_t(2) * output_rect.position.x - output_rect.size.x) / output_rect.size.x;
		crop[3][1] = (real_t(2) * output_rect.position.y + output_rect.size.y - real_t(parent_size.y)) / output_rect.size.y;
		return crop * p_parent_projection;
	}

	// Scale a common parent NDC jitter offset before adding it to the regional
	// depth-correction matrix. This does not choose a jitter sequence or phase.
	Vector2 parent_to_region_jitter(const Vector2 &p_parent_jitter) const {
		DEV_ASSERT(is_valid());
		return p_parent_jitter * Vector2(parent_size) / Vector2(output_rect.size);
	}

	bool has_same_mapping(const HybridPiPRegion &p_other) const {
		return is_valid() && p_other.is_valid() && parent_size == p_other.parent_size && output_rect == p_other.output_rect &&
				render_size == p_other.render_size && allocation_size == p_other.allocation_size;
	}

	// Layout remapping only. Camera/object motion, depth/normal rejection and
	// history generation still belong to the temporal consumer.
	Vector2 remap_uv_to(const HybridPiPRegion &p_other, const Vector2 &p_uv) const {
		return p_other.parent_to_region_uv(region_to_parent_uv(p_uv));
	}
};

struct HybridPiPLayout {
	enum class Result {
		OK,
		INVALID_INPUT,
		OUTSIDE_VIEW,
		CAPACITY_EXCEEDED,
	};

	Size2i output_size;
	Rect2i protected_rect;
	HybridPiPRegion background;
	HybridPiPRegion native;

	// The protected rectangle covers the entire scope plus aperture. Guard pixels
	// expand its rendered crop; alignment expands outward, except at viewport edges.
	// A nonzero capacity is a hard preparation limit, never a resize request.
	// Failure leaves r_layout untouched, allowing the caller to retain a ready mode.
	static Result create(const Size2i &p_output_size, const Rect2i &p_protected_rect, int p_guard_pixels, const Size2i &p_alignment, const Size2i &p_native_capacity, HybridPiPLayout &r_layout) {
		if (p_output_size.x <= 0 || p_output_size.y <= 0 || p_protected_rect.size.x <= 0 || p_protected_rect.size.y <= 0 ||
				p_guard_pixels < 0 || p_alignment.x <= 0 || p_alignment.y <= 0 ||
				(p_native_capacity != Size2i() && (p_native_capacity.x <= 0 || p_native_capacity.y <= 0))) {
			return Result::INVALID_INPUT;
		}

		// Widen before addition: a caller's offscreen rectangle or guard must not
		// overflow an int32 endpoint and turn into an apparently valid tiny crop.
		int64_t lower[2];
		int64_t upper[2];
		for (int axis = 0; axis < 2; axis++) {
			lower[axis] = MAX(int64_t(0), int64_t(p_protected_rect.position[axis]));
			upper[axis] = MIN(int64_t(p_output_size[axis]), int64_t(p_protected_rect.position[axis]) + p_protected_rect.size[axis]);
			if (upper[axis] <= lower[axis]) {
				return Result::OUTSIDE_VIEW;
			}
		}

		HybridPiPLayout candidate;
		candidate.output_size = p_output_size;
		candidate.protected_rect = Rect2i(int32_t(lower[0]), int32_t(lower[1]), int32_t(upper[0] - lower[0]), int32_t(upper[1] - lower[1]));
		for (int axis = 0; axis < 2; axis++) {
			const int64_t alignment = p_alignment[axis];
			lower[axis] = MAX(int64_t(0), lower[axis] - p_guard_pixels) / alignment * alignment;
			upper[axis] = MIN(int64_t(p_output_size[axis]), ((upper[axis] + p_guard_pixels + alignment - 1) / alignment) * alignment);
		}

		candidate.native.parent_size = p_output_size;
		candidate.native.output_rect = Rect2i(int32_t(lower[0]), int32_t(lower[1]), int32_t(upper[0] - lower[0]), int32_t(upper[1] - lower[1]));
		candidate.native.render_size = candidate.native.output_rect.size;
		candidate.native.allocation_size = p_native_capacity == Size2i() ? candidate.native.render_size : p_native_capacity;
		if (candidate.native.allocation_size.x < candidate.native.render_size.x || candidate.native.allocation_size.y < candidate.native.render_size.y) {
			return Result::CAPACITY_EXCEEDED;
		}

		candidate.background.parent_size = p_output_size;
		candidate.background.output_rect = Rect2i(Point2i(), p_output_size);
		candidate.background.render_size = Size2i(p_output_size.x / 2 + p_output_size.x % 2, p_output_size.y / 2 + p_output_size.y % 2);
		candidate.background.allocation_size = candidate.background.render_size;
		r_layout = candidate;
		return Result::OK;
	}

	// Fixed-extent production regions keep internal_size identical to texture
	// extent for existing effects/SDKs. Move the crop without reallocating it.
	static Result create_fixed(const Size2i &p_output_size, const Rect2i &p_protected_rect, int p_guard_pixels, const Size2i &p_alignment, const Size2i &p_native_capacity, HybridPiPLayout &r_layout) {
		if (p_native_capacity.x <= 0 || p_native_capacity.y <= 0 || p_native_capacity.x > p_output_size.x || p_native_capacity.y > p_output_size.y) {
			return Result::CAPACITY_EXCEEDED;
		}
		HybridPiPLayout candidate;
		const Result result = create(p_output_size, p_protected_rect, p_guard_pixels, p_alignment, p_native_capacity, candidate);
		if (result != Result::OK) {
			return result;
		}
		for (int axis = 0; axis < 2; axis++) {
			const int64_t capacity = p_native_capacity[axis];
			const int64_t required_begin = candidate.native.output_rect.position[axis];
			const int64_t required_end = required_begin + candidate.native.output_rect.size[axis];
			const int64_t minimum = MAX(int64_t(0), required_end - capacity);
			const int64_t maximum = MIN(required_begin, int64_t(p_output_size[axis]) - capacity);
			const int64_t alignment = p_alignment[axis];
			const int64_t centered = CLAMP((required_begin + required_end - capacity) / 2, minimum, maximum);
			int64_t begin = centered / alignment * alignment;
			if (begin < minimum) {
				begin = (minimum + alignment - 1) / alignment * alignment;
			}
			if (begin > maximum) {
				// An odd-sized viewport can have an unaligned final crop origin.
				if (maximum == int64_t(p_output_size[axis]) - capacity) {
					begin = maximum;
				} else {
					return Result::CAPACITY_EXCEEDED;
				}
			}
			candidate.native.output_rect.position[axis] = int32_t(begin);
		}
		candidate.native.output_rect.size = p_native_capacity;
		candidate.native.render_size = p_native_capacity;
		candidate.native.allocation_size = p_native_capacity;
		r_layout = candidate;
		return Result::OK;
	}
};

} // namespace RendererRD
