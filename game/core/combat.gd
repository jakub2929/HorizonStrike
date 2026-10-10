extends RefCounted
## CS damage rules (systems sheet combat.*, D3/D4/D17).

const Sheets := preload("res://core/sheets.gd")
const Progression := preload("res://core/progression.gd")


## Damage after CS range falloff: damage * range_modifier ^ (distance_u / range_step_u).
static func range_falloff(weapon_id: String, base_damage: float, distance_m: float) -> float:
	var rm := Sheets.weapon_num(weapon_id, "range_modifier", 1.0)
	if rm <= 0.0:
		return base_damage
	var dist_u := distance_m / Sheets.sys_num("combat.units_to_m", 0.0254)
	return base_damage * pow(rm, dist_u / Sheets.sys_num("combat.range_step_u", 500.0))


## CS armor rule. Returns {health: float, armor_lost: float}.
## while armor > 0: health_damage = damage * armor_ratio * armor_ratio_scale; armor lost = (damage - health) * bonus;
## if that exceeds the armor left, the remainder goes to health (CS behaviour).
static func apply_armor(damage: float, armor_ratio: float, armor: float) -> Dictionary:
	if armor <= 0.0 or armor_ratio <= 0.0:
		return {"health": damage, "armor_lost": 0.0}
	var scale := Sheets.sys_num("combat.armor_ratio_scale", 0.5)
	var bonus := Sheets.sys_num("combat.armor_bonus", 0.5)
	var new_dmg := damage * armor_ratio * scale
	var armor_lost := (damage - new_dmg) * bonus
	if armor_lost > armor:
		armor_lost = armor
		new_dmg = damage - armor_lost / bonus
	return {"health": new_dmg, "armor_lost": armor_lost}


## Machine states that count as unaware for a silent strike (combat.silent_strike_rule: idle, patrol, graze, scavenge).
const UNAWARE_STATES := ["idle", "patrol", "graze", "scavenge"]


## Every hit the player deals to a machine goes through here (0.3): the damage upgrade multiplies the base damage
## (upgrades.damage, before the machine's armour and weak-spot multipliers), the machine takes the hit (hit point and
## normal for its sparks: frozen take_hit(weapon_id, base_damage, part, is_weak, hit_pos, hit_normal)), then Game
## awards XP for a kill and drives the hit effects. silent = a silent strike (the caller multiplied the damage).
## Returns the health damage dealt.
static func player_hit(m: Node, weapon_id: String, base_damage: float, part: String, weak: bool,
		hit_pos: Vector3 = Vector3.INF, hit_normal: Vector3 = Vector3.ZERO, silent: bool = false) -> float:
	if m == null or not is_instance_valid(m):
		return 0.0
	var alive_before := str(m.get("state")) != "dead"
	var dmg := base_damage * Progression.damage_mult()
	var dealt: float
	if m.get_method_argument_count("take_hit") >= 6:
		dealt = m.take_hit(weapon_id, dmg, part, weak, hit_pos, hit_normal)
	else:
		dealt = m.take_hit(weapon_id, dmg, part, weak)   # machine.gd before stroje's 0.3 signature
	var killed := alive_before and str(m.get("state")) == "dead"
	Game.on_player_hit(m, weapon_id, dealt, part, weak, hit_pos, hit_normal, killed, silent)
	return dealt


## combat.silent_strike_rule: a knife stab on an unaware machine from outside its sight cone.
static func is_silent_strike(m: Node, attacker_head: Vector3) -> bool:
	if m == null or not is_instance_valid(m) or not UNAWARE_STATES.has(str(m.get("state"))):
		return false
	var eye: Vector3 = m.eye_position() if m.has_method("eye_position") else (m as Node3D).global_position
	var to := attacker_head - eye
	var flat := Vector3(to.x, 0.0, to.z)
	if flat.length() < 0.01:
		return false
	var fwd: Vector3 = m.forward() if m.has_method("forward") else -(m as Node3D).global_transform.basis.z
	var fov: float = float(m.get("sight_fov")) if m.get("sight_fov") != null else deg_to_rad(100.0)
	return fwd.angle_to(flat.normalized()) > fov * 0.5


## Kill reward (D3): round(weapon.kill_award * economy.kill_award_factor * machine.kill_reward_mult).
static func kill_reward(weapon_id: String, machine_type: String) -> int:
	var award: Variant = Sheets.weapon(weapon_id, "kill_award")
	if award == null:
		var cls := str(Sheets.weapon_row(weapon_id).get("kill_award_class", ""))
		award = Sheets.sys(cls) if cls != "" else 0
	var factor := Sheets.sys_num("economy.kill_award_factor", 1.0)
	var mult := Sheets.machine_num(machine_type, "kill_reward_mult", 1.0)
	return int(round(float(award) * factor * mult))


## Fall damage: none below fall_safe_speed_u, 100 at fall_fatal_speed_u, linear between.
static func fall_damage(fall_speed_mps: float) -> float:
	var u := fall_speed_mps / Sheets.sys_num("combat.units_to_m", 0.0254)
	var safe := Sheets.sys_num("combat.fall_safe_speed_u", 580.0)
	var fatal := Sheets.sys_num("combat.fall_fatal_speed_u", 1024.0)
	if u <= safe:
		return 0.0
	return (u - safe) * 100.0 / maxf(fatal - safe, 1.0)
