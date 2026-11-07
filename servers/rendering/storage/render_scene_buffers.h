/**************************************************************************/
/*  render_scene_buffers.h                                                */
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
#include "servers/rendering/rendering_server_enums.h"

class RenderSceneBuffersConfiguration : public RefCounted {
	GDCLASS(RenderSceneBuffersConfiguration, RefCounted);

private:
	RID render_target;

	Size2i internal_size;
	Size2i target_size;
	uint32_t view_count = 1;

	RSE::ViewportScaling3DMode scaling_3d_mode = RSE::VIEWPORT_SCALING_3D_MODE_OFF;
	RSE::ViewportMSAA msaa_3d = RSE::VIEWPORT_MSAA_DISABLED;
	RSE::ViewportScreenSpaceAA screen_space_aa = RSE::VIEWPORT_SCREEN_SPACE_AA_DISABLED;
	RSE::ViewportAnisotropicFiltering anisotropic_filtering_level = RSE::VIEWPORT_ANISOTROPY_4X;

	float fsr_sharpness = 0.0;
	float texture_mipmap_bias = 0.0;
	bool use_taa = false;
	bool use_debanding = false;
	bool allow_target_vrs = true;

protected:
	static void _bind_methods();

public:
	void set_allow_target_vrs(bool p_allow) { allow_target_vrs = p_allow; }
	bool get_allow_target_vrs() const { return allow_target_vrs; }

	RID get_render_target() const { return render_target; }
	void set_render_target(RID p_render_target) { render_target = p_render_target; }

	Size2i get_internal_size() const { return internal_size; }
	void set_internal_size(Size2i p_internal_size) { internal_size = p_internal_size; }

	Size2i get_target_size() const { return target_size; }
	void set_target_size(Size2i p_target_size) { target_size = p_target_size; }

	uint32_t get_view_count() const { return view_count; }
	void set_view_count(uint32_t p_view_count) { view_count = p_view_count; }

	RSE::ViewportScaling3DMode get_scaling_3d_mode() const { return scaling_3d_mode; }
	void set_scaling_3d_mode(RSE::ViewportScaling3DMode p_scaling_3d_mode) { scaling_3d_mode = p_scaling_3d_mode; }

	RSE::ViewportMSAA get_msaa_3d() const { return msaa_3d; }
	void set_msaa_3d(RSE::ViewportMSAA p_msaa_3d) { msaa_3d = p_msaa_3d; }

	RSE::ViewportScreenSpaceAA get_screen_space_aa() const { return screen_space_aa; }
	void set_screen_space_aa(RSE::ViewportScreenSpaceAA p_screen_space_aa) { screen_space_aa = p_screen_space_aa; }

	float get_fsr_sharpness() const { return fsr_sharpness; }
	void set_fsr_sharpness(float p_fsr_sharpness) { fsr_sharpness = p_fsr_sharpness; }

	float get_texture_mipmap_bias() const { return texture_mipmap_bias; }
	void set_texture_mipmap_bias(float p_texture_mipmap_bias) { texture_mipmap_bias = p_texture_mipmap_bias; }

	RSE::ViewportAnisotropicFiltering get_anisotropic_filtering_level() const { return anisotropic_filtering_level; }
	void set_anisotropic_filtering_level(RSE::ViewportAnisotropicFiltering p_anisotropic_filtering_level) { anisotropic_filtering_level = p_anisotropic_filtering_level; }

	bool get_use_taa() const { return use_taa; }
	void set_use_taa(bool p_use_taa) { use_taa = p_use_taa; }

	bool get_use_debanding() const { return use_debanding; }
	void set_use_debanding(bool p_use_debanding) { use_debanding = p_use_debanding; }

	RenderSceneBuffersConfiguration() {}
	virtual ~RenderSceneBuffersConfiguration() {}
};

class RenderSceneBuffers : public RefCounted {
	GDCLASS(RenderSceneBuffers, RefCounted);

protected:
	static void _bind_methods();

public:
	RenderSceneBuffers() {}
	virtual ~RenderSceneBuffers() {}

	// A preparation request is separate from the per-frame ADS/layout request.
	// Backends which do not implement regional rendering retain uniform output.
	struct HybridPiPConfiguration {
		bool enabled = false;
		bool active = false;
		bool blur_enabled = true;
		bool resident_parent = false;
		Size2i native_capacity;
		Rect2 native_region;
		PackedVector2Array aperture;
		uint64_t preparation_generation = 0;
	};

	void set_hybrid_pip_configuration(const HybridPiPConfiguration &p_configuration) {
		if (p_configuration.preparation_generation != hybrid_pip_configuration.preparation_generation || p_configuration.enabled != hybrid_pip_configuration.enabled) {
			hybrid_pip_status.clear();
		}
		hybrid_pip_configuration = p_configuration;
	}
	const HybridPiPConfiguration &get_hybrid_pip_configuration() const { return hybrid_pip_configuration; }
	void set_hybrid_pip_status(const Dictionary &p_status) { hybrid_pip_status = p_status; }
	Dictionary get_hybrid_pip_status() const {
		Dictionary result = hybrid_pip_status.duplicate();
		result["enabled"] = hybrid_pip_configuration.enabled;
		result["requested_active"] = hybrid_pip_configuration.active;
		if (!hybrid_pip_configuration.enabled || !hybrid_pip_configuration.active) {
			result["active"] = false;
		}
		if (!result.has("ready")) {
			result["ready"] = false;
			result["active"] = false;
			result["reason"] = "not_prepared_or_unsupported";
		}
		return result;
	}

	virtual void configure(const RenderSceneBuffersConfiguration *p_config) = 0;

	// for those settings that are unlikely to require buffers to be recreated, we'll add setters
	virtual void set_fsr_sharpness(float p_fsr_sharpness) = 0;
	virtual void set_texture_mipmap_bias(float p_texture_mipmap_bias) = 0;
	virtual void set_anisotropic_filtering_level(RSE::ViewportAnisotropicFiltering p_anisotropic_filtering_level) = 0;
	virtual void set_use_debanding(bool p_use_debanding) = 0;

private:
	HybridPiPConfiguration hybrid_pip_configuration;
	Dictionary hybrid_pip_status;
};
