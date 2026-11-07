/**************************************************************************/
/*  test_hybrid_pip_layout.cpp                                            */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_hybrid_pip_layout)

#include "servers/rendering/renderer_rd/hybrid_pip_layout.h"

#include <climits>

namespace TestHybridPiPLayout {

using RendererRD::HybridPiPLayout;
using RendererRD::HybridPiPRegion;

TEST_CASE("[HybridPiP] Scope input scaling preserves coverage and peripheral workload") {
	HybridPiPLayout layout;
	const Rect2i scope(1336, 352, 736, 896);
	REQUIRE(HybridPiPLayout::create_fixed(Size2i(3440, 1440), scope, 0, Size2i(1, 1), scope.size, layout) == HybridPiPLayout::Result::OK);
	for (float scale : { 1.0f, 0.667f, 0.58f, 0.5f, 0.333f }) {
		CHECK(layout.native.set_input_scale(scale));
		CHECK(layout.native.render_size == Size2i(int(736 * scale), int(896 * scale)));
		CHECK(layout.native.allocation_size == layout.native.render_size);
		CHECK(layout.native.output_rect == scope);
		CHECK(layout.background.render_size == Size2i(1720, 720));
	}
	CHECK_FALSE(layout.native.set_input_scale(0));
	CHECK_FALSE(layout.native.set_input_scale(2));
}

TEST_CASE("[HybridPiP] Odd dimensions and clipped guards retain complete coverage") {
	HybridPiPLayout layout;
	REQUIRE(HybridPiPLayout::create(Size2i(1281, 721), Rect2i(1100, 600, 250, 200), 32, Size2i(16, 16), Size2i(), layout) == HybridPiPLayout::Result::OK);
	CHECK(layout.protected_rect == Rect2i(1100, 600, 181, 121));
	CHECK(layout.native.output_rect == Rect2i(1056, 560, 225, 161));
	CHECK(layout.native.render_size == Size2i(225, 161));
	CHECK(layout.background.render_size == Size2i(641, 361));
	CHECK(layout.background.sample_position_to_parent_pixel(Vector2(layout.background.render_size)).is_equal_approx(Vector2(1281, 721)));
	CHECK(layout.native.region_to_parent_uv(Vector2(1, 1)).is_equal_approx(Vector2(1, 1)));

	REQUIRE(HybridPiPLayout::create(Size2i(1281, 721), Rect2i(-10, -20, 50, 50), 0, Size2i(16, 16), Size2i(), layout) == HybridPiPLayout::Result::OK);
	CHECK(layout.protected_rect == Rect2i(0, 0, 40, 30));
	CHECK(layout.native.output_rect == Rect2i(0, 0, 48, 32));
}

TEST_CASE("[HybridPiP] Capacity limits and invalid requests preserve the ready layout") {
	HybridPiPLayout layout;
	REQUIRE(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(448, 176, 368, 448), 32, Size2i(16, 16), Size2i(512, 576), layout) == HybridPiPLayout::Result::OK);
	const HybridPiPRegion ready = layout.native;
	CHECK(ready.output_rect == Rect2i(416, 144, 432, 512));
	CHECK(ready.allocation_size == Size2i(512, 576));
	CHECK(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(448, 176, 368, 448), 128, Size2i(16, 16), Size2i(512, 576), layout) == HybridPiPLayout::Result::CAPACITY_EXCEEDED);
	CHECK(layout.native.has_same_mapping(ready));
	CHECK(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(1500, 0, 50, 50), 0, Size2i(1, 1), Size2i(), layout) == HybridPiPLayout::Result::OUTSIDE_VIEW);
	CHECK(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(INT_MAX - 4, 0, 20, 50), 0, Size2i(1, 1), Size2i(), layout) == HybridPiPLayout::Result::OUTSIDE_VIEW);
	CHECK(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(0, 0, 100, 100), -1, Size2i(1, 1), Size2i(), layout) == HybridPiPLayout::Result::INVALID_INPUT);
	CHECK(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(0, 0, 100, 100), 0, Size2i(0, 1), Size2i(), layout) == HybridPiPLayout::Result::INVALID_INPUT);
	CHECK(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(0, 0, 100, 100), 0, Size2i(1, 1), Size2i(100, 0), layout) == HybridPiPLayout::Result::INVALID_INPUT);
	CHECK(layout.native.has_same_mapping(ready));

	REQUIRE(HybridPiPLayout::create(Size2i(1281, 721), Rect2i(0, 0, 1, 1), INT_MAX, Size2i(16, 16), Size2i(), layout) == HybridPiPLayout::Result::OK);
	CHECK(layout.native.output_rect == Rect2i(0, 0, 1281, 721));
}

