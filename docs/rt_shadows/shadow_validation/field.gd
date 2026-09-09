extends Node3D

# A field of thick grass blades, rendered several ways so the screen space
# shadow can be judged against a trace of the SAME blades rather than against a
# shadow map, which would bring its own resolution and bias error to the
# comparison.
#
#   a_off      blades cast nothing                          -- unshadowed baseline
#   h<H>_t<T>  screen space on, at that hardness/thickness   -- under test
#   b_rt       blades IN the acceleration structure, traced  -- GROUND TRUTH
#
# The variants come from SHADOW_HARDNESS and SHADOW_THICKNESS, rendered as a
# cross product; see _variants(). The defaults reproduce the chunky-blade table
# in FINDINGS.md.
#
# Blade size is what a game actually scatters when it wants visual density
# without millions of primitives: 1.0 x 1.5 cm cross section, 25 cm tall, with a
# per-instance height scale of 90% to 110%, so blades stand between 22.5 and
# 27.5 cm. field_thin.gd is the same comparison at 2.2 cm x 4 mm, which is much
# nearer a real blade and much further from what a game ships.
#
# Framing is chosen from arithmetic rather than taste. Camera pitch decides how
# much ground is visible, and the visible area decides the blade count: at a
# shallow pitch the far frustum ray approaches the horizon and the field runs to
# infinity. At 1.00 m and 36 degrees the ground is visible from 0.5 m to 6.7 m,
# which is 41 square meters -- small enough to fill densely and still render.

const BLADE_W := 0.015
const BLADE_D := 0.010
const BLADE_H := 0.25
const H_SCALE_MIN := 0.90
const H_SCALE_MAX := 1.10
const TILT_MAX_DEG := 11.0

const DENSITY := 65.0    # blades per square meter, about a tenth of the
                         # lush field: individual shadows have to be legible
const R_MIN := 0.12
const R_MAX := 7.60
const WEDGE_MARGIN_DEG := 26.0  # scatter a little wider than the frustum, so
                                # off-screen blades cast into view the way real
                                # grass does -- which is exactly where a screen
                                # space march must lose to a trace.
const CLUSTER_SIZE := 4
const CLUSTER_SPREAD := 0.16

const CAM_H := 1.00
const CAM_PITCH := -36.0
const CAM_FOV := 55.0
const CAM_Z := 3.30
const ASPECT := 16.0 / 9.0

const SUN_ELEV := 38.0   # high enough that most of a 25 cm blade's shadow fits
const SUN_AZIM := 52.0   # the High tier's 96 pixel march at this framing
const SSS := "rendering/lights_and_shadows/screen_space_shadows/"
const OUT := "res://out/"

var _grass: MultiMeshInstance3D
var _frame := 0
var _stage := 0
var _t0 := 0
var _vars: Array = []
var _vi := 0


func _ready() -> void:
	_pin_quality()
	_t0 = Time.get_ticks_msec()
	_build()



# The quality tier is pinned HERE rather than left to project.godot, because the
# rigs in this directory share one project and were measured at DIFFERENT tiers.
# The tier bounds the march in PIXELS, so it changes shadow AREA directly: the
# same scene at Medium instead of High scores about 0.8x of the mass. Leaving it to
# the project file made a rig silently inherit the wrong tier and report numbers
# that did not reproduce.
func _pin_quality() -> void:
	var q := 2
	if OS.has_environment("SHADOW_QUALITY"):
		q = int(OS.get_environment("SHADOW_QUALITY"))
	ProjectSettings.set_setting("rendering/lights_and_shadows/screen_space_shadows/quality", q)
	print("quality tier: %d (0 Low, 1 Medium, 2 High, 3 Ultra)" % q)

func _wedge_area() -> float:
	var half := deg_to_rad(_h_fov_deg() * 0.5 + WEDGE_MARGIN_DEG)
	return half * (R_MAX * R_MAX - R_MIN * R_MIN)


func _h_fov_deg() -> float:
	# Deliberately a constant rather than the live window size. Asking
	# DisplayServer gives zero in a headless dry run, which makes the wedge NaN
	# and the blade count garbage; worse, it would make the scatter depend on the
	# render resolution, so two runs at different sizes would not be the same
	# scene. ASPECT must match the resolution the runner asks for.
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(CAM_FOV) * 0.5) * ASPECT))


