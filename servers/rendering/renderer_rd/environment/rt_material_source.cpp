/**************************************************************************/
/*  rt_material_source.cpp                                                */
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

#include "rt_material_source.h"

#include "core/os/os.h"
#include "servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.h"
#include "servers/rendering/renderer_rd/renderer_compositor_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/rendering_server.h"

using namespace RendererRD;

String RaytracingMaterialSource::texture_expression(void *p_context, const StringName &p_name, const String &p_index) {
	const TextureContext &context = *static_cast<TextureContext *>(p_context);
	ERR_FAIL_COND_V(!context.arrays.has(p_name), String());
	String index = itos(context.offsets[p_name]) + "u";
	if (!p_index.is_empty()) {
		index += " + uint(" + p_index + ")";
	}
	return context.arrays[p_name] + "[nonuniformEXT(GISourceIndices(gi_source_context.texture_address).data[" + index + "])]";
}

Error RaytracingMaterialSource::compile(const ShaderCompiler &p_native_compiler, const SpatialShader &p_shader, uint32_t p_id, Shader &r_shader) {
	ShaderCompiler::DefaultIdentifierActions defaults = p_native_compiler.get_default_actions();
	const String prefix = "rtm" + itos(p_id) + "_";
	const String uniform_type = "RTM" + itos(p_id) + "Uniforms";
	defaults.identifier_prefix = prefix;
	defaults.shared_stage_globals = true;
	defaults.private_varyings = true;
	defaults.base_uniform_string = uniform_type + "(gi_source_context.uniform_address).";
	defaults.global_buffer_array_variable = "gi_global_uniforms.data";
	defaults.instance_uniform_index_variable = "gi_source_context.info.z";
	defaults.check_multiview_samplers = false;
	defaults.renames["INSTANCE_ID"] = "int(gi_source_context.info.y)";
	defaults.renames["VERTEX_ID"] = "int(gi_source_vertex_index)";
	defaults.renames["TIME"] = "gi_source_frame.time";
	defaults.renames["EXPOSURE"] = "gi_source_frame.exposure";
	defaults.renames["MAIN_CAM_INV_VIEW_MATRIX"] = "inv_view_matrix";
	defaults.renames["IN_SHADOW_PASS"] = "false";
	defaults.renames["CAMERA_VISIBLE_LAYERS"] = "gi_source_frame.layer_mask";
	defaults.renames["OUTPUT_IS_SRGB"] = "false";
	defaults.renames["CLIP_SPACE_FAR"] = "0.0";
	defaults.renames["FRAGCOORD"] = "gi_source_fragcoord";
	defaults.renames["FRONT_FACING"] = "gi_source_front_face";
	defaults.renames["DEPTH"] = "gi_source_depth";
	defaults.renames["IS_MULTIVIEW"] = "false";
	defaults.renames["VIEW_INDEX"] = "0";
	// There are no raster derivatives at a secondary hit. Ordinary implicit
	// samples use the caller's explicit reference texture/cone LOD; explicit
	// textureLod/textureGrad calls remain authored shader operations.
	defaults.implicit_texture_lod = "gi_source_lod";
	defaults.texture_coordinate_inputs["UV"] = "gi_source_triangle_uv[$CORNER]";
	defaults.texture_coordinate_inputs["UV2"] = "gi_source_triangle_uv2[$CORNER]";
	defaults.texture_coordinate_varying_prefix = "gi_source_corner_";
	defaults.implicit_texture_lod_expression = [](ShaderLanguage::DataType p_type, const String &p_sampler, const String &p_coordinate) -> String {
		if (p_type == ShaderLanguage::TYPE_SAMPLER2D || p_type == ShaderLanguage::TYPE_ISAMPLER2D || p_type == ShaderLanguage::TYPE_USAMPLER2D) {
			if (!p_coordinate.is_empty() && p_coordinate != "gi_source_triangle_uv[$CORNER]") {
				return "gi_source_mapped_texture_lod(vec2(textureSize(" + p_sampler + ", 0)), " + p_coordinate.replace("$CORNER", "0") + ", " + p_coordinate.replace("$CORNER", "1") + ", " + p_coordinate.replace("$CORNER", "2") + ")";
			}
			return "gi_source_texture_lod(vec2(textureSize(" + p_sampler + ", 0)))";
		}
		return "gi_source_lod";
	};
	defaults.discard_code = "gi_source_discarded = true;";
	TextureContext context;
	uint32_t texture_count = 0;
	for (const ShaderCompiler::GeneratedCode::Texture &texture : p_shader.texture_uniforms) {
		context.arrays[texture.name] = "gi_source_" + ShaderLanguage::get_datatype_name(texture.type);
		context.offsets[texture.name] = texture_count;
		texture_count += MAX(texture.array_size, 1);
	}
	defaults.texture_uniform_expression = texture_expression;
	defaults.texture_uniform_userdata = &context;
	ShaderCompiler compiler;
	compiler.initialize(defaults);
	ShaderCompiler::IdentifierActions actions;
	actions.entry_point_stages["vertex"] = ShaderCompiler::STAGE_VERTEX;
	actions.entry_point_stages["fragment"] = ShaderCompiler::STAGE_FRAGMENT;
	bool uses_derivatives = false;
	for (const char *name : { "dFdx", "dFdy", "fwidth", "dFdxCoarse", "dFdyCoarse", "fwidthCoarse", "dFdxFine", "dFdyFine", "fwidthFine", "textureQueryLod" }) {
		actions.usage_flag_pointers[name] = &uses_derivatives;
	}
	HashMap<StringName, ShaderLanguage::ShaderNode::Uniform> uniforms;
	actions.uniforms = &uniforms;
	ShaderCompiler::GeneratedCode generated;
	Error error = compiler.compile(RSE::SHADER_SPATIAL, p_shader.code, &actions, p_shader.path, generated);
	ERR_FAIL_COND_V(error != OK, error);
	if (uses_derivatives) {
		WARN_PRINT_ONCE(vformat("AMD GI source shader requires raster derivatives (%s); its surfaces are omitted from transport.", p_shader.path));
		return ERR_UNAVAILABLE;
	}
	ERR_FAIL_COND_V_MSG(generated.uniform_total_size != p_shader.ubo_size || generated.uniform_offsets != p_shader.ubo_offsets, ERR_BUG, "RT source-material uniforms must match the native material buffer layout.");
	if (p_shader.uses_emission && generated.has_unqualified_texture_coordinates) {
		WARN_PRINT(vformat("AMD GI emitter shader '%s' contains implicit texture reads outside the supported 2D affine mapping subset; the existing fallback is retained and filtering for those reads is not qualified. Explicit textureLod/textureGrad reads remain authored.", p_shader.path));
	}

	String source;
	if (generated.uniform_total_size != 0) {
		source += "layout(buffer_reference, std140, buffer_reference_align=16) readonly buffer " + uniform_type + " {\n" + generated.uniforms + "};\n";
	}
	for (const auto &varying : generated.private_varyings) {
		if (varying.array_size == 0) {
			source += ShaderLanguage::get_datatype_name(varying.type) + " gi_source_corner_" + varying.name + "[3];\n";
		}
	}
	source += generated.stage_globals[ShaderCompiler::STAGE_VERTEX];
	for (const char *stage : { "vertex", "fragment" }) {
		source += "void " + prefix + stage + "() {\n";
		if (generated.code.has(stage)) {
			source += generated.code[stage];
		}
		source += "}\n";
	}
	source += "GISourceMaterial " + prefix + "evaluate(uint instance, uint primitive, vec2 barycentrics, bool front_face) {\n";
	for (const auto &varying : generated.private_varyings) {
		source += ShaderLanguage::get_datatype_name(varying.type) + " accumulated_" + varying.name;
		if (varying.array_size > 0) {
			source += "[" + itos(varying.array_size) + "]";
		}
		source += ";\n";
	}
	source += "GIVertex interpolated;\nvec2 triangle_uv[3];\n";
	source += "uvec3 indices = gi_triangle_indices(instance, primitive);\n";
	source += "vec3 weights = vec3(1.0-barycentrics.x-barycentrics.y, barycentrics);\n";
	source += "gi_source_begin(instance, front_face);\n";
	// Vertex texture reads have no raster footprint. Do not let a previous
	// triangle's emitter area, or the fragment cone LOD, leak into them.
	source += "bool emitter_filtered=gi_source_filtered;\nfloat fragment_lod=gi_source_lod;\ngi_source_filtered=false;\ngi_source_lod=0.0;\n";
	source += "for (uint corner=0u; corner<3u; corner++) {\n";
	source += "gi_source_vertex_begin(instance, indices[corner]);\n";
	// Capsaicin's light builder packs each emitter UV into half2 before
	// proposal/target interpolation. Ordinary material hits keep source UVs.
	source += prefix + "vertex();\nif (emitter_filtered) uv_interp = unpackHalf2x16(packHalf2x16(uv_interp));\ntriangle_uv[corner] = uv_interp;\n";
	source += "gi_source_triangle_uv[corner]=uv_interp;\ngi_source_triangle_uv2[corner]=uv2_interp;\n";
	source += "gi_source_vertex_accumulate(interpolated, weights[corner], corner==0u);\n";
	for (const auto &varying : generated.private_varyings) {
		if (varying.array_size == 0) {
			source += "gi_source_corner_" + varying.name + "[corner] = " + varying.name + ";\n";
		}
		for (int i = 0; i < MAX(varying.array_size, 1); i++) {
			String element = varying.name + (varying.array_size > 0 ? "[" + itos(i) + "]" : String());
			if (varying.flat) {
				source += "if (corner==0u) accumulated_" + element + " = " + element + ";\n";
			} else {
				source += "if (corner==0u) accumulated_" + element + " = " + element + " * weights[corner]; else accumulated_" + element + " += " + element + " * weights[corner];\n";
			}
		}
	}
	source += "}\n";
	source += "vec2 edge_uv0=triangle_uv[1]-triangle_uv[0], edge_uv1=triangle_uv[2]-triangle_uv[0];\ngi_source_uv_area=abs(edge_uv0.x*edge_uv1.y-edge_uv1.x*edge_uv0.y);\ngi_source_filtered=emitter_filtered;\ngi_source_lod=fragment_lod;\ngi_source_fragment_begin(interpolated);\n";
	for (const auto &varying : generated.private_varyings) {
		source += varying.name + " = accumulated_" + varying.name + ";\n";
	}
	source += prefix + "fragment();\n";
	source += "return gi_source_fragment_end(" + String(p_shader.uses_normal_map ? "true" : "false") + ");\n}\n";
	r_shader.id = p_id;
	r_shader.source = source;
	r_shader.textures = generated.texture_uniforms;
	r_shader.texture_count = texture_count;
	return OK;
}

