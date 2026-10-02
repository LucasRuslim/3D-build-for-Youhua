class_name NetworkedProp
extends RigidBody3D
## A piece of furniture that can be pushed, picked up and thrown, and stays in
## sync across online / LAN multiplayer.
##
## Networking model (server authoritative):
## - The multiplayer authority of this node (peer 1 = the host by default)
##   runs the real physics simulation.
## - Every other peer keeps the body frozen as KINEMATIC (so their characters
##   still collide with it) and smoothly follows the replicated state.
## - Players never move the prop directly; they ask the authority through
##   request_pickup() / request_throw() / request_drop() and it validates.
## - Works unchanged in single player / local split-screen: with no network
##   peer Godot uses OfflineMultiplayerPeer (id 1), so this peer simulates.
##
## Holding: the authority looks for a node in the "prop_holders" group whose
## multiplayer authority is the requesting peer (see PropHolder). That node
## supplies the hold transform, aim direction and the body to ignore.

signal picked_up(peer_id: int)
signal dropped(peer_id: int)
signal thrown(peer_id: int, velocity: Vector3)
## Emitted on the authority when the prop hits something hard enough to hurt.
## thrower_peer_id is 0 if nobody threw it recently (e.g. it was knocked over).
signal hit(body: Node, impact_speed: float, thrower_peer_id: int)

const HOLDER_GROUP := &"prop_holders"
const PROP_GROUP := &"networked_props"

@export_group("Throwing")
## Launch speed in m/s along the holder's aim direction.
@export var throw_speed := 13.0
## Extra upward launch as a fraction of throw_speed (gives a nice arc).
@export var throw_lift := 0.18
## Random tumble added on throw, in rad/s.
@export var throw_spin := 6.0
## How far a player may be from the prop to pick it up (metres).
@export var max_pickup_distance := 2.5
## Where the prop sits relative to the holder's hold point.
@export var hold_offset := Transform3D.IDENTITY

@export_group("Damage")
## Impacts slower than this (m/s) don't emit `hit`.
@export var damage_min_speed := 4.0
## A throw counts as "owned" by the thrower for this long (seconds).
@export var thrower_credit_time := 3.0

@export_group("Pushing")
## How hard running into the prop shoves it. 1.0 = the prop is pushed to
## roughly the character's speed; lower feels heavier.
@export var push_strength := 1.0
## Pushes faster than this (m/s) are clamped. Stops cheating clients from
## launching furniture.
@export var max_push_speed := 12.0

@export_group("Network smoothing")
## Higher = snappier but jerkier remote motion.
@export var interpolation_speed := 18.0
## Remote copies further than this from the server state just teleport.
@export var snap_distance := 3.0

# --- Replicated state (written by the authority, read by everyone else) ----
var net_position := Vector3.ZERO
var net_rotation := Quaternion.IDENTITY
var net_linear_velocity := Vector3.ZERO
## Peer currently holding the prop, 0 if none.
var holder_peer_id := 0

var _simulating := true
var _held_by: Node3D
var _ignored_body: PhysicsBody3D
var _last_thrower := 0
var _last_throw_time := -1000.0
# Velocity just before the latest impact. Continuous collision detection
# slows the body down in the same step it touches something, so the current
# velocity is already too low by the time body_entered fires; this keeps
# the recent peak velocity and lets it fade over about 0.1 s.
var _impact_velocity := Vector3.ZERO
var _recent_hits := {}  # collider instance id -> time of last reported hit
var _sweep_hit := KinematicCollision3D.new()
# Where the current hit happened, for subclasses (e.g. a pencil sticking into
# a wall). For sweep hits: how far the body still had to travel to touch,
# and the surface normal. Zero when the hit came from a real contact.
var _hit_travel := Vector3.ZERO
var _hit_normal := Vector3.ZERO


func _ready() -> void:
	add_to_group(PROP_GROUP)
	contact_monitor = true
	max_contacts_reported = max(max_contacts_reported, 4)
	body_entered.connect(_on_body_entered)
	if not is_multiplayer_authority() and net_position != Vector3.ZERO:
		# Spawned at runtime (e.g. by a vending machine): the host already
		# sent where it is, so start there.
		global_transform = Transform3D(Basis(net_rotation), net_position)
	else:
		_write_net_state()
	_update_mode(true)


func _physics_process(delta: float) -> void:
	_update_mode()
	if _simulating:
		_server_tick()
	else:
		_follow_net_state(delta)


# --------------------------------------------------------------------------
# Public API: call these on any peer (from player input).
# --------------------------------------------------------------------------

func request_pickup() -> void:
	_rpc_pickup.rpc_id(get_multiplayer_authority())


func request_throw() -> void:
	_rpc_throw.rpc_id(get_multiplayer_authority())


func request_drop() -> void:
	_rpc_drop.rpc_id(get_multiplayer_authority())


func is_held() -> bool:
	return holder_peer_id != 0


