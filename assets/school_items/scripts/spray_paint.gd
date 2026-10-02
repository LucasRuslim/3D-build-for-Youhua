class_name SprayPaint
extends StationeryWeapon
## A can of spray paint that really paints. Hold attack (PropHolder.attack(),
## release with attack_release()) to spray: a mist comes out of the nozzle
## and paint marks appear on whatever it hits (walls, floors, furniture,
## players). Marks stick to the thing they're on, so a painted chair keeps
## its paint when it's thrown. Sprayed players get the "painted" status
## effect (see StatusEffects) for the game to use (blurry screen, tracking...).
## The can holds `paint_duration` seconds of paint (`paint` is synced);
## empty, it's a small club.
##
## The paint is a fine airbrush spray: each puff is thousands of tiny
## droplets, and passes build up like real spray paint (a quick pass is a
## light coat, holding on one spot makes it solid).
##
## Networking: the host decides where paint lands and tells every peer, so
## everyone sees the same paint; players who join later get it replayed.
## All paint on one surface is drawn as one MultiMesh ("PaintLayer_<colour>"
## child of that surface), so thousands of puffs stay cheap. Each surface
## keeps at most `max_marks` puffs (after that the oldest are painted over).
##
## Model convention: origin in the middle of the can, upright, nozzle on top
## spraying along -Z.

signal painted(body: Node, at: Vector3)

@export_group("Paint")
@export var paint_color := Color(0.82, 0.04, 0.06)
@export var spray_range := 4.0
@export var spray_spread_deg := 4.0
## Seconds of spraying in a full can.
@export var paint_duration := 20.0
@export var rays_per_tick := 10
## Puff size (metres) up close and at full range: the spray widens with
## distance like a real can.
@export var mark_size_near := 0.05
@export var mark_size_far := 0.22
## Most puffs kept per surface (per colour).
@export var max_marks := 4000
## How long sprayed players stay "painted".
@export var painted_effect_duration := 4.0
## Spray nozzle in local coordinates.
@export var nozzle := Vector3(0.0, 0.112, -0.018)

## Synced.
var paint := 1.0
var spraying := false

var _tick := 0.0
var _mist: CPUParticles3D
var _history: Array = []  # host: [path, local transform] for late joiners
var _last_painted := {}   # host: body -> time, so effects aren't spammed
const TICK := 0.05

static var _quad: QuadMesh
static var _materials := {}


func _ready() -> void:
	super()
	_mist = _make_mist()
	add_child(_mist)
	_mist.position = nozzle
	dropped.connect(func(_p): spraying = false)
	thrown.connect(func(_p, _v): spraying = false)
	if multiplayer.is_server():
		multiplayer.peer_connected.connect(_on_peer_connected)


func _physics_process(delta: float) -> void:
	super(delta)
	if _simulating:
		if spraying and (holder_peer_id == 0 or paint <= 0.0):
			spraying = false
		if spraying:
			paint = maxf(paint - delta / paint_duration, 0.0)
			_tick += delta
			while _tick >= TICK:
				_tick -= TICK
				_spray_tick()
	_mist.emitting = spraying


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

## Attack pressed: spray if there's paint left, otherwise swing.
func request_attack() -> void:
	if paint > 0.0:
		_rpc_spray.rpc_id(get_multiplayer_authority(), true)
	else:
		super()


## Attack released: stop spraying.
func request_release() -> void:
	_rpc_spray.rpc_id(get_multiplayer_authority(), false)


## Host only.
func refill(amount := 1.0) -> void:
	paint = clampf(paint + amount, 0.0, 1.0)


## Global transforms of every paint puff on `body` (any colour). Each puff
## is a 1x1 quad scaled by its basis; basis.z is the surface normal.
static func marks_on(body: Node) -> Array:
	var out := []
	for c in body.get_children():
		if c is MultiMeshInstance3D and c.name.begins_with("PaintLayer"):
			for t in c.get_meta("puffs", []):
				out.append(c.global_transform * t)
	return out


## How many puffs are on `body`.
static func mark_count_on(body: Node) -> int:
	var n := 0
	for c in body.get_children():
		if c is MultiMeshInstance3D and c.name.begins_with("PaintLayer"):
			n += c.get_meta("puffs", []).size()
	return n


@rpc("any_peer", "call_local", "reliable")
func _rpc_spray(on: bool) -> void:
	if not is_multiplayer_authority():
		return
	if multiplayer.get_remote_sender_id() != holder_peer_id:
		return
	spraying = on and paint > 0.0
	_tick = TICK


# --------------------------------------------------------------------------
# Painting (host decides, every peer draws)
# --------------------------------------------------------------------------

