class_name Arrow
extends StationeryWeapon
## An arrow. On its own it's a small pointy weapon: stab with it or throw it
## like a dart. A player holding a Bow can collect arrows into the bow and
## shoot them (see bow.gd). Fired arrows fly tip-first, report their hits as
## kind "shot" credited to the shooter, and stick into walls.
##
## Model convention: origin at the middle of the shaft, tip along -Z, nock
## (back end) at +Z `nock_offset` metres.

enum BowState { FREE, NOCKED, STOWED }

## Local Z of the nock (where the string sits).
@export var nock_offset := 0.345

## Replicated: FREE = loose in the world, NOCKED = on the bow string,
## STOWED = carried by a bow (hidden).
var bow_state := BowState.FREE

var _bow: Node3D  # host only: the Bow carrying this arrow
var _saved_layer := 1
var _saved_mask := 1


func _ready() -> void:
	super()
	_saved_layer = collision_layer
	_saved_mask = collision_mask


func is_held() -> bool:
	return super() or bow_state != BowState.FREE


func _physics_process(delta: float) -> void:
	super(delta)
	# Every peer: hide stowed arrows, and arrows in a bow don't collide.
	visible = bow_state != BowState.STOWED
	var loose := bow_state == BowState.FREE
	collision_layer = _saved_layer if loose else 0
	collision_mask = _saved_mask if loose else 0
	if not _simulating or loose:
		return
	if not is_instance_valid(_bow) or not _bow.is_inside_tree():
		detach_from_bow()
		return
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = _bow.call("nock_transform_for", self)
	_write_net_state()


# --------------------------------------------------------------------------
# Called by the Bow, on the host only.
# --------------------------------------------------------------------------

func attach_to_bow(bow: Node3D, state: BowState) -> void:
	_bow = bow
	bow_state = state
	_stuck = false
	freeze = true


func launch_from_bow(velocity: Vector3, shooter_peer: int, shooter_body: PhysicsBody3D, bow: PhysicsBody3D) -> void:
	_bow = null
	bow_state = BowState.FREE
	collision_layer = _saved_layer
	collision_mask = _saved_mask
	freeze = false
	sleeping = false
	linear_velocity = velocity
	angular_velocity = Vector3.ZERO
	_last_thrower = shooter_peer
	_last_throw_time = _now()
	_throw_kind = "shot"
	_impact_velocity = velocity
	# Don't hit the archer or the bow on the way out.
	_set_ignored_body(shooter_body)
	_forget_ignored_body_later()
	if is_instance_valid(bow):
		add_collision_exception_with(bow)
		get_tree().create_timer(0.3, true, true).timeout.connect(func():
			if is_instance_valid(bow):
				remove_collision_exception_with(bow))
	_write_net_state()


## Drop out of the bow (bow dropped, thrown, or gone).
func detach_from_bow() -> void:
	_bow = null
	bow_state = BowState.FREE
	collision_layer = _saved_layer
	collision_mask = _saved_mask
	freeze = false
	sleeping = false
	linear_velocity = Vector3(randf_range(-0.5, 0.5), 0.5, randf_range(-0.5, 0.5))
	_throw_kind = "throw"
