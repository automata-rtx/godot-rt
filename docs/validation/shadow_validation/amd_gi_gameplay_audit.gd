extends "res://amd_gi.gd"

# Defect reproduction, not a passing visual acceptance test. See
# docs/AMD_GI_GAMEPLAY_AUDIT.md for diagnostic flags and the recorded baseline.
const GI := "rendering/global_illumination/amd_gi/"

func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	var metal: StandardMaterial3D = get_node("ShortBox").mesh.material
	metal.metallic = 1.0
	metal.roughness = 0.2
	metal.albedo_color = Color(0.83, 0.58, 0.12)
	print("AUDIT stage: stationary metal")
	await _settle(32)
	print("AUDIT stage: moving metal")
	for frame in 16:
		get_node("ShortBox").position.x += 0.01
		get_node("ShortBox").rotate_y(0.01)
		await _settle(1)
	print("AUDIT stage: stopped metal")
	await _settle(32)
	var pulse := OmniLight3D.new()
	pulse.position = Vector3(0, 2, 0)
	pulse.light_energy = 2
	pulse.light_size = 0
	pulse.visible = false
	add_child(pulse)
	print("AUDIT stage: light pulses")
	for cycle in 3:
		pulse.visible = true
		await _settle(2)
		pulse.visible = false
		await _settle(6)
	print("AUDIT stage: flickering geometry")
	var flicker := _box("Flicker", Vector3(1, 1, 0), Vector3(0.04, 1, 0.04), Color.WHITE)
	for frame in 12:
		flicker.visible = frame % 2 == 0
		await _settle(1)
	print("AUDIT FINISHED")
	get_tree().quit()
