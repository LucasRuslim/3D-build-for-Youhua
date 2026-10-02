extends SceneTree
## Two-process network check over ENet on localhost:
##   godot --headless --path . --script res://tests/net_test.gd -- server &
##   godot --headless --path . --script res://tests/net_test.gd -- client
## The client grabs Chair4 and throws it; both sides must see it fly.

const DummyTarget := preload("res://tests/dummy_target.gd")
const STAB_SPOT := Vector3(4.0, 1.1, 5.6)  # client's hand for the stationery part
const SPRAY_SPOT := Vector3(4.5, 1.2, -0.5)  # client's hand for the fire extinguisher part

var failures := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		failures += 1


func paint_marks(node: Node) -> int:
	return node.get_children().filter(func(c): return c.name.begins_with("PaintMark")).size()


func seconds(t: float) -> void:
	await create_timer(t).timeout


func _initialize() -> void:
	var role: String = OS.get_cmdline_user_args()[0]
	var demo = load("res://demo/props_demo.tscn").instantiate()
	root.add_child(demo)
	# A sleepy target that exists on both peers (same path), so its
	# StatusEffects sync from the host to the client.
	var sleeper: CharacterBody3D = DummyTarget.new()
	sleeper.name = "Sleeper"
	var scs := CollisionShape3D.new()
	scs.shape = CapsuleShape3D.new()
	scs.shape.radius = 0.3
	scs.shape.height = 1.8
	sleeper.add_child(scs)
	var sleeper_se := StatusEffects.new()
	sleeper_se.name = "StatusEffects"
	sleeper.add_child(sleeper_se)
	sleeper.position = Vector3(5.1, 0.92, 0.0)
	demo.add_child(sleeper)
	await process_frame
	var chair: NetworkedProp = demo.get_node("Props/Chair4")
	var start := chair.global_position

	if role == "server":
		check(demo.host() == OK, "server: hosting")
		# Spray paint on the front wall before anyone joins: a late joiner
		# must still see it.
		var can: SprayPaint = demo.get_node("Props/SprayPaint")
		var my_hand = demo.get_node("Hands/1")
		my_hand.follow_mouse = false
		my_hand.global_transform = Transform3D(Basis.IDENTITY, can.global_position + Vector3(0, 0.5, 0.3))
		for i in 3:
			await physics_frame
		my_hand.holder.try_grab()
		for i in 3:
			await physics_frame
		my_hand.global_transform = Transform3D(Basis.IDENTITY, Vector3(-1.2, 1.4, -5.0))
		for i in 3:
			await physics_frame
		my_hand.holder.attack()
		await seconds(0.5)
		my_hand.holder.attack_release()
		my_hand.holder.drop()
		var wall_n: Node = demo.get_node("WallN")
		var painted_before := paint_marks(wall_n)
		check(painted_before > 10, "server: painted the front wall before the client joined (%d marks)" % painted_before)
		# Host-only target for the client's pencil stab (damage is host-side).
		var dummy: CharacterBody3D = DummyTarget.new()
		var dcs := CollisionShape3D.new()
		dcs.shape = CapsuleShape3D.new()
		dcs.shape.radius = 0.3
		dcs.shape.height = 1.8
		dummy.add_child(dcs)
		dummy.position = STAB_SPOT + Vector3(0, -0.19, -0.6)
		demo.add_child(dummy)
		var foam_target: CharacterBody3D = DummyTarget.new()
		var fcs := CollisionShape3D.new()
		fcs.shape = dcs.shape
		foam_target.add_child(fcs)
		foam_target.position = SPRAY_SPOT + Vector3(0, -0.2, -2.0)
		demo.add_child(foam_target)
		var hits := []
		chair.hit.connect(func(body, speed, thrower): hits.append([body.name, speed, thrower]))
		var t := 0.0
		while t < 15.0 and root.multiplayer.get_peers().is_empty():
			await seconds(0.1)
			t += 0.1
		check(not root.multiplayer.get_peers().is_empty(), "server: client connected")
		var client_id: int = root.multiplayer.get_peers()[0] if not root.multiplayer.get_peers().is_empty() else 0
		var held_seen := false
		t = 0.0
		while t < 8.0:
			held_seen = held_seen or chair.holder_peer_id == client_id
			await seconds(0.05)
			t += 0.05
		check(held_seen, "server: client %d picked the chair up" % client_id)
		var moved := chair.global_position.distance_to(start)
		check(moved > 1.2, "server: chair flew %.2f m" % moved)
		check(hits.any(func(h): return h[2] == client_id), "server: hit credited to client (%s)" % [hits])
		# Stationery: the client stabs the dummy, then throws the pencil at the east wall.
		var pencil: StationeryWeapon = demo.get_node("Props/Pencil")
		t = 0.0
		while t < 15.0 and not (pencil.is_stuck() and dummy.hits.size() > 0):
			await seconds(0.1)
			t += 0.1
		var stabs: Array = dummy.hits.filter(func(h): return h.kind == "stab" and h.attacker == client_id)
		check(stabs.size() == 1 and stabs[0].damage == pencil.melee_damage,
				"server: client's pencil stab hit the dummy (%s)" % [dummy.hits])
		check(pencil.is_stuck() and absf(pencil.global_position.x - 6.85) < 0.3,
				"server: thrown pencil stuck in the east wall (x=%.2f)" % pencil.global_position.x)
		# Archery: the client loads Arrow0 into the bow and shoots the west wall.
		var arrow: Arrow = demo.get_node("Props/Arrow0")
		var arrow_hits := []
		arrow.weapon_hit.connect(func(body, dmg, attacker, kind): arrow_hits.append([body.name, dmg, attacker, kind]))
		t = 0.0
		while t < 15.0 and not arrow.is_stuck():
			await seconds(0.1)
			t += 0.1
		check(arrow.is_stuck() and absf(arrow.global_position.x + 6.5) < 0.4,
				"server: client's arrow stuck in the west wall (x=%.2f)" % arrow.global_position.x)
		check(arrow_hits.any(func(h): return h[3] == "shot" and h[2] == client_id and h[1] > 40.0),
				"server: arrow hit credited to the client as a shot (%s)" % [arrow_hits])
		# Fire extinguisher: the client sprays the foam target.
		t = 0.0
		while t < 15.0 and foam_target.hits.size() < 4:
			await seconds(0.1)
			t += 0.1
		await seconds(0.5)
		var foam: Array = foam_target.hits.filter(func(h): return h.kind == "spray" and h.attacker == client_id)
		check(foam.size() >= 4 and not foam_target.knockbacks.is_empty(),
				"server: client's foam hit the target %d times and pushed it back" % foam.size())
		# Vending machine: the client buys a drink and drinks it.
		var machine: VendingMachine = demo.get_node("VendingMachine")
		var bought := []
		var drank := []
		machine.vended.connect(func(peer, item):
			bought.append(peer)
			item.drunk.connect(func(p, e): drank.append(p)))
		t = 0.0
		while t < 20.0 and drank.is_empty():
			await seconds(0.1)
			t += 0.1
		check(bought == [client_id], "server: the client bought a drink (%s)" % [bought])
		check(drank == [client_id], "server: the client drank it (%s)" % [drank])
		# Ball bucket: the client's volley puts the shared Sleeper to sleep.
		t = 0.0
		while t < 15.0 and not sleeper_se.is_active(&"sleep"):
			await seconds(0.1)
			t += 0.1
		check(sleeper_se.is_active(&"sleep"), "server: the client's volley put the sleeper to sleep")
		# Spray paint: the client paints the front wall too.
		t = 0.0
		while t < 15.0 and paint_marks(wall_n) < painted_before + 10:
			await seconds(0.1)
			t += 0.1
		check(paint_marks(wall_n) >= painted_before + 10,
				"server: sees the client's paint on the wall (%d marks)" % paint_marks(wall_n))
		await seconds(1.0)
	else:
		check(demo.join("127.0.0.1") == OK, "client: joining")
		var t := 0.0
		while t < 10.0 and root.multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			await seconds(0.1)
			t += 0.1
		var me: int = root.multiplayer.get_unique_id()
		check(me > 1, "client: connected as peer %d" % me)
		t = 0.0
		while t < 5.0 and not demo.get_node("Hands").has_node(str(me)):
			await seconds(0.1)
			t += 0.1
		var hand = demo.get_node_or_null("Hands/%d" % me)
		check(hand != null, "client: host spawned my hand")
		check(demo.get_node("Hands").has_node("1"), "client: host's hand replicated")
		await seconds(2.0)  # paint from before we joined is replayed a moment after connecting
		var wall_n: Node = demo.get_node("WallN")
		var replayed := paint_marks(wall_n)
		check(replayed > 10, "client: sees paint sprayed before it joined (%d marks)" % replayed)
		check(chair.freeze, "client: remote chair is kinematic (host simulates)")
		# Run a local character into Chair0: the push goes to the host, which
		# moves the chair, and the move comes back to us.
		var chair0: NetworkedProp = demo.get_node("Props/Chair0")
		var c0_start := chair0.global_position
		var runner := CharacterBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = CapsuleShape3D.new()
		cs.shape.radius = 0.3
		cs.shape.height = 1.8
		runner.add_child(cs)
		runner.position = c0_start + Vector3(-1.2, 0.91, 0)  # set before adding: never overlaps
		demo.add_child(runner)
		for i in 60:
			runner.velocity = Vector3(5, 0, 0)
			var v := runner.velocity
			runner.move_and_slide()
			NetworkedProp.push_from_character(runner, v)
			await physics_frame
		runner.queue_free()
		await seconds(1.0)
		var shoved := chair0.global_position.distance_to(c0_start)
		check(shoved > 0.5, "client: running into Chair0 shoved it %.2f m (host-simulated)" % shoved)

		hand.follow_mouse = false
		# Face +X so the throw goes along the row, not into this chair's own desk.
		var face_x := Basis.looking_at(Vector3.RIGHT, Vector3.UP)
		hand.global_transform = Transform3D(face_x, start + Vector3(-0.6, 1.1, 0))
		await seconds(0.5)  # let the hand position reach the host
		check(hand.holder.try_grab(), "client: grab requested")
		await seconds(0.5)
		check(chair.holder_peer_id == me, "client: sees itself holding the chair")
		var held_pos := chair.global_position
		check(held_pos.y > 0.4, "client: chair lifted to the hand (y=%.2f)" % held_pos.y)
		hand.holder.throw()
		await seconds(2.0)
		check(chair.holder_peer_id == 0, "client: chair released")
		var moved := chair.global_position.distance_to(start)
		check(moved > 1.2, "client: replicated chair flew %.2f m" % moved)

		# Stationery over the network: grab the pencil off its desk, stab the
		# host's dummy, then throw it into the east wall.
		var pencil: StationeryWeapon = demo.get_node("Props/Pencil")
		hand.global_transform = Transform3D(Basis.IDENTITY, pencil.global_position + Vector3(0, 0.4, 0.3))
		await seconds(0.5)
		check(hand.holder.try_grab(), "client: pencil grab requested")
		await seconds(0.5)
		check(pencil.holder_peer_id == me, "client: holding the pencil")
		hand.global_transform = Transform3D(Basis.IDENTITY, STAB_SPOT)
		await seconds(0.6)
		hand.holder.attack()
		await seconds(0.6)
		hand.global_transform = Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), STAB_SPOT)
		await seconds(0.5)
		hand.holder.throw()
		await seconds(1.5)
		check(pencil.holder_peer_id == 0 and absf(pencil.global_position.x - 6.85) < 0.3,
				"client: sees the pencil stuck in the wall (x=%.2f)" % pencil.global_position.x)

		# Archery: pick up the bow, load an arrow, draw and shoot the west wall.
		var bow: Bow = demo.get_node("Props/Bow")
		var arrow: Arrow = demo.get_node("Props/Arrow0")
		hand.global_transform = Transform3D(Basis.IDENTITY, bow.global_position + Vector3(0, 0.5, 0.3))
		await seconds(0.5)
		check(hand.holder.try_grab(), "client: bow grab requested")
		await seconds(0.5)
		check(bow.holder_peer_id == me, "client: holding the bow")
		hand.global_transform = Transform3D(Basis.IDENTITY, arrow.global_position + Vector3(0.05, 0.5, 0.2))
		await seconds(0.5)
		check(hand.holder.try_grab(), "client: arrow collect requested")
		await seconds(0.5)
		check(bow.arrow_count == 1 and arrow.bow_state == Arrow.BowState.NOCKED,
				"client: sees the arrow loaded on the string")
		hand.global_transform = Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP), Vector3(-4.0, 1.3, 5.0))
		await seconds(0.5)
		hand.holder.attack()
		await seconds(0.5)
		check(bow.draw_amount > 0.3, "client: sees the string being drawn (%.2f)" % bow.draw_amount)
		await seconds(0.5)
		hand.holder.attack_release()
		await seconds(1.5)
		check(bow.arrow_count == 0 and arrow.bow_state == Arrow.BowState.FREE and absf(arrow.global_position.x + 6.5) < 0.4,
				"client: sees the arrow stuck in the west wall (x=%.2f)" % arrow.global_position.x)

		# Fire extinguisher: drop the bow, grab the extinguisher, spray the host's target.
		hand.holder.drop()
		await seconds(0.5)
		var ext: FireExtinguisher = demo.get_node("Props/FireExtinguisher2")
		hand.global_transform = Transform3D(Basis.IDENTITY, ext.global_position + Vector3(-0.3, 0.4, 0))
		await seconds(0.5)
		check(hand.holder.try_grab(), "client: extinguisher grab requested")
		await seconds(0.5)
		check(ext.holder_peer_id == me, "client: holding the extinguisher")
		hand.global_transform = Transform3D(Basis.IDENTITY, SPRAY_SPOT)
		await seconds(0.6)
		hand.holder.attack()
		await seconds(0.8)
		check(ext.spraying, "client: sees the extinguisher spraying")
		hand.holder.attack_release()
		await seconds(0.5)
		check(not ext.spraying and ext.spray_charge < 0.95,
				"client: spray stopped, foam left %.2f" % ext.spray_charge)

		# Vending machine: buy a drink, pick it up, drink it.
		hand.holder.drop()
		await seconds(0.5)
		var machine: VendingMachine = demo.get_node("VendingMachine")
		var stock0 := machine.stock
		hand.global_transform = Transform3D(Basis.IDENTITY, machine.get_use_position() + Vector3(0, 0, 0.4))
		await seconds(0.5)
		check(hand.holder.use(), "client: used the vending machine")
		await seconds(1.5)
		var dispensed: Node = machine.get_node("Dispensed")
		check(dispensed.get_child_count() == 1 and machine.stock == stock0 - 1,
				"client: sees the drink the host dispensed (stock %d)" % machine.stock)
		if dispensed.get_child_count() == 1:
			var drink: Drink = dispensed.get_child(0)
			check(drink.global_position.distance_to(machine.global_position) < 1.5,
					"client: the drink appears at the machine, not at the origin")
			hand.global_transform = Transform3D(Basis.IDENTITY, drink.global_position + Vector3(0, 0.5, 0.3))
			await seconds(0.5)
			hand.holder.try_grab()
			await seconds(0.5)
			check(drink.holder_peer_id == me, "client: holding the drink")
			hand.holder.attack()
			await seconds(1.5)
			check(not drink.full, "client: sees the bottle emptied after drinking")
			hand.holder.drop()
			await seconds(0.5)

		# Ball bucket: volley at the shared Sleeper.
		var bucket: BallBucket = demo.get_node("Props/BallBucket")
		hand.global_transform = Transform3D(Basis.IDENTITY, bucket.global_position + Vector3(0, 0.4, 0.3))
		await seconds(0.5)
		hand.holder.try_grab()
		await seconds(0.5)
		check(bucket.holder_peer_id == me, "client: holding the ball bucket")
		hand.global_transform = Transform3D(Basis.IDENTITY, Vector3(5.1, 1.2, 2.0))
		await seconds(0.6)
		var balls0 := bucket.balls
		hand.holder.attack()
		await seconds(0.6)
		check(bucket.balls == balls0 - bucket.balls_per_volley, "client: sees the volley use balls (%d left)" % bucket.balls)
		var se: StatusEffects = demo.get_node("Sleeper/StatusEffects")
		check(se.is_active(&"sleep"), "client: sees the sleeper asleep (synced %s)" % [se.active_effects])

		# Spray paint: pick up the can the host left and paint the wall.
		hand.holder.drop()
		await seconds(0.5)
		var can: SprayPaint = demo.get_node("Props/SprayPaint")
		hand.global_transform = Transform3D(Basis.IDENTITY, can.global_position + Vector3(0, 0.5, 0.3))
		await seconds(0.5)
		hand.holder.try_grab()
		await seconds(0.5)
		check(can.holder_peer_id == me, "client: holding the spray paint")
		hand.global_transform = Transform3D(Basis.IDENTITY, Vector3(-0.4, 1.4, -5.0))
		await seconds(0.5)
		var before := paint_marks(wall_n)
		hand.holder.attack()
		await seconds(0.6)
		hand.holder.attack_release()
		await seconds(0.5)
		check(paint_marks(wall_n) >= before + 10, "client: its own spray paints the wall (%d -> %d marks)" % [before, paint_marks(wall_n)])

	print("RESULT[%s]: %s (%d failures)" % [role, "OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)
