extends Node3D

# Ambient-only validation scene. With no direct light and a fully rough, non
# specular white material, a shaded pixel is exactly ambient * albedo * AO, so
# dividing a render with occlusion by one without it recovers the AO term
# itself rather than something the shading has already mixed.
#
# Geometry is all axis aligned boxes so the same scene can be ray traced
# independently on the CPU without importing anything from the engine. The box
# lists below are GENERATED from scenes.py, which is the single source of truth;
# do not hand-edit them, and regenerate if that file changes.
#
# AO_SCENE picks the scene: unset for SOLID, "thin", or "room".

const SOLID_BOXES := [
	[Vector3(0, -0.1, 0), Vector3(20, 0.2, 20)],
	[Vector3(-1.2, 0.35, 0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(-0.25, 0.35, 0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(0.7, 0.35, 0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(1.65, 0.35, 0), Vector3(0.7, 0.7, 0.7)],
	[Vector3(0, 0.8, -1.2), Vector3(4, 1.6, 0.15)],
	[Vector3(1.6, 0.9, 0.9), Vector3(1.6, 0.06, 1)],
]
const SOLID_CAM := [Vector3(3.2, 2.4, 3.2), Vector3(0, 0.4, 0), Vector2(720, 720)]

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
const THIN_CAM := [Vector3(2.9, 1.9, 3.4), Vector3(0, 0.45, 0.2), Vector2(720, 720)]

const ROOM_BOXES := [
	[Vector3(0, -0.1, 0), Vector3(5, 0.2, 12)],
	[Vector3(0, 2.9, 0), Vector3(5, 0.2, 12)],
	[Vector3(-2.6, 1.4, 0), Vector3(0.2, 2.8, 12)],
	[Vector3(2.6, 1.4, 0), Vector3(0.2, 2.8, 12)],
	[Vector3(0, 1.4, -6.1), Vector3(5, 2.8, 0.2)],
	[Vector3(0, 1.4, 6.1), Vector3(5, 2.8, 0.2)],
	[Vector3(0, 2.65, -3), Vector3(5, 0.3, 0.35)],
	[Vector3(0, 2.65, 0), Vector3(5, 0.3, 0.35)],
	[Vector3(0, 2.65, 3), Vector3(5, 0.3, 0.35)],
	[Vector3(0, 0.74, -1), Vector3(1.4, 0.06, 3.6)],
	[Vector3(-0.6, 0.37, -3.6), Vector3(0.08, 0.74, 0.08)],
	[Vector3(-0.6, 0.37, -0.4), Vector3(0.08, 0.74, 0.08)],
	[Vector3(0.6, 0.37, -3.6), Vector3(0.08, 0.74, 0.08)],
	[Vector3(0.6, 0.37, -0.4), Vector3(0.08, 0.74, 0.08)],
	[Vector3(-1.15, 0.22, -2), Vector3(0.45, 0.44, 0.45)],
	[Vector3(-1.4, 0.6, -2), Vector3(0.06, 0.9, 0.45)],
	[Vector3(-1.15, 0.22, -0.2), Vector3(0.45, 0.44, 0.45)],
	[Vector3(-1.4, 0.6, -0.2), Vector3(0.06, 0.9, 0.45)],
	[Vector3(1.15, 0.22, -2), Vector3(0.45, 0.44, 0.45)],
	[Vector3(1.4, 0.6, -2), Vector3(0.06, 0.9, 0.45)],
	[Vector3(1.15, 0.22, -0.2), Vector3(0.45, 0.44, 0.45)],
	[Vector3(1.4, 0.6, -0.2), Vector3(0.06, 0.9, 0.45)],
	[Vector3(0, 0.006, -1), Vector3(2.6, 0.012, 4.4)],
	[Vector3(0, 0.006, 3.6), Vector3(2, 0.012, 2.4)],
]
const ROOM_CAM := [Vector3(0, 1.62, 4.6), Vector3(0, 1.3, -4), Vector2(1280, 720)]

const CAM_FOV := 75.0

var frames := 0

func _ready() -> void:
	var scene_name := OS.get_environment("AO_SCENE")
	var boxes: Array = SOLID_BOXES
	var cam_cfg: Array = SOLID_CAM
	if scene_name == "thin":
		boxes = THIN_BOXES
		cam_cfg = THIN_CAM
	elif scene_name == "room":
		boxes = ROOM_BOXES
		cam_cfg = ROOM_CAM

	# The viewport belongs to the scene: the effect radius under
	# scale_radius_with_distance is anchored to screen height, so only a scene
	# that is not square can catch an aspect dependent defect.
	var size: Vector2 = cam_cfg[2]
	get_window().size = Vector2i(int(size.x), int(size.y))
	get_viewport().size = Vector2i(int(size.x), int(size.y))

	var cam := Camera3D.new()
	cam.position = cam_cfg[0]
	add_child(cam)
	cam.look_at(cam_cfg[1], Vector3.UP)
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

	# Raw visibility by default: no artistic remap, so the output can be compared
	# against a physical reference rather than against a curve. Both estimators
	# are the identity at intensity 1 and power 1 -- but the ground truth one
	# scales ssao_intensity down before using it, because it reports a normalized
	# visibility rather than the legacy obscurance the 2.0 default was calibrated
	# against. So ask for whatever value CANCELS that scale instead of hardcoding
	# one, or the harness silently measures a curve instead of the estimator.
	var unity := 1.0
	if int(ProjectSettings.get_setting("rendering/environment/ssao/method", 0)) == 1:
		var gt_scale := float(ProjectSettings.get_setting(
				"rendering/environment/ssao/ground_truth/intensity_scale", 1.0))
		unity = 1.0 / maxf(gt_scale, 0.0001)
	e.ssao_intensity = float(OS.get_environment("AO_INTENSITY")) if OS.get_environment("AO_INTENSITY") != "" else unity
	# A knob, not a constant, so the SHIPPED configuration can be scored too.
	# Hardcoding 1.0 here is why the shipped power was never once measured.
	e.ssao_power = float(OS.get_environment("AO_POWER")) if OS.get_environment("AO_POWER") != "" else 1.0
	e.ssao_radius = float(OS.get_environment("AO_RADIUS")) if OS.get_environment("AO_RADIUS") != "" else 1.0
	env.environment = e
	add_child(env)

	print("AOREF ready scene=%s ssao=%s radius=%.3f intensity=%.3f power=%.3f" % [
			scene_name if scene_name != "" else "solid", e.ssao_enabled,
			e.ssao_radius, e.ssao_intensity, e.ssao_power])

func _process(_d: float) -> void:
	frames += 1
	if frames == 30:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("RT_TEST_OUT"))
		get_tree().quit()
