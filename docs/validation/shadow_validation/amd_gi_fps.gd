extends Node3D

# Procedural FPS stress scene. No game project files or settings are changed.
const GI := "rendering/global_illumination/amd_gi/"
var _camera: Camera3D
var _torch: SpotLight3D
var _muzzle: OmniLight3D
var _actor: Node3D
var _sun: DirectionalLight3D
var _hazard_materials: Array[StandardMaterial3D] = []
var _draw := 0
var _records: Array[Dictionary] = []
var _output := ""
var _experiment := ""
var _phase := ""
var _origin: Transform3D


func _box(parent: Node3D, label: String, position: Vector3, size: Vector3, color: Color, metal: float = 0.0, roughness: float = 0.85) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	if _phase == "close":
		# A painted-interior counterpart to the dark outdoor shack. Keep the
		# actual game flashlight values; make bounce visible through materials.
		match label:
			"BackWall": color = Color(0.78, 0.78, 0.75)
			"LeftWall": color = Color(0.68, 0.72, 0.65)
			"Roof": color = Color(0.70, 0.70, 0.70)
			"Ground": color = Color(0.65, 0.65, 0.62)
			"ShackBench": color = Color(0.70, 0.55, 0.33)
	material.albedo_color = color
	material.metallic = metal
	material.roughness = roughness
	mesh.material = material
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.position = position
	parent.add_child(node)
	return node


func _ready() -> void:
	_output = OS.get_environment("SHADOW_OUT_DIR")
	_experiment = OS.get_environment("GI_EXPERIMENT")
	_phase = OS.get_environment("GI_FPS_PHASE")
	if _phase.is_empty():
		_phase = "all"
	assert(not _output.is_empty())
	DirAccess.make_dir_recursive_absolute(_output)
	var masks := {"baseline": 0, "response": 1, "scheduling": 2, "transitions": 4, "response_scheduling": 3, "combined": 7}
	assert(masks.has(_experiment))
	var flags: int = masks[_experiment]
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "improvements/responsive_history", (flags & 1) != 0)
	ProjectSettings.set_setting(GI + "improvements/demand_scheduling", (flags & 2) != 0)
	ProjectSettings.set_setting(GI + "improvements/cache_transitions", (flags & 4) != 0)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	ProjectSettings.set_setting(GI + "reflections/enabled", true)
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().use_taa = false
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_build_scene()
	_run.call_deferred()


