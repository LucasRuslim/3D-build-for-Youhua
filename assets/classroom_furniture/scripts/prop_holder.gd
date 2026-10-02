class_name PropHolder
extends Node3D
## Add this as a child of your player, placed where the hands are (in front
## of the chest). It lets that player grab and throw NetworkedProps.
##
## Its multiplayer authority must be the peer that controls the player
## (it inherits it if you call set_multiplayer_authority(peer_id) on the
## player root, which is the usual Godot pattern). The player's transform
## must be replicated to the host so the host knows where the hands are.
##
## Call try_grab() / throw() / drop() from the player's input code on the
## controlling peer, or call toggle_grab_throw() from one button.

## Optional node whose -Z axis is the throw direction (e.g. the Camera3D or a
## head pivot). Must be replicated too. Defaults to this node's own -Z.
@export var aim_node: Node3D
## Grab range in metres measured from this node.
@export var reach := 1.8

func _enter_tree() -> void:
	add_to_group(NetworkedProp.HOLDER_GROUP)


## The transform held props snap to.
func get_hold_transform() -> Transform3D:
	return global_transform


func get_aim_direction() -> Vector3:
	var n := aim_node if is_instance_valid(aim_node) else self
	return -n.global_basis.z


## The player body: held / just-thrown props won't collide with it.
func get_holder_body() -> PhysicsBody3D:
	var n := get_parent()
	while n != null:
		if n is PhysicsBody3D:
			return n
		n = n.get_parent()
	return null


func held_prop() -> NetworkedProp:
	return NetworkedProp.find_prop_held_by(get_tree(), get_multiplayer_authority())


## The free prop within reach that's nearest to the hands, or null.
## Nearness = distance to the prop's surface + distance to its middle: the
## surface alone favours big furniture (a desk beats the pencil lying on it),
## the middle alone ignores size (a pencil on the next desk beats the chair
## you're touching). Reach is measured to the surface.
func find_grab_target() -> NetworkedProp:
	var best: NetworkedProp = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group(NetworkedProp.PROP_GROUP):
		var prop := node as NetworkedProp
		if prop == null or prop.is_held():
			continue
		var surface := _distance_to_prop(prop)
		if surface > reach:
			continue
		var d := surface + global_position.distance_to(_centre_of(prop))
		if d < best_d:
			best_d = d
			best = prop
	return best


func try_grab() -> bool:
	var held := held_prop()
	if held != null:
		# Holding something that can take the target in (a bow collecting
		# arrows)? Then grabbing loads it instead.
		var target := find_grab_target()
		if target and held.has_method("can_collect") and held.call("can_collect", target):
			held.call("request_collect", target)
			return true
		return false
	var prop := find_grab_target()
	if prop == null:
		return false
	prop.request_pickup()
	return true


func throw() -> void:
	var prop := held_prop()
	if prop:
		prop.request_throw()


func drop() -> void:
	var prop := held_prop()
	if prop:
		prop.request_drop()


## Melee attack with the held item, if it is a weapon (e.g. StationeryWeapon).
## Call on button press. With a loaded bow this starts drawing it.
func attack() -> void:
	var prop := held_prop()
	if prop and prop.has_method("request_attack"):
		prop.call("request_attack")


## Call when the attack button is released: a drawn bow shoots.
func attack_release() -> void:
	var prop := held_prop()
	if prop and prop.has_method("request_release"):
		prop.call("request_release")


## Use the nearest usable thing within `reach` (e.g. a vending machine):
## anything in the "usables" group with a request_use() method.
func use() -> bool:
	var best: Node3D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group(&"usables"):
		if not (node is Node3D) or not node.has_method("request_use"):
			continue
		var at: Vector3 = node.call("get_use_position") if node.has_method("get_use_position") else node.global_position
		var d := global_position.distance_to(at)
		if d <= reach and d < best_d:
			best_d = d
			best = node
	if best == null:
		return false
	best.call("request_use")
	return true


func toggle_grab_throw() -> void:
	var held := held_prop()
	if held:
		var target := find_grab_target()
		if target and held.has_method("can_collect") and held.call("can_collect", target):
			try_grab()  # e.g. load a nearby arrow into the bow
		else:
			throw()
	else:
		try_grab()


func _centre_of(prop: NetworkedProp) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for child in prop.get_children():
		if child is CollisionShape3D:
			sum += child.global_position
			n += 1
	return sum / n if n > 0 else prop.global_position


func _distance_to_prop(prop: NetworkedProp) -> float:
	# Distance to the nearest collision box, so big desks are easy to grab.
	var best := global_position.distance_to(prop.global_position)
	for child in prop.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			var local: Vector3 = child.global_transform.affine_inverse() * global_position
			var half: Vector3 = (child.shape as BoxShape3D).size * 0.5
			var clamped := local.clamp(-half, half)
			best = min(best, (local - clamped).length())
	return best
