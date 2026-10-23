extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	var source := _green_wall.mesh.surface_get_arrays(0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_INDEX]:
		arrays[channel] = source[channel]
	var colors := PackedColorArray()
	colors.resize(source[Mesh.ARRAY_VERTEX].size())
	colors.fill(Color.GREEN)
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.metallic_specular = 0.0
	mesh.surface_set_material(0, material)
	_green_wall.mesh = mesh
	await _settle(12)
	await _capture("materials_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("materials_green")
	# Only vertex colors are present in the attribute stream: tightly packed RGBA8.
	var attributes := PackedByteArray()
	for vertex in colors.size():
		attributes.append_array(PackedByteArray([0, 0, 255, 255]))
	mesh.surface_update_attribute_region(0, 0, attributes)
	await _settle(64)
	await _capture("materials_blue_updated")
	# Compare the retained preparation with a fresh surface containing those bytes.
	colors.fill(Color.BLUE)
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	await _settle(64)
	await _capture("materials_blue_rebuilt")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	colors.fill(Color.GREEN)
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	await _settle(12)
	await _capture("materials_disabled_after")
	print("AMD material preparation capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
