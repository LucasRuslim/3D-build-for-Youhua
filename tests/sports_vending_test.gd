extends SceneTree
## Offline checks for the sports items, the vending machine and the drinks:
##   godot --headless --path . --script res://tests/sports_vending_test.gd

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


func spawn(path: String, pos: Vector3, rot_y_deg := 0.0) -> Node3D:
	var n: Node3D = load(path).instantiate()
	n.position = pos
	n.rotation_degrees.y = rot_y_deg
	world.add_child(n)
	return n


## A character with StatusEffects (records hits, knockbacks, heals).
func make_person(pos: Vector3) -> CharacterBody3D:
	var t: CharacterBody3D = DummyTarget.new()
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	cs.shape.radius = 0.3
	cs.shape.height = 1.8
	t.add_child(cs)
	var se := StatusEffects.new()
	se.name = "StatusEffects"
	t.add_child(se)
	t.set_meta("heals", [])
	se.healed.connect(func(a, src): t.get_meta("heals").append(a))
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


func hands_at(pos: Vector3, look := Vector3.FORWARD) -> PropHolder:
	var h := PropHolder.new()
	world.add_child(h)
	h.global_transform = Transform3D(Basis.looking_at(look, Vector3.UP if absf(look.y) < 0.99 else Vector3.BACK), pos)
	return h


func grab(h: PropHolder, item: NetworkedProp) -> bool:
	var keep := h.global_transform
	h.global_position = item.global_position + Vector3(0, 0.5, 0.25)
	await wait_frames(1)
	h.try_grab()
	await wait_frames(3)
	h.global_transform = keep
	await wait_frames(2)
	return item.is_held()


