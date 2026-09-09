extends Node3D

# A measurable version of the grass case: a few well separated blades of KNOWN
# width, viewed from above so their shadows land on open ground and can be
# measured in pixels.
#
# Three renders of the identical scene:
#   a_rt        : blades cast RAYTRACED shadows, screen space off  -> REFERENCE
#   b_sss       : blades cast nothing, screen space shadows on    -> UNDER TEST
#   c_none      : blades cast nothing, screen space shadows off   -> baseline
#
# a is ground truth: the RT path traces the blade's actual triangles, so it has
# none of a shadow map's resolution or bias error to confound a width measurement.
# Comparing b against it is what turns "looks too thin" into a number.

const SSS := "rendering/lights_and_shadows/screen_space_shadows/enabled"
const OUT := "res://out/"

# 2.2 cm x 4 mm, which is what the hardness sweep table in FINDINGS.md was
# measured at and is nearly razor thin -- the case `hardness` exists for, where a
# blade is narrower than the march's one-pixel sample spacing.
#
# SSS_BLADE_W=0.12 gives deliberately fat blades whose shadow is tens of pixels
# across; use that when measuring shadow WIDTH, where a 2 cm shadow quantizes to
# two or three pixels and cannot resolve a tuning step. The two answer different
# questions and do NOT give the same numbers: at 12 cm the screen space area
# ratio is about 1.02 against the trace where at 2.2 cm it is about 1.49.
var BLADE_W := float(OS.get_environment("SSS_BLADE_W")) if OS.has_environment("SSS_BLADE_W") else 0.022
var BLADE_H := 0.9
var BLADE_D := float(OS.get_environment("SSS_BLADE_D")) if OS.has_environment("SSS_BLADE_D") else 0.004
var COLS := 5
var ROWS := 4
var SPACING := 1.5

var _grass: MultiMeshInstance3D
var _sun: DirectionalLight3D
var _cam: Camera3D
var _frame := 0
var _stage := 0
var _vars: Array = []
var _vi := 0


func _ready() -> void:
	_pin_quality()
	_build()
	print("=== probe: %d prisms, %.2f cm wide x %.2f cm deep, yaw=%s ===" % [COLS * ROWS, BLADE_W * 100.0, BLADE_D * 100.0, "random" if OS.has_environment("SSS_RANDOM_YAW") else "aligned"])
	# The distance the prisms actually sit at decides what a given surface_thickness
	# models, so report it rather than assume it.
	# A screen space march only has pixels to walk if the light is off the
	# camera's own axis. A sun directly behind the camera projects shadows almost
	# straight away from the viewer, which is the degenerate case for the
	# technique, so report the angle rather than leave it implicit.
	# A DirectionalLight3D emits along -Z of its own basis, so +Z points at the sun.
	var to_sun := _sun.global_transform.basis.z
	var cam_fwd := -_cam.global_transform.basis.z
	var cam_back := _cam.global_transform.basis.z
	print("sun: elevation %.1f deg, azimuth %.1f deg | angle(to_sun, camera_forward) = %.1f deg | angle(to_sun, camera_back) = %.1f deg" % [
			rad_to_deg(asin(clampf(to_sun.y, -1.0, 1.0))), _sun.rotation_degrees.y,
			rad_to_deg(acos(clampf(to_sun.dot(cam_fwd), -1.0, 1.0))),
			rad_to_deg(acos(clampf(to_sun.dot(cam_back), -1.0, 1.0)))])
	var cam3 := get_viewport().get_camera_3d()
	if cam3:
		var d_near := cam3.global_position.distance_to(Vector3(0, BLADE_H * 0.5, (ROWS - 1) * 0.5 * SPACING))
		var d_far := cam3.global_position.distance_to(Vector3(0, BLADE_H * 0.5, -(ROWS - 1) * 0.5 * SPACING))
		print("view distance: near row %.2f m, far row %.2f m, mean %.2f m" % [d_near, d_far, (d_near + d_far) * 0.5])



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

