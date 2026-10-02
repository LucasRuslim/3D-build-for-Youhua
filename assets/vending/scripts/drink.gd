class_name Drink
extends StationeryWeapon
## A drink: water bottle or potion.
## - Drink it: hold it and press attack. After `drink_time` the holder is
##   healed by `heal_amount` and gets `effect` (see StatusEffects) for
##   `effect_duration` seconds, and the bottle is empty.
## - Throw it full and it splashes where it lands (at `splash_min_speed` or
##   faster): everyone within `splash_radius` gets `splash_heal` and
##   `splash_effect`, and water leaves a slippery puddle.
## - Empty, it's just a light thing to hit people with.

signal drunk(peer_id: int, effect: StringName)
signal splashed(position: Vector3)

@export_group("Drink")
## Effect for whoever drinks it ("" = none). See StatusEffects for names.
@export var effect: StringName = &""
@export var effect_duration := 8.0
@export var effect_strength := 1.0
@export var heal_amount := 0.0
@export var drink_time := 0.7
@export_group("Splash")
@export var splash_min_speed := 5.0
@export var splash_radius := 2.5
@export var splash_heal := 0.0
@export var splash_effect: StringName = &""
@export var splash_duration := 4.0
@export var splash_strength := 1.0
## Leave a slippery water puddle where it splashes.
@export var makes_puddle := false
@export var liquid_color := Color(0.55, 0.8, 1.0)

## Synced.
var full := true

var _drink_t := -1.0
var _liquid: Array = []  # [MeshInstance3D, surface] showing the liquid
var _hidden_mat: StandardMaterial3D


func _ready() -> void:
	super()
	_hidden_mat = StandardMaterial3D.new()
	_hidden_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hidden_mat.albedo_color = Color(0, 0, 0, 0)
	for mi in find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var m: Material = mi.mesh.surface_get_material(i)
			if m and m.resource_name.begins_with("Liquid"):
				_liquid.append([mi, i])
	dropped.connect(func(_p): _drink_t = -1.0)
	thrown.connect(func(_p, _v): _drink_t = -1.0)


func _physics_process(delta: float) -> void:
	super(delta)
	if _simulating and _drink_t >= 0.0:
		if holder_peer_id == 0:
			_drink_t = -1.0
		else:
			_drink_t += delta
			if _drink_t >= drink_time:
				_finish_drink()
	for l in _liquid:
		l[0].set_surface_override_material(l[1], null if full else _hidden_mat)


## Attack: drink if full, otherwise swing the empty bottle.
func request_attack() -> void:
	if full:
		_rpc_drink.rpc_id(get_multiplayer_authority())
	else:
		super()


@rpc("any_peer", "call_local", "reliable")
func _rpc_drink() -> void:
	if not is_multiplayer_authority():
		return
	if multiplayer.get_remote_sender_id() != holder_peer_id or not full or _drink_t >= 0.0:
		return
	_drink_t = 0.0


func _finish_drink() -> void:
	_drink_t = -1.0
	full = false
	var peer := holder_peer_id
	var who := _drinker()
	if heal_amount > 0.0:
		StatusEffects.heal_body(who, heal_amount, peer)
	if effect != &"":
		StatusEffects.apply_to(who, effect, effect_duration, effect_strength, peer)
	drunk.emit(peer, effect)


# The holder's body, or whatever owns the hands.
func _drinker() -> Node:
	if is_instance_valid(_ignored_body):
		return _ignored_body
	if is_instance_valid(_held_by):
		var body: Node = _held_by.call("get_holder_body") if _held_by.has_method("get_holder_body") else null
		return body if body else _held_by.get_parent()
	return null


# Raise it to the mouth while drinking.
func _hold_transform() -> Transform3D:
	var t := super()
	if _drink_t < 0.0:
		return t
	var k := clampf(_drink_t / (drink_time * 0.4), 0.0, 1.0)
	return t * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(110.0 * k)), Vector3(0, 0.3 * k, 0.25 * k))


# --------------------------------------------------------------------------
# Splash (host)
# --------------------------------------------------------------------------

func _deliver_hit(body: Node, impact_speed: float, thrower: int) -> void:
	super(body, impact_speed, thrower)
	if full and holder_peer_id == 0 and impact_speed >= splash_min_speed:
		_splash(thrower)


func _splash(thrower: int) -> void:
	full = false
	var centre := global_position
	if splash_heal > 0.0 or splash_effect != &"":
		var space := get_world_3d().direct_space_state
		var query := PhysicsShapeQueryParameters3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = splash_radius
		query.shape = sphere
		query.transform = Transform3D(Basis.IDENTITY, centre)
		var exclude: Array[RID] = [get_rid()]
		query.exclude = exclude
		var done := {}
		for r in space.intersect_shape(query, 256):
			var body: Node = r.collider
			if body == null or done.has(body) or body is StaticBody3D or body is NetworkedProp:
				continue
			done[body] = true
			if splash_heal > 0.0:
				StatusEffects.heal_body(body, splash_heal, thrower)
			if splash_effect != &"":
				StatusEffects.apply_to(body, splash_effect, splash_duration, splash_strength, thrower)
	if makes_puddle:
		var ray := PhysicsRayQueryParameters3D.create(centre + Vector3.UP * 0.2, centre + Vector3.DOWN * 4.0)
		var self_only: Array[RID] = [get_rid()]
		ray.exclude = self_only
		ray.collide_with_areas = false
		var hit := get_world_3d().direct_space_state.intersect_ray(ray)
		var spot: Vector3 = hit.position if not hit.is_empty() else centre
		_spawn_puddle.rpc(spot + Vector3.UP * 0.005, thrower)
	splashed.emit(centre)
	_splash_fx.rpc(centre)


@rpc("authority", "call_local", "reliable")
func _spawn_puddle(at: Vector3, source_peer: int) -> void:
	var puddle := WaterPuddle.new()
	puddle.source_peer_id = source_peer
	get_parent().add_child(puddle)
	puddle.global_position = at


@rpc("authority", "call_local", "unreliable")
func _splash_fx(at: Vector3) -> void:
	var p := CPUParticles3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.03
	mesh.height = 0.06
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(liquid_color, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.1
	mesh.material = mat
	p.mesh = mesh
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = 40
	p.lifetime = 0.8
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 4.0
	p.gravity = Vector3(0, -9.8, 0)
	get_parent().add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)