func _initialize() -> void:
	world = Node3D.new()
	root.add_child(world)
	make_static_box(Vector3(0, -0.5, 0), Vector3(120, 1, 120))

	# --- Everything rests on the floor and can be picked up --------------
	var scenes := ["res://assets/sports/scenes/ping_pong_paddle.tscn", "res://assets/sports/scenes/badminton_racket.tscn",
			"res://assets/sports/scenes/shuttlecock.tscn", "res://assets/sports/scenes/ping_pong_ball.tscn",
			"res://assets/sports/scenes/ball_bucket.tscn"]
	for d in ["water_bottle_plastic", "potion_health", "potion_speed", "potion_strength", "potion_shield",
			"potion_sleep", "potion_jump"]:
		scenes.append("res://assets/vending/scenes/%s.tscn" % d)
	var items := []
	for i in scenes.size():
		items.append(spawn(scenes[i], Vector3(-20 + i * 2.0, 0.6, -20)))
	await wait_frames(180)
	for i in scenes.size():
		var it: NetworkedProp = items[i]
		var rest_y := it.global_position.y
		var max_speed := 0.5 if it is PingPongBall else 0.05  # a bouncy ball may still be rolling
		var resting := it.linear_velocity.length() < max_speed and rest_y > -0.01 and rest_y < 0.5
		var h := hands_at(Vector3(-20 + i * 2.0, 1.0, -19.5))
		var ok := await grab(h, it)
		check(resting and ok, "%s rests (y=%.2f) and can be picked up" % [scenes[i].get_file().get_basename(), rest_y])
		h.drop()
		await wait_frames(2)
		h.queue_free()
		it.queue_free()

	await _test_paddle_and_ball()
	await _test_racket_and_shuttle()
	await _test_bucket()
	await _test_vending()
	await _test_drinking()
	await _test_splashes()

	print("RESULT: %s (%d failures)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)


func _test_paddle_and_ball() -> void:
	var paddle: StationeryWeapon = spawn("res://assets/sports/scenes/ping_pong_paddle.tscn", Vector3(0, 0.1, 0))
	var ball: PingPongBall = spawn("res://assets/sports/scenes/ping_pong_ball.tscn", Vector3(0, 1.0, -0.6))
	var target := make_person(Vector3(0, 0.92, -6))
	var h := hands_at(Vector3(0, 1.2, 0))
	await wait_frames(30)
	check(await grab(h, paddle), "paddle picked up")
	ball.global_position = Vector3(0, 1.0, -0.6)
	ball.linear_velocity = Vector3.ZERO
	await wait_frames(1)
	var batted := []
	paddle.batted.connect(func(p, peer): batted.append(p))
	h.attack()
	await wait_frames(2)
	check(batted.has(ball) and ball.linear_velocity.length() > 12.0 and ball.linear_velocity.normalized().dot(Vector3.FORWARD) > 0.9,
			"paddle bats the ball forward at %.1f m/s" % ball.linear_velocity.length())
	await wait_frames(40)
	check(target.hits.any(func(x): return x.weapon == ball.name and x.attacker == 1),
			"batted ball hits a player, credited to the batter (%s)" % [target.hits])
	# Bounce: drop the ball from 1.5 m.
	ball.global_transform = Transform3D(Basis.IDENTITY, Vector3(5, 1.5, 5))
	ball.linear_velocity = Vector3.ZERO
	ball.sleeping = false  # it came to rest after the hit; wake it up
	await wait_frames(25)
	var peak := 0.0
	for i in 50:
		await physics_frame
		if ball.linear_velocity.y > 0:
			peak = maxf(peak, ball.global_position.y)
	check(peak > 0.7, "ping pong ball bounces back to %.2f m from 1.5 m" % peak)
	for n in [paddle, ball, target, h]:
		n.queue_free()
	await wait_frames(2)


func _test_racket_and_shuttle() -> void:
	var racket: StationeryWeapon = spawn("res://assets/sports/scenes/badminton_racket.tscn", Vector3(0, 0.1, 0))
	var shuttle: StationeryWeapon = spawn("res://assets/sports/scenes/shuttlecock.tscn", Vector3(0, 1.1, -0.7))
	var h := hands_at(Vector3(0, 1.2, 0))
	await wait_frames(30)
	check(await grab(h, racket), "racket picked up")
	shuttle.global_transform = Transform3D(Basis(Vector3.UP, 1.3), Vector3(0, 1.1, -0.7))  # nose pointing sideways
	shuttle.linear_velocity = Vector3.ZERO
	await wait_frames(1)
	h.attack()
	await wait_frames(2)
	var v0 := shuttle.linear_velocity.length()
	check(v0 > 20.0, "racket smashes the shuttlecock at %.1f m/s" % v0)
	await wait_frames(20)
	check(shuttle.tip_direction().dot(shuttle.linear_velocity.normalized()) > 0.8,
			"shuttlecock turns to fly nose-first")
	check(shuttle.linear_velocity.length() < v0 * 0.7, "shuttlecock slows down from drag (%.1f m/s)" % shuttle.linear_velocity.length())
	for n in [racket, shuttle, h]:
		n.queue_free()
	await wait_frames(2)


func _test_bucket() -> void:
	var bucket: BallBucket = spawn("res://assets/sports/scenes/ball_bucket.tscn", Vector3(0, 0.4, 0))
	var front := make_person(Vector3(0, 0.92, -3.0))
	var side := make_person(Vector3(3.0, 0.92, -1.0))
	make_static_box(Vector3(-2.0, 1, -1.8), Vector3(0.2, 3, 2.0))
	var hidden := make_person(Vector3(-3.5, 0.92, -2.8))
	var h := hands_at(Vector3(0, 1.2, 0))
	await wait_frames(60)
	check(await grab(h, bucket), "ball bucket picked up")
	var balls0 := bucket.balls
	h.attack()
	await wait_frames(3)
	var fse: StatusEffects = StatusEffects.find_on(front)
	check(fse.is_active(&"sleep") and front.hits.any(func(x): return x.kind == "volley"),
			"volley puts the player in front to sleep (%s)" % [fse.active_effects])
	check(not StatusEffects.find_on(side).is_active(&"sleep"), "player outside the cone stays awake")
	check(bucket.balls == balls0 - bucket.balls_per_volley, "volley uses %d balls (%d left)" % [bucket.balls_per_volley, bucket.balls])
	h.attack()
	await wait_frames(2)
	check(bucket.balls == balls0 - bucket.balls_per_volley, "volley has a cooldown")
	await wait_frames(int(bucket.volley_cooldown * 60) + 2)
	h.global_transform = Transform3D(Basis.looking_at((hidden.global_position - Vector3(0, 1.2, 0)) * Vector3(1, 0, 1)), Vector3(0, 1.2, 0))
	await wait_frames(2)
	h.attack()
	await wait_frames(3)
	check(not StatusEffects.find_on(hidden).is_active(&"sleep"), "volley doesn't go through walls")
	await wait_frames(int(2.6 * 60))
	check(not fse.is_active(&"sleep"), "sleep wears off after %.1f s" % bucket.sleep_duration)
	# Collect a loose ball into the bucket.
	var ball: PingPongBall = spawn("res://assets/sports/scenes/ping_pong_ball.tscn", Vector3(1.0, 0.3, 0.5))
	await wait_frames(40)
	h.global_position = ball.global_position + Vector3(0, 0.5, 0.2)
	await wait_frames(1)
	var before := bucket.balls
	h.try_grab()
	await wait_frames(3)
	check(bucket.balls == before + 1 and ball.absorbed and not ball.visible and bucket.is_held(),
			"grabbing a loose ball loads it into the bucket (%d balls)" % bucket.balls)
	# Too few balls: swing instead.
	bucket.balls = 2
	h.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))
	var close := make_person(Vector3(0, 0.92, -0.7))
	await wait_frames(int(bucket.attack_cooldown * 60) + 2)
	h.attack()
	await wait_frames(3)
	check(close.hits.size() == 1 and close.hits[0].kind == "swing" and not StatusEffects.find_on(close).is_active(&"sleep"),
			"nearly empty bucket swings instead (%s)" % [close.hits])
	for n in [bucket, front, side, hidden, h, ball, close]:
		n.queue_free()
	await wait_frames(2)