## Count this prop's next hits as thrown by `peer` (e.g. after a racket bats
## it). Host only.
func credit_throw(peer: int) -> void:
	_last_thrower = peer
	_last_throw_time = _now()


## Shove the prop as if something moving at `push_velocity` ran into it at
## `at_global`. Callable on any peer; clients forward it to the host.
func push(push_velocity: Vector3, at_global: Vector3) -> void:
	if is_multiplayer_authority():
		_apply_push(push_velocity, at_global)
	else:
		_rpc_push.rpc_id(get_multiplayer_authority(), push_velocity, at_global)


## CharacterBody3D doesn't push rigid bodies by itself: it just stops against
## them like a wall. Call this right after move_and_slide() with the velocity
## you had *before* move_and_slide() (which removes the blocked part):
##
##     var v := velocity
##     move_and_slide()
##     NetworkedProp.push_from_character(self, v)
static func push_from_character(character: CharacterBody3D, velocity_before_move: Vector3) -> void:
	var pushed := {}
	for i in character.get_slide_collision_count():
		var c := character.get_slide_collision(i)
		var prop := c.get_collider() as NetworkedProp
		if prop == null or pushed.has(prop) or prop.is_held():
			continue
		var n := c.get_normal()  # points from the prop towards the character
		if n.y > 0.7:
			continue  # standing on top of it, not running into it
		if velocity_before_move.dot(-n) < 0.2:
			continue  # moving away or just brushing past
		pushed[prop] = true
		prop.push(velocity_before_move, c.get_position())


## Finds the PropHolder node that belongs to `peer_id`, or null.
static func find_holder(tree: SceneTree, peer_id: int) -> Node3D:
	for node in tree.get_nodes_in_group(HOLDER_GROUP):
		if node is Node3D and node.get_multiplayer_authority() == peer_id:
			return node
	return null


## The prop currently held by `peer_id`, or null.
static func find_prop_held_by(tree: SceneTree, peer_id: int) -> NetworkedProp:
	for node in tree.get_nodes_in_group(PROP_GROUP):
		if node is NetworkedProp and node.holder_peer_id == peer_id:
			return node
	return null


# --------------------------------------------------------------------------
# RPCs (only act on the authority)
# --------------------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func _rpc_pickup() -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if is_held() or find_prop_held_by(get_tree(), peer) != null:
		return
	var holder := find_holder(get_tree(), peer)
	if holder == null:
		push_warning("%s: no PropHolder found for peer %d" % [name, peer])
		return
	if holder.global_position.distance_to(global_position) > max_pickup_distance + _approx_radius():
		return
	_held_by = holder
	holder_peer_id = peer
	_set_ignored_body(holder.call("get_holder_body") if holder.has_method("get_holder_body") else null)
	sleeping = false
	picked_up.emit(peer)


@rpc("any_peer", "call_local", "reliable")
func _rpc_throw() -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer != holder_peer_id or _held_by == null:
		return
	var aim: Vector3 = _held_by.call("get_aim_direction") if _held_by.has_method("get_aim_direction") \
			else -_held_by.global_basis.z
	var inherited := Vector3.ZERO
	if _ignored_body is CharacterBody3D:
		inherited = (_ignored_body as CharacterBody3D).velocity
	elif _ignored_body is RigidBody3D:
		inherited = (_ignored_body as RigidBody3D).linear_velocity
	_release()
	linear_velocity = aim.normalized() * throw_speed + Vector3.UP * throw_speed * throw_lift + inherited
	angular_velocity = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * throw_spin
	_last_thrower = peer
	_last_throw_time = _now()
	# Don't hit the thrower on the way out.
	_forget_ignored_body_later()
	thrown.emit(peer, linear_velocity)


@rpc("any_peer", "call_local", "reliable")
func _rpc_drop() -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer != holder_peer_id:
		return
	_release()
	_forget_ignored_body_later()
	dropped.emit(peer)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_push(push_velocity: Vector3, at_global: Vector3) -> void:
	if is_multiplayer_authority():
		_apply_push(push_velocity, at_global)


# --------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------

func _apply_push(push_velocity: Vector3, at_global: Vector3) -> void:
	if is_held() or freeze:
		return
	# Horizontal shove, towards the speed of whatever hit us. Re-sent every
	# frame while touching, so it eases the prop up to speed rather than
	# launching it, and applying it at the contact point tips things over.
	var dir := Vector3(push_velocity.x, 0, push_velocity.z)
	var speed := minf(dir.length(), max_push_speed) * push_strength
	if speed < 0.05:
		return
	dir = dir.normalized()
	var missing := speed - linear_velocity.dot(dir)
	if missing <= 0.0:
		return
	var offset := (at_global - global_position).limit_length(1.5)
	sleeping = false
	apply_impulse(dir * missing * mass * 0.5, offset)


