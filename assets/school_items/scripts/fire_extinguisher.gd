class_name FireExtinguisher
extends StationeryWeapon
## A fire extinguisher: a heavy club that can also spray foam.
## - Hold attack (PropHolder.attack()) to spray, release
##   (PropHolder.attack_release()) to stop. Foam in a cone in front damages a
##   little, pushes characters back (apply_knockback) and shoves loose props.
##   It doesn't go through walls. A full extinguisher sprays for
##   `spray_duration` seconds; `spray_charge` is replicated so the HUD can show
##   it.
## - Empty, attack is a heavy swing (the StationeryWeapon melee).
## - Thrown hard into something while it still has foam, it bursts: a foam
##   blast that knocks back everyone nearby.
## Damage arrives as on_weapon_hit(..., kind) with kind "spray" or "burst".
##
## Model convention: origin at the carry handle on top, body hanging below,
## hose nozzle pointing along -Z.

signal burst(position: Vector3)

@export_group("Spray")
@export var spray_range := 4.0
@export var spray_angle_deg := 22.0
## Seconds of spraying in a full extinguisher.
@export var spray_duration := 8.0
@export var spray_damage_per_second := 6.0
## Knockback speed given to sprayed characters (m/s).
@export var spray_push_speed := 6.0
## Push per second on sprayed loose props, in m/s² (must beat floor friction,
## ~6 m/s², to slide them). Capped at 10 kg worth.
@export var spray_prop_push := 12.0
## Hose nozzle in local coordinates.
@export var nozzle := Vector3(0.0, -0.05, -0.175)
@export_group("Burst")
@export var burst_min_speed := 9.0
@export var burst_radius := 2.5
@export var burst_damage := 10.0
@export var burst_push_speed := 9.0

## Replicated.
var spray_charge := 1.0
var spraying := false

var _tick := 0.0
var _spray_fx: CPUParticles3D
const TICK := 0.1


func _ready() -> void:
	super()
	_spray_fx = _make_foam(false)
	add_child(_spray_fx)
	_spray_fx.position = nozzle
	dropped.connect(func(_p): spraying = false)
	thrown.connect(func(_p, _v): spraying = false)


func _physics_process(delta: float) -> void:
	super(delta)
	if _simulating:
		if spraying and (holder_peer_id == 0 or spray_charge <= 0.0):
			spraying = false
		if spraying:
			spray_charge = maxf(spray_charge - delta / spray_duration, 0.0)
			_tick += delta
			while _tick >= TICK:
				_tick -= TICK
				_spray_tick(TICK)
	_spray_fx.emitting = spraying


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

## Attack pressed: spray if there's foam left, otherwise swing.
func request_attack() -> void:
	if spray_charge > 0.0:
		_rpc_spray.rpc_id(get_multiplayer_authority(), true)
	else:
		super()


## Attack released: stop spraying.
func request_release() -> void:
	_rpc_spray.rpc_id(get_multiplayer_authority(), false)


## Refill (e.g. from a pickup or a station in your level). Host only.
func refill(amount := 1.0) -> void:
	spray_charge = clampf(spray_charge + amount, 0.0, 1.0)


@rpc("any_peer", "call_local", "reliable")
func _rpc_spray(on: bool) -> void:
	if not is_multiplayer_authority():
		return
	if multiplayer.get_remote_sender_id() != holder_peer_id:
		return
	spraying = on and spray_charge > 0.0
	_tick = TICK  # first puff lands right away


# --------------------------------------------------------------------------
# Spray (host)
# --------------------------------------------------------------------------

func _spray_tick(dt: float) -> void:
	var origin := to_global(nozzle)
	var aim := -global_basis.z  # the hold transform points it where the holder aims
	if _held_by and _held_by.has_method("get_aim_direction"):
		aim = (_held_by.call("get_aim_direction") as Vector3).normalized()
	var exclude: Array[RID] = [get_rid()]
	if is_instance_valid(_ignored_body):
		exclude.append(_ignored_body.get_rid())
	for body in cone_targets(origin, aim, spray_range, spray_angle_deg, exclude):
		_foam_hit(body, aim, spray_damage_per_second * dt, spray_push_speed, spray_prop_push * dt, "spray")


func _foam_hit(body: Node, dir: Vector3, damage: float, push_speed: float, prop_impulse: float, kind: String) -> void:
	var attacker := holder_peer_id if holder_peer_id != 0 else _last_thrower
	if body.has_method("on_weapon_hit") or body.has_method("on_prop_hit"):
		weapon_hit.emit(body, damage, attacker, kind)
		_send_damage(body, damage, attacker, kind, damage)
	if body.has_method("apply_knockback"):
		body.call("apply_knockback", dir * push_speed)
	if body is RigidBody3D and not (body is NetworkedProp and body.is_held()):
		var rb := body as RigidBody3D
		rb.apply_central_impulse(dir * prop_impulse * minf(rb.mass, 10.0))


# --------------------------------------------------------------------------
# Burst when thrown hard (host)
# --------------------------------------------------------------------------

func _deliver_hit(body: Node, impact_speed: float, thrower: int) -> void:
	super(body, impact_speed, thrower)
	if holder_peer_id == 0 and impact_speed >= burst_min_speed and spray_charge > 0.2:
		_burst()


func _burst() -> void:
	spray_charge = maxf(spray_charge - 0.35, 0.0)
	var centre := global_position
	var space := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = burst_radius
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, centre)
	var exclude: Array[RID] = [get_rid()]
	query.exclude = exclude
	var done := {}
	for r in space.intersect_shape(query, 256):  # a busy classroom has lots of bodies in range
		var body: Node3D = r.collider
		if body == null or done.has(body) or body is StaticBody3D:
			continue
		done[body] = true
		var dir := (body_center(body) - centre)
		dir = (dir.normalized() if dir.length() > 0.01 else Vector3.UP) + Vector3.UP * 0.4
		_foam_hit(body, dir.normalized(), burst_damage, burst_push_speed, 3.0, "burst")
	burst.emit(centre)
	_burst_fx.rpc(centre)


@rpc("authority", "call_local", "unreliable")
func _burst_fx(at: Vector3) -> void:
	var fx := _make_foam(true)
	var parent: Node = get_tree().current_scene if get_tree().current_scene else get_parent()
	parent.add_child(fx)
	fx.global_position = at
	fx.emitting = true
	get_tree().create_timer(2.0).timeout.connect(fx.queue_free)


# --------------------------------------------------------------------------
# Foam particles (every peer)
# --------------------------------------------------------------------------

func _make_foam(one_shot: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.05
	mesh.height = 0.1
	mesh.radial_segments = 8
	mesh.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.96, 0.97, 1.0, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	p.mesh = mesh
	p.local_coords = false
	p.emitting = false
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.4))
	grow.add_point(Vector2(1, 2.2))
	p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.9))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	p.color_ramp = fade
	if one_shot:
		p.one_shot = true
		p.explosiveness = 0.95
		p.amount = 90
		p.lifetime = 1.2
		p.direction = Vector3.UP
		p.spread = 180.0
		p.initial_velocity_min = 2.0
		p.initial_velocity_max = 5.0
		p.gravity = Vector3(0, -1.5, 0)
		p.damping_min = 2.0
		p.damping_max = 3.0
	else:
		p.amount = 140
		p.lifetime = 0.55
		p.direction = Vector3(0, 0, -1)
		p.spread = spray_angle_deg * 0.6
		p.initial_velocity_min = 7.0
		p.initial_velocity_max = 10.0
		p.gravity = Vector3(0, -2.5, 0)
		p.damping_min = 4.0
		p.damping_max = 6.0
	return p
