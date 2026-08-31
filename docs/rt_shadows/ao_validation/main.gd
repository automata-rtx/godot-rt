extends Node3D

# Ambient-only validation scene. With no direct light and a fully rough, non
# specular white material, a shaded pixel is exactly ambient * albedo * AO, so
# dividing a render with occlusion by one without it recovers the AO term
# itself rather than something the shading has already mixed.
#
# Geometry is all axis aligned boxes so the same scene can be ray traced
# independently on the CPU without importing anything from the engine.

const BOXES := [
	# position, size
	[Vector3(0, -0.1, 0), Vector3(20, 0.2, 20)],
	[Vector3(-1.2, 0.35, 0.0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(-0.25, 0.35, 0.0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(0.7, 0.35, 0.0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(1.65, 0.35, 0.0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(0, 0.8, -1.2), Vector3(4.0, 1.6, 0.15)],
	[Vector3(1.6, 0.9, 0.9), Vector3(1.6, 0.06, 1.0)],
]

const CAM_POS := Vector3(3.2, 2.4, 3.2)
const CAM_TARGET := Vector3(0, 0.4, 0)
const CAM_FOV := 75.0

const THIN_BOXES := [
	[Vector3(0, -0.1, 0), Vector3(20, 0.2, 20)],
	[Vector3(-1.5, 1.05, 0), Vector3(0.05, 2.1, 2.2)],
	[Vector3(0.9, 1.1, -1.25), Vector3(2.4, 0.07, 0.22)],
	[Vector3(0.9, 1.1, -0.75), Vector3(2.4, 0.07, 0.22)],
	[Vector3(0.9, 1.1, -0.25), Vector3(2.4, 0.07, 0.22)],
	[Vector3(0.9, 1.1, 0.25), Vector3(2.4, 0.07, 0.22)],
	[Vector3(0.9, 1.1, 0.75), Vector3(2.4, 0.07, 0.22)],
	[Vector3(0.9, 1.1, 1.25), Vector3(2.4, 0.07, 0.22)],
	[Vector3(0.4, 0.62, 1.6), Vector3(1.4, 0.06, 1)],
	[Vector3(-0.2, 0.3, 1.18), Vector3(0.07, 0.6, 0.07)],
	[Vector3(-0.2, 0.3, 2.02), Vector3(0.07, 0.6, 0.07)],
	[Vector3(1, 0.3, 1.18), Vector3(0.07, 0.6, 0.07)],
	[Vector3(1, 0.3, 2.02), Vector3(0.07, 0.6, 0.07)],
]
const THIN_CAM_POS := Vector3(2.9, 1.9, 3.4)
const THIN_CAM_TARGET := Vector3(0, 0.45, 0.2)

var frames := 0

func _ready() -> void:
	var thin := OS.get_environment("AO_SCENE") == "thin"
	var boxes: Array = THIN_BOXES if thin else BOXES

	var cam := Camera3D.new()
	cam.position = THIN_CAM_POS if thin else CAM_POS
	add_child(cam)
	cam.look_at(THIN_CAM_TARGET if thin else CAM_TARGET, Vector3.UP)
	cam.current = true
	cam.fov = CAM_FOV
	cam.near = 0.05
	cam.far = 100.0

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.roughness = 1.0
	mat.metallic = 0.0
	# Kills the indirect specular lobe, which specular occlusion would otherwise
	# scale by a second, different factor and contaminate the ratio.
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	for b in boxes:
		var bm := BoxMesh.new()
		bm.size = b[1]
		var m := MeshInstance3D.new()
		m.mesh = bm
		m.position = b[0]
		m.material_override = mat
		add_child(m)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	e.ssao_enabled = OS.get_environment("AO_OFF") != "1"
	# Raw visibility: no artistic remap, so the output can be compared against a
	# physical reference rather than against a curve.
	e.ssao_intensity = float(OS.get_environment("AO_INTENSITY")) if OS.get_environment("AO_INTENSITY") != "" else 1.0
	e.ssao_power = 1.0
	e.ssao_radius = float(OS.get_environment("AO_RADIUS")) if OS.get_environment("AO_RADIUS") != "" else 1.0
	env.environment = e
	add_child(env)

	print("AOREF ready ssao=%s radius=%.3f" % [e.ssao_enabled, e.ssao_radius])

func _process(_d: float) -> void:
	frames += 1
	if frames == 30:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("RT_TEST_OUT"))
		get_tree().quit()