TEST_CASE("[HybridPiP] Parent sample and allocation coordinates round trip without clamping") {
	HybridPiPLayout current;
	HybridPiPLayout previous;
	REQUIRE(HybridPiPLayout::create(Size2i(1281, 721), Rect2i(401, 211, 320, 280), 17, Size2i(16, 16), Size2i(512, 512), current) == HybridPiPLayout::Result::OK);
	REQUIRE(HybridPiPLayout::create(Size2i(1281, 721), Rect2i(369, 195, 320, 280), 17, Size2i(16, 16), Size2i(512, 512), previous) == HybridPiPLayout::Result::OK);
	CHECK_FALSE(current.native.has_same_mapping(previous.native));
	for (const Vector2 &uv : { Vector2(0, 0), Vector2(1, 1), Vector2(0.3, 0.6), Vector2(-0.2, 1.1) }) {
		CHECK(current.native.parent_to_region_uv(current.native.region_to_parent_uv(uv)).is_equal_approx(uv));
		CHECK(current.native.allocation_to_region_uv(current.native.region_to_allocation_uv(uv)).is_equal_approx(uv));
		const Vector2 previous_uv = current.native.remap_uv_to(previous.native, uv);
		CHECK(previous.native.remap_uv_to(current.native, previous_uv).is_equal_approx(uv));
		CHECK(current.native.region_to_parent_uv(uv).is_equal_approx(previous.native.region_to_parent_uv(previous_uv)));
	}
	const Vector2 center(0.5, 0.5);
	CHECK(current.background.parent_pixel_to_sample_position(current.background.sample_position_to_parent_pixel(center)).is_equal_approx(center));
	CHECK(current.native.parent_pixel_to_sample_position(current.native.sample_position_to_parent_pixel(center)).is_equal_approx(center));
	CHECK(current.native.parent_to_region_uv(Vector2(0, 0)).x < 0);
	CHECK(current.native.parent_to_region_uv(Vector2(1, 1)).y > 1);
}

