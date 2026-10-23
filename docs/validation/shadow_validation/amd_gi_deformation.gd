extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	ProjectSettings.set_setting(GI + "max_distance", 20.0)
	var actor: MeshInstance3D = get_node("ShortBox")
	var original := actor.mesh
	var source := original.surface_get_arrays(0)
	var material := original.surface_get_material(0)
	var skeleton := Skeleton3D.new()
	skeleton.name = "CaptureSkeleton"
	skeleton.add_bone("root")
	skeleton.set_bone_rest(0, Transform3D.IDENTITY)
	add_child(skeleton)
	var skin := Skin.new()
	skin.add_bind(0, Transform3D.IDENTITY)
	await _settle(12)
	await _capture("deformation_disabled")
	for influences in [4, 8]:
		var arrays: Array = source.duplicate(true)
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		for vertex in arrays[Mesh.ARRAY_VERTEX].size():
			for influence in influences:
				bones.append(0)
				weights.append(1.0 / influences)
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		var delta := []
		delta.resize(Mesh.ARRAY_MAX)
		var positions := PackedVector3Array()
		var normals := PackedVector3Array()
		var tangents := PackedFloat32Array()
		positions.resize(arrays[Mesh.ARRAY_VERTEX].size())
		positions.fill(Vector3(0.2, 0.15, 0.0))
		normals.resize(positions.size())
		tangents.resize(positions.size() * 4)
		delta[Mesh.ARRAY_VERTEX] = positions
		delta[Mesh.ARRAY_NORMAL] = normals
		delta[Mesh.ARRAY_TANGENT] = tangents
		var posed := ArrayMesh.new()
		posed.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
		posed.add_blend_shape("offset")
		var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if influences == 8 else 0
		posed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [delta], {}, flags)
		posed.surface_set_material(0, material)
		actor.mesh = posed
		actor.skeleton = actor.get_path_to(skeleton)
		actor.skin = skin
		actor.set_blend_shape_value(0, 0.7)
		skeleton.set_bone_pose_rotation(0, Quaternion.IDENTITY)
		skeleton.set_bone_pose_position(0, Vector3.ZERO)
		if influences == 8:
			# Exercise the alternating native pose buffers used with temporal upscalers.
			get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			get_viewport().scaling_3d_scale = 0.5
		ProjectSettings.set_setting(GI + "enabled", true)
		print("stage deformation: animate %d" % influences)
		for frame in 12:
			skeleton.set_bone_pose_rotation(0, Quaternion(Vector3.FORWARD, float(frame + 1) * 0.035))
			skeleton.set_bone_pose_position(0, Vector3(0.0, float(frame + 1) * 0.025, 0.0))
			await _settle(1)
		await _settle(64)
		await _capture("deformation_pose_%d" % influences)
		ProjectSettings.set_setting(GI + "enabled", false)
		await _settle(16)
		await _capture("deformation_pose_direct_%d" % influences)
		# Independently bake the same deformation on the CPU as an ordinary static
		# mesh, then compare GI on the untouched room as well as the visible actor.
		var transform := Transform3D(Basis(Quaternion(Vector3.FORWARD, 12.0 * 0.035)), Vector3(0, 0.3, 0))
		var baked: Array = source.duplicate(true)
		for i in baked[Mesh.ARRAY_VERTEX].size():
			baked[Mesh.ARRAY_VERTEX][i] = transform * (source[Mesh.ARRAY_VERTEX][i] + positions[i] * 0.7)
			baked[Mesh.ARRAY_NORMAL][i] = transform.basis * source[Mesh.ARRAY_NORMAL][i]
			var tangent := Vector3(source[Mesh.ARRAY_TANGENT][i * 4], source[Mesh.ARRAY_TANGENT][i * 4 + 1], source[Mesh.ARRAY_TANGENT][i * 4 + 2])
			tangent = transform.basis * tangent
			for component in 3:
				baked[Mesh.ARRAY_TANGENT][i * 4 + component] = tangent[component]
		var reference := ArrayMesh.new()
		reference.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, baked)
		reference.surface_set_material(0, material)
		actor.skin = null
		actor.skeleton = NodePath()
		actor.mesh = reference
		await _settle(16)
		await _capture("deformation_baked_direct_%d" % influences)
		ProjectSettings.set_setting(GI + "enabled", true)
		await _settle(64)
		await _capture("deformation_baked_%d" % influences)
		ProjectSettings.set_setting(GI + "enabled", false)
	actor.mesh = original
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().scaling_3d_scale = 1.0
	await _settle(16)
	await _capture("deformation_disabled_after")
	print("AMD deformation capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
