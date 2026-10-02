extends SceneTree
## Renders preview PNGs of the bow and arrows:
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/render_archery.gd -- <out_dir>

func _initialize() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(800, 600)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	sun.light_energy = 0.6
	sun.shadow_enabled = true
	world.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6, 6)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.62, 0.6)
	plane.material = mat
	ground.mesh = plane
	world.add_child(ground)
	var cam := Camera3D.new()
	cam.fov = 35
	world.add_child(cam)

	var bow: Node3D = load("res://assets/archery/scenes/bow.tscn").instantiate()
	var arrow: Node3D = load("res://assets/archery/scenes/arrow.tscn").instantiate()
	for n in [bow, arrow]:
		n.process_mode = Node.PROCESS_MODE_DISABLED
		world.add_child(n)
	bow.position = Vector3(0, 0.75, 0)
	await process_frame  # let _ready() build the string

	# 1-2: bow upright with an arrow on the string, at rest and at full draw.
	for draw in [0.0, 1.0]:
		bow.draw_amount = draw
		bow._update_string()
		var nock: Vector3 = bow.nock_rest + Vector3(0, 0, bow.draw_length * draw)
		arrow.global_transform = bow.global_transform * Transform3D(Basis.IDENTITY, nock - Vector3(0, 0, arrow.nock_offset))
		cam.look_at_from_position(Vector3(1.9, 1.05, 0.6), Vector3(0, 0.72, -0.05))
		await _shot(out_dir.path_join("bow_draw_%d.png" % int(draw * 100)))
	# 3: close-up of the arrow's fletching and point.
	bow.visible = false
	arrow.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(90)), Vector3(0, 0.05, 0))
	cam.look_at_from_position(Vector3(0.25, 0.32, 0.75), Vector3(0, 0.03, 0))
	await _shot(out_dir.path_join("arrow.png"))
	quit()


func _shot(path: String) -> void:
	for k in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
