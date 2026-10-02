extends Node3D
## Stand-in "player" for the demo: one floating hand per connected peer that
## follows that peer's mouse. In your game the PropHolder goes on the player.

## Set false to drive the hand from code (used by the automated tests).
@export var follow_mouse := true

@onready var holder: PropHolder = $PropHolder
@onready var marker: MeshInstance3D = $Marker


func _enter_tree() -> void:
	# The spawner names each hand after its peer id.
	set_multiplayer_authority(name.to_int())


func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(fmod(name.to_int() * 0.618034, 1.0), 0.7, 0.95)
	marker.material_override = mat


func _process(_delta: float) -> void:
	marker.scale = Vector3.ONE * (1.6 if holder.held_prop() else 1.0)
	if not is_multiplayer_authority() or not follow_mouse:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var hit = Plane(Vector3.UP, 1.1).intersects_ray(from, dir)
	if hit == null:
		return
	var target: Vector3 = hit
	target.x = clamp(target.x, -6, 6)
	target.z = clamp(target.z, -6, 6)
	# Aim away from the camera, like a third-person brawler would.
	var aim := Vector3(target.x - cam.global_position.x, 0, target.z - cam.global_position.z)
	if aim.length() > 0.01:
		global_transform = Transform3D(Basis.looking_at(aim.normalized(), Vector3.UP), target)
	else:
		global_position = target


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			holder.toggle_grab_throw()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			holder.drop()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			holder.attack()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		holder.attack()