func _build_scene() -> void:
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.17, 0.22, 0.32)
	sky_material.sky_horizon_color = Color(0.35, 0.38, 0.42)
	sky_material.sky_energy_multiplier = 0.25
	sky_material.ground_energy_multiplier = 0.25
	sky.sky_material = sky_material
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.ambient_light_energy = 1.0
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.ssao_enabled = false
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var concrete := Color(0.48, 0.46, 0.42)
	_box(self, "Ground", Vector3(0, -0.15, -1), Vector3(16, 0.3, 20), concrete)
	_box(self, "BackWall", Vector3(0, 1.7, -6), Vector3(10, 3.4, 0.25), Color(0.48, 0.56, 0.6))
	_box(self, "LeftWall", Vector3(-4.5, 1.7, -1), Vector3(0.25, 3.4, 10), concrete)
	_box(self, "Roof", Vector3(-1.25, 3.4, -1), Vector3(6.5, 0.22, 10), Color(0.4, 0.43, 0.45))
	_box(self, "CornerPartition", Vector3(0.7, 1.3, -2.2), Vector3(0.24, 2.6, 3.2), Color(0.38, 0.29, 0.19))
	for z in [-4.4, -0.8, 2.8]:
		_box(self, "Post", Vector3(2.0, 1.6, z), Vector3(0.22, 3.2, 0.22), Color(0.28, 0.32, 0.26))
	_box(self, "ShackBench", Vector3(-2.8, 0.85, -4.0), Vector3(2.5, 0.18, 1.5), Color(0.5, 0.37, 0.2))
	for x in [-3.8, -1.8]:
		_box(self, "BenchLeg", Vector3(x, 0.4, -4), Vector3(0.16, 0.8, 0.9), concrete)
	for i in 6:
		var crate := _box(self, "Crate", Vector3(-3.65 + float(i % 2) * 0.85, 0.32, 0.7 - float(i / 2) * 1.1), Vector3(0.65, 0.64, 0.7), Color(0.32 + float(i % 2) * 0.13, 0.27, 0.17))
		crate.rotation.y = float(i) * 0.17
	for i in 8:
		_box(self, "Rail", Vector3(2.5 + float(i) * 0.3, 0.8, -4.8), Vector3(0.06, 1.6, 0.06), Color(0.18, 0.22, 0.25), 0.7, 0.25)
	_box(self, "PolishedPanel", Vector3(-4.32, 1.4, -2.0), Vector3(0.05, 1.2, 1.5), Color(0.72, 0.69, 0.61), 1.0, 0.12)
	var sun := DirectionalLight3D.new()
	_sun = sun
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_energy = 0.45
	sun.light_angular_distance = 0.0
	sun.shadow_enabled = true
	add_child(sun)
	# Mixed analytic lighting plus sky prevents the special all-dark shortcut.
	for i in 9:
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(-3.5 + float(i % 3) * 3.0, 2.75, 2.0 - float(i / 3) * 3.3)
		lamp.light_energy = 0.08
		lamp.light_color = Color(1.0, 0.76, 0.52) if i % 2 == 0 else Color(0.55, 0.72, 1.0)
		lamp.omni_range = 3.8
		lamp.light_size = 0.0
		lamp.shadow_enabled = true
		add_child(lamp)
	_camera = Camera3D.new()
	_camera.position = Vector3(-0.45, 1.65, 3.7)
	_camera.fov = 72
	add_child(_camera)
	_camera.look_at(Vector3(-1.15, 1.3, -4.4))
	if _phase == "close":
		_camera.position = Vector3(-2.0, 1.45, -2.2)
		_camera.look_at(Vector3(-2.2, 1.4, -5.7))
	_camera.make_current()
	_origin = _camera.transform
	var weapon := Node3D.new()
	weapon.position = Vector3(0.30, -0.29, -0.65)
	_camera.add_child(weapon)
	_box(weapon, "GoldReceiver", Vector3.ZERO, Vector3(0.11, 0.13, 0.43), Color(0.82, 0.57, 0.16), 1.0, 0.12)
	_box(weapon, "Barrel", Vector3(0, 0.035, -0.36), Vector3(0.045, 0.045, 0.37), Color(0.21, 0.22, 0.23), 0.85, 0.2)
	_box(weapon, "Magazine", Vector3(0, -0.15, -0.05), Vector3(0.09, 0.23, 0.16), Color(0.73, 0.49, 0.14), 1.0, 0.16)
	if _phase == "day":
		# The extra weapon-turn sequence also exercises curved polished metal.
		var barrel_mesh := CylinderMesh.new()
		barrel_mesh.top_radius = 0.05
		barrel_mesh.bottom_radius = 0.05
		barrel_mesh.height = 0.37
		barrel_mesh.radial_segments = 12
		var gold := StandardMaterial3D.new()
		gold.albedo_color = Color(0.82, 0.57, 0.16)
		gold.metallic = 1.0
		gold.roughness = 0.08
		barrel_mesh.material = gold
		var curved_barrel := MeshInstance3D.new()
		curved_barrel.mesh = barrel_mesh
		curved_barrel.position = Vector3(0, 0.035, -0.36)
		curved_barrel.rotation.x = PI / 2.0
		weapon.add_child(curved_barrel)
	_torch = SpotLight3D.new()
	_torch.position = Vector3(0.08, -0.035, -0.55)
	_torch.light_energy = 6.0
	_torch.light_color = Color(1.0, 0.96, 0.88)
	_torch.spot_range = 45.0
	_torch.spot_angle = 26.0
	_torch.light_size = 0.0
	_torch.shadow_enabled = true
	_torch.visible = false
	weapon.add_child(_torch)
	_muzzle = OmniLight3D.new()
	_muzzle.position = Vector3(0, 0.035, -0.58)
	_muzzle.light_color = Color(1.0, 0.85, 0.55)
	_muzzle.light_energy = 6.0
	_muzzle.omni_range = 7.0
	_muzzle.light_size = 0.0
	_muzzle.shadow_enabled = true
	_muzzle.visible = false
	weapon.add_child(_muzzle)
	_actor = Node3D.new()
	_actor.position = Vector3(-1.0, 0, -3.7)
	add_child(_actor)
	_box(_actor, "Torso", Vector3(0, 1.05, 0), Vector3(0.55, 0.8, 0.3), Color(0.19, 0.27, 0.17))
	_box(_actor, "Head", Vector3(0, 1.65, 0), Vector3(0.28, 0.3, 0.28), Color(0.56, 0.38, 0.25))
	for x in [-0.15, 0.15]:
		_box(_actor, "Leg", Vector3(x, 0.35, 0), Vector3(0.18, 0.7, 0.22), Color(0.14, 0.16, 0.16))
	for group in 2:
		var emission := StandardMaterial3D.new()
		emission.albedo_color = Color(0.03, 0.05, 0.08)
		emission.emission_enabled = true
		emission.emission = Color(0.12, 0.7, 1.0)
		emission.emission_energy_multiplier = 0.0
		_hazard_materials.append(emission)
		for i in 4:
			var rod := _box(self, "HazardStrip", Vector3(-3.5 + float(i) * 0.5, 1.6 + float(group) * 0.45, -5.7), Vector3(0.055, 0.8, 0.055), Color.WHITE)
			rod.rotation.z = (-0.6 if i % 2 == 0 else 0.6) + float(group) * 0.2
			rod.material_override = emission


