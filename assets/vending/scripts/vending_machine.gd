class_name VendingMachine
extends StaticBody3D
## A drinks vending machine. A player presses "use" near it
## (PropHolder.use()) and it drops a product out of its tray: a random one by
## default (weighted by `weights`), or a chosen one through
## request_use(index). Products are spawned on the host and replicated by
## the machine's own MultiplayerSpawner, so everyone sees the same drink.
## Each player has a cooldown, and the machine has limited `stock`.
##
## Model convention: origin on the floor under the middle, front facing +Z.

signal vended(peer_id: int, item: Node)
signal sold_out

## Scenes it can dispense. Each must also be listed in the MultiplayerSpawner.
@export var products: Array[PackedScene] = []
## Relative chance of each product (missing entries count as 1).
@export var weights: Array[float] = []
## Products left. Synced. Set to -1 for unlimited.
@export var stock := 24
@export var cooldown_per_player := 2.0
## Where products come out (machine-local): just in front of the tray.
@export var dispense_point := Vector3(-0.14, 0.32, 0.5)
## Where players should stand/aim to use it (machine-local).
@export var use_point := Vector3(0.0, 1.1, 0.55)

var _last_use := {}  # host: peer -> time


func _ready() -> void:
	add_to_group(&"usables")


func get_use_position() -> Vector3:
	return to_global(use_point)


## Call on any peer. index < 0 = random product.
func request_use(index := -1) -> void:
	_rpc_use.rpc_id(1, index)


@rpc("any_peer", "call_local", "reliable")
func _rpc_use(index: int) -> void:
	if not multiplayer.is_server() or products.is_empty():
		return
	var peer := multiplayer.get_remote_sender_id()
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last_use.get(peer, -1000.0)) < cooldown_per_player:
		return
	if stock == 0:
		sold_out.emit()
		return
	_last_use[peer] = now
	if index < 0 or index >= products.size():
		index = _pick()
	var item: Node3D = products[index].instantiate()
	# Place it before adding, so the position goes out with the spawn.
	var spot := Transform3D(Basis(Vector3.UP, randf_range(-0.4, 0.4)), dispense_point)
	item.transform = spot
	$Dispensed.add_child(item, true)
	if item is RigidBody3D:
		(item as RigidBody3D).linear_velocity = global_basis.z * 1.2 + Vector3.UP * 0.5
	if stock > 0:
		stock -= 1
	vended.emit(peer, item)


func _pick() -> int:
	var total := 0.0
	for i in products.size():
		total += weights[i] if i < weights.size() else 1.0
	var r := randf() * total
	for i in products.size():
		r -= weights[i] if i < weights.size() else 1.0
		if r <= 0.0:
			return i
	return products.size() - 1
