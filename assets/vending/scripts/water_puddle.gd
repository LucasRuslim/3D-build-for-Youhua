class_name WaterPuddle
extends Area3D
## A slippery puddle left by a splashed water bottle. Anyone standing in it
## keeps getting the "slip" status effect (see StatusEffects). It dries up
## after `lifetime` seconds. Created on every peer by Drink; only the host
## applies effects.

@export var radius := 1.1
@export var lifetime := 15.0
@export var slip_duration := 1.2
var source_peer_id := 0

var _age := 0.0
var _tick := 0.0
var _mat: StandardMaterial3D


func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_layer = 0
	collision_mask = 1
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = 0.4
	cs.shape = shape
	cs.position.y = 0.2
	add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.004
	mesh.radial_segments = 32
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.6, 0.8, 1.0, 0.45)
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.roughness = 0.03
	_mat.metallic = 0.3
	mesh.material = _mat
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _physics_process(delta: float) -> void:
	_age += delta
	var fade := clampf((lifetime - _age) / 2.0, 0.0, 1.0)  # dries up over the last 2 s
	_mat.albedo_color.a = 0.45 * fade
	if _age >= lifetime:
		queue_free()
		return
	if not multiplayer.is_server():
		return
	_tick += delta
	if _tick < 0.25:
		return
	_tick = 0.0
	for body in get_overlapping_bodies():
		if not (body is NetworkedProp):
			StatusEffects.apply_to(body, &"slip", slip_duration, 1.0, source_peer_id)
