extends SceneTree
## Renders preview PNGs of every stationery weapon:
##   xvfb-run godot --path . --rendering-driver opengl3 --script res://tools/render_stationery.gd -- <out_dir>

const ITEMS := ["pencil", "ballpoint_pen", "ruler", "scissors", "compass", "stapler", "eraser", "pencil_case"]

func _initialize() -> void:
	var out_dir: String = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(800, 600)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	# A sky like a real level, so metal has something to reflect.
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = sky
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.6
	sun.shadow_enabled = true
	world.add_child(sun)
	# A green desk-top coloured surface to put things on.
	var top := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(3, 3)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color8(139, 199, 109)
	mat.roughness = 0.5
	plane.material = mat
	top.mesh = plane
	world.add_child(top)
	var cam := Camera3D.new()
	cam.fov = 30
	world.add_child(cam)

	var nodes := []
	for i in ITEMS.size():
		var n: Node3D = load("res://assets/stationery/scenes/%s.tscn" % ITEMS[i]).instantiate()
		n.process_mode = Node.PROCESS_MODE_DISABLED
		world.add_child(n)
		nodes.append(n)
	# Each item on its own, then all of them side by side.
	for i in ITEMS.size():
		for j in nodes.size():
			nodes[j].visible = j == i
		var n: Node3D = nodes[i]
		var aabb := _aabb(n)
		n.global_position = Vector3(0, -aabb.position.y, 0)
		aabb = _aabb(n)
		var c := aabb.get_center()
		var r: float = aabb.size.length()
		cam.look_at_from_position(c + Vector3(0.55, 0.75, 0.55).normalized() * r * 1.3, c)
		await _shot(out_dir.path_join("item_%s.png" % ITEMS[i]))
	for j in nodes.size():
		nodes[j].visible = true
		var a := _aabb(nodes[j])
		nodes[j].global_position = Vector3((j - 3.5) * 0.085, nodes[j].global_position.y, 0)
	cam.look_at_from_position(Vector3(0.0, 0.55, 0.55), Vector3(0, 0, -0.02))
	await _shot(out_dir.path_join("all.png"))
	quit()


func _shot(path: String) -> void:
	for k in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)


func _aabb(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = mi.global_transform * mi.get_aabb()
		box = a if first else box.merge(a)
		first = false
	return box
