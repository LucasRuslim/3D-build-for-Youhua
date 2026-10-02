class_name BallBucket
extends StationeryWeapon
## A bucket full of ping pong balls. Attack fires a volley of balls in a cone:
## everyone it hits takes a little damage and falls asleep (status effect
## "sleep", see StatusEffects). Each volley uses `balls_per_volley` balls;
## grab near loose PingPongBalls while holding the bucket to collect them.
## Without enough balls, attack swings the bucket.
##
## Model convention: origin at the handle, bucket hanging below, opening up.

signal volley_fired(peer_id: int, targets: Array)

@export_group("Volley")
@export var max_balls := 40
@export var balls_per_volley := 6
@export var volley_range := 6.0
@export var volley_angle_deg := 18.0
@export var volley_cooldown := 1.2
@export var volley_damage := 2.0
## How long people hit by a volley sleep (seconds).
@export var sleep_duration := 2.5
@export var volley_push := 2.0
## How far from the hands a loose ball can be to collect it.
@export var collect_range := 2.0

## Synced: balls in the bucket.
var balls := 30

var _last_volley := -1000.0
var _fill_surfaces: Array = []  # [MeshInstance3D, surface index] of the visible balls
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
			if m and m.resource_name.begins_with("BucketBalls"):
				_fill_surfaces.append([mi, i])


func _physics_process(delta: float) -> void:
	super(delta)
	for f in _fill_surfaces:
		f[0].set_surface_override_material(f[1], null if balls > 0 else _hidden_mat)


## Attack: volley if there are enough balls, otherwise swing the bucket.
func request_attack() -> void:
	if balls >= balls_per_volley:
		_rpc_volley.rpc_id(get_multiplayer_authority())
	else:
		super()


func can_collect(prop: Node) -> bool:
	return prop is PingPongBall and not prop.is_held() and balls < max_balls


func request_collect(prop: Node) -> void:
	_rpc_collect.rpc_id(get_multiplayer_authority(), get_path_to(prop))


@rpc("any_peer", "call_local", "reliable")
func _rpc_collect(path: NodePath) -> void:
	if not is_multiplayer_authority():
		return
	if multiplayer.get_remote_sender_id() != holder_peer_id or _held_by == null:
		return
	var ball := get_node_or_null(path) as PingPongBall
	if ball == null or not can_collect(ball):
		return
	if ball.global_position.distance_to(_held_by.global_position) > collect_range:
		return
	ball.absorb()
	balls += 1


@rpc("any_peer", "call_local", "reliable")
func _rpc_volley() -> void:
	if not is_multiplayer_authority():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peer != holder_peer_id or _held_by == null or balls < balls_per_volley:
		return
	var now := _now()
	if now - _last_volley < volley_cooldown:
		return
	_last_volley = now
	_attack_t = 0.0
	balls -= balls_per_volley
	var aim: Vector3 = _held_by.call("get_aim_direction") if _held_by.has_method("get_aim_direction") \
			else -_held_by.global_basis.z
	aim = aim.normalized()
	var mouth := global_position + Vector3(0, -0.08, 0) + aim * 0.25
	var exclude: Array[RID] = [get_rid()]
	if is_instance_valid(_ignored_body):
		exclude.append(_ignored_body.get_rid())
	var hit_bodies := cone_targets(mouth, aim, volley_range, volley_angle_deg, exclude)
	for body in hit_bodies:
		if body is NetworkedProp:  # furniture, items: just a nudge
			if not body.is_held():
				body.apply_central_impulse(aim * volley_push * minf(body.mass, 5.0) * 0.3)
			continue
		weapon_hit.emit(body, volley_damage, peer, "volley")
		_send_damage(body, volley_damage, peer, "volley", volley_damage)
		StatusEffects.apply_to(body, &"sleep", sleep_duration, 1.0, peer)
		if body.has_method("apply_knockback"):
			body.call("apply_knockback", aim * volley_push)
	volley_fired.emit(peer, hit_bodies)
	_volley_fx.rpc(mouth, aim)


@rpc("authority", "call_local", "unreliable")
func _volley_fx(at: Vector3, aim: Vector3) -> void:
	var p := CPUParticles3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.02
	mesh.height = 0.04
	mesh.radial_segments = 8
	mesh.rings = 4
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.4
	mesh.material = mat
	p.mesh = mesh
	p.one_shot = true
	p.explosiveness = 0.9
	p.amount = balls_per_volley * 4
	p.lifetime = 1.4
	p.local_coords = false
	p.direction = Vector3(0, 0.1, -1)
	p.spread = volley_angle_deg
	p.initial_velocity_min = 9.0
	p.initial_velocity_max = 13.0
	p.gravity = Vector3(0, -9.8, 0)
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1))
	ramp.set_color(1, Color(0.95, 0.52, 0.18))
	p.color_initial_ramp = ramp
	var parent: Node = get_parent()
	parent.add_child(p)
	p.global_transform = Transform3D(Basis.looking_at(aim, Vector3.UP if absf(aim.y) < 0.99 else Vector3.BACK), at)
	p.emitting = true
	get_tree().create_timer(2.0).timeout.connect(p.queue_free)