func _build() -> void:
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(60, 60)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.42, 0.37, 0.27)
	gm.roughness = 1.0
	ground_mesh.material = gm
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	add_child(ground)

	# A prism, not a quad: the blade has real geometric depth, which is what
	# surface_thickness stands in for and what the trace actually intersects.
	var blade := BoxMesh.new()
	blade.size = Vector3(BLADE_W, BLADE_H, BLADE_D)
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(1, 1, 1)
	bm.roughness = 1.0
	# Per-instance color needs this, or every blade renders white.
	bm.vertex_color_use_as_albedo = true
	blade.material = bm

	var area := _wedge_area()
	var count := int(area * DENSITY)
	var clusters := int(count / CLUSTER_SIZE)
	count = clusters * CLUSTER_SIZE

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# use_colors has to be set before instance_count, or the buffer is sized
	# without room for the color and set_instance_color fails.
	mm.use_colors = true
	mm.mesh = blade
	mm.instance_count = count

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260909
	var half_wedge := deg_to_rad(_h_fov_deg() * 0.5 + WEDGE_MARGIN_DEG)
	var i := 0
	for c in clusters:
		# Uniform density in the wedge needs r drawn from sqrt, not uniformly:
		# area grows with r, so a flat draw crowds everything at the camera.
		var r := sqrt(rng.randf_range(R_MIN * R_MIN, R_MAX * R_MAX))
		var th := rng.randf_range(-half_wedge, half_wedge)
		var cx := sin(th) * r
		var cz := CAM_Z - cos(th) * r
		for k in CLUSTER_SIZE:
			var t := Transform3D.IDENTITY
			t = t.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			# Lean, but only slightly: a prism tilted far enough reads as fallen
			# over rather than as grass.
			var tilt := deg_to_rad(rng.randf_range(0.0, TILT_MAX_DEG))
			var tilt_dir := rng.randf_range(0.0, TAU)
			t = t.rotated(Vector3(cos(tilt_dir), 0.0, sin(tilt_dir)), tilt)
			var hs := rng.randf_range(H_SCALE_MIN, H_SCALE_MAX)
			# scaled_local, NOT scaled. Transform3D.scaled is a LEFT multiply --
			# Basis::scale multiplies the basis ROWS -- so it scales along the
			# PARENT axes. Applied after the tilt that shears a leaning blade into
			# a parallelepiped and changes its lean by about a degree. The height
			# has to be applied in the blade's own frame.
			t = t.scaled_local(Vector3(1.0, hs, 1.0))
			var px := cx + rng.randfn(0.0, CLUSTER_SPREAD)
			var pz := cz + rng.randfn(0.0, CLUSTER_SPREAD)
			# The box is centered on its origin, so lift it half a blade to stand
			# on the ground rather than sink through it.
			t.origin = Vector3(px, BLADE_H * hs * 0.5, pz)
			mm.set_instance_transform(i, t)
			# Color variance, or the field reads as one plastic sheet.
			var v := rng.randf()
			mm.set_instance_color(i, Color(
					lerpf(0.11, 0.30, v) + rng.randf_range(-0.02, 0.02),
					lerpf(0.30, 0.55, v) + rng.randf_range(-0.03, 0.03),
					lerpf(0.07, 0.17, v)))
			i += 1

	_grass = MultiMeshInstance3D.new()
	_grass.multimesh = mm
	# The whole point: the blades are NOT in the acceleration structure, so they
	# cast nothing into the raytraced mask. The reference stage puts them back.
	_grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grass)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.7
	sun.shadow_enabled = true
	# Hard sun. The fork defaults angular distance to 0.25 degrees, and a
	# penumbra would blur the very edge being compared.
	sun.light_angular_distance = 0.0
	# These are shadow MAP values, and the raytraced path derives its ray origin
	# offset from them. Left large, a ray starting half a meter along the normal
	# steps straight past a 25 cm blade's contact shadow and the reference is
	# wrong. This bit an earlier run.
	sun.shadow_bias = 0.002
	sun.shadow_normal_bias = 0.0
	var azim := SUN_AZIM
	if OS.has_environment("LUSH_SUN_AZ"):
		azim = float(OS.get_environment("LUSH_SUN_AZ"))
	sun.rotation_degrees = Vector3(-SUN_ELEV, azim, 0.0)
	add_child(sun)

	var cam := Camera3D.new()
	cam.fov = CAM_FOV
	cam.near = 0.05
	cam.position = Vector3(0.0, CAM_H, CAM_Z)
	cam.rotation_degrees = Vector3(CAM_PITCH, 0.0, 0.0)
	cam.current = true
	add_child(cam)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.48, 0.72)
	sky_mat.sky_horizon_color = Color(0.66, 0.72, 0.76)
	sky_mat.ground_bottom_color = Color(0.30, 0.27, 0.20)
	sky_mat.ground_horizon_color = Color(0.52, 0.48, 0.40)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.16
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	print("=== lush: %d blades (%d clusters x %d), %.1f m2 wedge, %.0f/m2, %d triangles ===" % [
			count, clusters, CLUSTER_SIZE, area, count / area, count * 12])
	print("blade %.1f x %.1f cm section, %.1f cm tall, height scale %.2f-%.2f -> %.1f-%.1f cm" % [
			BLADE_W * 100.0, BLADE_D * 100.0, BLADE_H * 100.0, H_SCALE_MIN, H_SCALE_MAX,
			BLADE_H * H_SCALE_MIN * 100.0, BLADE_H * H_SCALE_MAX * 100.0])
	print("camera %.2f m pitch %.0f fov %.0f (h_fov %.1f), ground visible %.2f-%.2f m" % [
			CAM_H, CAM_PITCH, CAM_FOV, _h_fov_deg(),
			CAM_H / tan(deg_to_rad(-CAM_PITCH + CAM_FOV * 0.5)),
			CAM_H / tan(deg_to_rad(-CAM_PITCH - CAM_FOV * 0.5))])
	print("sun elevation %.0f azimuth %.0f, ground shadow of a %.0f cm blade = %.2f m" % [
			SUN_ELEV, azim, BLADE_H * 100.0, BLADE_H / tan(deg_to_rad(SUN_ELEV))])


