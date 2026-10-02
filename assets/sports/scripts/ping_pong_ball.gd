class_name PingPongBall
extends StationeryWeapon
## A ping pong ball: light, very bouncy, can be thrown or batted with a
## paddle. A player holding a BallBucket can collect loose balls into it
## (grab near the ball), which refills the bucket's volley ammo.

## Synced: true once the ball has gone into a bucket (hidden, no collision).
var absorbed := false

var _saved_layer := 1
var _saved_mask := 1


func _ready() -> void:
	super()
	_saved_layer = collision_layer
	_saved_mask = collision_mask


func is_held() -> bool:
	return super() or absorbed


func _physics_process(delta: float) -> void:
	super(delta)
	visible = not absorbed
	collision_layer = 0 if absorbed else _saved_layer
	collision_mask = 0 if absorbed else _saved_mask
	if absorbed and _simulating:
		freeze = true


## Host: the ball goes into a bucket.
func absorb() -> void:
	absorbed = true
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
