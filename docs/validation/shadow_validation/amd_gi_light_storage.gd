extends "res://gi.gd"

# Byte-equivalence and command-count regression, not a performance benchmark.
# The reference oracle intentionally rebuilds every emitter each frame.
const GI := "rendering/global_illumination/amd_gi/"


func _settle_storage(label: String, frames: int = 4) -> void:
	print("LIGHT_STORAGE stage ", label)
	for frame in frames:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _run() -> void:
	for flag in ["GODOT_AMD_GI_VALIDATE_LIGHT_STORAGE", "GODOT_AMD_GI_VALIDATE_EMITTER_UPDATES"]:
		if OS.get_environment(flag) != "1":
			push_error("LIGHT_STORAGE requires " + flag + "=1")
			get_tree().quit(1)
			return
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "emissive_sampling", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	# Allocate the rejected flare before the static emitters so showing it would
	# shift their collected indices. This matches the game's additive flash.
	var flare := MeshInstance3D.new()
	var flare_material := StandardMaterial3D.new()
	flare_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flare_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flare_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flare.material_override = flare_material
	flare.mesh = SphereMesh.new()
	flare.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flare.visible = false
	add_child(flare)
	var material := StandardMaterial3D.new()
	material.emission_enabled = true
	material.emission = Color(0.2, 0.4, 0.7)
	material.roughness = 1.0
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.12, 0.12, 0.12)
	mesh.material = material
	for i in 16:
		var emitter := MeshInstance3D.new()
		emitter.mesh = mesh
		emitter.position = Vector3(float(i % 8) * 0.3 - 1.05, 0.6 + float(i / 8) * 0.4, -1.5)
		add_child(emitter)
	var flashes: Array[OmniLight3D] = []
	for i in 16:
		var light := OmniLight3D.new()
		light.position = Vector3(0.0, 1.8, -0.5)
		light.light_energy = 6.0
		light.omni_range = 7.0
		light.light_size = 0.0
		light.visible = false
		add_child(light)
		flashes.append(light)
	await _settle_storage("warmup", 16)
	print("LIGHT_STORAGE checked")
	_light.visible = false
	await _settle_storage("zero analytic lights")
	_light.visible = true
	await _settle_storage("one analytic light restored")
	_light.light_negative = true
	await _settle_storage("negative analytic light excluded")
	_light.light_negative = false
	await _settle_storage("positive analytic light restored")
	# With the room's permanent light, cross every allocation boundary from
	# one to 32 slots, then shrink the active prefix without moving emitters.
	for count in [2, 3, 5, 9, 17, 9, 5, 3, 2, 1]:
		for i in flashes.size():
			flashes[i].visible = i < count - 1
		await _settle_storage("active count %d" % count)
	flashes[0].visible = true
	await _settle_storage("replacement baseline")
	flashes[0].visible = false
	flashes[1].visible = true
	await _settle_storage("same count different light identity")
	flashes[1].queue_free()
	var replacement := OmniLight3D.new()
	replacement.position = Vector3(0.1, 1.8, -0.5)
	replacement.light_energy = 6.0
	replacement.omni_range = 7.0
	replacement.light_size = 0.0
	add_child(replacement)
	flashes[1] = replacement
	await _settle_storage("same count newly allocated light")
	replacement.visible = false
	for cycle in 8:
		flare.rotation.z = float(cycle) * 0.31
		flare.scale = Vector3.ONE * (0.1 + float(cycle) * 0.01)
		flare.visible = true
		flashes[0].visible = true
		await _settle_storage("blink %d on" % cycle, 3)
		flashes[0].visible = false
		flare.visible = false
		await _settle_storage("blink %d off" % cycle, 3)
	await _settle_storage("unchanged after blinks")
	print("LIGHT_STORAGE complete")
	get_tree().quit()