TEST_CASE("[HybridPiP] Cropped projections preserve parent rays depth and jitter") {
	HybridPiPLayout layout;
	REQUIRE(HybridPiPLayout::create(Size2i(1280, 720), Rect2i(160, 80, 400, 320), 0, Size2i(1, 1), Size2i(), layout) == HybridPiPLayout::Result::OK);
	const Projection parent = Projection::create_perspective(35, 1280.0 / 720.0, 0.01, 200.0);
	const Projection cropped = layout.native.crop_projection(parent);
	const Projection inverse = parent.inverse();
	Projection correction;
	correction.set_depth_correction(true);
	const Vector2 jitter(0.0005, -0.0007);
	Projection parent_jittered_correction = correction;
	parent_jittered_correction.add_jitter_offset(jitter);
	Projection crop_jittered_correction = correction;
	crop_jittered_correction.add_jitter_offset(layout.native.parent_to_region_jitter(jitter));
	for (const Vector2 &uv : { Vector2(0, 0), Vector2(1, 1), Vector2(0.5, 0.5), Vector2(0.2, 0.7) }) {
		const Vector2 parent_uv = layout.native.region_to_parent_uv(uv);
		// Raw Godot projection: +Y is up; image UV uses +Y down.
		const Vector4 parent_ndc(parent_uv.x * 2 - 1, 1 - parent_uv.y * 2, 0.2, 1);
		const Vector4 view_homogeneous = inverse.xform(parent_ndc);
		const Vector4 clip = cropped.xform(view_homogeneous);
		const Vector2 crop_uv(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
		CHECK(crop_uv.is_equal_approx(uv));
		CHECK(Math::is_equal_approx(clip.z / clip.w, parent_ndc.z));
		const Vector4 parent_corrected = (parent_jittered_correction * parent).xform(view_homogeneous);
		const Vector4 crop_corrected = (crop_jittered_correction * cropped).xform(view_homogeneous);
		const Vector2 parent_corrected_uv(parent_corrected.x / parent_corrected.w * 0.5 + 0.5, parent_corrected.y / parent_corrected.w * 0.5 + 0.5);
		const Vector2 crop_corrected_uv(crop_corrected.x / crop_corrected.w * 0.5 + 0.5, crop_corrected.y / crop_corrected.w * 0.5 + 0.5);
		CHECK(layout.native.region_to_parent_uv(crop_corrected_uv).is_equal_approx(parent_corrected_uv));
		CHECK(Math::is_equal_approx(crop_corrected.z / crop_corrected.w, parent_corrected.z / parent_corrected.w));
	}
	const Projection background = layout.background.crop_projection(parent);
	for (int column = 0; column < 4; column++) {
		CHECK(background[column].is_equal_approx(parent[column]));
	}
}

TEST_CASE("[HybridPiP] Fixed crop preserves extent and guarded coverage while moving") {
	HybridPiPLayout first;
	REQUIRE(HybridPiPLayout::create_fixed(Size2i(1280, 720), Rect2i(448, 176, 368, 448), 64, Size2i(16, 16), Size2i(512, 576), first) == HybridPiPLayout::Result::OK);
	CHECK(first.native.render_size == Size2i(512, 576));
	CHECK(first.native.allocation_size == first.native.render_size);
	CHECK(first.native.output_rect.size == first.native.render_size);
	CHECK(first.native.output_rect.encloses(Rect2i(384, 112, 496, 576)));
	HybridPiPLayout moved;
	REQUIRE(HybridPiPLayout::create_fixed(Size2i(1280, 720), Rect2i(496, 144, 368, 448), 64, Size2i(16, 16), Size2i(512, 576), moved) == HybridPiPLayout::Result::OK);
	CHECK(moved.native.render_size == first.native.render_size);
	CHECK(moved.native.output_rect.position != first.native.output_rect.position);
	for (const Vector2 &uv : { Vector2(0, 0), Vector2(1, 1), Vector2(0.37, 0.84) }) {
		const Vector2 previous_uv = moved.native.remap_uv_to(first.native, uv);
		CHECK(first.native.remap_uv_to(moved.native, previous_uv).is_equal_approx(uv));
	}
	HybridPiPLayout clipped;
	REQUIRE(HybridPiPLayout::create_fixed(Size2i(1279, 719), Rect2i(1100, 540, 200, 200), 64, Size2i(16, 16), Size2i(512, 576), clipped) == HybridPiPLayout::Result::OK);
	CHECK(clipped.native.output_rect.get_end() == Size2i(1279, 719));
	CHECK(clipped.native.render_size == Size2i(512, 576));
	CHECK(clipped.background.render_size == Size2i(640, 360));
	CHECK(HybridPiPLayout::create_fixed(Size2i(1280, 720), Rect2i(448, 176, 368, 448), 65, Size2i(16, 16), Size2i(512, 576), first) == HybridPiPLayout::Result::CAPACITY_EXCEEDED);
}

} // namespace TestHybridPiPLayout
