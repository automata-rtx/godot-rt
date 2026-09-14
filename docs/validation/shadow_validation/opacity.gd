extends Node3D

# Does DirectionalLight3D.shadow_opacity do what it says on a RAYTRACED sun?
#
# shadow_opacity is a linear fade of the shadow toward fully lit, so the light a
# shadowed pixel loses at 0.5 must be exactly half what it loses at 1.0. Three
# captures -- no shadow at all, opacity 1.0, opacity 0.5 -- make that a ratio
# that can be read off rather than judged.
#
# Boxes on open ground, hard sun, denoiser off, so the shadow is deterministic
# and binary and the ratio is not measuring filter noise.

const OUT := "res://out/"
var _sun: DirectionalLight3D
var _boxes: Node3D
var _frame := 0
var _stage := 0


func _ready() -> void:
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(40, 40)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.62, 0.58, 0.50)
	gm.roughness = 1.0
	ground_mesh.material = gm
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	add_child(ground)

	_boxes = Node3D.new()
	add_child(_boxes)
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.30, 0.34, 0.40)
	bm.roughness = 1.0
	for x in 4:
		for z in 3:
			var box := BoxMesh.new()
			box.size = Vector3(0.5, 1.2, 0.5)
			box.material = bm
			var mi := MeshInstance3D.new()
			mi.mesh = box
			mi.position = Vector3((x - 1.5) * 1.9, 0.6, (z - 1.0) * 1.9)
			_boxes.add_child(mi)

	_sun = DirectionalLight3D.new()
	_sun.light_energy = 1.4
	_sun.shadow_enabled = true
	_sun.light_angular_distance = 0.0
	_sun.shadow_bias = 0.002
	_sun.shadow_normal_bias = 0.0
	_sun.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	add_child(_sun)

	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.position = Vector3(0.0, 4.2, 6.5)
	cam.rotation_degrees = Vector3(-30.0, 0.0, 0.0)
	cam.current = true
	add_child(cam)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.07, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.70)
	env.ambient_light_energy = 0.20
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	print("=== shadow_opacity probe: raytraced sun, hard, denoiser off ===")


func _shoot(n: String) -> void:
	print("saved %s err=%d" % [n, get_viewport().get_texture().get_image().save_png(OUT + n + ".png")])


const RT_DIR := "rendering/lights_and_shadows/raytraced_shadows/directional/enabled"

# Opacities to sweep. lost(o) should be proportional to o exactly once; if the
# fade is applied k times it goes as o^k, so the exponent of the fitted curve
# counts the applications directly.
const OPS := [1.0, 0.75, 0.5, 0.25]


func _process(_dt: float) -> void:
	_frame += 1
	match _stage:
		0:
			if _frame > 40:
				for c in _boxes.get_children():
					c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				_stage = 1; _frame = 0
		1:
			if _frame > 20:
				_shoot("a_none")
				for c in _boxes.get_children():
					c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				_sun.shadow_opacity = OPS[0]
				_stage = 2; _frame = 0
		2, 3, 4, 5:
			if _frame > 22:
				var k := _stage - 2
				_shoot("rt_%03d" % int(OPS[k] * 100.0))
				if k + 1 < OPS.size():
					_sun.shadow_opacity = OPS[k + 1]
					_stage += 1
				else:
					# Control: the shadow MAP path, which applies the fade once and
					# must therefore come out exactly linear. If it does not, the
					# fault is in the measurement rather than the raytraced path.
					ProjectSettings.set_setting(RT_DIR, false)
					_sun.shadow_opacity = 1.0
					_stage = 6
				_frame = 0
		6:
			if _frame > 25:
				_shoot("map_100")
				_sun.shadow_opacity = 0.5
				_stage = 7; _frame = 0
		7:
			if _frame > 22:
				_shoot("map_050")
				print("=== done ===")
				get_tree().quit()
