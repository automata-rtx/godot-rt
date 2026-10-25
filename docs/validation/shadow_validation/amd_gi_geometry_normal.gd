extends Node3D

# Run only with explicit permission to launch the renderer. This is an attachment
# correctness test, not a visual judgment or a reflection-flicker benchmark.
const P0 := Vector3(-0.6, -0.6, 0.0)
const P1 := Vector3(0.0, 0.6, 0.3)
const P2 := Vector3(0.6, -0.6, 0.6)
const AUTHORED := Vector3(0.0, 0.98, 0.2)

class NormalReadback extends CompositorEffect:

	signal completed(ok: bool, details: String)

	const SOURCE := """#version 450
layout(local_size_x=1, local_size_y=1, local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D geometry_normal;
layout(set=0,binding=1) uniform sampler2D shading_normal;
layout(set=0,binding=2,std430) writeonly buffer Result { vec4 value[2]; } result;
layout(push_constant,std430) uniform Params { vec2 sample_uv; } params;
void main() {
    ivec2 pixel = ivec2(params.sample_uv * vec2(textureSize(geometry_normal, 0)));
    result.value[0] = texelFetch(geometry_normal, pixel, 0);
    result.value[1] = texelFetch(shading_normal, pixel, 0);
}
"""

	var sample_uv := Vector2(0.5, 0.5)
	var expected_geometry := Vector3.BACK
	var expected_shading := Vector3.BACK
	var _finished := false
	var _frames := 0
	var _valid_frames := 0


	func _init() -> void:
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE


	func _finish(ok: bool, details: String) -> void:
		completed.emit(ok, details)


	func _render_callback(_type: int, render_data: RenderData) -> void:
		if _finished:
			return
		_frames += 1
		var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
		if buffers == null or not buffers.has_texture("amd_gi_geometry", "geometry_normal") or not buffers.has_texture("amd_gi_geometry", "shading_normal"):
			if _frames >= 60:
				_finished = true
				_finish.call_deferred(false, "GI normal attachments did not become available")
			return
		# Allow initial native shader/pipeline setup to settle before sampling.
		_valid_frames += 1
		if _valid_frames < 4:
			return
		_finished = true
		var rd := RenderingServer.get_rendering_device()
		var source := RDShaderSource.new()
		source.source_compute = SOURCE
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_compute.is_empty():
			_finish.call_deferred(false, spirv.compile_error_compute)
			return
		var shader := rd.shader_create_from_spirv(spirv)
		var pipeline := rd.compute_pipeline_create(shader)
		var output := rd.storage_buffer_create(32)
		var sampler := rd.sampler_create(RDSamplerState.new())
		var uniforms: Array[RDUniform] = []
		for index in 2:
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.binding = index
			uniform.add_id(sampler)
			uniform.add_id(buffers.get_texture("amd_gi_geometry", "geometry_normal" if index == 0 else "shading_normal"))
			uniforms.append(uniform)
		var result_uniform := RDUniform.new()
		result_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		result_uniform.binding = 2
		result_uniform.add_id(output)
		uniforms.append(result_uniform)
		var bindings := rd.uniform_set_create(uniforms, shader, 0)
		var push := PackedFloat32Array([sample_uv.x, sample_uv.y]).to_byte_array()
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, bindings, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()
		# Main-device synchronous readback flushes the graph; do not submit/sync it
		# as if it were a standalone RenderingDevice. These attachments have no
		# COPY_FROM usage, so sample them rather than using texture_get_data.
		var values := rd.buffer_get_data(output).to_float32_array()
		for rid in [bindings, pipeline, output, sampler, shader]:
			rd.free_rid(rid)
		if values.size() != 8:
			_finish.call_deferred(false, "Normal readback size was not 32 bytes")
			return
		var geometry := (Vector3(values[0], values[1], values[2]) * 2.0 - Vector3.ONE).normalized()
		var shading := (Vector3(values[4], values[5], values[6]) * 2.0 - Vector3.ONE).normalized()
		# A2B10G10R10 UNORM quantization plus normalized reconstruction.
		var ok := values[3] > 0.5 and values[7] > 0.5 and geometry.distance_to(expected_geometry) < 0.005 and shading.distance_to(expected_shading) < 0.005
		_finish.call_deferred(ok, "geometry=%s expected=%s shading=%s expected=%s" % [geometry, expected_geometry, shading, expected_shading])


var _completed := false


func _ready() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", false)
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	get_viewport().use_taa = false
	get_viewport().scaling_3d_scale = 1.0
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([P0, P1, P2])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([AUTHORED.normalized(), AUTHORED.normalized(), AUTHORED.normalized()])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.8, 0.6, 0.2)
	material.metallic = 1.0
	material.roughness = 0.25
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	add_child(instance)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position = Vector3(0, 0, 5)
	add_child(camera)
	camera.current = true
	var effect := NormalReadback.new()
	effect.expected_geometry = (P2 - P0).cross(P1 - P0).normalized()
	effect.expected_shading = AUTHORED.normalized()
	effect.sample_uv = camera.unproject_position((P0 + P1 + P2) / 3.0) / get_viewport().get_visible_rect().size
	effect.completed.connect(_on_completed)
	var compositor := Compositor.new()
	compositor.compositor_effects = [effect]
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.compositor = compositor
	add_child(world)
	print("GI_GEOMETRY_NORMAL analytic plane=%s authored=%s angle_deg=%f" % [effect.expected_geometry, effect.expected_shading, rad_to_deg(effect.expected_geometry.angle_to(effect.expected_shading))])
	_timeout.call_deferred()


func _timeout() -> void:
	await get_tree().create_timer(30.0).timeout
	if not _completed:
		_on_completed(false, "No compositor result within 30 seconds")


func _on_completed(ok: bool, details: String) -> void:
	_completed = true
	print("GI_GEOMETRY_NORMAL %s: %s" % ["PASS" if ok else "FAIL", details])
	if not ok:
		push_error(details)
	get_tree().quit(0 if ok else 1)
