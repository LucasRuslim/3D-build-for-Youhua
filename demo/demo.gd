extends Node3D
## Demo / test level for the classroom furniture props.
##
##   Mouse    move your hand            LMB  grab / throw
##   RMB      drop                      E / MMB  stab or swing held stationery;
##                                      with the bow: hold to draw, release to shoot
##                                      with a fire extinguisher: hold to spray foam
##                                      with a drink: drink it; ball bucket: volley
##   F        use (vending machine)
##   (holding the bow, LMB near an arrow loads it; same for the ball bucket and balls)
##   Space    shockwave (host only)
##   F1       host a LAN/online game    F2   join (default 127.0.0.1)
##   R        reset furniture (host)
##
## Command line:  godot --path . -- --host        start as host
##                godot --path . -- --join=IP     join a host

const PORT := 7777
const HAND_SCENE := preload("res://demo/demo_hand.tscn")

@onready var hands: Node3D = $Hands
@onready var props: Node3D = $Props
@onready var status_label: Label = $UI/Status

var _start_transforms := {}


func _ready() -> void:
	for p in props.get_children():
		_start_transforms[p.name] = p.global_transform
	multiplayer.peer_connected.connect(_add_hand)
	multiplayer.peer_disconnected.connect(_remove_hand)
	multiplayer.connected_to_server.connect(_set_status.bind("Connected"))
	multiplayer.connection_failed.connect(_set_status.bind("Connection failed"))
	multiplayer.server_disconnected.connect(_set_status.bind("Host left"))
	_add_hand(1)  # offline play: we are peer 1
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			host()
		elif arg.begins_with("--join"):
			join(arg.get_slice("=", 1) if "=" in arg else "127.0.0.1")
	_set_status("Offline")


func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, 8)
	if err != OK:
		_set_status("Could not host on port %d (%s)" % [PORT, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	_set_status("Hosting on port %d" % PORT)
	return OK


func join(address: String) -> Error:
	# The host spawns everyone's hands, so drop our offline one.
	for h in hands.get_children():
		hands.remove_child(h)
		h.queue_free()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		_set_status("Could not join %s (%s)" % [address, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	_set_status("Joining %s ..." % address)
	return OK


func _add_hand(peer_id: int) -> void:
	if not multiplayer.is_server() or hands.has_node(str(peer_id)):
		return
	var hand := HAND_SCENE.instantiate()
	hand.name = str(peer_id)
	hands.add_child(hand, true)


func _remove_hand(peer_id: int) -> void:
	if multiplayer.is_server() and hands.has_node(str(peer_id)):
		hands.get_node(str(peer_id)).queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F1:
			host()
		KEY_F2:
			join("127.0.0.1")
		KEY_SPACE:
			_shockwave.rpc_id(1)
		KEY_R:
			_reset.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _shockwave() -> void:
	if not multiplayer.is_server():
		return
	for p in props.get_children():
		var prop := p as NetworkedProp
		if prop and not prop.is_held():
			var away := prop.global_position * Vector3(1, 0, 1)
			prop.apply_central_impulse((away.normalized() * 2.0 + Vector3.UP * 3.0) * prop.mass)
			prop.apply_torque_impulse(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * prop.mass * 0.3)


@rpc("any_peer", "call_local", "reliable")
func _reset() -> void:
	if not multiplayer.is_server():
		return
	for p in props.get_children():
		var prop := p as NetworkedProp
		if prop and not prop.is_held() and _start_transforms.has(prop.name):
			PhysicsServer3D.body_set_state(prop.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, _start_transforms[prop.name])
			prop.global_transform = _start_transforms[prop.name]
			prop.linear_velocity = Vector3.ZERO
			prop.angular_velocity = Vector3.ZERO


func _set_status(text: String) -> void:
	status_label.text = "%s   (peer %d)\nLMB grab/throw  RMB drop  E attack/drink  F use  Space shockwave  R reset  F1 host  F2 join" \
			% [text, multiplayer.get_unique_id()]
