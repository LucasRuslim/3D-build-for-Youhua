extends SceneTree
## Close-up of one spray stroke at 1 m, to judge the droplet size (README):
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/screenshot_spray_closeup.gd -- <out.png>
func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(900, 600)
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.3, 0.3, 0.3)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(1, 1, 1)
	env.environment.ambient_light_energy = 0.9
	w.add_child(env)
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	cs.shape.size = Vector3(4, 3, 0.2)
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(4, 3, 0.2)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.86, 0.88)
	bm.material = m
	mi.mesh = bm
	b.add_child(mi)
	b.position = Vector3(0, 1.5, -1.1)
	w.add_child(b)
	var can: SprayPaint = load("res://assets/school_items/scenes/spray_paint.tscn").instantiate()
	can.position = Vector3(0, 0.1, 0)
	w.add_child(can)
	var hands := PropHolder.new()
	w.add_child(hands)
	await process_frame
	hands.global_position = Vector3(0, 0.6, 0.3)
	for i in 3:
		await physics_frame
	hands.try_grab()
	for i in 3:
		await physics_frame
	hands.global_position = Vector3(0, 1.5, 0.0)  # 1 m from the wall
	hands.attack()
	for k in 120:  # a slow S-curve
		var t := k / 119.0
		hands.look_at(Vector3(lerpf(-0.6, 0.6, t), 1.5 + 0.25 * sin(t * TAU), -1.0))
		await physics_frame
	hands.attack_release()
	hands.global_position = Vector3(2.0, 1.5, 0.0)
	var cam := Camera3D.new()
	cam.fov = 40
	w.add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.5, 0.4), Vector3(0, 1.5, -1.0))
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	quit()
