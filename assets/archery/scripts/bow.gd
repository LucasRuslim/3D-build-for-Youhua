class_name Bow
extends StationeryWeapon
## A bow that shoots Arrow props. Bow and arrows are separate pickups:
## - Hold the bow and "grab" near an arrow (PropHolder.try_grab() or
##   toggle_grab_throw()) to load it. The bow carries up to `max_arrows`.
## - Press attack (PropHolder.attack()) to draw, release
##   (PropHolder.attack_release()) to shoot. A longer draw shoots faster.
## - Without arrows, attack swings the bow as a club.
## - Dropping or throwing the bow spills the arrows it carries.
##
## Everything is resolved on the host, like the other props; clients see the
## string and nocked arrow follow the replicated draw.
##
## Model convention: origin at the grip, held upright (limbs along Y), the
## arrow flies along -Z and the string is on the +Z (archer) side.

## Emitted on the host when an arrow leaves the bow.
signal shot(arrow: Node, shooter_peer_id: int, speed: float)

@export_group("Archery")
@export var max_arrows := 12
## Arrow speed at full draw (m/s).
@export var shoot_speed := 40.0
## Fraction of shoot_speed for a quick tap.
@export var min_draw := 0.3
## Seconds to reach full draw.
@export var draw_time := 0.7
## How far back the string is pulled at full draw (metres).
@export var draw_length := 0.25
## How far from the hands an arrow can be to load it.
@export var collect_range := 2.0
@export_subgroup("String (bow-local points)")
@export var string_top := Vector3(0, 0.555, 0.125)
@export var string_bottom := Vector3(0, -0.555, 0.125)
## Where the arrow's nock sits on the string at rest.
@export var nock_rest := Vector3(0.012, 0.0, 0.125)

## Replicated: arrows carried, and how far the string is drawn (0-1).
var arrow_count := 0
var draw_amount := 0.0

var _arrows: Array = []  # host only; _arrows[0] is the nocked one
var _drawing := false
var _draw_start := 0.0
var _string_top_mesh: MeshInstance3D
var _string_bottom_mesh: MeshInstance3D


func _ready() -> void:
	super()
	_make_string()
	dropped.connect(func(_peer): _spill_arrows())
	thrown.connect(func(_peer, _v): _spill_arrows())


func _physics_process(delta: float) -> void:
	super(delta)
	if _simulating:
		_arrows = _arrows.filter(func(a): return is_instance_valid(a) and a.bow_state != Arrow.BowState.FREE)
		arrow_count = _arrows.size()
		draw_amount = clampf((_now() - _draw_start) / draw_time, 0.0, 1.0) if _drawing else 0.0
	_update_string()


# --------------------------------------------------------------------------
# Public API (any peer)
# --------------------------------------------------------------------------

func can_collect(prop: Node) -> bool:
	return prop is Arrow and not prop.is_held() and arrow_count < max_arrows


func request_collect(prop: Node) -> void:
	_rpc_collect.rpc_id(get_multiplayer_authority(), get_path_to(prop))


## Attack button pressed: start drawing if loaded, otherwise swing the bow.
func request_attack() -> void:
	if arrow_count > 0:
		_rpc_draw.rpc_id(get_multiplayer_authority())
	else:
		super()


## Attack button released: shoot.
func request_release() -> void:
	_rpc_release.rpc_id(get_multiplayer_authority())


## Where an arrow carried by this bow sits (host and clients).
func nock_transform_for(arrow: Node) -> Transform3D:
	var nock := nock_rest
	if not _arrows.is_empty() and arrow == _arrows[0]:
		nock.z += draw_length * draw_amount
	return global_transform * Transform3D(Basis.IDENTITY, nock - Vector3(0, 0, arrow.nock_offset))


# --------------------------------------------------------------------------
# RPCs (host)
# --------------------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func _rpc_collect(path: NodePath) -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer != holder_peer_id or _held_by == null:
		return
	var arrow := get_node_or_null(path) as Arrow
	if arrow == null or not can_collect(arrow):
		return
	if arrow.global_position.distance_to(_held_by.global_position) > collect_range:
		return
	_arrows.append(arrow)
	arrow_count = _arrows.size()
	arrow.attach_to_bow(self, Arrow.BowState.NOCKED if _arrows.size() == 1 else Arrow.BowState.STOWED)


@rpc("any_peer", "call_local", "reliable")
func _rpc_draw() -> void:
	if not is_multiplayer_authority():
		return
	if multiplayer.get_remote_sender_id() != holder_peer_id or _arrows.is_empty() or _drawing:
		return
	_drawing = true
	_draw_start = _now()


@rpc("any_peer", "call_local", "reliable")
func _rpc_release() -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer != holder_peer_id or not _drawing or _held_by == null:
		return
	_drawing = false
	var charge := clampf((_now() - _draw_start) / draw_time, 0.0, 1.0)
	_arrows = _arrows.filter(func(a): return is_instance_valid(a))
	if _arrows.is_empty():
		return
	var arrow: Arrow = _arrows.pop_front()
	var aim: Vector3 = _held_by.call("get_aim_direction") if _held_by.has_method("get_aim_direction") \
			else -_held_by.global_basis.z
	aim = aim.normalized()
	var speed := shoot_speed * lerpf(min_draw, 1.0, charge)
	# Start from the nock, pointing where the archer aims.
	var start := nock_transform_for(arrow)
	arrow.global_transform = Transform3D(Basis.looking_at(aim, Vector3.UP if absf(aim.y) < 0.99 else Vector3.BACK),
			start.origin)
	arrow.launch_from_bow(aim * speed, peer, _ignored_body, self)
	if not _arrows.is_empty():
		_arrows[0].attach_to_bow(self, Arrow.BowState.NOCKED)
	arrow_count = _arrows.size()
	draw_amount = 0.0
	shot.emit(arrow, peer, speed)


# --------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------

func _spill_arrows() -> void:
	_drawing = false
	if not _simulating:
		return
	for a in _arrows:
		if is_instance_valid(a):
			a.detach_from_bow()
	_arrows.clear()
	arrow_count = 0


func _make_string() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color8(237, 230, 214)
	mat.roughness = 0.8
	for i in 2:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.0025, 1.0, 0.0025)
		box.material = mat
		mi.mesh = box
		mi.name = "StringTop" if i == 0 else "StringBottom"
		add_child(mi)
		if i == 0:
			_string_top_mesh = mi
		else:
			_string_bottom_mesh = mi


func _update_string() -> void:
	var nock := nock_rest + Vector3(0, 0, draw_length * draw_amount)
	nock.x = 0.0
	_place_segment(_string_top_mesh, string_top, nock)
	_place_segment(_string_bottom_mesh, string_bottom, nock)


func _place_segment(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var y := d.normalized()
	var x := Vector3.RIGHT
	var z := x.cross(y).normalized()
	mi.transform = Transform3D(Basis(x, y * d.length(), z), (a + b) * 0.5)
