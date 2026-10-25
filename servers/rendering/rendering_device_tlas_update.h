/**************************************************************************/
/*  rendering_device_tlas_update.h                                        */
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

#include <cstdint>

// Tracks only submitted builds. Invalidating dependent BLAS bounds does not
// erase the existing TLAS structure, which can still be refitted in place.
struct RenderingDeviceTLASUpdateState {
	bool has_build = false;
	bool all_active = false;
	uint32_t instance_count = 0;

	bool can_update(bool p_requested, bool p_allowed, uint32_t p_instance_count, bool p_all_active) const {
		// Vulkan updates cannot change primitive count or active membership.
		// Mixed active/inactive lists conservatively use a complete build.
		return p_requested && p_allowed && has_build && p_instance_count > 0 && instance_count == p_instance_count && all_active && p_all_active;
	}

	void record_build(uint32_t p_instance_count, bool p_all_active) {
		has_build = true;
		instance_count = p_instance_count;
		all_active = p_all_active;
	}
};
