@tool
class_name CharacterOutfit
extends Node3D
## The student character: a rigged model whose clothes can be changed.
##
##   $Student.top = &"tshirt_navy"       # or set_top(&"tshirt_navy")
##   $Student.bottom = &"trousers_grey"
##   $Student.top = &"none"              # take it off
##   $Student.glasses = false
##   $Student.top_tint = Color.RED       # multiplies the clothing texture
##   $Student.play(&"walk")              # idle / walk / run (looping)
##   $Student.set_move_speed(4.0)        # picks idle/walk/run from a speed (m/s)
##
## Clothes are separate skinned .glb files on the same skeleton; register your
## own with CharacterOutfit.register_top(&"hoodie", "res://.../hoodie.glb")
## (same for bottoms). A clothing piece's meshes are moved onto this
## character's Skeleton3D so they follow every animation.
##
## Multiplayer: top, bottom, glasses and the tints are plain properties and are
## in the scene's MultiplayerSynchronizer, so whoever has authority over the
## character (usually its player) changes them and everyone sees the outfit.
## Model: faces +Z, feet at the origin, about 1.75 m tall.

const MODELS := "res://assets/characters/student/models/"
static var TOPS := {
	&"tank_white": MODELS + "top_tank_white.glb",
	&"tshirt_navy": MODELS + "top_tshirt_navy.glb",
	&"none": "",
}
static var BOTTOMS := {
	&"shorts_black": MODELS + "bottom_shorts_black.glb",
	&"trousers_grey": MODELS + "bottom_trousers_grey.glb",
	&"none": "",
}

@export var top: StringName = &"tank_white":
	set(v):
		top = v
		_refresh(&"top")
@export var bottom: StringName = &"shorts_black":
	set(v):
		bottom = v
		_refresh(&"bottom")
@export var glasses := true:
	set(v):
		glasses = v
		_refresh(&"glasses")
@export var top_tint := Color.WHITE:
	set(v):
		top_tint = v
		_refresh(&"top")
@export var bottom_tint := Color.WHITE:
	set(v):
		bottom_tint = v
		_refresh(&"bottom")
## Speeds (m/s) used by set_move_speed().
@export var walk_speed := 1.4
@export var run_speed := 4.5

var _skeleton: Skeleton3D
var _anim: AnimationPlayer


static func register_top(id: StringName, glb_path: String) -> void:
	TOPS[id] = glb_path


static func register_bottom(id: StringName, glb_path: String) -> void:
	BOTTOMS[id] = glb_path


func _ready() -> void:
	_find_parts()
	if _anim:
		for a in [&"idle", &"walk", &"run"]:
			if _anim.has_animation(a):
				_anim.get_animation(a).loop_mode = Animation.LOOP_LINEAR
		if not Engine.is_editor_hint():
			play(&"idle")
	_refresh(&"top")
	_refresh(&"bottom")
	_refresh(&"glasses")


func set_top(id: StringName) -> void:
	top = id


func set_bottom(id: StringName) -> void:
	bottom = id


func set_glasses(on: bool) -> void:
	glasses = on


func get_skeleton() -> Skeleton3D:
	_find_parts()
	return _skeleton


func get_animation_player() -> AnimationPlayer:
	_find_parts()
	return _anim


## Play idle / walk / run (blends over `blend` seconds).
func play(anim: StringName, blend := 0.2, speed := 1.0) -> void:
	_find_parts()
	if _anim and _anim.has_animation(anim):
		if _anim.current_animation != String(anim):
			_anim.play(anim, blend)
		_anim.speed_scale = speed


## Pick idle / walk / run from a horizontal speed and match the step rate.
func set_move_speed(speed: float) -> void:
	if speed < 0.15:
		play(&"idle")
	elif speed < (walk_speed + run_speed) * 0.5:
		play(&"walk", 0.2, clampf(speed / walk_speed, 0.5, 1.8))
	else:
		play(&"run", 0.2, clampf(speed / run_speed, 0.6, 1.6))


## The clothing meshes worn in a slot (&"top" or &"bottom").
func get_clothing(slot: StringName) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if _skeleton:
		for c in _skeleton.get_children():
			if c is MeshInstance3D and c.get_meta(&"slot", &"") == slot:
				out.append(c)
	return out


func _find_parts() -> void:
	if _skeleton and is_instance_valid(_skeleton):
		return
	var model := get_node_or_null(^"Model")
	if model == null:
		return
	var sk := model.find_children("*", "Skeleton3D", true, false)
	_skeleton = sk[0] if sk.size() > 0 else null
	var ap := model.find_children("*", "AnimationPlayer", true, false)
	_anim = ap[0] if ap.size() > 0 else null


func _refresh(slot: StringName) -> void:
	if not is_inside_tree():
		return
	_find_parts()
	if _skeleton == null:
		return
	if slot == &"glasses":
		for n in [&"GlassesMesh", &"GlassesLensMesh"]:
			var g := _skeleton.get_node_or_null(NodePath(String(n))) as Node3D
			if g:
				g.visible = glasses
		return
	var id: StringName = top if slot == &"top" else bottom
	var table: Dictionary = TOPS if slot == &"top" else BOTTOMS
	var tint: Color = top_tint if slot == &"top" else bottom_tint
	var worn := get_clothing(slot)
	if worn.size() > 0 and worn[0].get_meta(&"id", &"") == id:
		_apply_tint(worn, tint)
		return
	for m in worn:
		_skeleton.remove_child(m)
		m.free()
	var path: String = table.get(id, "")
	if path == "":
		if not table.has(id):
			push_warning("CharacterOutfit: unknown %s '%s'" % [slot, id])
		return
	var piece := (load(path) as PackedScene).instantiate()
	var added: Array[MeshInstance3D] = []
	for m in piece.find_children("*", "MeshInstance3D", true, false):
		m.get_parent().remove_child(m)
		m.owner = null
		_skeleton.add_child(m)
		m.skeleton = NodePath("..")
		m.set_meta(&"slot", slot)
		m.set_meta(&"id", id)
		added.append(m)
	piece.free()
	_apply_tint(added, tint)


func _apply_tint(meshes: Array[MeshInstance3D], tint: Color) -> void:
	for m in meshes:
		for i in m.get_surface_override_material_count():
			var base := m.mesh.surface_get_material(i) as BaseMaterial3D
			if base == null:
				continue
			if tint == Color.WHITE:
				m.set_surface_override_material(i, null)
			else:
				var mat := base.duplicate() as BaseMaterial3D
				mat.albedo_color = base.albedo_color * tint
				m.set_surface_override_material(i, mat)
