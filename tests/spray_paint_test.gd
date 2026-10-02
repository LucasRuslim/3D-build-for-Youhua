extends SceneTree
## Offline checks for the spray paint:
##   godot --headless --path . --script res://tests/spray_paint_test.gd

const DummyTarget := preload("res://tests/dummy_target.gd")

var failures := 0
var world: Node3D


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		failures += 1


func wait_frames(n: int) -> void:
	for i in n:
		await physics_frame


func make_static_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	cs.shape.size = size
	b.add_child(cs)
	b.position = pos
	world.add_child(b)
	return b


func marks_on(node: Node) -> Array:
	return SprayPaint.marks_on(node)  # global transforms of the paint puffs


func _initialize() -> void:
	world = Node3D.new()
	root.add_child(world)
	make_static_box(Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	var wall := make_static_box(Vector3(0, 1.5, -3.1), Vector3(10, 3, 0.2))  # face at z = -3.0

	var can: SprayPaint = load("res://assets/school_items/scenes/spray_paint.tscn").instantiate()
	can.position = Vector3(0, 0.4, 0)
	world.add_child(can)
	await wait_frames(120)
	check(can.global_position.y > 0.05 and can.global_position.y < 0.2 and can.linear_velocity.length() < 0.05,
			"spray can rests on the floor (y=%.3f)" % can.global_position.y)
	var hands := PropHolder.new()
	world.add_child(hands)
	hands.global_position = can.global_position + Vector3(0, 0.6, 0.3)
	await wait_frames(1)
	hands.try_grab()
	await wait_frames(3)
	check(can.is_held(), "spray can picked up")

	# Paint the wall.
	hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.5))
	await wait_frames(2)
	hands.attack()
	await wait_frames(60)
	check(can.spraying, "holding attack sprays")
	hands.attack_release()
	await wait_frames(2)
	check(not can.spraying, "releasing attack stops spraying")
	var on_wall := marks_on(wall)
	check(on_wall.size() > 80, "a second of spraying leaves %d paint puffs on the wall" % on_wall.size())
	var layers := wall.get_children().filter(func(c): return c is MultiMeshInstance3D)
	check(layers.size() == 1, "all the paint on the wall is one MultiMesh layer")
	var sizes: Array = on_wall.map(func(m): return m.basis.x.length())
	check(sizes.max() < 0.15, "spray puffs stay narrow at 1.5 m (largest %.3f m; the droplets in them are ~0.5 mm)" % sizes.max())
	var flat := on_wall.all(_flat_on_wall)
	check(flat, "marks lie flat on the wall surface, facing out")
	var spread := on_wall.all(_near_aim)
	check(spread, "marks land where the can is aimed (within 40 cm at 1.5 m)")
	check(can.paint < 1.0 and can.paint > 0.9, "paint is used up while spraying (%.2f left)" % can.paint)

	# Paint sticks to things that move.
	var chair: RigidBody3D = load("res://assets/classroom_furniture/scenes/school_chair.tscn").instantiate()
	chair.position = Vector3(3, 0, -1.6)
	world.add_child(chair)
	await wait_frames(30)
	hands.global_transform = Transform3D(Basis.looking_at(chair.global_position + Vector3(0, 0.6, 0) - Vector3(3, 1.2, 0)),
			Vector3(3, 1.2, 0))
	await wait_frames(int(can.attack_cooldown * 60) + 2)
	hands.attack()
	await wait_frames(30)
	hands.attack_release()
	await wait_frames(2)
	var on_chair := marks_on(chair)
	check(on_chair.size() > 10, "the chair gets painted (%d marks)" % on_chair.size())
	if on_chair.size() > 0:
		var rel: Vector3 = chair.to_local(on_chair[0].origin)
		chair.global_transform = Transform3D(Basis(Vector3.UP, 1.2), Vector3(6, 0, 3))
		await wait_frames(2)
		var moved: Transform3D = marks_on(chair)[0]
		check(moved.origin.distance_to(on_chair[0].origin) > 1.0 and chair.to_local(moved.origin).distance_to(rel) < 0.001,
				"paint moves with the chair")

	# Spraying a player marks them "painted".
	var person: CharacterBody3D = DummyTarget.new()
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	cs.shape.radius = 0.3
	cs.shape.height = 1.8
	person.add_child(cs)
	var se := StatusEffects.new()
	se.name = "StatusEffects"
	person.add_child(se)
	person.position = Vector3(-3, 0.92, -1.5)
	world.add_child(person)
	hands.global_transform = Transform3D(Basis.looking_at(Vector3(-3, 1.2, -1.5) - Vector3(-3, 1.2, 0)), Vector3(-3, 1.2, 0))
	await wait_frames(3)
	hands.attack()
	await wait_frames(20)
	hands.attack_release()
	await wait_frames(2)
	check(se.is_active(&"painted") and marks_on(person).size() > 0,
			"a sprayed player gets painted (%d marks, %s)" % [marks_on(person).size(), se.active_effects])

	# A surface keeps at most max_marks puffs; then the oldest get painted over.
	var wall2 := make_static_box(Vector3(0, 1.5, 4.1), Vector3(10, 3, 0.2))  # face at z = 4.0
	can.max_marks = 60
	hands.global_transform = Transform3D(Basis.looking_at(Vector3.BACK), Vector3(0, 1.4, 2.5))
	await wait_frames(2)
	hands.attack()
	await wait_frames(90)
	hands.attack_release()
	await wait_frames(3)
	check(marks_on(wall2).size() == 60, "a surface keeps at most max_marks puffs (%d)" % marks_on(wall2).size())

	# Empty can: no paint, attack swings.
	hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.5))
	can.paint = 0.01
	hands.attack()
	await wait_frames(30)
	hands.attack_release()
	check(can.paint == 0.0 and not can.spraying, "the can runs out of paint")
	var victim: CharacterBody3D = DummyTarget.new()
	var vcs := CollisionShape3D.new()
	vcs.shape = cs.shape
	victim.add_child(vcs)
	victim.position = hands.global_position + Vector3(0, -0.2, -0.6)
	world.add_child(victim)
	await wait_frames(int(can.attack_cooldown * 60) + 2)
	hands.attack()
	await wait_frames(3)
	check(victim.hits.size() == 1 and victim.hits[0].kind == "swing", "an empty can is a club (%s)" % [victim.hits])

	print("RESULT: %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)


func _flat_on_wall(m: Transform3D) -> bool:
	return absf(m.origin.z + 3.0) < 0.006 and m.basis.z.normalized().dot(Vector3.BACK) > 0.99


func _near_aim(m: Transform3D) -> bool:
	return Vector2(m.origin.x, m.origin.y - 1.4).length() < 0.4
