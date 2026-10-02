extends CharacterBody3D
## Test target that records every weapon hit it receives.

var hits := []


func on_weapon_hit(weapon: Node, damage: float, attacker_peer_id: int, kind: String) -> void:
	hits.append({"weapon": weapon.name, "damage": damage, "attacker": attacker_peer_id, "kind": kind})
