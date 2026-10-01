extends SceneTree
## Two-process network check over ENet on localhost:
##   godot --headless --path . --script res://tests/net_test.gd -- server &
##   godot --headless --path . --script res://tests/net_test.gd -- client
## The client grabs Chair4 and throws it; both sides must see it fly.

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

	print("RESULT[%s]: %s (%d failures)" % [role, "OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures else 0)
