extends SceneTree
## Front and three-quarter views of the vending machine (for the README):
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/render_vending.gd -- <out_dir>

func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(900, 1100)
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment.glow_enabled = true
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 20, 0)
	sun.light_energy = 0.5
	sun.shadow_enabled = true
	w.add_child(sun)
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.53)
	plane.material = mat
	floor.mesh = plane
	w.add_child(floor)
	var m: Node3D = load("res://assets/vending/scenes/vending_machine.tscn").instantiate()
	w.add_child(m)
	var drinks := ["water_bottle_plastic", "potion_health", "potion_speed", "potion_strength", "potion_shield",
			"potion_sleep", "potion_jump"]
	for i in drinks.size():
		var d: Node3D = load("res://assets/vending/scenes/%s.tscn" % drinks[i]).instantiate()
		d.process_mode = Node.PROCESS_MODE_DISABLED
		w.add_child(d)
		d.position = Vector3(-0.45 + i * 0.15, 0.13, 0.75)
	var cam := Camera3D.new()
	cam.fov = 40
	w.add_child(cam)
	await process_frame
	for shot in [["vending_front.png", Vector3(0.0, 1.2, 3.1), Vector3(0, 1.0, 0)],
			["vending_angle.png", Vector3(1.9, 1.5, 2.4), Vector3(0, 0.95, 0.2)],
			["vending_close.png", Vector3(0.2, 1.2, 1.5), Vector3(0.0, 1.05, 0.3)]]:
		cam.look_at_from_position(shot[1], shot[2])
		for k in 5:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join(shot[0]))
	quit()
