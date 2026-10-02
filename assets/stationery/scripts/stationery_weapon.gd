class_name StationeryWeapon
extends NetworkedProp
## Stationery that works as a weapon: pick it up, then stab / swing it, or
## throw it. Pointy items fly tip-first and stick into walls and floors.
##
## Everything from NetworkedProp still applies (host-authoritative, synced,
## pick up / throw / drop through a PropHolder). On top of that:
## - request_attack(): melee attack with the held item ("stab" or "swing").
## - Thrown hits deal damage too.
## - Damage goes to the hit body's on_weapon_hit(weapon, damage,
##   attacker_peer_id, kind) if it has one (kind is "stab", "swing", "throw",
##   or "shot" for arrows fired from a bow), otherwise to on_prop_hit(prop, impact_speed, thrower) like
##   furniture. The `weapon_hit` signal fires on the host either way.
##
## Model convention: the grip is at the origin and the business end (tip /
## blade / front) points along -Z, the direction the holder aims.

## Emitted on the host for every melee or thrown hit that deals damage.
signal weapon_hit(body: Node, damage: float, attacker_peer_id: int, kind: String)

enum AttackStyle { STAB, SWING }

@export_group("Weapon")
@export var attack_style := AttackStyle.STAB
## Damage of one melee attack.
@export var melee_damage := 10.0
## How far in front of the hand a melee attack reaches (metres).
@export var melee_range := 0.9
## Seconds between melee attacks.
@export var attack_cooldown := 0.45
## Thrown damage per m/s of impact speed (13 m/s throw x 1.0 = 13 damage).
@export var throw_damage_per_speed := 1.0
## Multiplier when a pointy item lands tip-first.
@export var tip_first_bonus := 1.5
## Melee swings knock loose props (desks, chairs, ...) with this impulse.
@export var swing_knockback := 3.0
## Melee hits push characters back at this speed (m/s), through their
## apply_knockback(velocity) method if they have one. 0 = no knockback.
@export var melee_knockback := 0.0
## Thrown items spin flat around their own up axis (trays, books) instead of
## tumbling randomly.
@export var flat_spin := false
## Use continuous collision detection while flying fast, so thin, fast items
## don't pass through things. It kills bounces, so balls turn it off.
@export var ccd_in_flight := true

@export_group("Pointy")
## Fly tip-first like a dart and stick into static surfaces (walls, floor).
@export var pointy := false
## Minimum impact speed to stick (m/s).
@export var stick_min_speed := 6.0
## How deep the tip sinks in when it sticks (metres).
@export var stick_depth := 0.015

var _last_attack := -1000.0
var _attack_t := -1.0  # animation time since the attack started, < 0 = idle
var _stuck := false
# The `kind` reported for impacts while flying ("throw", or "shot" for arrows
# fired from a bow).
var _throw_kind := "throw"

const ATTACK_ANIM_TIME := 0.18


func _ready() -> void:
	super()
	picked_up.connect(func(_peer):
		_stuck = false
		_throw_kind = "throw")
	thrown.connect(func(_peer, _v):
		if flat_spin:
			angular_velocity = global_basis.y * throw_spin)


func _physics_process(delta: float) -> void:
	super(delta)
	if not _simulating:
		return
	if _attack_t >= 0.0:
		_attack_t += delta
		if _attack_t > ATTACK_ANIM_TIME:
			_attack_t = -1.0
	# Continuous collision detection stops fast throws from passing through
	# things, but on small, light items it also makes resting contact jittery
	# (they can sink into a desk). So only use it while flying fast.
	continuous_cd = ccd_in_flight and linear_velocity.length() > 4.0
	if pointy and not freeze and holder_peer_id == 0:
		_steer_tip_into_flight(delta)


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

## Melee attack with the held weapon. Call on any peer (the holder's).
func request_attack() -> void:
	_rpc_attack.rpc_id(get_multiplayer_authority())


func is_stuck() -> bool:
	return _stuck


## World-space direction the tip points.
func tip_direction() -> Vector3:
	return -global_basis.z


