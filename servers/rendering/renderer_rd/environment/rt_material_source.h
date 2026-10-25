/**************************************************************************/
/*  rt_material_source.h                                                  */
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

#include "servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.h"
#include "servers/rendering/renderer_scene_render.h"

namespace RendererRD {
// Native shader code evaluated at the source triangle/UV. This code generator
// allocates its attribute/uniform adapters only for an active AMD GI scene.
class RaytracingMaterialSource {
public:
	using SpatialShader = RendererSceneRenderImplementation::SceneShaderForwardClustered::ShaderData;
	struct Shader {
		uint32_t id = 0;
		String source;
		Vector<ShaderCompiler::GeneratedCode::Texture> textures;
		uint32_t texture_count = 0;
	};
	static Error compile(const ShaderCompiler &p_native_compiler, const SpatialShader &p_shader, uint32_t p_id, Shader &r_shader);

	// Layout shared with rt_material_source_inc.glsl. Addresses borrow source
	// geometry and own only the small native uniform/attribute copies.
	struct Context {
		uint64_t uniform_address = 0;
		uint64_t texture_address = 0;
		uint64_t attribute_address = 0;
		uint64_t reserved = 0;
		uint32_t attributes[4] = { UINT32_MAX, UINT32_MAX, UINT32_MAX, 0 };
		uint32_t custom_offsets[4] = { UINT32_MAX, UINT32_MAX, UINT32_MAX, UINT32_MAX };
		uint32_t custom_formats[4] = {};
		float uv_scale[4] = {};
		float color[4] = { 1, 1, 1, 1 };
		float custom[4] = {};
		uint32_t info[4] = {};
	};
	static_assert(sizeof(Context) == 144);
	void begin_frame();
	void clear();
	Error add_surface(RID p_material, const RendererSceneRender::RaytracingGIInstance &p_instance, uint32_t p_surface, const Color &p_color, const Color &p_custom);
	bool end_frame();
	String get_shader_source() const;
	uint64_t get_shader_revision() const { return shader_revision; }
	void append_uniforms(LocalVector<RD::Uniform> &r_uniforms) const;
	void add_buffer_reads(RD::ComputeListID p_list) const;
	~RaytracingMaterialSource();

private:
	struct Material {
		RID uniforms, indices;
		Vector<uint8_t> uniform_bytes;
		Vector<uint32_t> texture_indices;
		String code;
		Context context;
		uint32_t shader = 0;
		uint64_t frame = 0;
	};
	struct SurfaceLayout {
		Context context;
		RID source;
		uint64_t format = UINT64_MAX;
		uint64_t frame = 0;
		uint32_t count = 0;
	};
	struct MeshLayouts {
		Vector<SurfaceLayout> surfaces;
		uint64_t frame = 0;
	};
	struct Attributes {
		RID buffer;
		uint64_t revision = 0;
		uint64_t frame = 0;
		uint32_t size = 0;
	};
	struct TextureArray {
		ShaderLanguage::DataType type;
		Vector<RID> textures;
		HashMap<RID, uint32_t> indices;
		RID fallback;
		uint32_t capacity = 1;
	};
	HashMap<RID, Material> materials;
	HashMap<RID, Attributes> attributes;
	HashMap<RID, MeshLayouts> mesh_layouts;
	HashMap<String, uint32_t> shader_ids;
	Vector<Shader> shaders;
	Vector<TextureArray> texture_arrays;
	LocalVector<Context> contexts;
	LocalVector<Context> uploaded_contexts;
	RID context_buffer;
	uint32_t context_capacity = 0;
	uint64_t frame = 0;
	uint64_t shader_revision = 1;
	int texture_array(ShaderLanguage::DataType p_type, RID p_fallback);
	bool update_buffer(RID &r_buffer, Vector<uint8_t> &r_previous, const Vector<uint8_t> &p_bytes);
	Error surface_context(RID p_mesh, uint32_t p_surface, Context &r_context);
	static Context build_surface_context(uint64_t p_format, uint32_t p_count, const Vector4 &p_uv_scale, uint64_t p_attribute_address);
	struct TextureContext {
		HashMap<StringName, String> arrays;
		HashMap<StringName, uint32_t> offsets;
	};
	static String texture_expression(void *p_context, const StringName &p_name, const String &p_index);
};
} // namespace RendererRD
