extends SceneTree
## Offline checks: props settle upright, can be picked up, thrown, and report hits.
##   godot --headless --path . --script res://tests/physics_test.gd

var failures := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		failures += 1


func wait_frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var floor := StaticBody3D.new()
	var fs := CollisionShape3D.new()
	fs.shape = BoxShape3D.new()
	fs.shape.size = Vector3(30, 1, 30)
	fs.position.y = -0.5
	floor.add_child(fs)
	world.add_child(floor)
	var wall := StaticBody3D.new()
	var ws := CollisionShape3D.new()
	ws.shape = BoxShape3D.new()
	ws.shape.size = Vector3(30, 4, 0.5)
	wall.add_child(ws)
	wall.position = Vector3(0, 2, -3)  # well inside one throw's flight
	world.add_child(wall)

	for scene_name in ["school_desk", "school_chair"]:
		var prop: NetworkedProp = load("res://assets/classroom_furniture/scenes/%s.tscn" % scene_name).instantiate()
		prop.position = Vector3(0, 0.15, 0)
		world.add_child(prop)
		await wait_frames(1)

		# Collision boxes should cover the visible mesh.
		var mesh_box := AABB()
		for mi in prop.find_children("*", "MeshInstance3D", true, false):
			var a: AABB = mi.global_transform * mi.get_aabb()
			mesh_box = a if mesh_box.size == Vector3.ZERO else mesh_box.merge(a)
		var col_box := AABB()
		for cs in prop.find_children("*", "CollisionShape3D", false, false):
			var s: Vector3 = cs.shape.size
			var a: AABB = cs.global_transform * AABB(-s / 2, s)
			col_box = a if col_box.size == Vector3.ZERO else col_box.merge(a)
		var grow := col_box.grow(0.02)
		check(grow.encloses(mesh_box) or (mesh_box.size - col_box.size).length() < 0.06,
				"%s collision %s matches mesh %s" % [scene_name, col_box.size, mesh_box.size])

		await wait_frames(150)
		check(abs(prop.global_position.y) < 0.02, "%s settles on the floor (y=%.3f)" % [scene_name, prop.global_position.y])
		check(prop.global_basis.y.dot(Vector3.UP) > 0.99, "%s stays upright" % scene_name)
		check(prop.linear_velocity.length() < 0.05, "%s comes to rest" % scene_name)

		var holder := PropHolder.new()
		holder.name = "Holder"
		world.add_child(holder)
		holder.global_transform = Transform3D(Basis.IDENTITY, prop.global_position + Vector3(0, 1.1, 0.6))
		check(holder.find_grab_target() == prop, "%s is found as grab target" % scene_name)
		check(holder.try_grab(), "%s grab request sent" % scene_name)
		await wait_frames(3)
		check(prop.is_held() and prop.holder_peer_id == 1, "%s is held by peer 1" % scene_name)
		holder.global_position += Vector3(0.5, 0.3, 0)
		await wait_frames(2)
		var want: Vector3 = (holder.global_transform * prop.hold_offset).origin
		check(prop.global_position.distance_to(want) < 0.01, "%s follows the hand" % scene_name)

		var hits := []
		prop.hit.connect(func(body, speed, thrower): hits.append([body, speed, thrower]))
		holder.throw()
		await wait_frames(2)
		check(not prop.is_held(), "%s released on throw" % scene_name)
		check(prop.linear_velocity.length() > 10.0, "%s thrown at %.1f m/s" % [scene_name, prop.linear_velocity.length()])
		await wait_frames(120)
		var hit_wall := hits.any(func(h): return h[0] == wall)
		check(hit_wall, "%s hit signal fired on the wall" % scene_name)
		if hits.size() > 0:
			check(hits[0][2] == 1, "%s hit is credited to thrower peer 1" % scene_name)
		holder.queue_free()
		prop.queue_free()
		await wait_frames(2)

	# A running CharacterBody3D (the usual player node) shoves furniture.
	for scene_name in ["school_desk", "school_chair"]:
		var prop: NetworkedProp = load("res://assets/classroom_furniture/scenes/%s.tscn" % scene_name).instantiate()
		world.add_child(prop)
		await wait_frames(60)
		var start := prop.global_position
		var runner := CharacterBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = CapsuleShape3D.new()
		cs.shape.radius = 0.3
		cs.shape.height = 1.8
		runner.add_child(cs)
		runner.position = Vector3(-1.5, 0.91, 0)  # set before adding, so it never overlaps the prop
		world.add_child(runner)
		for i in 60:
			runner.velocity = Vector3(5, 0, 0)  # running at 5 m/s along +X
			var v := runner.velocity
			runner.move_and_slide()
			NetworkedProp.push_from_character(runner, v)
			await physics_frame
		await wait_frames(30)
		var moved := prop.global_position.x - start.x
		var tipped := prop.global_basis.y.dot(Vector3.UP) < 0.7
		check(moved > 0.5, "running into the %s shoves it %.2f m%s" % [scene_name, moved, " and knocks it over" if tipped else ""])
		runner.queue_free()
		prop.queue_free()
		await wait_frames(2)

	print("RESULT: %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)