# --------------------------------------------------------------------------
# Melee
# --------------------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func _rpc_attack() -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer != holder_peer_id or _held_by == null:
		return
	var now := _now()
	if now - _last_attack < attack_cooldown:
		return
	_last_attack = now
	_attack_t = 0.0

	var aim: Vector3 = _held_by.call("get_aim_direction") if _held_by.has_method("get_aim_direction") \
			else -_held_by.global_basis.z
	aim = aim.normalized()
	var origin := _held_by.global_position
	var exclude: Array[RID] = [get_rid()]
	if is_instance_valid(_ignored_body):
		exclude.append(_ignored_body.get_rid())
	var kind := "stab" if attack_style == AttackStyle.STAB else "swing"
	for body in _melee_targets(origin, aim, exclude):
		weapon_hit.emit(body, melee_damage, peer, kind)
		_send_damage(body, melee_damage, peer, kind, melee_damage)
		if melee_knockback > 0.0 and body.has_method("apply_knockback"):
			body.call("apply_knockback", (aim + Vector3.UP * 0.3).normalized() * melee_knockback)
		if body is RigidBody3D and not (body is NetworkedProp and body.is_held()):
			var push := aim * swing_knockback * (0.5 if kind == "stab" else 1.0)
			(body as RigidBody3D).apply_central_impulse(push * minf((body as RigidBody3D).mass, 10.0) * 0.2)


func _melee_targets(origin: Vector3, aim: Vector3, exclude: Array[RID]) -> Array:
	var space := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	query.shape = sphere
	query.exclude = exclude
	query.collision_mask = collision_mask
	var found: Array = []
	if attack_style == AttackStyle.STAB:
		# A thin thrust: the first thing along the aim line takes the hit.
		sphere.radius = 0.08
		var d := 0.15
		while d <= melee_range + 0.001:
			query.transform = Transform3D(Basis.IDENTITY, origin + aim * d)
			for r in space.intersect_shape(query, 16):
				var body: Node = r.collider
				if _is_melee_target(body):
					return [body]
			d += 0.1
	else:
		# A wide arc in front: everything inside gets hit.
		sphere.radius = melee_range * 0.5
		query.transform = Transform3D(Basis.IDENTITY, origin + aim * melee_range * 0.55)
		for r in space.intersect_shape(query, 64):
			var body: Node = r.collider
			if _is_melee_target(body) and not found.has(body):
				found.append(body)
	return found


func _is_melee_target(body: Node) -> bool:
	return body != null and body != self and body is PhysicsBody3D and not (body is StaticBody3D)


# Lunge forward (stab) or sweep across (swing) while attacking.
func _hold_transform() -> Transform3D:
	var t := super()
	if _attack_t < 0.0:
		return t
	var k := sin(clampf(_attack_t / ATTACK_ANIM_TIME, 0.0, 1.0) * PI)
	if attack_style == AttackStyle.STAB:
		return t * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.35 * k))
	var swing := lerpf(1.1, -1.1, clampf(_attack_t / ATTACK_ANIM_TIME, 0.0, 1.0))
	return t * Transform3D(Basis(Vector3.UP, swing * k), Vector3(0, 0, -0.15 * k))


# --------------------------------------------------------------------------
# Throwing
# --------------------------------------------------------------------------

func _deliver_hit(body: Node, impact_speed: float, thrower: int) -> void:
	var damage := impact_speed * throw_damage_per_speed
	var tip_first := pointy and linear_velocity.length() > 0.1 \
			and tip_direction().dot(linear_velocity.normalized()) > 0.6
	if tip_first:
		damage *= tip_first_bonus
	hit.emit(body, impact_speed, thrower)
	weapon_hit.emit(body, damage, thrower, _throw_kind)
	_send_damage(body, damage, thrower, _throw_kind, impact_speed)
	if tip_first and impact_speed >= stick_min_speed and body is StaticBody3D:
		_stick(body)


func _send_damage(body: Node, damage: float, attacker: int, kind: String, impact_speed: float) -> void:
	if body.has_method("on_weapon_hit"):
		body.call("on_weapon_hit", self, damage, attacker, kind)
	elif body.has_method("on_prop_hit"):
		body.call("on_prop_hit", self, impact_speed, attacker)


func _stick(_into: Node) -> void:
	# Move up to the surface (sweep hits are reported a step early), then
	# sink the tip in a little and freeze there until someone grabs it.
	var t := global_transform
	t.origin += _hit_travel + tip_direction() * stick_depth
	_stuck = true
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = t
	_impact_velocity = Vector3.ZERO
	_write_net_state()


# Like a dart's fins: turn the tip towards the direction of flight.
func _steer_tip_into_flight(delta: float) -> void:
	var v := linear_velocity
	if v.length() < 4.0:
		return
	var want := v.normalized()
	var axis := tip_direction().cross(want)
	angular_velocity = angular_velocity.lerp(axis * 25.0, clampf(10.0 * delta, 0.0, 1.0))