func _test_vending() -> void:
	var machine: VendingMachine = spawn("res://assets/vending/scenes/vending_machine.tscn", Vector3(10, 0, 0))
	await wait_frames(5)
	var h := hands_at(machine.to_global(Vector3(0.1, 1.1, 1.0)))
	var vended := []
	machine.vended.connect(func(peer, item): vended.append(item))
	var stock0 := machine.stock
	check(h.use(), "hands can use the vending machine")
	await wait_frames(3)
	var dispensed: Node = machine.get_node("Dispensed")
	check(vended.size() == 1 and dispensed.get_child_count() == 1 and vended[0] is Drink and machine.stock == stock0 - 1,
			"machine drops a drink (%s), stock %d" % [vended[0].name if vended.size() else "none", machine.stock])
	h.use()
	await wait_frames(3)
	check(vended.size() == 1, "each player has a cooldown")
	await wait_frames(30)
	var d: Node3D = vended[0]
	var local := machine.to_local(d.global_position)
	check(local.z > 0.35 and absf(local.x) < 0.5 and d.global_position.y < 0.3,
			"the drink lands in front of the machine (local %s)" % local.snappedf(0.01))
	await wait_frames(int(machine.cooldown_per_player * 60))
	machine.request_use(0)  # choose a product: 0 = water
	await wait_frames(3)
	check(vended.size() == 2 and vended[1].name.begins_with("PlasticWaterBottle"), "a chosen product can be bought")
	machine.stock = 0
	await wait_frames(int(machine.cooldown_per_player * 60) + 2)
	var sold_out := []
	machine.sold_out.connect(func(): sold_out.append(true))
	h.use()
	await wait_frames(3)
	check(vended.size() == 2 and sold_out.size() == 1, "an empty machine sells nothing")
	machine.queue_free()
	h.queue_free()
	await wait_frames(2)