func _shoot(n: String) -> void:
	var img := get_viewport().get_texture().get_image()
	print("saved %s err=%d  t=%.1fs" % [n, img.save_png(OUT + n + ".png"),
			(Time.get_ticks_msec() - _t0) / 1000.0])


func _cfg(k: String, v) -> void:
	ProjectSettings.set_setting(SSS + k, v)


func _env(k: String, dflt: String) -> String:
	return OS.get_environment(k) if OS.has_environment(k) else dflt


# The variants to render, as the cross product of two lists. The defaults
# reproduce the two hardness rows of the chunky-blade table in FINDINGS.md; set
# SHADOW_THICKNESS to "0.0025,0.005,0.010" to reproduce its thickness sweep too.
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
	_cfg("hardness", v.h)
	_cfg("surface_thickness", v.t)
	_cfg("enabled", true)
	print("stage: screen space ON, hardness %s, surface_thickness %s" % [v.h, v.t])


# Frames to settle before a capture. Every raytraced_shadows and
# screen_space_shadows setting except the master enabled flag is live, but live
# means "next frame", so a capture taken on the frame a setting changed is a
# blend of two configurations. These are generous on purpose: the whole run is
# about a minute and a silently blended capture costs far more than the frames.
const SETTLE := 12
const SETTLE_FIRST := 30
const SETTLE_RT := 25


func _process(_dt: float) -> void:
	_frame += 1
	match _stage:
		0:
			if _frame > SETTLE_FIRST:
				_cfg("enabled", false)
				_stage = 1
				_frame = 0
		1:
			if _frame > SETTLE:
				# The blades were built with cast_shadow = Off, so nothing casts
				# here at all. This is the divisor: every other capture differs
				# from it ONLY in the shadow term, which is what lets the
				# difference be read as the shadow with no segmentation mask.
				_shoot("a_off")
				_vars = _variants()
				_vi = 0
				_apply_variant()
				_stage = 2
				_frame = 0
		2:
			if _frame > SETTLE:
				_shoot(_vars[_vi].name)
				_vi += 1
				if _vi < _vars.size():
					_apply_variant()
					_frame = 0
				else:
					_cfg("enabled", false)
					# Last, and the expensive one: every blade now enters the
					# acceleration structure, which is exactly the per-frame CPU
					# cost the screen space pass exists to avoid paying.
					_grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
					print("stage: raytraced reference, blades into the structure")
					_stage = 3
					_frame = 0
		3:
			if _frame > SETTLE_RT:
				_shoot("b_rt")
				print("=== done ===")
				get_tree().quit()
