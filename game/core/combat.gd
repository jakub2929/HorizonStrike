extends RefCounted
## CS damage rules (systems sheet combat.*, D3/D4/D17).

const Sheets := preload("res://core/sheets.gd")


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
