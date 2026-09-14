extends Node3D

# A field of multimesh-scattered grass blades on a ground plane, rendered twice
# under lavapipe: once with screen space shadows off, once on. The difference of
# the two is exactly what the feature adds.

# 15,000 is what the thin-field table in FINDINGS.md was measured at, paired
# with this rig's 1280x720 (see run.sh). Both matter: the count sets how much
# the field self-shadows, and the resolution sets how many pixels a blade is
# wide, which is the whole variable `hardness` exists for.
var BLADES := int(OS.get_environment("FIELD_BLADES")) if OS.has_environment("FIELD_BLADES") else 15000
const FIELD := 11.0
const SSS_SETTING := "rendering/lights_and_shadows/screen_space_shadows/enabled"
const OUT := "res://out/"

var _shots: Array[String] = []
var _grass: MultiMeshInstance3D
var _frame := 0
var _stage := 0
var _vars: Array = []
var _vi := 0


func _ready() -> void:
	_pin_quality()
	_build_world()
	print("=== scene built: %d blades ===" % BLADES)
	print("msaa_3d=", ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d"))



# The quality tier is pinned HERE rather than left to project.godot, because the
# rigs in this directory share one project and were measured at DIFFERENT tiers.
# The tier bounds the march in PIXELS, so it changes shadow AREA directly: the
# same scene at Medium instead of High scores about 0.8x of the mass. Leaving it to
# the project file made a rig silently inherit the wrong tier and report numbers
# that did not reproduce.
func _pin_quality() -> void:
	var q := 1
	if OS.has_environment("SHADOW_QUALITY"):
		q = int(OS.get_environment("SHADOW_QUALITY"))
	ProjectSettings.set_setting("rendering/lights_and_shadows/screen_space_shadows/quality", q)
	print("quality tier: %d (0 Low, 1 Medium, 2 High, 3 Ultra)" % q)

func _build_world() -> void:
	# ---- ground ------------------------------------------------------------
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(FIELD * 2.0, FIELD * 2.0)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.22, 0.26, 0.16)
	ground_mat.roughness = 1.0
	ground_mat.specular = 0.0
	ground_mesh.material = ground_mat
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	add_child(ground)

	# ---- one blade: a thin upright prism ------------------------------------
	# A box rather than a quad, so the blade has the geometric depth that
	# surface_thickness stands in for, and so the raytraced reference traces a
	# closed solid rather than a zero-thickness sheet.
	var blade := BoxMesh.new()
	blade.size = Vector3(0.022, 0.30, 0.004)
	var blade_mat := StandardMaterial3D.new()
	blade_mat.albedo_color = Color(0.35, 0.52, 0.19)
	blade_mat.roughness = 1.0
	blade_mat.specular = 0.0
	blade.material = blade_mat

	# ---- scatter ------------------------------------------------------------
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = blade
	mm.instance_count = BLADES

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260909 # deterministic, so the two renders differ only by the setting
	for i in BLADES:
		var x := rng.randf_range(-FIELD, FIELD)
		var z := rng.randf_range(-FIELD, FIELD)
		var h := rng.randf_range(0.7, 1.4)
		var t := Transform3D.IDENTITY
		t = t.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
		t = t.rotated(Vector3.RIGHT, rng.randf_range(-0.22, 0.22))
		t = t.scaled(Vector3(1.0, h, 1.0))
		# The plane is centered on its origin, so lift it half a blade to stand on
		# the ground rather than sink through it.
		t.origin = Vector3(x, 0.30 * h * 0.5, z)
		mm.set_instance_transform(i, t)

	_grass = MultiMeshInstance3D.new()
	_grass.multimesh = mm
	# The whole point of the exercise: the blades are NOT in the acceleration
	# structure, so they cast nothing into the raytraced mask.
	_grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grass)

	# ---- sun ----------------------------------------------------------------
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	# Low enough that blades throw shadows across their neighbors, high enough
	# that those shadows stay inside the march's pixel budget.
	sun.rotation_degrees = Vector3(-26.0, 38.0, 0.0)
	add_child(sun)

	# ---- camera: standing in the grass, looking across it -------------------
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.08
	cam.position = Vector3(0.0, 1.05, 4.4)
	cam.rotation_degrees = Vector3(-19.0, 0.0, 0.0)
	cam.current = true
	add_child(cam)

	# ---- environment --------------------------------------------------------
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.5, 0.72)
	sky_mat.sky_horizon_color = Color(0.62, 0.68, 0.72)
	sky_mat.ground_bottom_color = Color(0.25, 0.26, 0.22)
	sky_mat.ground_horizon_color = Color(0.55, 0.58, 0.55)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _shoot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := OUT + name + ".png"
	var err := img.save_png(path)
	print("saved %s (%dx%d) err=%d" % [path, img.get_width(), img.get_height(), err])
	_shots.append(path)


func _sss(k: String, v) -> void:
	ProjectSettings.set_setting("rendering/lights_and_shadows/screen_space_shadows/" + k, v)


func _env(k: String, dflt: String) -> String:
	return OS.get_environment(k) if OS.has_environment(k) else dflt


# Same contract as field.gd: a cross product of hardness and thickness, named so
# one scorer reads both rigs. Defaults reproduce the thin-field table in
# FINDINGS.md.
func _variants() -> Array:
	var out := []
	for t in _env("SHADOW_THICKNESS", "0.005").split(","):
		for h in _env("SHADOW_HARDNESS", "1,0").split(","):
			out.append({
				"h": float(h.strip_edges()),
				"t": float(t.strip_edges()),
				"name": "h%s_t%s" % [h.strip_edges(), t.strip_edges()],
			})
	return out


func _apply_variant() -> void:
	var v: Dictionary = _vars[_vi]
	_sss("hardness", v.h)
	_sss("surface_thickness", v.t)
	_sss("enabled", true)
	print("=== screen space ON, hardness %s, surface_thickness %s ===" % [v.h, v.t])


func _process(_dt: float) -> void:
	_frame += 1
	# One scene, rendered several ways. The raytraced capture is the reference:
	# the blades are in the acceleration structure and their real triangles are
	# traced, so whatever it puts on the ground is the answer the screen space
	# pass is trying to reproduce without paying the per-blade CPU cost of being
	# in there.
	match _stage:
		0:
			if _frame > 25:
				_sss("enabled", false)
				_stage = 1
				_frame = 0
		1:
			if _frame > 12:
				_shoot("a_off")
				_vars = _variants()
				_vi = 0
				_apply_variant()
				_stage = 2
				_frame = 0
		2:
			if _frame > 12:
				_shoot(_vars[_vi].name)
				_vi += 1
				if _vi < _vars.size():
					_apply_variant()
					_frame = 0
				else:
					_sss("enabled", false)
					# The blades go into the acceleration structure for the
					# reference. This is the cost the whole feature exists to
					# avoid, so it is only ever paid here.
					_grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
					print("=== raytraced reference: blades cast into the structure ===")
					_stage = 3
					_frame = 0
		3:
			if _frame > 20:
				_shoot("b_rt")
				print("=== done ===")
				get_tree().quit()
