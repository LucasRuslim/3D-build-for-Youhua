extends SceneTree
## Screenshot of the spray paint in use: a hand sprays red paint over a wall
## and a chair, drawing a big zigzag. Used for the README:
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/screenshot_spray_paint.gd -- <out.png>

func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(1000, 640)
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 25, 0)
	sun.light_energy = 0.6
	sun.shadow_enabled = true
	w.add_child(sun)
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.78, 0.8, 0.82)
	for spec in [[Vector3(0, -0.5, 0), Vector3(12, 1, 12), Color(0.55, 0.55, 0.53)],
			[Vector3(0, 1.5, -2.6), Vector3(8, 3, 0.2), Color(0.85, 0.86, 0.88)]]:
		var b := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = BoxShape3D.new()
		cs.shape.size = spec[1]
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = spec[1]
		var m := StandardMaterial3D.new()
		m.albedo_color = spec[2]
		bm.material = m
		mi.mesh = bm
		b.add_child(mi)
		b.position = spec[0]
		w.add_child(b)
	var chair: Node3D = load("res://assets/classroom_furniture/scenes/school_chair.tscn").instantiate()
	chair.position = Vector3(0.9, 0, -1.4)
	chair.rotation_degrees.y = -20
	w.add_child(chair)
	var can: SprayPaint = load("res://assets/school_items/scenes/spray_paint.tscn").instantiate()
	can.position = Vector3(0, 0.1, 0.6)
	w.add_child(can)
	var hands := PropHolder.new()
	w.add_child(hands)
	hands.global_position = Vector3(0, 0.6, 0.9)
	for i in 30:
		await physics_frame
	hands.try_grab()
	for i in 3:
		await physics_frame
	hands.global_position = Vector3(-0.3, 1.3, -0.3)
	# Draw a zigzag on the wall, then paint the chair.
	var pts := [Vector3(-1.6, 2.2, -2.5), Vector3(-0.9, 0.9, -2.5), Vector3(-0.2, 2.2, -2.5), Vector3(0.5, 0.9, -2.5),
			Vector3(1.2, 2.2, -2.5)]
	hands.attack()
	for s in pts.size() - 1:
		for k in 40:
			var target: Vector3 = pts[s].lerp(pts[s + 1], k / 40.0)
			hands.look_at(target)
			await physics_frame
	for k in 50:
		hands.look_at(chair.global_position + Vector3(0, 0.55 + 0.25 * sin(k * 0.3), 0))
		await physics_frame
	hands.attack_release()
	var cam := Camera3D.new()
	cam.fov = 50
	w.add_child(cam)
	cam.look_at_from_position(Vector3(1.6, 1.5, 2.2), Vector3(-0.1, 1.2, -1.8))
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	print("marks: ", can.get_marks().size(), " paint left: ", snappedf(can.paint, 0.01))
	quit()
