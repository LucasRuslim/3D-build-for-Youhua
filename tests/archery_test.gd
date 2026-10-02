extends SceneTree
## Offline checks for the bow and arrows:
##   godot --headless --path . --script res://tests/archery_test.gd

const DummyTarget := preload("res://tests/dummy_target.gd")
const BOW := preload("res://assets/archery/scenes/bow.tscn")
const ARROW := preload("res://assets/archery/scenes/arrow.tscn")

var failures := 0
var world: Node3D
var wall: StaticBody3D


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


func _initialize() -> void:
	world = Node3D.new()
	root.add_child(world)
	var floor := StaticBody3D.new()
	var fs := CollisionShape3D.new()
	fs.shape = BoxShape3D.new()
	fs.shape.size = Vector3(60, 1, 60)
	fs.position.y = -0.5
	floor.add_child(fs)
	world.add_child(floor)
	wall = StaticBody3D.new()
	var ws := CollisionShape3D.new()
	ws.shape = BoxShape3D.new()
	ws.shape.size = Vector3(60, 8, 0.5)
	wall.add_child(ws)
	wall.position = Vector3(0, 4, -12.25)  # front face at z = -12
	world.add_child(wall)

	# Bow and 4 arrows lying on the floor.
	var bow: Bow = BOW.instantiate()
	bow.position = Vector3(0, 0.05, 0)
	bow.rotation_degrees = Vector3(0, 0, 90)
	world.add_child(bow)
	var arrows: Array[Arrow] = []
	for i in 4:
		var a: Arrow = ARROW.instantiate()
		a.position = Vector3(0.3 + i * 0.06, 0.05, 0.8)
		world.add_child(a)
		arrows.append(a)
	await wait_frames(150)
	check(bow.global_position.y > -0.01 and bow.global_position.y < 0.08 and bow.linear_velocity.length() < 0.05,
			"bow rests on the floor (y=%.3f)" % bow.global_position.y)
	check(arrows.all(func(a): return a.global_position.y > -0.01 and a.global_position.y < 0.05),
			"arrows rest on the floor")

	var hands := PropHolder.new()
	world.add_child(hands)
	hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.1, 0.4))
	check(hands.try_grab(), "bow grab requested")
	await wait_frames(3)
	check(bow.is_held(), "bow is held")

	# Load three arrows by "grabbing" them with the bow in hand.
	for i in 3:
		check(hands.try_grab(), "arrow %d collected into the bow" % (i + 1))
		await wait_frames(3)
	check(bow.arrow_count == 3, "bow carries 3 arrows (%d)" % bow.arrow_count)
	var nocked := arrows.filter(func(a): return a.bow_state == Arrow.BowState.NOCKED)
	var stowed := arrows.filter(func(a): return a.bow_state == Arrow.BowState.STOWED)
	check(nocked.size() == 1 and stowed.size() == 2, "1 arrow on the string, 2 stowed")
	check(nocked[0].visible and stowed.all(func(a): return not a.visible), "only the nocked arrow is visible")
	check(nocked[0].is_held() and nocked[0].collision_layer == 0, "loaded arrows can't be grabbed and don't collide")
	var other := PropHolder.new()
	world.add_child(other)
	other.global_transform = Transform3D(Basis.IDENTITY, nocked[0].global_position + Vector3(0, 0.2, 0))
	var t := other.find_grab_target()
	check(not (t is Arrow and t.bow_state != Arrow.BowState.FREE), "another player can't take arrows out of the bow")
	other.queue_free()
	var loose: Arrow = arrows.filter(func(a): return a.bow_state == Arrow.BowState.FREE)[0]

	# Full draw at the wall.
	hands.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, 0))
	await wait_frames(2)
	var shots := []
	bow.shot.connect(func(a, peer, speed): shots.append([a, peer, speed]))
	var first: Arrow = nocked[0]
	var wall_hits := []
	first.weapon_hit.connect(func(body, dmg, attacker, kind): wall_hits.append([body, dmg, attacker, kind]))
	hands.attack()
	await wait_frames(50)  # ~0.83 s, past the 0.7 s full draw
	check(bow.draw_amount > 0.99, "string drawn back fully (%.2f)" % bow.draw_amount)
	hands.attack_release()
	await wait_frames(2)
	check(shots.size() == 1 and shots[0][0] == first and absf(shots[0][2] - bow.shoot_speed) < 0.5,
			"full draw shoots at %.1f m/s" % (shots[0][2] if shots.size() else 0.0))
	check(bow.arrow_count == 2 and stowed.any(func(a): return a.bow_state == Arrow.BowState.NOCKED),
			"next arrow moves onto the string (%d left)" % bow.arrow_count)
	await wait_frames(60)
	check(first.is_stuck() and absf(first.global_position.z + 12.0) < 0.4,
			"arrow flies 12 m and sticks into the wall (z=%.2f)" % first.global_position.z)
	check(first.tip_direction().dot(Vector3.FORWARD) > 0.95, "arrow sticks tip-first, pointing where it was shot")
	var wh := wall_hits.filter(func(h): return h[0] == wall)
	check(wh.size() > 0 and wh[0][3] == "shot" and wh[0][2] == 1 and wh[0][1] > 40.0,
			"wall hit is a 'shot' by peer 1 for %s damage" % ("%.1f" % wh[0][1] if wh.size() else "no"))

	# Quick tap at a player: weak shot, still hits.
	var target := make_target(Vector3(0, 0.9, -4.0))
	await wait_frames(2)
	hands.attack()
	await wait_frames(1)
	hands.attack_release()
	await wait_frames(2)
	check(shots.size() == 2 and shots[1][2] < bow.shoot_speed * 0.4,
			"quick tap shoots weakly (%.1f m/s)" % (shots[1][2] if shots.size() > 1 else 0.0))
	await wait_frames(60)
	var sh: Array = target.hits.filter(func(h): return h.kind == "shot")
	check(sh.size() == 1 and sh[0].attacker == 1 and sh[0].damage > 10.0,
			"arrow hits the player: %s" % [target.hits])
	target.queue_free()

	# Collect a stuck arrow back from the wall.
	hands.global_transform = Transform3D(Basis.IDENTITY, first.global_position + Vector3(0, 0, 1.2))
	await wait_frames(2)
	check(hands.try_grab() and await _wait_true(func(): return first.bow_state != Arrow.BowState.FREE),
			"stuck arrow collected back into the bow")
	check(not first.is_stuck() and bow.arrow_count == 2, "bow carries %d arrows again" % bow.arrow_count)

	# Dropping the bow spills its arrows.
	hands.drop()
	await wait_frames(90)
	check(bow.arrow_count == 0 and arrows.all(func(a): return a.bow_state == Arrow.BowState.FREE and a.visible),
			"dropping the bow spills its arrows")

	# Empty bow: attack is a melee swing.
	hands.global_transform = Transform3D(Basis.IDENTITY, bow.global_position + Vector3(0, 0.8, 0.3))
	await wait_frames(2)
	for a in arrows:  # move the loose arrows out of reach
		a.global_position += Vector3(8, 0, 0)
	await wait_frames(2)
	hands.try_grab()
	await wait_frames(3)
	check(bow.is_held() and bow.arrow_count == 0, "bow picked up again, empty")
	var dummy := make_target(hands.global_position + Vector3(0, -0.2, -0.6))
	await wait_frames(2)
	hands.attack()
	await wait_frames(3)
	check(dummy.hits.size() == 1 and dummy.hits[0].kind == "swing" and dummy.hits[0].damage == bow.melee_damage,
			"empty bow swings as a club: %s" % [dummy.hits])
	dummy.queue_free()
	hands.drop()
	await wait_frames(30)

	# An arrow on its own: stab and throw by hand.
	hands.global_transform = Transform3D(Basis.IDENTITY, loose.global_position + Vector3(0, 0.8, 0.3))
	await wait_frames(2)
	hands.try_grab()
	await wait_frames(3)
	check(loose.is_held() and loose.holder_peer_id == 1, "an arrow can be picked up by hand")
	dummy = make_target(hands.global_position + Vector3(0, -0.2, -0.6))
	await wait_frames(2)
	hands.attack()
	await wait_frames(3)
	check(dummy.hits.size() == 1 and dummy.hits[0].kind == "stab" and dummy.hits[0].damage == loose.melee_damage,
			"hand-held arrow stabs: %s" % [dummy.hits])
	dummy.queue_free()

	print("RESULT: %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)


func _wait_true(cond: Callable, frames := 10) -> bool:
	for i in frames:
		if cond.call():
			return true
		await physics_frame
	return cond.call()