func _step(count: int) -> void:
	for index in count:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_draw += 1


func _save(label: String) -> void:
	assert(get_viewport().get_texture().get_image().save_png(_output.path_join(label + ".png")) == OK)
	_records.append({"label": label, "draw": _draw, "torch_visible": _torch.visible, "muzzle_visible": _muzzle.visible, "camera": str(_camera.transform), "actor": str(_actor.position), "hazard": [_hazard_materials[0].emission_energy_multiplier, _hazard_materials[1].emission_energy_multiplier]})
	# Keep frame provenance if the cloud interrupts a long capture. Only the
	# final capture.json / completion marker certifies a finished sequence.
	var progress := FileAccess.open(_output.path_join("progress.json"), FileAccess.WRITE)
	progress.store_string(JSON.stringify(_records, "\t") + "\n")
	print("FPS_CAPTURE ", label, " draw=", _draw)


func _hold(label: String, frames: int, marks: Array = []) -> void:
	for i in frames:
		await _step(1)
		if i + 1 in marks:
			_save("%s_%03d" % [label, i + 1])


func _steady(label: String, count: int = 12) -> void:
	for i in count:
		await _step(1)
		_save("%s_%02d" % [label, i])


func _run() -> void:
	await _step(8)
	_save("direct_off")
	_torch.visible = true
	await _step(8)
	_save("direct_on")
	_torch.visible = false
	await _step(4)
	ProjectSettings.set_setting(GI + "enabled", true)
	await _step(128)
	_save("ambient_settled")
	await _steady("ambient_steady")
	if _phase == "stability":
		_torch.visible = true
		await _step(256)
		await _steady("constant", 64)
	if _phase == "day":
		# Separate sequence: retain the main suite's exact frame history.
		for i in 64:
			_sun.rotation_degrees = Vector3(lerpf(-48.0, -6.0, float(i + 1) / 64.0), -32, 0)
			_sun.light_energy = lerpf(0.45, 0.03, float(i + 1) / 64.0)
			await _step(1)
			if i % 8 == 7:
				_save("sunset_%02d" % (i + 1))
		await _hold("sunset_hold", 96, [1, 4, 8, 16, 32, 64, 96])
		_sun.rotation_degrees = Vector3(-48, -32, 0)
		_sun.light_energy = 0.45
		await _hold("sun_return", 96, [1, 4, 8, 16, 32, 64, 96])
		_torch.visible = true
		await _step(96)
		for i in 32:
			_camera.rotation.y = _origin.basis.get_euler().y + sin(float(i + 1) / 32.0 * TAU) * 0.28
			await _step(1)
			if i % 4 == 3:
				_save("turn_%02d" % (i + 1))
		_camera.transform = _origin
		await _hold("turn_hold", 96, [1, 4, 8, 16, 32, 64, 96])
		for i in 32:
			_camera.position = _origin.origin.lerp(Vector3(0.38, 1.65, 0.0), float(i + 1) / 32.0)
			await _step(1)
			if i % 4 == 3:
				_save("weapon_wall_%02d" % (i + 1))
		await _hold("weapon_wall_hold", 96, [1, 4, 8, 16, 32, 64, 96])
	if _phase == "cache":
		_torch.visible = true
		await _step(96)
		for i in 32:
			_camera.position = _origin.origin + Vector3(2.1, 0, -1.0) * float(i + 1) / 32.0
			await _step(1)
			if i % 4 == 3:
				_save("corner_%02d" % (i + 1))
		await _hold("corner_hold", 128, range(1, 33) + [64, 128])
		_save("corner_settled")
		await _steady("corner_steady")
	if _phase in ["all", "response", "pilot", "close"]:
		_torch.visible = true
		await _hold("torch_on", 160, [1, 4, 8, 16, 32, 64, 128, 160])
		await _steady("torch_steady")
		_torch.visible = false
		await _hold("torch_off", 96, [1, 4, 8, 16, 32, 64, 96])
		await _steady("dark_steady")
	if _phase in ["all", "motion"]:
		_torch.visible = true
		await _step(96)
		for i in 32:
			_torch.rotation.y = lerpf(-0.3, 0.3, float(i + 1) / 32.0)
			await _step(1)
			if i % 4 == 3:
				_save("sweep_%02d" % (i + 1))
		await _step(96)
		_save("sweep_settled")
		_torch.rotation.y = 0.0
		_camera.transform = _origin
		await _step(64)
		for i in 32:
			_camera.position = _origin.origin + Vector3(2.1, 0, -1.0) * float(i + 1) / 32.0
			await _step(1)
			if i % 4 == 3:
				_save("corner_%02d" % (i + 1))
		await _step(128)
		_save("corner_settled")
		await _steady("corner_steady")
		_camera.transform = _origin
		await _step(96)
		for i in 32:
			_actor.position.x = lerpf(-1.0, -2.6, float(i + 1) / 32.0)
			await _step(1)
			if i % 4 == 3:
				_save("actor_%02d" % (i + 1))
		await _step(96)
		_save("actor_settled")
		_actor.position.x = -1.0
		_torch.visible = false
		await _step(96)
	if _phase in ["all", "pulses"]:
		_muzzle.visible = true
		await _hold("muzzle_on", 3, [1, 3])
		_muzzle.visible = false
		await _hold("muzzle_off", 64, [1, 4, 8, 16, 32, 64])
		for i in 48:
			var group := (i / 4) % 2 # Intentional integer division: four-frame pulses.
			_hazard_materials[group].emission_energy_multiplier = 8.0
			_hazard_materials[1 - group].emission_energy_multiplier = 0.0
			await _step(1)
			if i >= 24 or i % 4 == 3:
				_save("hazard_%02d" % (i + 1))
		for material in _hazard_materials:
			material.emission_energy_multiplier = 0.0
		await _hold("hazard_off", 64, [1, 4, 8, 16, 32, 64])
	var report := {"experiment": _experiment, "phase": _phase, "device": RenderingServer.get_video_adapter_name(), "engine": Engine.get_version_info(), "size": str(get_viewport().size), "fsr2": false, "taa": false, "vbao": false, "primary_rays_per_pixel": 0.25, "gi_denoiser": true, "multibounce": true, "reflections": true, "captures": _records, "notes": "Actual light visibility toggles; mixed sky/analytic/emissive lighting, moving rigid actor and polished first-person weapon. Fixed-frame visual test, not hardware performance."}
	var file := FileAccess.open(_output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	print("IMPROVEMENTS complete FPS ", _experiment, " ", _phase)
	get_tree().quit()
