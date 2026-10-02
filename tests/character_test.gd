extends SceneTree
## Offline checks for the student character (rig, outfits, animations):
##   godot --headless --path . --script res://tests/character_test.gd

const HUMANOID := ["Root", "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
		"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
		"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
		"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
		"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes"]

var failures := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		failures += 1


func wait_frames(n: int) -> void:
	for i in n:
		await process_frame


func mesh_ids(s: CharacterOutfit, slot: StringName) -> Array:
	return s.get_clothing(slot).map(func(m): return String(m.name).trim_suffix("Mesh"))


func world_aabb(s: CharacterOutfit) -> AABB:
	var box := AABB()
	var first := true
	for m in s.get_skeleton().get_children():
		if m is MeshInstance3D and m.visible:
			var b: AABB = m.global_transform * m.get_aabb()
			box = b if first else box.merge(b)
			first = false
	return box


func _initialize() -> void:
	var s: CharacterOutfit = load("res://assets/characters/student/scenes/student.tscn").instantiate()
	root.add_child(s)
	await wait_frames(2)

	# Rig
	var sk := s.get_skeleton()
	check(sk != null, "model has a Skeleton3D")
	var missing := HUMANOID.filter(func(b): return sk.find_bone(b) < 0)
	check(missing.is_empty(), "skeleton uses Godot humanoid bone names (missing: %s)" % [missing])
	var skinned := 0
	for m in sk.get_children():
		if m is MeshInstance3D:
			if m.skin != null and m.get_node_or_null(m.skeleton) == sk:
				skinned += 1
			for i in m.skin.get_bind_count():
				if sk.find_bone(m.skin.get_bind_name(i)) < 0:
					check(false, "%s bind %d '%s' names a bone" % [m.name, i, m.skin.get_bind_name(i)])
					break
	check(skinned >= 7, "body, head, hair, glasses and both clothes are skinned to the skeleton (%d)" % skinned)
	var box := world_aabb(s)
	check(box.end.y > 1.7 and box.end.y < 1.82 and box.position.y < 0.01 and box.position.y > -0.03,
			"about 1.75 m tall, feet on the floor (%.2f..%.2f)" % [box.position.y, box.end.y])
	var face := sk.get_node_or_null("HeadMesh") as MeshInstance3D
	var fmat := face.mesh.surface_get_material(0) as BaseMaterial3D if face else null
	check(fmat != null and fmat.texture_filter == BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
			"textures are nearest-filtered (PS3 texel look)")

	# Outfits
	check(mesh_ids(s, &"top") == ["TankTop"] and mesh_ids(s, &"bottom") == ["Shorts"],
			"default outfit: white tank top + black shorts")
	var tank: MeshInstance3D = s.get_clothing(&"top")[0]
	var tmat := tank.mesh.surface_get_material(0) as BaseMaterial3D
	check(tmat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, "tank top openings are alpha-scissored")
	s.top = &"tshirt_navy"
	s.bottom = &"trousers_grey"
	await wait_frames(2)
	check(mesh_ids(s, &"top") == ["TShirt"] and mesh_ids(s, &"bottom") == ["Trousers"],
			"swap to navy T-shirt + grey trousers")
	check(not is_instance_valid(tank) or tank.is_queued_for_deletion() or tank.get_parent() == null,
			"old top removed")
	s.top = &"none"
	s.bottom = &"none"
	await wait_frames(2)
	check(s.get_clothing(&"top").is_empty() and s.get_clothing(&"bottom").is_empty(), "clothes can be taken off")
	CharacterOutfit.register_top(&"tank_again", "res://assets/characters/student/models/top_tank_white.glb")
	s.set_top(&"tank_again")
	s.set_bottom(&"shorts_black")
	await wait_frames(2)
	check(mesh_ids(s, &"top") == ["TankTop"], "custom registered clothing works")
	s.top_tint = Color(1, 0, 0)
	var tinted := s.get_clothing(&"top")[0].get_surface_override_material(0) as BaseMaterial3D
	check(tinted != null and tinted.albedo_color.g < 0.1 and tinted.albedo_color.r > 0.5, "top tint recolours it")
	s.top_tint = Color.WHITE
	check(s.get_clothing(&"top")[0].get_surface_override_material(0) == null, "white tint restores the texture")
	s.glasses = false
	check(not sk.get_node("GlassesMesh").visible, "glasses can be taken off")
	s.glasses = true
	var sync := s.get_node("OutfitSync") as MultiplayerSynchronizer
	var props := []
	for i in sync.replication_config.get_properties().size():
		props.append(String(sync.replication_config.get_properties()[i]))
	check(props.has(".:top") and props.has(".:bottom") and props.has(".:glasses"), "outfit is network-synced")

	# Animations: clothes follow the skeleton.
	var ap := s.get_animation_player()
	for a in ["idle", "walk", "run"]:
		check(ap.has_animation(a) and ap.get_animation(a).loop_mode == Animation.LOOP_LINEAR, "%s animation loops" % a)
	var shorts: MeshInstance3D = s.get_clothing(&"bottom")[0]
	var knee := sk.find_bone("LeftLowerLeg")
	var rest_knee := sk.get_bone_global_pose(knee).origin
	s.play(&"walk", 0.0)
	ap.seek(0.25, true)
	ap.pause()
	await wait_frames(2)
	var walk_knee := sk.get_bone_global_pose(knee).origin
	check(walk_knee.distance_to(rest_knee) > 0.05, "walk moves the legs (knee moved %.2f m)" % walk_knee.distance_to(rest_knee))
	check(shorts.get_node(shorts.skeleton) == sk, "clothes are driven by the same skeleton")
	s.set_move_speed(0.0)
	check(ap.current_animation == "idle", "standing still plays idle")
	s.set_move_speed(1.4)
	check(ap.current_animation == "walk", "1.4 m/s plays walk")
	s.set_move_speed(5.0)
	check(ap.current_animation == "run", "5 m/s plays run")

	print("\n%d failure(s)" % failures)
	quit(1 if failures else 0)
