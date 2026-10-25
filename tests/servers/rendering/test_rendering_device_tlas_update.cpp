/**************************************************************************/
/*  test_rendering_device_tlas_update.cpp                                 */
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

TEST_FORCE_LINK(test_rendering_device_tlas_update)

#include "servers/rendering/rendering_device_tlas_update.h"

namespace TestRenderingDeviceTLASUpdate {

TEST_CASE("[RenderingDevice] TLAS refit eligibility follows successful builds") {
	RenderingDeviceTLASUpdateState state;
	CHECK_FALSE(state.can_update(true, true, 3, true));
	state.record_build(3, true);
	CHECK(state.can_update(true, true, 3, true));
	CHECK_FALSE(state.can_update(false, true, 3, true));
	CHECK_FALSE(state.can_update(true, false, 3, true));
	CHECK_FALSE(state.can_update(true, true, 4, true));
	CHECK_FALSE(state.can_update(true, true, 3, false));

	// A failed preparation submits nothing and must not replace the snapshot.
	CHECK_FALSE(state.can_update(true, true, 4, true));
	CHECK(state.can_update(true, true, 3, true));
	state.record_build(4, true);
	CHECK(state.can_update(true, true, 4, true));
	CHECK_FALSE(state.can_update(true, true, 3, true));

	// An inactive membership transition requires a build, even at equal count.
	state.record_build(4, false);
	CHECK_FALSE(state.can_update(true, true, 4, true));
	CHECK_FALSE(state.can_update(true, true, 4, false));
	state.record_build(4, true);
	CHECK(state.can_update(true, true, 4, true));

	state.record_build(0, true);
	CHECK_FALSE(state.can_update(true, true, 0, true));
	state = RenderingDeviceTLASUpdateState();
	CHECK_FALSE(state.can_update(true, true, 4, true));
}

} // namespace TestRenderingDeviceTLASUpdate
