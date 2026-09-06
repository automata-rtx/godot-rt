/**************************************************************************/
/*  dlss.h                                                                */
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

// Self-guarding: defines STREAMLINE_ENABLED, and compiles to nothing where Streamline cannot run.
#include "drivers/vulkan/streamline_vk.h"

#ifdef STREAMLINE_ENABLED

#include "core/templates/paged_allocator.h"
#include "servers/rendering/rendering_device.h"

namespace RendererRD {

// DLSS super resolution, as a temporal upscaler beside FSR2 and MetalFX.
//
// Unlike those two the work is not recorded by the engine at all: Streamline is handed the raw
// command buffer and records its own passes into it. That is what `driver_callback_add()` is
// for -- it hands over the command buffer at a point where the render graph has already put
// every resource named alongside it into the layout the callback promises.
class DLSSEffect {
	struct CallbackArgs {
		DLSSEffect *owner = nullptr;
		uint32_t viewport = 0;
		Size2i output_size;
		StreamlineVK::Quality quality = StreamlineVK::QUALITY_DLAA;
		StreamlineVK::Preset preset = StreamlineVK::PRESET_DEFAULT;
		StreamlineVK::CameraConstants camera;
		StreamlineVK::UpscaleInputs inputs;
	};

	PagedAllocator<CallbackArgs, true, 16> args_allocator;
	static void callback(RDD *p_driver, RDD::CommandBufferID p_command_buffer, CallbackArgs *p_userdata);

public:
	struct Parameters {
		// Unique per view, and stable across frames: Streamline keeps this viewport's history
		// under it.
		uint32_t viewport = 0;
		Size2i internal_size;
		Size2i target_size;
		float scale = 1.0f;
		StreamlineVK::Preset preset = StreamlineVK::PRESET_DEFAULT;

		RID color;
		RID depth;
		RID velocity;
		RID exposure; // Optional; without it DLSS estimates exposure itself.
		RID output;

		float z_near = 0.0f;
		float z_far = 0.0f;
		float fov_y = 0.0f;
		float aspect = 1.0f;
		Vector2 jitter; // Pixels, the same value FSR2 is given.
		bool reset_accumulation = false;
		bool orthographic = false;

		Projection view_to_clip;
		Projection clip_to_view;
		Projection clip_to_prev_clip;
		Projection prev_clip_to_clip;
		Transform3D camera_transform;
	};

	static bool is_available();
	void upscale(const Parameters &p_params);
};

// DLSS frame generation.
//
// Unlike super resolution this runs nowhere in the frame the engine records: the interpolation
// happens inside the present hook, long after this command buffer has been submitted. All this
// does is hand Streamline the inputs it will read there -- which is why they are tagged as valid
// until present, and why the hudless colour has to be a copy rather than the render target
// itself: the interface is drawn over the render target before it reaches the screen.
class DLSSFrameGeneration {
	struct CallbackArgs {
		uint32_t viewport = 0;
		StreamlineVK::CameraConstants camera;
		StreamlineVK::FrameGenerationInputs inputs;
	};

	static void callback(RDD *p_driver, RDD::CommandBufferID p_command_buffer, CallbackArgs *p_userdata);

public:
	struct Parameters {
		uint32_t viewport = 0;
		bool enabled = false;
		Size2i output_size;
		Size2i internal_size;

		// The render target, still holding the tone-mapped 3D image with nothing drawn over it.
		RID hudless_source;
		RID depth;
		RID velocity;

		float z_near = 0.0f;
		float z_far = 0.0f;
		float fov_y = 0.0f;
		float aspect = 1.0f;
		Vector2 jitter;
		bool reset_accumulation = false;
		bool orthographic = false;

		Projection view_to_clip;
		Projection clip_to_view;
		Projection clip_to_prev_clip;
		Projection prev_clip_to_clip;
		Transform3D camera_transform;
	};

	static bool is_available();
	// Returns whether frame generation is running on this viewport after the call.
	static bool update(const Parameters &p_params);
};

} //namespace RendererRD

#endif // STREAMLINE_ENABLED
