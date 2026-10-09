extends RefCounted
## Shooting helpers. Weapons are taken and fired through the player's input (slot keys, the fire button) with
## simulated events; Game.aim_at only points the camera (setup, like a player's mouse look). A shot's effect is read
## from the game state: the target's health, the weapon's ammo.

const InputSim := preload("res://autotest/lib/inputsim.gd")


static func is_dead(m: Variant) -> bool:
	return not is_instance_valid(m) or str(m.get("state")) == "dead" or float(m.get("health")) <= 0.0


static func equip(ctx, weapon_id: String) -> bool:
	## the weapon's slot key (InputSim.equip), then its deploy time
	var inp = InputSim.new(ctx)
	return await inp.equip(weapon_id)


static func shot_interval(ctx, weapon_id: String) -> float:
	## time between test shots: the cycle time, and long enough for the CS inaccuracy to recover (tapping, like a
	## player aiming at a still target; a spray would test recoil, not the reward/damage path)
	if weapon_id == "knife":
		return float(ctx.oracle.system("combat.knife_primary_interval_s")) + 0.05
	var o = ctx.oracle
	var mode := int(WeaponsSheet.ROWS.get(weapon_id, {}).get("default_mode", 0))
	var c: float = o.num(o.weapon(weapon_id, "cycle_time"), mode)
	var rec: float = o.num(o.weapon(weapon_id, "recovery_time_stand"))
	return maxf(c if not is_nan(c) else 0.3, rec if not is_nan(rec) else 0.0) + 0.05


static func ammo_of(ctx, weapon_id: String) -> Variant:
	var p: Node = ctx.player
	return p.call("ammo", weapon_id) if p != null and p.has_method("ammo") else null


static func shoot(ctx, inp, m: Node) -> Dictionary:
	## one press of the fire button; the effect on m read back from its health
	var id := str(ctx.player.get("current_weapon")) if ctx.player != null else ""
	var before := float(m.get("health")) if is_instance_valid(m) else 0.0
	var ammo0: Variant = ammo_of(ctx, id)
	await inp.tap("fire")
	await ctx.physics_frames(3)
	var after := float(m.get("health")) if is_instance_valid(m) else 0.0
	var ammo1: Variant = ammo_of(ctx, id)
	var fired: bool = id == "knife" or not (ammo0 is Vector2i) or ammo1 != ammo0
	return {"hit": after < before, "damage": before - after, "health_before": before, "fired": fired, "ammo": [str(ammo0), str(ammo1)]}


static func kill(ctx, m: Node, weapon_id: String, part: String = "body", max_shots: int = 80, timeout_s: float = 40.0) -> Dictionary:
	## aim_at + fire button until the machine is dead; knife: steps closer while out of reach
	var inp = InputSim.new(ctx)
	var shots := []
	var t_end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var interval := shot_interval(ctx, weapon_id)
	var reach: float = float(ctx.oracle.system("combat.knife_reach_m"))
	while not is_dead(m) and shots.size() < max_shots and Time.get_ticks_msec() < t_end:
		await ctx.call_api(ctx.game, "aim_at", [m, part])
		await ctx.physics_frames(1)
		var shot: Dictionary = await shoot(ctx, inp, m)
		shots.append(shot)
		if not shot.fired and shots.filter(func(s): return not s.fired).size() >= 5:
			break  # the fire button does nothing: no point in 80 presses
		if weapon_id == "knife" and not shot.hit:
			# out of reach: step toward the machine (setup move, not part of the system under test)
			var pp: Vector3 = ctx.player_pos()
			var to: Vector3 = (m as Node3D).global_position - pp
			to.y = 0.0
			if to.length() > reach * 0.5:
				await ctx.call_api(ctx.game, "teleport", [pp + to.normalized() * minf(0.5, to.length() - reach * 0.5)])
		var ammo: Variant = ammo_of(ctx, weapon_id)
		if (ammo is Vector2i or ammo is Vector2) and int(ammo.x) == 0 and weapon_id != "knife":
			# empty clip: the player reloads (reload key), then waits the reload time from the oracle
			await inp.tap("reload")
			var rt: float = ctx.oracle.num(ctx.oracle.weapon(weapon_id, "reload_time"))
			await ctx.wait((rt if not is_nan(rt) else 2.5) + 0.2)
		await ctx.wait(interval)
	var hits := shots.filter(func(s): return s.hit).size()
	var unfired := shots.filter(func(s): return not s.fired).size()
	var out := {"dead": is_dead(m), "shots": shots.size(), "hits": hits, "presses_without_shot": unfired,
		"ammo_end": str(ammo_of(ctx, weapon_id)), "interval_s": snappedf(interval, 0.001), "first_shots": shots.slice(0, 8),
		"fire_key": inp.describe("fire")}
	if not is_dead(m):
		await ctx.physics_frames(1)
		out["line_of_sight_at_end"] = ctx.line_of_sight_to(m, part)
	return out
