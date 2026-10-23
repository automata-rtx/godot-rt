extends "res://amd_gi.gd"

# Explicit area-light sampling at the normal quarter-rate probe budget.
# No analytic light, screen feedback, or continuation can mask a missing term.
const GI := "rendering/global_illumination/amd_gi/"

func _run() -> void:
	_light.visible = false
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "multibounce", false)
	ProjectSettings.set_setting(GI + "screen_feedback", false)
	ProjectSettings.set_setting(GI + "reflections/enabled", false)
	var panel := _box("Emitter", Vector3(0, 2.85, 0), Vector3(1.8, 0.02, 1.8), Color.BLACK)
	var material: StandardMaterial3D = panel.mesh.material
	material.emission_enabled = true
	material.emission = Color(1.0, 0.45, 0.12)
	material.emission_energy_multiplier = 4.0
	for mode in [true, false]:
		ProjectSettings.set_setting(GI + "emissive_sampling", mode)
		await _settle(64)
		await _capture("emitter_on" if mode else "emitter_hit_only")
	ProjectSettings.set_setting(GI + "emissive_sampling", true)
	await _settle(32)
	print("EMITTER stage: flicker")
	for cycle in 4:
		panel.visible = false
		await _settle(2)
		await _capture("emitter_flicker_off_%d" % cycle)
		panel.visible = true
		await _settle(2)
		await _capture("emitter_flicker_on_%d" % cycle)
	print("EMITTER stage: removal")
	panel.visible = false
	await _settle(32)
	await _capture("emitter_removed")
	print("EMITTER FINISHED")
	get_tree().quit(1 if _failures else 0)
