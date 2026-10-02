extends SceneTree
## Offline checks for every stationery weapon:
##   godot --headless --path . --script res://tests/stationery_test.gd

const ITEMS := ["pencil", "ballpoint_pen", "ruler", "scissors", "compass", "stapler", "eraser", "pencil_case"]
const DummyTarget := preload("res://tests/dummy_target.gd")

var failures := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		failures += 1


func wait_frames(n: int) -> void:
	for i in n:
		await physics_frame


func make_target(pos: Vector3) -> CharacterBody3D:
	var t: CharacterBody3D = DummyTarget.new()
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	cs.shape.radius = 0.3
	cs.shape.height = 1.8
	t.add_child(cs)
	t.position = pos
	return t


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var floor := StaticBody3D.new()
	var fs := CollisionShape3D.new()
	fs.shape = BoxShape3D.new()
	fs.shape.size = Vector3(40, 1, 40)
	fs.position.y = -0.5
	floor.add_child(fs)
	world.add_child(floor)
	var wall := StaticBody3D.new()
	var ws := CollisionShape3D.new()
	ws.shape = BoxShape3D.new()
	ws.shape.size = Vector3(40, 6, 0.5)
	wall.add_child(ws)
	wall.position = Vector3(0, 3, -4.25)  # front face at z = -4
	world.add_child(wall)

	for item_name in ITEMS:
		var w: StationeryWeapon = load("res://assets/stationery/scenes/%s.tscn" % item_name).instantiate()
		w.position = Vector3(0, 0.3, 0)
		world.add_child(w)
		await wait_frames(150)
		check(w.global_position.y > -0.01 and w.global_position.y < 0.06 and w.linear_velocity.length() < 0.05,
				"%s lands and rests on the floor (y=%.3f)" % [item_name, w.global_position.y])

		var holder := PropHolder.new()
		world.add_child(holder)
		holder.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.0, 0.6))
		check(holder.try_grab(), "%s grab requested" % item_name)
		await wait_frames(3)
		check(w.is_held(), "%s is held" % item_name)

		# Melee: target 0.6 m in front of the hand.
		var target := make_target(Vector3(0, 0.9, 0.6 - 0.6))
		world.add_child(target)
		await wait_frames(2)
		holder.attack()
		holder.attack()  # second one is inside the cooldown
		await wait_frames(3)
		var kind := "stab" if w.attack_style == StationeryWeapon.AttackStyle.STAB else "swing"
		check(target.hits.size() == 1 and target.hits[0].kind == kind and target.hits[0].damage == w.melee_damage
				and target.hits[0].attacker == 1,
				"%s %s hits once for %s damage (%s)" % [item_name, kind, w.melee_damage, target.hits])
		await wait_frames(int(w.attack_cooldown * 60) + 2)
		holder.attack()
		await wait_frames(3)
		check(target.hits.size() == 2, "%s can attack again after the cooldown" % item_name)
		target.queue_free()
		await wait_frames(2)

		# Throw at the wall.
		var wall_hits := []
		w.weapon_hit.connect(func(body, dmg, attacker, k): wall_hits.append([body, dmg, attacker, k]))
		holder.throw()
		await wait_frames(90)
		var on_wall := wall_hits.filter(func(h): return h[0] == wall)
		check(on_wall.size() > 0 and on_wall[0][1] > 0 and on_wall[0][3] == "throw",
				"%s thrown into the wall deals %s damage" % [item_name, "%.1f" % on_wall[0][1] if on_wall.size() else "no"])
		if w.pointy:
			check(w.is_stuck() and w.freeze and abs(w.global_position.z + 4.0) < 0.25,
					"%s sticks into the wall (z=%.2f)" % [item_name, w.global_position.z])
			# Pull it back out.
			holder.global_position = w.global_position + Vector3(0, 0, 0.8)
			await wait_frames(1)
			check(holder.try_grab(), "%s stuck item can be grabbed back" % item_name)
			await wait_frames(3)
			check(w.is_held() and not w.is_stuck(), "%s pulled out of the wall" % item_name)
		else:
			check(not w.is_stuck(), "%s bounces off (blunt items don't stick)" % item_name)
			holder.global_position = w.global_position + Vector3(0, 0.8, 0.3)
			await wait_frames(1)
			holder.try_grab()
			await wait_frames(3)
			check(w.is_held(), "%s picked up again" % item_name)

		# Throw at a person.
		holder.global_transform = Transform3D(Basis.IDENTITY, Vector3(3, 1.0, 0))
		await wait_frames(2)
		var victim := make_target(Vector3(3, 0.91, -2.0))
		world.add_child(victim)
		await wait_frames(1)
		holder.throw()
		await wait_frames(60)
		var thrown_hits: Array = victim.hits.filter(func(h): return h.kind == "throw")
		check(thrown_hits.size() > 0 and thrown_hits[0].damage > 3.0,
				"%s thrown at a player deals %s damage" % [item_name, "%.1f" % thrown_hits[0].damage if thrown_hits.size() else "no"])
		victim.queue_free()
		holder.queue_free()
		w.queue_free()
		await wait_frames(2)

	# Grab choice: the hands should pick the thing they're obviously at.
	var desk: Node3D = load("res://assets/classroom_furniture/scenes/school_desk.tscn").instantiate()
	desk.position = Vector3(10, 0, 0)
	world.add_child(desk)
	var chair: Node3D = load("res://assets/classroom_furniture/scenes/school_chair.tscn").instantiate()
	chair.position = Vector3(10, 0, 0.55)
	chair.rotation_degrees.y = 180
	world.add_child(chair)
	var pencil: StationeryWeapon = load("res://assets/stationery/scenes/pencil.tscn").instantiate()
	pencil.position = Vector3(10.05, 0.79, 0.0)
	world.add_child(pencil)
	var compass: StationeryWeapon = load("res://assets/stationery/scenes/compass.tscn").instantiate()
	compass.position = Vector3(10.05, 0.79, -0.15)
	world.add_child(compass)
	await wait_frames(90)
	var picker := PropHolder.new()
	world.add_child(picker)
	picker.global_position = pencil.global_position + Vector3(0, 0.4, 0.3)
	await wait_frames(1)
	check(picker.find_grab_target() == pencil, "hands over a desk pick the pencil on it, not the desk")
	picker.global_position = chair.global_position + Vector3(-0.6, 1.1, 0.2)
	await wait_frames(1)
	check(picker.find_grab_target() == chair, "hands beside a chair pick the chair, not the compass on the desk")

	print("RESULT: %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)
