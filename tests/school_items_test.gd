extends SceneTree
## Offline checks for the everyday school-item weapons:
##   godot --headless --path . --script res://tests/school_items_test.gd

const ITEMS := ["fire_extinguisher", "broom", "umbrella", "textbook", "backpack", "water_bottle", "basketball",
		"trash_bin", "board_eraser", "lunch_tray"]
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


func make_target(pos: Vector3) -> CharacterBody3D:
	var t: CharacterBody3D = DummyTarget.new()
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	cs.shape.radius = 0.3
	cs.shape.height = 1.8
	t.add_child(cs)
	t.position = pos
	world.add_child(t)
	return t


func make_static_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	cs.shape.size = size
	b.add_child(cs)
	b.position = pos
	world.add_child(b)
	return b


func _initialize() -> void:
	world = Node3D.new()
	root.add_child(world)
	make_static_box(Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	var wall := make_static_box(Vector3(0, 3, -6.25), Vector3(80, 6, 0.5))  # face at z = -6

	for item_name in ITEMS:
		var w: StationeryWeapon = load("res://assets/school_items/scenes/%s.tscn" % item_name).instantiate()
		w.position = Vector3(0, 0.8, 0)
		world.add_child(w)
		await wait_frames(180)
		var low := w.global_position.y - _bottom_offset(w)
		check(low > -0.02 and w.linear_velocity.length() < 0.05,
				"%s lands and rests on the floor (bottom at y=%.3f)" % [item_name, low])

		var hands := PropHolder.new()
		world.add_child(hands)
		hands.global_transform = Transform3D(Basis.IDENTITY, w.global_position + Vector3(0, 0.9, 0.5))
		await wait_frames(1)
		hands.try_grab()
		await wait_frames(3)
		check(w.is_held(), "%s can be picked up" % item_name)
		hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
		await wait_frames(2)

		if w is FireExtinguisher:
			await _test_extinguisher(w, hands, wall)
		else:
			var target := make_target(Vector3(0, 1.0, -0.6))
			await wait_frames(2)
			hands.attack()
			await wait_frames(3)
			var kind := "stab" if w.attack_style == StationeryWeapon.AttackStyle.STAB else "swing"
			check(target.hits.size() == 1 and target.hits[0].kind == kind and target.hits[0].damage == w.melee_damage,
					"%s %s hits for %s (%s)" % [item_name, kind, w.melee_damage, target.hits])
			if w.melee_knockback > 0.0:
				check(target.knockbacks.size() == 1 and target.knockbacks[0].length() > w.melee_knockback * 0.9,
						"%s knocks the target back (%s)" % [item_name, target.knockbacks])
			target.queue_free()
			await wait_frames(2)

		# Throw at a character 3 m ahead.
		hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(4, 1.2, 0))
		await wait_frames(int(w.attack_cooldown * 60) + 2)
		var victim := make_target(Vector3(4, 0.92, -3))
		await wait_frames(1)
		var spin_axis_ok := true
		hands.throw()
		await wait_frames(2)
		if w.flat_spin:
			spin_axis_ok = absf(w.angular_velocity.normalized().dot(w.global_basis.y)) > 0.95
			check(spin_axis_ok, "%s spins flat like a frisbee" % item_name)
		await wait_frames(60)
		var th: Array = victim.hits.filter(func(h): return h.kind == "throw")
		check(th.size() > 0 and th[0].damage > 3.0,
				"%s thrown at a player deals %s damage" % [item_name, "%.1f" % th[0].damage if th.size() else "no"])
		victim.queue_free()

		if item_name == "basketball":
			# Drop it from 2 m: it should bounce back up a good way.
			w.global_transform = Transform3D(Basis.IDENTITY, Vector3(-4, 2.0, 0))
			w.linear_velocity = Vector3.ZERO
			w.angular_velocity = Vector3.ZERO
			await wait_frames(30)
			var peak := 0.0
			for i in 60:
				await physics_frame
				if w.linear_velocity.y > 0:
					peak = maxf(peak, w.global_position.y)
			check(peak > 0.9, "basketball bounces back up to %.2f m" % peak)

		hands.queue_free()
		w.queue_free()
		await wait_frames(2)

	print("RESULT: %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)


func _test_extinguisher(ext: FireExtinguisher, hands: PropHolder, wall: StaticBody3D) -> void:
	# Spray: a target 2.5 m ahead gets foamed, one off to the side doesn't,
	# and one behind a wall doesn't.
	var front := make_target(Vector3(0, 1.0, -2.5))
	var side := make_target(Vector3(3.0, 1.0, -1.0))
	var screen := make_static_box(Vector3(1.5, 1.0, 0.0), Vector3(0.2, 3, 2.0))  # between us and `hidden`
	var hidden := make_target(Vector3(3.0, 1.0, 0.0))
	var crate: RigidBody3D = load("res://assets/classroom_furniture/scenes/school_chair.tscn").instantiate()
	crate.position = Vector3(0.6, 0.0, -3.5)  # low objects need some distance to be in the cone
	world.add_child(crate)
	await wait_frames(30)
	var crate_start := crate.global_position
	var charge0 := ext.spray_charge
	hands.attack()
	await wait_frames(60)  # spray 1 s straight ahead
	check(ext.spraying, "extinguisher is spraying while attack is held")
	# Turn towards the hidden target (behind the screen) and keep spraying.
	hands.global_transform = Transform3D(Basis.looking_at(Vector3.RIGHT), Vector3(0, 1.2, 0))
	await wait_frames(30)
	hands.attack_release()
	await wait_frames(2)
	check(not ext.spraying, "releasing attack stops the spray")
	var dmg: float = front.hits.reduce(func(a, h): return a + h.damage, 0.0)
	check(front.hits.size() >= 8 and front.hits.all(func(h): return h.kind == "spray" and h.attacker == 1),
			"spray hits the target in front repeatedly (%d hits, %.1f damage)" % [front.hits.size(), dmg])
	check(front.knockbacks.size() >= 8 and front.knockbacks[0].normalized().dot(Vector3.FORWARD) > 0.9,
			"spray pushes the target away")
	check(side.hits.is_empty(), "target outside the spray cone isn't hit")
	check(hidden.hits.is_empty(), "spray doesn't go through walls")
	check(crate.global_position.distance_to(crate_start) > 0.3,
			"spray shoves a chair %.2f m" % crate.global_position.distance_to(crate_start))
	check(ext.spray_charge < charge0 - 0.15 and ext.spray_charge > 0.6,
			"foam is used up while spraying (%.2f left)" % ext.spray_charge)
	for n in [front, side, screen, hidden, crate]:
		n.queue_free()

	# Empty extinguisher swings instead.
	ext.spray_charge = 0.0
	hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	var t := make_target(Vector3(0, 1.0, -0.6))
	await wait_frames(3)
	hands.attack()
	await wait_frames(3)
	check(not ext.spraying and t.hits.size() == 1 and t.hits[0].kind == "swing" and t.hits[0].damage == ext.melee_damage,
			"empty extinguisher swings for %s (%s)" % [ext.melee_damage, t.hits])
	hands.attack_release()
	t.queue_free()

	# Thrown into a wall with foam left: bursts and knocks back bystanders.
	ext.refill()
	await wait_frames(int(ext.attack_cooldown * 60) + 2)
	hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -3.0))
	var bystander := make_target(Vector3(1.2, 1.0, -5.0))
	await wait_frames(3)
	var bursts := []
	ext.burst.connect(func(p): bursts.append(p))
	ext.throw_speed = 12.0
	hands.throw()
	await wait_frames(60)
	check(bursts.size() == 1, "extinguisher bursts when it slams into the wall (%d)" % bursts.size())
	check(bystander.hits.any(func(h): return h.kind == "burst") and not bystander.knockbacks.is_empty(),
			"burst hits and knocks back a bystander (%s)" % [bystander.hits])
	check(ext.spray_charge < 0.7, "burst uses foam (%.2f left)" % ext.spray_charge)
	bystander.queue_free()
	# Pick it back up for the common throw test.
	await wait_frames(60)
	hands.global_transform = Transform3D(Basis.IDENTITY, ext.global_position + Vector3(0, 0.9, 0.3))
	await wait_frames(1)
	hands.try_grab()
	await wait_frames(3)
	check(ext.is_held(), "extinguisher picked up again")


# Height of the origin above the lowest mesh vertex (exact, even when tilted).
func _bottom_offset(w: Node3D) -> float:
	var lo := INF
	for mi in w.find_children("*", "MeshInstance3D", true, false):
		if not mi.visible or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			for v in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				lo = minf(lo, (mi.global_transform * v).y)
	return w.global_position.y - lo
