/**************************************************************************/
/*  streamline_vk.h                                                       */
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

#if defined(VULKAN_ENABLED) && defined(WINDOWS_ENABLED)
// Streamline ships a Windows-only interposer, so the integration compiles out everywhere else.
#define STREAMLINE_ENABLED
#endif

#ifdef STREAMLINE_ENABLED

#include "core/math/projection.h"
#include "core/math/rect2i.h"
#include "core/math/transform_3d.h"
#include "core/math/vector2.h"
#include "core/string/ustring.h"
#include "core/templates/rid.h"

// Owns the Streamline runtime for the process.
//
// The interposer DLL is loaded before volk is initialized, and volk is then pointed at the
// `vkGetInstanceProcAddr` that DLL exports. Every Vulkan entry point the engine resolves after
// that comes from Streamline where Streamline wants it -- `vkCreateInstance`, `vkCreateDevice`,
// `vkCreateSwapchainKHR`, `vkAcquireNextImageKHR` and `vkQueuePresentKHR` -- and from the Vulkan
// loader for everything else. That is NVIDIA's "manual hooking" route for Vulkan, and it is what
// lets frame generation own the swapchain without the engine calling present any differently.
//
// Taking the create-instance and create-device proxies also means Streamline adds the instance
// extensions, device extensions, Vulkan 1.2/1.3 feature bits and extra queues its features need,
// so none of that is duplicated here and `slSetVulkanInfo` is not called.
//
// Nothing in this header names a Vulkan or Streamline type: native handles cross as `uint64_t`,
// the same way `RenderingDevice::get_driver_resource()` hands them out. That keeps the renderer
// side of the integration free of both include paths.
class StreamlineVK {
public:
	enum Feature {
		FEATURE_DLSS_SUPER_RESOLUTION,
		FEATURE_DLSS_FRAME_GENERATION,
		FEATURE_REFLEX,
		FEATURE_MAX,
	};

	// Latency markers, in the order one frame reaches them.
	enum Marker {
		MARKER_SIMULATION_START,
		MARKER_SIMULATION_END,
		MARKER_RENDER_SUBMIT_START,
		MARKER_RENDER_SUBMIT_END,
		MARKER_PRESENT_START,
		MARKER_PRESENT_END,
	};

	// Quality presets, mapped from the viewport's 3D scale.
	enum Quality {
		QUALITY_DLAA,
		QUALITY_MAX_QUALITY,
		QUALITY_BALANCED,
		QUALITY_MAX_PERFORMANCE,
		QUALITY_ULTRA_PERFORMANCE,
	};

	// How a texture is being handed over, which is what decides the layout it is in when the
	// command buffer reaches the tag. These have to agree with the usage the same texture was
	// declared with in the enclosing `RenderingDevice::driver_callback_add()` call.
	enum TextureUse {
		TEXTURE_USE_SAMPLED, // CALLBACK_RESOURCE_USAGE_TEXTURE_SAMPLE.
		TEXTURE_USE_STORAGE, // CALLBACK_RESOURCE_USAGE_STORAGE_IMAGE_READ_WRITE.
	};

	// One Vulkan image, described the way Streamline wants to be handed one.
	struct Texture {
		uint64_t image = 0; // VkImage.
		uint64_t view = 0; // VkImageView.
		uint32_t format = 0; // VkFormat.
		uint32_t layout = 0; // VkImageLayout.
		uint32_t usage = 0; // VkImageUsageFlags.
		Size2i size;
		Rect2i extent; // Sub-rectangle in use. Empty means the whole image.

		bool is_valid() const { return image != 0; }
	};

	// Everything the common constants need that the engine already knows per view.
	struct CameraConstants {
		Projection view_to_clip;
		Projection clip_to_view;
		Projection clip_to_prev_clip;
		Projection prev_clip_to_clip;
		Transform3D camera_transform;
		Vector2 jitter_pixels;
		float z_near = 0.0f;
		float z_far = 0.0f;
		float fov_y = 0.0f;
		float aspect = 1.0f;
		bool reset = false;
		bool orthographic = false;
	};

	struct UpscaleInputs {
		Texture color;
		Texture depth;
		Texture motion_vectors;
		Texture exposure; // Optional.
		Texture output;
	};

	struct FrameGenerationInputs {
		Texture depth;
		Texture motion_vectors;
		Texture hudless_color; // Optional, but strongly wanted: without it the UI is interpolated too.
	};

	// Loads the interposer and calls `slInit`. Returns the interposer's `vkGetInstanceProcAddr`
	// for `volkInitializeCustom()`, or 0 when Streamline is switched off, missing, unsigned or
	// refuses to start -- in which case the engine carries on with the plain Vulkan loader and
	// no singleton exists.
	static uint64_t initialize();
	static void finalize();
	static StreamlineVK *get_singleton() { return singleton; }

	// Called once the physical device exists; until then no feature can be queried, because
	// support depends on the adapter.
	void set_physical_device(uint64_t p_physical_device);
	bool is_supported(Feature p_feature) const;

	// Frame boundaries on the rendering thread. Every tag, constant, marker and evaluation in
	// between shares the one frame token these take.
	void frame_begin();
	void frame_end();
	void set_marker(Marker p_marker);
	void sleep();

	// Super resolution. Options are re-sent only when the output size, quality or exposure
	// source actually changes, so this is safe to call once per frame per view.
	//
	// `p_command_buffer` is an `RDD::CommandBufferID`, as handed to a driver callback; the
	// underlying VkCommandBuffer is resolved here rather than at the call site.
	bool super_resolution_evaluate(uint64_t p_command_buffer, uint32_t p_viewport, const Size2i &p_output_size, Quality p_quality, const CameraConstants &p_camera, const UpscaleInputs &p_inputs);
	void super_resolution_release(uint32_t p_viewport);

	// Frame generation. `frame_generation_set_enabled()` returns whether it is actually running,
	// which is what gates everything below it: the feature has to be supported, switched on,
	// backed by Reflex, and accepted by the plugin for this viewport.
	bool frame_generation_set_enabled(uint32_t p_viewport, bool p_enabled, const Size2i &p_output_size, const Size2i &p_mvec_depth_size);
	bool frame_generation_is_running(uint32_t p_viewport) const;
	void frame_generation_release(uint32_t p_viewport);

	// Takes the copy of the presented image from before the interface was drawn over it.
	// Allocates its target on first use and frees it again as soon as frame generation stops,
	// so a project that never turns the feature on never pays for the texture or the copy.
	void frame_generation_capture_hudless(uint32_t p_viewport, RID p_source_texture, const Size2i &p_size);
	RID frame_generation_get_hudless(uint32_t p_viewport) const;

	void frame_generation_tag(uint64_t p_command_buffer, uint32_t p_viewport, const CameraConstants &p_camera, const FrameGenerationInputs &p_inputs);

	static Quality quality_from_scale(float p_scale);

	// Translates one of the engine's textures. Returns an empty Texture for an invalid RID, so
	// an optional input can simply be passed through.
	static Texture texture_from_rid(RID p_texture, TextureUse p_use);

	StreamlineVK() {}
	~StreamlineVK() {}

private:
	void _set_constants(uint32_t p_viewport, const CameraConstants &p_camera);
	String _requirements_hint(Feature p_feature);
	void _free_hudless(uint32_t p_viewport);

	static StreamlineVK *singleton;

	struct Internal;
	Internal *internal = nullptr;

	bool _load(const String &p_directory);
	void _unload();
};

#endif // STREAMLINE_ENABLED
