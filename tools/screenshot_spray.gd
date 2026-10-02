extends SceneTree
## Screenshot of the fire extinguisher spraying foam (used for the README):
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/screenshot_spray.gd -- <out.png>

func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(1000, 600)
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
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 0.6
	sun.shadow_enabled = true
	w.add_child(sun)
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.6, 0.58)
	plane.material = mat
	floor.mesh = plane
	w.add_child(floor)
	var ext: Node3D = load("res://assets/school_items/scenes/fire_extinguisher.tscn").instantiate()
	ext.process_mode = Node.PROCESS_MODE_DISABLED
	w.add_child(ext)
	var chair: Node3D = load("res://assets/classroom_furniture/scenes/school_chair.tscn").instantiate()
	chair.process_mode = Node.PROCESS_MODE_DISABLED
	w.add_child(chair)
	await process_frame
	ext.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-90)), Vector3(0, 1.1, 0))  # nozzle towards +X
	chair.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-60)), Vector3(2.4, 0, 0.2))
	var fx: CPUParticles3D = ext.get("_spray_fx")
	fx.process_mode = Node.PROCESS_MODE_ALWAYS
	fx.emitting = true
	var cam := Camera3D.new()
	cam.fov = 45
	w.add_child(cam)
	cam.look_at_from_position(Vector3(1.0, 1.4, 2.6), Vector3(1.1, 0.8, 0))
	for k in 50:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	quit()
