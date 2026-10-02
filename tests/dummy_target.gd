extends CharacterBody3D
## Test target that records every weapon hit it receives.

var hits := []
var knockbacks := []


func on_weapon_hit(weapon: Node, damage: float, attacker_peer_id: int, kind: String) -> void:
	hits.append({"weapon": weapon.name, "damage": damage, "attacker": attacker_peer_id, "kind": kind})


func apply_knockback(v: Vector3) -> void:
	knockbacks.append(v)
