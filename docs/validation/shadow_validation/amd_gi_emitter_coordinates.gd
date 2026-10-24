extends "res://amd_gi_source_material.gd"

# Each mip stores its level in red and its sample position in green/blue.
# This tests the selected footprint and coordinates independently of lighting noise.
func _mip_texture() -> ImageTexture:
	var bytes := PackedByteArray()
	for mip in 6:
		var width := 32 >> mip
		for y in width:
			for x in width:
				for value in [float(mip) / 8.0, (float(x) + 0.5) / width, (float(y) + 0.5) / width, 1.0]:
					var at := bytes.size()
					bytes.resize(at + 4)
					bytes.encode_float(at, value)
	return ImageTexture.create_from_image(Image.create_from_data(32, 32, true, Image.FORMAT_RGBAF, bytes))


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "reflections/enabled", false)
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_disabled;
uniform sampler2D test_map : filter_nearest_mipmap, repeat_disable;
uniform int mapping = 0;
uniform vec2 scale = vec2(0.25, 0.5);
uniform float angle = 0.37;
varying vec2 bridge;
varying flat vec2 fixed_uv;
void vertex() {
    bridge = UV2;
    fixed_uv = UV2;
    UV *= 4.0;
}
void fragment() {
    ALBEDO = vec3(0.25);
    ALBEDO.r *= 0.5;
    EMISSION = texture(test_map, UV).rgb;
    if (mapping == 1) {
        EMISSION = texture(test_map, UV2).rgb;
    } else if (mapping == 2) {
        EMISSION = texture(test_map, UV2 * vec2(4.0, 0.25) + vec2(0.02, 0.03)).rgb;
    } else if (mapping == 3) {
        mat2 rotation = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle)));
        vec2 mapped = rotation * (UV2 * scale) + vec2(0.3, 0.1);
        EMISSION = texture(test_map, mapped).rgb;
    } else if (mapping == 4) {
        vec2 mapped = UV;
        mapped *= vec2(0.125, 0.25);
        mapped += vec2(0.1, 0.2);
        EMISSION = texture(test_map, mapped).rgb;
    } else if (mapping == 5) {
        EMISSION = texture(test_map, vec2(bridge.x * 2.0, bridge.y * 0.25)).rgb;
    } else if (mapping == 6) {
        vec2 mapped = UV;
        mapped = UV2 * 0.5;
        EMISSION = texture(test_map, mapped).rgb;
    } else if (mapping == 7) {
        EMISSION = texture(test_map, UV2.yx * vec2(-0.5, 0.25) + vec2(0.6, 0.1)).rgb;
    } else if (mapping == 8) {
        EMISSION = texture(test_map, UV2 / vec2(4.0, 2.0), 0.375).rgb;
    } else if (mapping == 9) {
        EMISSION = textureLod(test_map, UV2, 2.0).rgb;
    } else if (mapping == 10) {
        EMISSION = texture(test_map, fixed_uv).rgb;
    }
}
"""
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("test_map", _mip_texture())
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
	for phase in 22:
		if phase == 11:
			_instance.mesh = _mesh(true)
			_material.set_shader_parameter("scale", Vector2(0.5, 0.125))
			_material.set_shader_parameter("angle", -0.61)
		_material.set_shader_parameter("mapping", phase % 11)
		print("COORDINATE phase %d" % phase)
		for frame in 4:
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
	print("COORDINATE FINISHED")
	get_tree().quit()
