extends SceneTree
## Character sheet renders (front / side / back / side like the reference),
## outfit variants and an animation frame:
##   xvfb-run godot --path . --rendering-driver opengl3 --resolution 560x1000 --script res://tools/render_character.gd -- <out_dir>

func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(560, 1000)
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.WHITE
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.85, 0.85, 0.88)
	env.environment.ambient_light_energy = 0.5
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 25, 0)
	sun.light_energy = 1.25
	w.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 200, 0)
	fill.light_energy = 0.35
	w.add_child(fill)
	var s: CharacterOutfit = load("res://assets/characters/student/scenes/student.tscn").instantiate()
	w.add_child(s)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.9
	w.add_child(cam)
	await process_frame
	s.get_animation_player().stop()
	s.get_skeleton().reset_bone_poses()
	var views := [["front", 0.0], ["left", 90.0], ["back", 180.0], ["right", 270.0]]
	var outfits := [["tank_white", "shorts_black"], ["tshirt_navy", "trousers_grey"], ["none", "none"]]
	for o in outfits.size():
		s.top = outfits[o][0]
		s.bottom = outfits[o][1]
		for v in views:
			if o > 0 and v[0] != "front":
				continue
			var a := deg_to_rad(v[1])
			cam.look_at_from_position(Vector3(sin(a), 0, cos(a)) * 4.0 + Vector3(0, 0.88, 0), Vector3(0, 0.88, 0))
			await _shot(out.path_join("student_%s_%s.png" % [outfits[o][0], v[0]]))
	# Close-up of the face.
	s.top = &"tank_white"
	s.bottom = &"shorts_black"
	cam.size = 0.42
	cam.look_at_from_position(Vector3(0, 1.6, 4), Vector3(0, 1.6, 0))
	await _shot(out.path_join("student_face.png"))
	cam.look_at_from_position(Vector3(4, 1.6, 0), Vector3(0, 1.6, 0))
	await _shot(out.path_join("student_face_side.png"))
	cam.size = 0.6
	cam.look_at_from_position(Vector3(1.0, 0.95, 4), Vector3(0, 0.95, 0))
	await _shot(out.path_join("student_waist.png"))
	# Animation frames.
	cam.size = 1.9
	for anim in [["walk", 0.25], ["run", 0.2], ["idle", 0.5]]:
		s.play(anim[0], 0.0)
		s.get_animation_player().seek(anim[1], true)
		s.get_animation_player().pause()
		cam.look_at_from_position(Vector3(2.8, 0.9, 2.8), Vector3(0, 0.9, 0))
		await _shot(out.path_join("student_anim_%s.png" % anim[0]))
	quit()


func _shot(path: String) -> void:
	for k in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
