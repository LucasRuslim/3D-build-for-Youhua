class_name StatusEffects
extends Node
## Timed status effects (sleep, slip, speed, ...) for a player or NPC.
##
## Add one as a child of your player body. Weapons, potions, puddles and the
## ping pong ball bucket find it through StatusEffects.apply_to(body, ...)
## and heal_body(body, ...). Effects are decided on the host and synced to
## everyone, so every peer can show them (snoring, sliding, glowing...).
##
## Your player code reads them, e.g.:
##     if $StatusEffects.is_active(&"sleep"): return            # no input
##     speed *= $StatusEffects.strength_of(&"speed", 1.0)
##     if $StatusEffects.is_active(&"slip"): keep sliding, ignore steering
##
## Effects used by the props in this pack (strength meaning in brackets):
##   sleep  (-)           can't act        -- ball bucket volley, sleep potion
##   slip   (-)           loses footing    -- water puddles
##   speed  (x multiplier)                 -- speed potion
##   strength (x damage)                   -- strength potion
##   shield (x damage taken, e.g. 0.5)     -- shield potion
##   jump   (x jump height)                -- jump potion
## Healing isn't an effect: it goes to your body's heal(amount) method, or,
## if it has none, this node's `healed` signal.
##
## If your body has its own apply_status_effect(effect, duration, strength,
## source_peer_id) method, that is used instead of this node.

signal effect_started(effect: StringName, strength: float)
signal effect_ended(effect: StringName)
signal healed(amount: float, source_peer_id: int)

## Synced: effect -> strength for every active effect.
var active_effects := {}

var _time_left := {}  # host only: effect -> seconds left
var _seen := {}       # every peer: what we've emitted signals for


func _enter_tree() -> void:
	# Effects are decided by the host, whoever controls the player.
	set_multiplayer_authority(1, true)


func _ready() -> void:
	var sync := MultiplayerSynchronizer.new()
	sync.name = "StatusSync"
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:active_effects"))
	config.property_set_spawn(NodePath(".:active_effects"), true)
	config.property_set_replication_mode(NodePath(".:active_effects"),
			SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	add_child(sync)
	sync.set_multiplayer_authority(1)


func _physics_process(delta: float) -> void:
	# A player that sets its authority recursively after we entered the tree
	# would take this node over; the host must keep it.
	if get_multiplayer_authority() != 1:
		set_multiplayer_authority(1, true)
	if is_multiplayer_authority():
		var changed := false
		for e in _time_left.keys():
			_time_left[e] -= delta
			if _time_left[e] <= 0.0:
				_time_left.erase(e)
				active_effects.erase(e)
				changed = true
		if changed:
			active_effects = active_effects.duplicate()  # new value, so it re-syncs
	_emit_changes()


## Start (or extend) an effect. Host only; elsewhere it does nothing.
func apply(effect: StringName, duration: float, strength := 1.0, source_peer_id := 0) -> void:
	if not is_multiplayer_authority():
		return
	_time_left[effect] = maxf(float(_time_left.get(effect, 0.0)), duration)
	var e := active_effects.duplicate()
	e[effect] = strength
	active_effects = e
	_emit_changes()


func clear(effect: StringName) -> void:
	if not is_multiplayer_authority():
		return
	_time_left.erase(effect)
	var e := active_effects.duplicate()
	e.erase(effect)
	active_effects = e


func is_active(effect: StringName) -> bool:
	return active_effects.has(effect)


func strength_of(effect: StringName, default := 1.0) -> float:
	return float(active_effects.get(effect, default))


## Seconds left (host only; clients get 0).
func time_left(effect: StringName) -> float:
	return float(_time_left.get(effect, 0.0))


## Apply an effect to any body: its own apply_status_effect() if it has one,
## else its StatusEffects child. Returns false if it can't take effects.
static func apply_to(body: Node, effect: StringName, duration: float, strength := 1.0, source_peer_id := 0) -> bool:
	if body == null:
		return false
	if body.has_method("apply_status_effect"):
		body.call("apply_status_effect", effect, duration, strength, source_peer_id)
		return true
	var se := find_on(body)
	if se:
		se.apply(effect, duration, strength, source_peer_id)
		return true
	return false


## Heal any body: its heal(amount) method, else its StatusEffects' signal.
static func heal_body(body: Node, amount: float, source_peer_id := 0) -> bool:
	if body == null:
		return false
	if body.has_method("heal"):
		body.call("heal", amount)
		return true
	var se := find_on(body)
	if se:
		se.healed.emit(amount, source_peer_id)
		return true
	return false


static func find_on(body: Node) -> StatusEffects:
	for c in body.get_children():
		if c is StatusEffects:
			return c
	return null


func _emit_changes() -> void:
	for e in active_effects:
		if not _seen.has(e):
			_seen[e] = true
			effect_started.emit(e, float(active_effects[e]))
	for e in _seen.keys():
		if not active_effects.has(e):
			_seen.erase(e)
			effect_ended.emit(e)