func _spray_tick() -> void:
	var origin := to_global(nozzle)
	var aim := -global_basis.z
	if _held_by and _held_by.has_method("get_aim_direction"):
		aim = (_held_by.call("get_aim_direction") as Vector3).normalized()
	var cone := Basis.looking_at(aim, Vector3.UP if absf(aim.y) < 0.99 else Vector3.BACK)
	var spread := tan(deg_to_rad(spray_spread_deg))
	var exclude: Array[RID] = [get_rid()]
	if is_instance_valid(_ignored_body):
		exclude.append(_ignored_body.get_rid())
	var space := get_world_3d().direct_space_state
	var paths := []
	var xforms := []
	var now := _now()
	for i in rays_per_tick:
		var a := randf() * TAU
		var r := sqrt(randf()) * spread
		var dir := (cone * Vector3(cos(a) * r, sin(a) * r, -1.0)).normalized()
		var ray := PhysicsRayQueryParameters3D.create(origin, origin + dir * spray_range)
		ray.exclude = exclude
		var hit := space.intersect_ray(ray)
		if hit.is_empty() or not (hit.collider is Node3D):
			continue
		var body: Node3D = hit.collider
		var n: Vector3 = hit.normal
		var dist := origin.distance_to(hit.position)
		var size := lerpf(mark_size_near, mark_size_far, dist / spray_range) * randf_range(0.8, 1.25)
		var x := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized().rotated(n, randf() * TAU)
		var y := n.cross(x)
		var mark := Transform3D(Basis(x * size, y * size, n), hit.position + n * randf_range(0.0015, 0.004))
		paths.append(body.get_path())
		xforms.append(body.global_transform.affine_inverse() * mark)
		if not (body is StaticBody3D or body is NetworkedProp):
			if now - float(_last_painted.get(body, -10.0)) > 0.5:
				_last_painted[body] = now
				StatusEffects.apply_to(body, &"painted", painted_effect_duration, 1.0, holder_peer_id)
				painted.emit(body, hit.position)
	if paths.is_empty():
		return
	for i in paths.size():
		_history.append([paths[i], xforms[i]])
	if _history.size() > max_marks * 2:
		_history = _history.slice(_history.size() - max_marks * 2)
	_send_marks(paths, xforms, 0)


# Each surface's path goes once per batch, then a small index per puff.
func _send_marks(paths: Array, xforms: Array, to_peer: int) -> void:
	var unique := []
	var index := PackedByteArray()
	for p in paths:
		var k := unique.find(p)
		if k < 0:
			k = unique.size()
			unique.append(p)
		index.append(k)
	if to_peer == 0:
		_add_marks.rpc(unique, index, xforms)
	else:
		_add_marks.rpc_id(to_peer, unique, index, xforms)


@rpc("authority", "call_local", "reliable")
func _add_marks(paths: Array, index: PackedByteArray, xforms: Array) -> void:
	var targets := paths.map(func(p): return get_node_or_null(p))
	for i in xforms.size():
		var target: Node = targets[index[i]]
		if target != null:
			_add_puff(_layer_for(target), xforms[i])


# The MultiMesh holding this colour's paint on `target`, created on first use.
func _layer_for(target: Node) -> MultiMeshInstance3D:
	var lname := "PaintLayer_" + paint_color.to_html(false)
	var layer := target.get_node_or_null(lname) as MultiMeshInstance3D
	if layer == null:
		layer = MultiMeshInstance3D.new()
		layer.name = lname
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _quad_mesh()
		mm.instance_count = 256
		mm.visible_instance_count = 0
		layer.multimesh = mm
		layer.material_override = _material()
		layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		layer.set_meta("next", 0)
		layer.set_meta("puffs", [])  # our own copy: the renderer's can't be read back reliably
		target.add_child(layer)
	return layer


func _add_puff(layer: MultiMeshInstance3D, xform: Transform3D) -> void:
	var mm := layer.multimesh
	var puffs: Array = layer.get_meta("puffs")
	var used := puffs.size()
	if used < max_marks:
		if used >= mm.instance_count:
			# Grow: resizing a MultiMesh clears it, so restore from our copy.
			mm.instance_count = mini(mm.instance_count * 2, max_marks)
			for i in used:
				mm.set_instance_transform(i, puffs[i])
		puffs.append(xform)
		mm.set_instance_transform(used, xform)
		mm.visible_instance_count = used + 1
	else:
		# Full: paint over the oldest puff.
		var i: int = layer.get_meta("next", 0)
		puffs[i] = xform
		mm.set_instance_transform(i, xform)
		layer.set_meta("next", (i + 1) % used)


# Replay existing paint to a player who just joined.
func _on_peer_connected(id: int) -> void:
	await get_tree().create_timer(1.0).timeout
	if _history.is_empty() or not multiplayer.get_peers().has(id):
		return
	for start in range(0, _history.size(), 200):
		var chunk := _history.slice(start, start + 200)
		_send_marks(chunk.map(func(h): return h[0]), chunk.map(func(h): return h[1]), id)


func _quad_mesh() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	return _quad


# Alpha-blended fine droplets. All puffs of one colour blend the same way in
# any order, so overlapping puffs need no sorting and build up naturally.
func _material() -> StandardMaterial3D:
	var key := paint_color.to_html()
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_texture = load("res://assets/school_items/textures/paint_spray.png")
		m.albedo_color = paint_color
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.55
		_materials[key] = m
	return _materials[key]


func _make_mist() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.004
	mesh.height = 0.008
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(paint_color, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	p.mesh = mesh
	p.local_coords = false
	p.emitting = false
	p.amount = 220
	p.lifetime = 0.35
	p.direction = Vector3(0, 0, -1)
	p.spread = spray_spread_deg * 1.4
	p.initial_velocity_min = 6.0
	p.initial_velocity_max = 9.0
	p.gravity = Vector3(0, -1.0, 0)
	p.damping_min = 3.0
	p.damping_max = 5.0
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.5))
	grow.add_point(Vector2(1, 2.5))
	p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.8))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	p.color_ramp = fade
	return p
