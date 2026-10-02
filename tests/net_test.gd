extends SceneTree
## Two-process network check over ENet on localhost:
##   godot --headless --path . --script res://tests/net_test.gd -- server &
##   godot --headless --path . --script res://tests/net_test.gd -- client
## The client grabs Chair4 and throws it; both sides must see it fly.

const DummyTarget := preload("res://tests/dummy_target.gd")
const STAB_SPOT := Vector3(4.0, 1.1, 5.6)  # client's hand for the stationery part

var failures := 0


func check(cond: bool, msg: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + msg)
	if not cond:
		failures += 1


func seconds(t: float) -> void:
	await create_timer(t).timeout


func _initialize() -> void:
	var role: String = OS.get_cmdline_user_args()[0]
	var demo = load("res://demo/props_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	var chair: NetworkedProp = demo.get_node("Props/Chair4")
	var start := chair.global_position

	if role == "server":
		check(demo.host() == OK, "server: hosting")
		# Host-only target for the client's pencil stab (damage is host-side).
		var dummy: CharacterBody3D = DummyTarget.new()
		var dcs := CollisionShape3D.new()
		dcs.shape = CapsuleShape3D.new()
		dcs.shape.radius = 0.3
		dcs.shape.height = 1.8
		dummy.add_child(dcs)
		dummy.position = STAB_SPOT + Vector3(0, -0.19, -0.6)
		demo.add_child(dummy)
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

	print("RESULT[%s]: %s (%d failures)" % [role, "OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)