func _build() -> void:
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(40, 40)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.55, 0.55, 0.52)
	gm.roughness = 1.0
	gm.specular = 0.0
	ground_mesh.material = gm
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	add_child(ground)

	# A thin rectangular prism rather than a zero-thickness quad, so the blade has
	# the real geometric depth that surface_thickness exists to stand in for.
	var blade := BoxMesh.new()
	blade.size = Vector3(BLADE_W, BLADE_H, BLADE_D)
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.30, 0.48, 0.18)
	bm.roughness = 1.0
	bm.specular = 0.0
	# A closed solid, so back faces should be culled the way real geometry is.
	blade.material = bm

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = blade
	mm.instance_count = COLS * ROWS
	var i := 0
	for cx in COLS:
		for cz in ROWS:
			var t := Transform3D.IDENTITY
			if OS.has_environment("SSS_RANDOM_YAW"):
				# Real scattered grass. An orientation-dependent defect can only
				# show here, not in the aligned case.
				var rr := RandomNumberGenerator.new()
				rr.seed = 1000 + i
				t = t.rotated(Vector3.UP, rr.randf_range(0.0, TAU))
			t.origin = Vector3((cx - (COLS - 1) * 0.5) * SPACING, BLADE_H * 0.5,
					(cz - (ROWS - 1) * 0.5) * SPACING)
			mm.set_instance_transform(i, t)
			i += 1

	_grass = MultiMeshInstance3D.new()
	_grass.multimesh = mm
	add_child(_grass)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	# A hard sun: this fork defaults light_angular_distance to 0.25 degrees, and
	# a soft penumbra would blur the very edge being measured.
	sun.light_angular_distance = 0.0
	# These were shadow-MAP values. The raytraced path derives its ray origin
	# offset from them, so leaving them large biases the reference itself: a ray
	# that starts half a meter along the normal can step straight past a 2 cm
	# blade's contact shadow. Swept, so the reference can be shown to converge.
	sun.shadow_bias = float(OS.get_environment("SSS_BIAS")) if OS.has_environment("SSS_BIAS") else 0.02
	sun.shadow_normal_bias = float(OS.get_environment("SSS_NBIAS")) if OS.has_environment("SSS_NBIAS") else 0.5
	var sun_el := float(OS.get_environment("SSS_SUN_EL")) if OS.has_environment("SSS_SUN_EL") else 38.0
	var sun_az := float(OS.get_environment("SSS_SUN_AZ")) if OS.has_environment("SSS_SUN_AZ") else 0.0
	sun.rotation_degrees = Vector3(-sun_el, sun_az, 0.0)
	add_child(sun)
	_sun = sun

	# Looking down the sun's own azimuth, so each shadow runs straight away from
	# its blade and its width is a horizontal run of pixels.
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.position = Vector3(0.0, 4.6, 6.4)
	cam.rotation_degrees = Vector3(-33.0, 0.0, 0.0)
	cam.current = true
	add_child(cam)
	_cam = cam

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.07, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.65)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _shoot(n: String) -> void:
	var img := get_viewport().get_texture().get_image()
	print("saved %s err=%d" % [n, img.save_png(OUT + n + ".png")])


func _env(k: String, dflt: String) -> String:
	return OS.get_environment(k) if OS.has_environment(k) else dflt


# Same capture contract as field.gd and field_thin.gd, so one scorer reads all
# three: a_off is the unshadowed baseline, b_rt is the traced reference, and
# every h<H>_t<T> is a screen space variant. The whole sweep runs in ONE render,
# because every screen_space_shadows setting is live from one frame to the next.
#
# Defaults reproduce the hardness sweep table in FINDINGS.md.
func _variants() -> Array:
	var out := []
	for t in _env("SHADOW_THICKNESS", "0.005").split(","):
		for h in _env("SHADOW_HARDNESS", "0,0.25,0.5,0.75,1").split(","):
			out.append({
				"h": float(h.strip_edges()),
				"t": float(t.strip_edges()),
				"name": "h%s_t%s" % [h.strip_edges(), t.strip_edges()],
			})
	return out


func _apply_variant() -> void:
	var v: Dictionary = _vars[_vi]
	var base := "rendering/lights_and_shadows/screen_space_shadows/"
	ProjectSettings.set_setting(base + "hardness", v.h)
	ProjectSettings.set_setting(base + "surface_thickness", v.t)
	# Bend scale bilinear_threshold with surface_thickness, so the sweep does too
	# rather than holding an edge-detect tuned for a different thickness.
	ProjectSettings.set_setting(base + "bilinear_threshold", 0.02 * (v.t / 0.005))
	if OS.has_environment("SSS_CONTRAST"):
		ProjectSettings.set_setting(base + "contrast", float(OS.get_environment("SSS_CONTRAST")))
	ProjectSettings.set_setting(SSS, true)
	print("stage: hardness %s, surface_thickness %s" % [v.h, v.t])


func _process(_dt: float) -> void:
	_frame += 1
	match _stage:
		0:
			if _frame > 45:
				# Out of the acceleration structure, screen space off: the
				# unshadowed baseline every other capture is differenced against.
				_grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				ProjectSettings.set_setting(SSS, false)
				_stage = 1
				_frame = 0
		1:
			if _frame > 14:
				_shoot("a_off")
				_vars = _variants()
				_vi = 0
				_apply_variant()
				_stage = 2
				_frame = 0
		2:
			if _frame > 14:
				_shoot(_vars[_vi].name)
				_vi += 1
				if _vi < _vars.size():
					_apply_variant()
					_frame = 0
				else:
					ProjectSettings.set_setting(SSS, false)
					# The reference: the prisms go into the acceleration
					# structure and their real triangles are traced, so it
					# carries none of a shadow map's resolution or bias error to
					# confound a width measurement.
					_grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
					print("stage: raytraced reference, prisms into the structure")
					_stage = 3
					_frame = 0
		3:
			if _frame > 20:
				_shoot("b_rt")
				print("=== done ===")
				get_tree().quit()