func _test_drinking() -> void:
	var person := make_person(Vector3(20, 0.92, 0))
	var h := PropHolder.new()
	person.add_child(h)
	h.position = Vector3(0, 0.3, -0.4)
	var se: StatusEffects = StatusEffects.find_on(person)
	var potion: Drink = spawn("res://assets/vending/scenes/potion_health.tscn", Vector3(20, 0.2, -0.6))
	await wait_frames(40)
	h.try_grab()
	await wait_frames(3)
	check(potion.is_held(), "health potion picked up")
	var drunk := []
	potion.drunk.connect(func(peer, e): drunk.append(peer))
	h.attack()
	await wait_frames(int(potion.drink_time * 60) + 4)
	check(drunk.size() == 1 and person.get_meta("heals") == [50.0] and not potion.full,
			"drinking the health potion heals 50 and empties it (%s)" % [person.get_meta("heals")])
	var victim := make_person(Vector3(20, 0.92, -1.2))
	await wait_frames(int(potion.attack_cooldown * 60) + 2)
	h.attack()
	await wait_frames(3)
	check(victim.hits.size() == 1 and victim.hits[0].kind == "swing", "an empty bottle is just a club")
	victim.queue_free()
	h.drop()
	await wait_frames(20)
	potion.queue_free()
	var speed: Drink = spawn("res://assets/vending/scenes/potion_speed.tscn", Vector3(20, 0.2, -0.6))
	await wait_frames(40)
	h.try_grab()
	await wait_frames(3)
	h.attack()
	await wait_frames(int(speed.drink_time * 60) + 4)
	check(se.is_active(&"speed") and is_equal_approx(se.strength_of(&"speed"), 1.6),
			"speed potion gives speed x1.6 (%s)" % [se.active_effects])
	h.drop()
	await wait_frames(5)
	speed.queue_free()
	person.queue_free()
	await wait_frames(2)


func _test_splashes() -> void:
	# Water: thrown at the floor, it leaves a slippery puddle.
	var water: Drink = spawn("res://assets/vending/scenes/water_bottle_plastic.tscn", Vector3(30, 0.2, 0))
	var h := hands_at(Vector3(30, 1.4, 0.3))
	await wait_frames(40)
	check(await grab(h, water), "water bottle picked up")
	h.global_transform = Transform3D(Basis.looking_at(Vector3(0, -0.6, -1).normalized()), Vector3(30, 1.4, 0.3))
	await wait_frames(2)
	var splashed := []
	water.splashed.connect(func(p): splashed.append(p))
	h.throw()
	await wait_frames(40)
	var puddles := world.find_children("*", "WaterPuddle", true, false)
	check(splashed.size() == 1 and not water.full and puddles.size() == 1,
			"thrown water bottle splashes and leaves a puddle (%d)" % puddles.size())
	if puddles.size() == 1:
		var walker := make_person(puddles[0].global_position + Vector3(0, 0.92, 0))
		await wait_frames(20)
		check(StatusEffects.find_on(walker).is_active(&"slip"), "standing in the puddle makes a player slip")
		walker.global_position += Vector3(4, 0, 0)
		await wait_frames(int(1.5 * 60))
		check(not StatusEffects.find_on(walker).is_active(&"slip"), "slipping stops after leaving the puddle")
		walker.queue_free()
	h.queue_free()
	# Sleep potion splash: everyone near the impact falls asleep.
	var a := make_person(Vector3(40, 0.92, -3.0))
	var b := make_person(Vector3(41.2, 0.92, -3.4))
	var far := make_person(Vector3(46, 0.92, -3.0))
	var sleep: Drink = spawn("res://assets/vending/scenes/potion_sleep.tscn", Vector3(40, 0.2, 0.5))
	var h2 := hands_at(Vector3(40, 1.4, 0.8))
	await wait_frames(40)
	check(await grab(h2, sleep), "sleep potion picked up")
	h2.throw()
	await wait_frames(40)
	check(StatusEffects.find_on(a).is_active(&"sleep") and StatusEffects.find_on(b).is_active(&"sleep")
			and not StatusEffects.find_on(far).is_active(&"sleep"), "sleep potion splash puts everyone nearby to sleep")
	# Health potion splash heals nearby players.
	var heal: Drink = spawn("res://assets/vending/scenes/potion_health.tscn", Vector3(40, 0.2, 0.5))
	await wait_frames(40)
	check(await grab(h2, heal), "health potion picked up")
	h2.throw()
	await wait_frames(40)
	check(a.get_meta("heals").has(25.0), "health potion splash heals players nearby (%s)" % [a.get_meta("heals")])