void RaytracingMaterialSource::begin_frame() {
	frame++;
	context_cursor = 0;
	prepared_calls = 0;
	prepared_hits = 0;
	prepared_unique = 0;
	for (TextureArray &array : texture_arrays) {
		array.textures.clear();
		array.indices.clear();
	}
	MaterialStorage::get_singleton()->_update_queued_materials();
}

int RaytracingMaterialSource::texture_array(ShaderLanguage::DataType p_type, RID p_fallback) {
	for (int i = 0; i < texture_arrays.size(); i++) {
		if (texture_arrays[i].type == p_type) {
			return i;
		}
	}
	TextureArray array;
	array.type = p_type;
	array.fallback = p_fallback;
	texture_arrays.push_back(array);
	shader_revision++;
	return texture_arrays.size() - 1;
}

bool RaytracingMaterialSource::update_buffer(RID &r_buffer, Vector<uint8_t> &r_previous, const Vector<uint8_t> &p_bytes) {
	if (r_buffer.is_valid() && r_previous == p_bytes) {
		return true;
	}
	RD *rd = RD::get_singleton();
	if (r_buffer.is_null() || r_previous.size() != p_bytes.size()) {
		if (r_buffer.is_valid()) {
			rd->free_rid(r_buffer);
		}
		r_buffer = rd->storage_buffer_create(MAX(p_bytes.size(), 16), {}, 0, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	}
	ERR_FAIL_COND_V(r_buffer.is_null(), false);
	if (!p_bytes.is_empty()) {
		ERR_FAIL_COND_V(rd->buffer_update(r_buffer, 0, p_bytes.size(), p_bytes.ptr()) != OK, false);
	}
	r_previous = p_bytes;
	return true;
}

Error RaytracingMaterialSource::prepare_surface(RID p_material, RID p_mesh, uint32_t p_surface, Context &r_context) {
	static const bool disabled = !OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_PREPARED_CONTEXTS").is_empty();
	static const bool validate = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE").is_empty();
	static const bool trace = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_PREPARED_CONTEXTS").is_empty();
	if (disabled) {
		return prepare_surface_uncached(p_material, p_mesh, p_surface, r_context);
	}
	if (trace) {
		prepared_calls++;
	}
	const PreparedSurfaceKey key{ p_material, p_mesh, p_surface };
	const PreparedSurface *prepared = prepared_surfaces.getptr(key);
	if (prepared && prepared->frame == frame) {
		if (validate) {
			Context reference;
			Error error = prepare_surface_uncached(p_material, p_mesh, p_surface, reference);
			ERR_FAIL_COND_V(error != OK, error);
			ERR_FAIL_COND_V_MSG(memcmp(&reference, &prepared->context, sizeof(Context)) != 0, ERR_BUG, "AMD GI prepared surface context differs from current source reconstruction.");
		}
		r_context = prepared->context;
		if (trace) {
			prepared_hits++;
		}
		return OK;
	}
	// Preserve first-use material/texture ordering and native region-write
	// polling. Failures are never cached and retain the original retry path.
	Error error = prepare_surface_uncached(p_material, p_mesh, p_surface, r_context);
	if (error == OK) {
		prepared_surfaces.insert(key, { r_context, frame });
		if (trace) {
			prepared_unique++;
		}
	}
	return error;
}

Error RaytracingMaterialSource::prepare_surface_uncached(RID p_material, RID p_mesh, uint32_t p_surface, Context &r_context) {
	RD *rd = RD::get_singleton();
	MaterialStorage *storage = MaterialStorage::get_singleton();
	auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(storage->material_get_data(p_material, MaterialStorage::SHADER_TYPE_3D));
	Context context;
	const Context *material_context = nullptr;
	if (data && data->shader_data) {
		Material &material = materials[p_material];
		if (material.frame != frame) {
			const SpatialShader &native = *data->shader_data;
			const uint32_t *id = material.shader && material.code == native.code ? &material.shader : shader_ids.getptr(native.code);
			if (!id) {
				Shader compiled;
				Error error = compile(RendererSceneRenderImplementation::RenderForwardClustered::get_singleton()->get_material_shader_compiler(), native, shaders.size() + 1, compiled);
				if (error == ERR_UNAVAILABLE) {
					shader_ids.insert(native.code, UINT32_MAX);
					return error;
				}
				ERR_FAIL_COND_V(error != OK, error);
				shaders.push_back(compiled);
				shader_ids.insert(native.code, compiled.id);
				id = shader_ids.getptr(native.code);
				shader_revision++;
			}
			if (*id == UINT32_MAX) {
				return ERR_UNAVAILABLE;
			}
			material.shader = *id;
			material.code = native.code;
			ERR_FAIL_COND_V(!update_buffer(material.uniforms, material.uniform_bytes, data->get_uniform_data(true)), ERR_CANT_CREATE);
			Vector<uint32_t> indices;
			const Vector<RID> &textures = data->get_texture_data();
			uint32_t index = 0;
			for (const auto &texture : native.texture_uniforms) {
				const int array_index = texture_array(texture.type, data->get_default_texture_id(texture.type, texture.hint));
				TextureArray &array = texture_arrays.write[array_index];
				for (int element = 0; element < MAX(texture.array_size, 1); element++) {
					ERR_FAIL_COND_V(index >= uint32_t(textures.size()), ERR_BUG);
					RID texture_rid = textures[index++];
					uint32_t *slot = array.indices.getptr(texture_rid);
					if (!slot) {
						array.indices.insert(texture_rid, array.textures.size());
						array.textures.push_back(texture_rid);
						slot = array.indices.getptr(texture_rid);
					}
					indices.push_back(*slot);
				}
			}
			if (material.indices.is_null() || material.texture_indices != indices) {
				if (material.indices.is_null() || material.texture_indices.size() != indices.size()) {
					if (material.indices.is_valid()) {
						rd->free_rid(material.indices);
					}
					material.indices = rd->storage_buffer_create(MAX(indices.size() * int(sizeof(uint32_t)), 16), {}, 0, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
				}
				ERR_FAIL_COND_V(material.indices.is_null(), ERR_CANT_CREATE);
				if (!indices.is_empty()) {
					ERR_FAIL_COND_V(rd->buffer_update(material.indices, 0, indices.size() * sizeof(uint32_t), indices.ptr()) != OK, ERR_CANT_CREATE);
				}
				material.texture_indices = indices;
			}
			material.context.uniform_address = rd->buffer_get_device_address(material.uniforms);
			material.context.texture_address = rd->buffer_get_device_address(material.indices);
			material.context.info[0] = material.shader;
			material.context.info[3] = native.uses_world_coordinates ? 4u : 0u;
			static const bool validate = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE").is_empty();
			if (validate) {
				if (!material.uniform_bytes.is_empty()) {
					const Vector<uint8_t> bytes = rd->buffer_get_data(material.uniforms, 0, material.uniform_bytes.size());
					ERR_FAIL_COND_V_MSG(bytes != data->get_uniform_data(true), ERR_BUG, "AMD GI material uniforms differ from native material data.");
				}
				if (!indices.is_empty()) {
					const Vector<uint8_t> bytes = rd->buffer_get_data(material.indices, 0, indices.size() * sizeof(uint32_t));
					ERR_FAIL_COND_V_MSG(bytes.size() != int64_t(indices.size() * sizeof(uint32_t)) || memcmp(bytes.ptr(), indices.ptr(), bytes.size()) != 0, ERR_BUG, "AMD GI texture indices differ from current dense texture order.");
				}
			}
			// Offscreen GI consumers still need live render-target textures.
			data->set_as_used();
			material.frame = frame;
		}
		material_context = &material.context;
	}
	Error layout_error = surface_context(p_mesh, p_surface, context);
	ERR_FAIL_COND_V(layout_error != OK, layout_error);
	if (material_context) {
		context.uniform_address = material_context->uniform_address;
		context.texture_address = material_context->texture_address;
		context.info[0] = material_context->info[0];
		context.info[3] |= material_context->info[3];
	}
	r_context = context;
	return OK;
}

Error RaytracingMaterialSource::add_surface(RID p_material, const RendererSceneRender::RaytracingGIInstance &p_instance, uint32_t p_surface, const Color &p_color, const Color &p_custom, Context *r_base_context, bool p_validate_retained) {
	Context context;
	Error error = prepare_surface(p_material, p_instance.mesh, p_surface, context);
	if (error != OK) {
		return error;
	}
	if (r_base_context) {
		*r_base_context = context;
	}
	for (uint32_t i = 0; i < 4; i++) {
		context.color[i] = p_color[i];
		context.custom[i] = p_custom[i];
	}
	context.info[1] = p_instance.element;
	context.info[2] = uint32_t(p_instance.uniforms_offset);
	if (p_validate_retained) {
		ERR_FAIL_COND_V_MSG(context_cursor >= contexts.size() || memcmp(&contexts[context_cursor], &context, sizeof(Context)) != 0, ERR_BUG, "AMD GI retained material context differs from full reconstruction.");
	}
	if (context_cursor >= contexts.size() || memcmp(&contexts[context_cursor], &context, sizeof(Context)) != 0) {
		context_dirty_begin = MIN(context_dirty_begin, context_cursor);
		context_dirty_end = MAX(context_dirty_end, context_cursor + 1);
	}
	if (context_cursor == contexts.size()) {
		contexts.push_back(context);
	} else {
		contexts[context_cursor] = context;
	}
	context_cursor++;
	return OK;
}

bool RaytracingMaterialSource::retain_contexts(uint32_t p_count) {
	ERR_FAIL_COND_V(context_cursor > contexts.size() || p_count > contexts.size() - context_cursor, false);
	context_cursor += p_count;
	return true;
}

RaytracingMaterialSource::Context RaytracingMaterialSource::build_surface_context(uint64_t p_format, uint32_t p_count, const Vector4 &p_uv_scale, uint64_t p_attribute_address) {
	Context context;
	context.attribute_address = p_attribute_address;
	if (p_attribute_address) {
		RenderingServer *server = RenderingServer::get_singleton();
		context.attributes[3] = server->mesh_surface_get_format_attribute_stride(p_format, p_count) / sizeof(uint32_t);
		const RSE::ArrayType builtin[] = { RSE::ARRAY_TEX_UV, RSE::ARRAY_TEX_UV2, RSE::ARRAY_COLOR };
		for (uint32_t i = 0; i < 3; i++) {
			if (p_format & (uint64_t(1) << builtin[i])) {
				context.attributes[i] = server->mesh_surface_get_format_offset(p_format, p_count, builtin[i]) / sizeof(uint32_t);
			}
		}
		for (uint32_t i = 0; i < 4; i++) {
			if (p_format & (uint64_t(1) << (RSE::ARRAY_CUSTOM0 + i))) {
				context.custom_offsets[i] = server->mesh_surface_get_format_offset(p_format, p_count, RSE::ARRAY_CUSTOM0 + i) / sizeof(uint32_t);
				context.custom_formats[i] = (p_format >> (RSE::ARRAY_FORMAT_CUSTOM0_SHIFT + i * RSE::ARRAY_FORMAT_CUSTOM_BITS)) & RSE::ARRAY_FORMAT_CUSTOM_MASK;
			}
		}
	}
	for (uint32_t i = 0; i < 4; i++) {
		context.uv_scale[i] = p_uv_scale[i];
	}
	context.info[3] = (p_format & RSE::ARRAY_FORMAT_TANGENT) ? 1u : 0u;
	context.info[3] |= (p_format & RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES) ? 2u : 0u;
	return context;
}

Error RaytracingMaterialSource::surface_context(RID p_mesh, uint32_t p_surface, Context &r_context) {
	MeshStorage *meshes = MeshStorage::get_singleton();
	RD *rd = RD::get_singleton();
	static const bool validate = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE").is_empty();
	MeshLayouts &mesh = mesh_layouts[p_mesh];
	if (mesh.frame != frame) {
		mesh.surfaces.resize(meshes->mesh_get_surface_count(p_mesh));
		mesh.frame = frame;
	}
	ERR_FAIL_UNSIGNED_INDEX_V(p_surface, uint32_t(mesh.surfaces.size()), ERR_INVALID_PARAMETER);
	SurfaceLayout &layout = mesh.surfaces.write[p_surface];
	if (layout.frame != frame) {
		// Poll each shared surface once per scene update. Native region writes
		// increment data_revision without emitting scene dependency notifications.
		void *surface = meshes->mesh_get_surface(p_mesh, p_surface);
		const uint64_t format = meshes->mesh_surface_get_format(surface);
		const uint32_t count = meshes->mesh_surface_get_vertex_count(surface);
		const Vector4 uv_scale = meshes->mesh_surface_get_uv_scale(surface);
		const RID source = meshes->mesh_surface_get_attribute_buffer_rd_rid(p_mesh, p_surface);
		uint64_t address = 0;
		if (source.is_valid()) {
			const uint32_t stride = RenderingServer::get_singleton()->mesh_surface_get_format_attribute_stride(format, count);
			if (stride > 0) {
				Attributes &copy = attributes[source];
				const uint32_t size = stride * count;
				const uint64_t revision = meshes->mesh_surface_get_data_revision(surface);
				if (copy.buffer.is_null() || copy.size != size) {
					if (copy.buffer.is_valid()) {
						rd->free_rid(copy.buffer);
					}
					copy.buffer = rd->storage_buffer_create(size, {}, 0, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
					ERR_FAIL_COND_V(copy.buffer.is_null(), ERR_CANT_CREATE);
					copy.size = size;
					copy.revision = UINT64_MAX;
				}
				if (copy.revision != revision) {
					ERR_FAIL_COND_V(rd->buffer_copy(source, copy.buffer, 0, 0, size) != OK, ERR_CANT_CREATE);
					copy.revision = revision;
				}
				copy.frame = frame;
				address = rd->buffer_get_device_address(copy.buffer);
				if (validate) {
					ERR_FAIL_COND_V_MSG(rd->buffer_get_data(source, 0, size) != rd->buffer_get_data(copy.buffer, 0, size), ERR_BUG, "AMD GI source attributes differ from native attribute buffer.");
				}
			}
		}
		bool changed = layout.format != format || layout.count != count || layout.source != source || layout.context.attribute_address != address;
		for (uint32_t i = 0; i < 4; i++) {
			changed |= layout.context.uv_scale[i] != uv_scale[i];
		}
		if (changed) {
			layout.context = build_surface_context(format, count, uv_scale, address);
			layout.format = format;
			layout.count = count;
			layout.source = source;
		}
		layout.frame = frame;
	}
	r_context = layout.context;
	if (validate) {
		void *surface = meshes->mesh_get_surface(p_mesh, p_surface);
		const RID source = meshes->mesh_surface_get_attribute_buffer_rd_rid(p_mesh, p_surface);
		const Attributes *copy = attributes.getptr(source);
		const uint64_t format = meshes->mesh_surface_get_format(surface);
		const uint32_t count = meshes->mesh_surface_get_vertex_count(surface);
		const bool has_attributes = RenderingServer::get_singleton()->mesh_surface_get_format_attribute_stride(format, count) > 0;
		const Context reference = build_surface_context(format, count, meshes->mesh_surface_get_uv_scale(surface), copy && has_attributes ? rd->buffer_get_device_address(copy->buffer) : 0);
		ERR_FAIL_COND_V_MSG(memcmp(&reference, &r_context, sizeof(Context)) != 0, ERR_BUG, "AMD GI cached surface layout differs from full reconstruction.");
	}
	return OK;
}

bool RaytracingMaterialSource::end_frame() {
	contexts.resize(context_cursor);
	RD *rd = RD::get_singleton();
	for (TextureArray &array : texture_arrays) {
		if (array.textures.size() > int(array.capacity)) {
			array.capacity = Math::next_power_of_2(uint32_t(array.textures.size()));
			shader_revision++;
		}
	}
	if (context_buffer.is_null() || contexts.size() > context_capacity) {
		if (context_buffer.is_valid()) {
			rd->free_rid(context_buffer);
		}
		context_capacity = Math::next_power_of_2(MAX(contexts.size(), 1u));
		context_buffer = rd->storage_buffer_create(16 + context_capacity * sizeof(Context));
		uploaded_contexts.clear();
		context_dirty_begin = 0;
		context_dirty_end = contexts.size();
	}
	ERR_FAIL_COND_V(context_buffer.is_null(), false);
	float header[4] = { float(RendererCompositorRD::get_singleton()->get_total_time()), float(contexts.size()), 0, 0 };
	ERR_FAIL_COND_V(rd->buffer_update(context_buffer, 0, sizeof(header), header) != OK, false);
	uint32_t first_changed = MIN(context_dirty_begin, contexts.size());
	uint32_t end_changed = MIN(context_dirty_end, contexts.size());
	static const bool disable_changed_ranges = !OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_CHANGED_RANGES").is_empty();
	if (disable_changed_ranges) {
		first_changed = 0;
		end_changed = contexts.size();
	}
	if (contexts.size() > uploaded_contexts.size()) {
		first_changed = MIN(first_changed, uploaded_contexts.size());
		end_changed = contexts.size();
	}
	while (first_changed < end_changed && first_changed < uploaded_contexts.size() && memcmp(&contexts[first_changed], &uploaded_contexts[first_changed], sizeof(Context)) == 0) {
		first_changed++;
	}
	while (end_changed > first_changed && end_changed <= uploaded_contexts.size() && memcmp(&contexts[end_changed - 1], &uploaded_contexts[end_changed - 1], sizeof(Context)) == 0) {
		end_changed--;
	}
	if (end_changed > first_changed) {
		// One coalesced range bounds transfer-command overhead even if changes
		// are scattered. Dense IDs and source texture order remain unchanged.
		ERR_FAIL_COND_V(rd->buffer_update(context_buffer, sizeof(header) + first_changed * sizeof(Context), (end_changed - first_changed) * sizeof(Context), contexts.ptr() + first_changed) != OK, false);
	}
	static const bool validate = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE").is_empty();
	if (validate) {
		const Vector<uint8_t> uploaded = rd->buffer_get_data(context_buffer, 0, sizeof(header) + contexts.size() * sizeof(Context));
		ERR_FAIL_COND_V_MSG(uploaded.size() != int64_t(sizeof(header) + contexts.size() * sizeof(Context)) || memcmp(uploaded.ptr(), header, sizeof(header)) != 0 || (!contexts.is_empty() && memcmp(uploaded.ptr() + sizeof(header), contexts.ptr(), contexts.size() * sizeof(Context)) != 0), false, "AMD GI context upload differs from full reconstruction.");
	}
	// Never publish the CPU upload snapshot before all transfer calls succeed.
	if (uploaded_contexts.size() != contexts.size()) {
		uploaded_contexts.resize(contexts.size());
	}
	if (end_changed > first_changed) {
		memcpy(uploaded_contexts.ptr() + first_changed, contexts.ptr() + first_changed, (end_changed - first_changed) * sizeof(Context));
	}
	context_dirty_begin = UINT32_MAX;
	context_dirty_end = 0;
	LocalVector<PreparedSurfaceKey> expired_prepared;
	for (const auto &entry : prepared_surfaces) {
		if (entry.value.frame != frame) {
			expired_prepared.push_back(entry.key);
		}
	}
	for (const PreparedSurfaceKey &key : expired_prepared) {
		prepared_surfaces.erase(key);
	}
	static const bool trace_prepared = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_PREPARED_CONTEXTS").is_empty();
	if (trace_prepared) {
		print_line(vformat("AMD GI prepared contexts: calls=%d hits=%d unique_successful_keys=%d", prepared_calls, prepared_hits, prepared_unique));
	}
	// Remove resources once their source is no longer in the collected scene.
	LocalVector<RID> expired;
	for (const auto &entry : materials) {
		if (entry.value.frame != frame) {
			if (entry.value.uniforms.is_valid()) {
				rd->free_rid(entry.value.uniforms);
			}
			if (entry.value.indices.is_valid()) {
				rd->free_rid(entry.value.indices);
			}
			expired.push_back(entry.key);
		}
	}
	for (RID rid : expired) {
		materials.erase(rid);
	}
	expired.clear();
	for (const auto &entry : attributes) {
		if (entry.value.frame != frame) {
			rd->free_rid(entry.value.buffer);
			expired.push_back(entry.key);
		}
	}
	for (RID rid : expired) {
		attributes.erase(rid);
	}
	expired.clear();
	for (const auto &entry : mesh_layouts) {
		if (entry.value.frame != frame) {
			expired.push_back(entry.key);
		}
	}
	for (RID rid : expired) {
		mesh_layouts.erase(rid);
	}
	return true;
}

String RaytracingMaterialSource::get_shader_source() const {
	String source;
	for (int i = 0; i < texture_arrays.size(); i++) {
		const TextureArray &array = texture_arrays[i];
		String type = ShaderLanguage::get_datatype_name(array.type);
		source += "layout(set=1,binding=" + itos(14 + i) + ") uniform " + type.replace("sampler", "texture") + " gi_source_" + type + "[" + itos(array.capacity) + "];\n";
	}
	for (const Shader &compiled : shaders) {
		source += compiled.source;
	}
	source += "GISourceMaterial gi_source_material_filtered(uint instance, uint primitive, vec2 barycentrics, bool front_face, float lod, bool filtered) {\n gi_source_lod = lod;\n gi_source_filtered = filtered;\n switch (gi_sources.data[instance].info.x) {\n";
	for (const Shader &compiled : shaders) {
		source += "case " + itos(compiled.id) + "u: return rtm" + itos(compiled.id) + "_evaluate(instance, primitive, barycentrics, front_face);\n";
	}
	source += "default: return GISourceMaterial(vec4(1), vec4(0), vec4(1,1,0,0));\n }\n}\n";
	source += "GISourceMaterial gi_source_material(uint instance, uint primitive, vec2 barycentrics, bool front_face, float lod) { return gi_source_material_filtered(instance, primitive, barycentrics, front_face, lod, false); }\n";
	return source;
}

void RaytracingMaterialSource::append_uniforms(LocalVector<RD::Uniform> &r_uniforms) const {
	MaterialStorage::get_singleton()->samplers_rd_get_default().append_uniforms(r_uniforms, 2);
	RD::Uniform contexts_uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, context_buffer);
	r_uniforms.push_back(contexts_uniform);
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, MaterialStorage::get_singleton()->global_shader_uniforms_get_storage_buffer()));
	for (int i = 0; i < texture_arrays.size(); i++) {
		const TextureArray &array = texture_arrays[i];
		RD::Uniform textures(RD::UNIFORM_TYPE_TEXTURE, 14 + i, Vector<RID>());
		for (uint32_t index = 0; index < array.capacity; index++) {
			textures.append_id(index < uint32_t(array.textures.size()) ? array.textures[index] : array.fallback);
		}
		r_uniforms.push_back(textures);
	}
}

