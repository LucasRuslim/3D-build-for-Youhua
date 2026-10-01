extends SceneTree
## Renders preview PNGs of the props:
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/render_preview.gd -- <out_dir>

const SHOTS := [
	# [file, camera position, look-at]
	["preview_pair.png", Vector3(1.25, 1.35, 1.55), Vector3(0.05, 0.45, 0.0)],
	["preview_desk_top.png", Vector3(0.25, 1.55, 0.85), Vector3(0.0, 0.7, -0.05)],
	["preview_chair_side.png", Vector3(-1.3, 0.85, 1.25), Vector3(0.0, 0.45, 0.55)],
	["preview_back.png", Vector3(-0.9, 1.1, -1.6), Vector3(0.0, 0.45, 0.25)],
	["preview_chair_front.png", Vector3(0.75, 1.15, 1.55), Vector3(0.0, 0.5, 0.55)],
	["preview_chair_basket.png", Vector3(0.75, 0.38, 1.35), Vector3(0.0, 0.14, 0.55)],
	["preview_chair_profile.png", Vector3(1.6, 0.7, 0.55), Vector3(0.0, 0.55, 0.55)],
]

func _initialize() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "res://"
	root.size = Vector2i(1280, 960)
	var world := Node3D.new()
	root.add_child(world)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.57, 0.6)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.85, 0.87, 0.9)
	env.environment.ambient_light_energy = 0.25
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.55
	sun.shadow_enabled = true
	world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, -140, 0)
	fill.light_energy = 0.2
	world.add_child(fill)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.7, 0.7, 0.69)
	floor_mat.roughness = 0.35
	plane.material = floor_mat
	floor_mesh.mesh = plane
	world.add_child(floor_mesh)

	var desk: Node3D = load("res://assets/classroom_furniture/scenes/school_desk.tscn").instantiate()
	world.add_child(desk)
	var chair: Node3D = load("res://assets/classroom_furniture/scenes/school_chair.tscn").instantiate()
	chair.position = Vector3(0.0, 0, 0.55)
	chair.rotation_degrees.y = 180  # chair faces the desk
	world.add_child(chair)
	for b in [desk, chair]:
		b.process_mode = Node.PROCESS_MODE_DISABLED

	var cam := Camera3D.new()
	cam.fov = 45
	world.add_child(cam)
	for shot in SHOTS:
		cam.look_at_from_position(shot[1], shot[2])
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out_dir.path_join(shot[0]))
		print("saved ", shot[0])
	quit()
