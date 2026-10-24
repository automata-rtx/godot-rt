extends Node3D

const GI := "rendering/global_illumination/amd_gi/"
var _material: ShaderMaterial
var _instance: MeshInstance3D


func _mesh(compressed: bool) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-2, -2, 0), Vector3(2, -2, 0), Vector3(-2, 2, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2(0.5, 0), Vector2(0, 0.5)])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0.125, 0.25), Vector2(0.875, 0.25), Vector2(0.125, 0.75)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(0.2, 0, 0), Color(0.4, 0, 0), Color(0.6, 0, 0)])
	arrays[Mesh.ARRAY_CUSTOM0] = PackedFloat32Array([1.25, 2.25, 3.25])
	var flags := Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	if compressed:
		flags |= Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	mesh.surface_set_material(0, _material)
	return mesh


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "reflections/enabled", false)
	RenderingServer.global_shader_parameter_add("gi_source_bias", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.03125)
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_disabled, depth_draw_always;
uniform sampler2D test_map : filter_nearest_mipmap, repeat_disable;
uniform int coverage_mode = 0;
uniform vec3 tint = vec3(1.0, 0.5, 0.25);
global uniform float gi_source_bias;
instance uniform float instance_bias = 0.0625;
varying vec2 bridge;
varying float attribute_value;
void vertex() {
    bridge = UV2;
    attribute_value = CUSTOM0.x + texture(test_map, vec2(0.11, 0.08)).r;
    UV *= 4.0;
}
void fragment() {
    ALBEDO = vec3(bridge, COLOR.r) + vec3(attribute_value * 0.1 + gi_source_bias + instance_bias);
    ALPHA = 0.25 + bridge.y * 0.5;
    EMISSION = texture(test_map, UV).rgb * tint;
    if (coverage_mode > 0) {
        float coverage = textureLod(test_map, UV + vec2(0.013, 0.017), 0.0).r;
        ALPHA = coverage;
        if (coverage_mode == 2) {
            ALPHA = 1.0;
            if (coverage < 0.5) { discard; }
        }
    }
}
"""
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBAF)
	for y in 32:
		for x in 32:
			image.set_pixel(x, y, Color(float((x + y) % 2), float(x) / 31.0, float(y) / 31.0, 1))
	image.generate_mipmaps()
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("test_map", ImageTexture.create_from_image(image))
	_instance = MeshInstance3D.new()
	_instance.mesh = _mesh(false)
	add_child(_instance)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	add_child(world)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 5)
	add_child(camera)
	camera.make_current()
	for phase in 8:
		if phase == 1:
			_material.set_shader_parameter("tint", Vector3(0.5, 1.0, 0.75))
			RenderingServer.global_shader_parameter_set("gi_source_bias", 0.125)
			_instance.set_instance_shader_parameter("instance_bias", 0.25)
		if phase == 2:
			_instance.mesh = _mesh(true)
		if phase == 3:
			_instance.transform = Transform3D(Basis(Vector3.UP, 0.3), Vector3(0.25, 0, 0))
			camera.position.x += 0.5
		if phase == 6:
			_material.set_shader_parameter("tint", Vector3.ZERO)
		if phase == 7:
			shader.code = shader.code.replace("    EMISSION = texture(test_map, UV).rgb * tint;", "")
		if phase >= 4:
			_material.set_shader_parameter("coverage_mode", phase - 3)
		print("SOURCE phase %d" % phase)
		for frame in 4:
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
	print("SOURCE FINISHED")
	get_tree().quit()