void RaytracingMaterialSource::add_buffer_reads(RD::ComputeListID p_list) const {
	RD *rd = RD::get_singleton();
	for (const auto &entry : materials) {
		if (entry.value.frame == frame) {
			rd->compute_list_add_buffer_read(p_list, entry.value.uniforms);
			rd->compute_list_add_buffer_read(p_list, entry.value.indices);
		}
	}
	for (const auto &entry : attributes) {
		if (entry.value.frame == frame) {
			rd->compute_list_add_buffer_read(p_list, entry.value.buffer);
		}
	}
}

void RaytracingMaterialSource::append_buffer_reads(LocalVector<RID> &r_buffers) const {
	for (const auto &entry : materials) {
		if (entry.value.frame == frame) {
			r_buffers.push_back(entry.value.uniforms);
			r_buffers.push_back(entry.value.indices);
		}
	}
	for (const auto &entry : attributes) {
		if (entry.value.frame == frame) {
			r_buffers.push_back(entry.value.buffer);
		}
	}
}

void RaytracingMaterialSource::clear() {
	RD *rd = RD::get_singleton();
	for (const auto &entry : materials) {
		if (entry.value.uniforms.is_valid()) {
			rd->free_rid(entry.value.uniforms);
		}
		if (entry.value.indices.is_valid()) {
			rd->free_rid(entry.value.indices);
		}
	}
	for (const auto &entry : attributes) {
		rd->free_rid(entry.value.buffer);
	}
	if (context_buffer.is_valid()) {
		rd->free_rid(context_buffer);
	}
	context_buffer = RID();
	context_capacity = 0;
	context_cursor = 0;
	context_dirty_begin = UINT32_MAX;
	context_dirty_end = 0;
	prepared_surfaces.clear();
	materials.clear();
	attributes.clear();
	mesh_layouts.clear();
	texture_arrays.clear();
	contexts.clear();
	uploaded_contexts.clear();
	shaders.clear();
	shader_ids.clear();
	shader_revision++;
}

RaytracingMaterialSource::~RaytracingMaterialSource() {
	clear();
}