func _update_mode(force := false) -> void:
	var sim := is_multiplayer_authority()
	if sim == _simulating and not force:
		return
	_simulating = sim
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	if sim:
		freeze = holder_peer_id != 0
	else:
		# Remote copy: driven by replicated state, still solid for players.
		freeze = true
		_held_by = null


func _server_tick() -> void:
	if holder_peer_id != 0:
		if not is_instance_valid(_held_by) or not _held_by.is_inside_tree():
			# Holder disconnected or died: just let go.
			var peer := holder_peer_id
			_release()
			dropped.emit(peer)
		else:
			freeze = true
			global_transform = _hold_transform()
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO
	_sweep_for_impacts(get_physics_process_delta_time())
	var v := linear_velocity
	if v.length_squared() >= _impact_velocity.length_squared():
		_impact_velocity = v
	else:
		_impact_velocity *= 0.88
	_write_net_state()


func _hold_transform() -> Transform3D:
	var t: Transform3D = _held_by.call("get_hold_transform") if _held_by.has_method("get_hold_transform") \
			else _held_by.global_transform
	return (t * hold_offset).orthonormalized()


func _release() -> void:
	holder_peer_id = 0
	_held_by = null
	freeze = false
	sleeping = false


func _set_ignored_body(body: PhysicsBody3D) -> void:
	if is_instance_valid(_ignored_body):
		remove_collision_exception_with(_ignored_body)
		_ignored_body.remove_collision_exception_with(self)
	_ignored_body = body
	if is_instance_valid(body):
		add_collision_exception_with(body)
		body.add_collision_exception_with(self)


func _forget_ignored_body_later() -> void:
	var body := _ignored_body
	await get_tree().create_timer(0.35, true, true).timeout
	# Only if nobody picked the prop up again in the meantime.
	if _ignored_body == body and holder_peer_id == 0:
		_set_ignored_body(null)


func _write_net_state() -> void:
	net_position = global_position
	net_rotation = global_basis.get_rotation_quaternion()
	net_linear_velocity = linear_velocity


func _follow_net_state(delta: float) -> void:
	var cur := global_transform
	if cur.origin.distance_to(net_position) > snap_distance:
		global_transform = Transform3D(Basis(net_rotation), net_position)
		return
	var w := 1.0 - exp(-interpolation_speed * delta)
	var rot := cur.basis.get_rotation_quaternion().slerp(net_rotation, w)
	global_transform = Transform3D(Basis(rot), cur.origin.lerp(net_position, w))


func _on_body_entered(body: Node) -> void:
	if not _simulating or body == _ignored_body:
		return
	_hit_travel = Vector3.ZERO
	_hit_normal = Vector3.ZERO
	var impact := _impact_velocity
	if body is RigidBody3D:
		impact -= (body as RigidBody3D).linear_velocity
	if _report_hit(body, impact.length()):
		# One impact, one hit: the next hit needs fresh speed.
		_impact_velocity = linear_velocity


## Fast props can be stopped by continuous collision detection just before
## touching what they hit, in which case Godot reports no contact at all. So
## while moving fast, sweep the body one step ahead and count that as a hit.
func _sweep_for_impacts(delta: float) -> void:
	if holder_peer_id != 0 or freeze or linear_velocity.length() < damage_min_speed:
		return
	if test_move(global_transform, linear_velocity * delta * 1.5, _sweep_hit, 0.001):
		var body := _sweep_hit.get_collider() as Node
		if body == null or body == _ignored_body:
			return
		var rel := linear_velocity
		if body is RigidBody3D:
			rel -= (body as RigidBody3D).linear_velocity
		# Only the speed going into the surface hurts, not grazing.
		var into := absf(rel.dot(_sweep_hit.get_normal()))
		_hit_travel = _sweep_hit.get_travel()
		_hit_normal = _sweep_hit.get_normal()
		_report_hit(body, maxf(into, rel.length() * 0.5))


func _report_hit(body: Node, impact_speed: float) -> bool:
	if impact_speed < damage_min_speed:
		return false
	var now := _now()
	var id := body.get_instance_id()
	if now - float(_recent_hits.get(id, -1000.0)) < 0.25:
		return false  # same impact already reported by the other detector
	if _recent_hits.size() > 32:
		_recent_hits.clear()
	_recent_hits[id] = now
	var thrower := _last_thrower if now - _last_throw_time <= thrower_credit_time else 0
	_deliver_hit(body, impact_speed, thrower)
	return true


## Called on the authority for every impact that counts. Subclasses (e.g.
## StationeryWeapon) override this to turn impacts into weapon damage.
func _deliver_hit(body: Node, impact_speed: float, thrower: int) -> void:
	hit.emit(body, impact_speed, thrower)
	if body.has_method("on_prop_hit"):
		body.call("on_prop_hit", self, impact_speed, thrower)


func _approx_radius() -> float:
	var r := 0.0
	for child in get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			r = max(r, child.position.length() + (child.shape as BoxShape3D).size.length() * 0.5)
	return r


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
