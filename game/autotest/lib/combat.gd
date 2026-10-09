extends RefCounted
## Shooting helpers on top of the Game API (aim_at + fire are the real weapon path).


static func is_dead(m: Variant) -> bool:
	return not is_instance_valid(m) or str(m.get("state")) == "dead" or float(m.get("health")) <= 0.0


static func equip(ctx, weapon_id: String) -> void:
	## equip and wait the weapon's deploy time (from the oracle) so the first fire() is accepted
	await ctx.call_api(ctx.game, "equip", [weapon_id])
	var deploy: float = ctx.oracle.num(ctx.oracle.weapon(weapon_id, "deploy_time"))
	await ctx.wait((deploy if not is_nan(deploy) else 1.0) + 0.15)


static func shot_interval(ctx, weapon_id: String) -> float:
	if weapon_id == "knife":
		return float(ctx.oracle.system("combat.knife_primary_interval_s")) + 0.05
	var o = ctx.oracle
	var mode := int(WeaponsSheet.ROWS.get(weapon_id, {}).get("default_mode", 0))
	var c: float = o.num(o.weapon(weapon_id, "cycle_time"), mode)
	return (c if not is_nan(c) else 0.3) + 0.05


static func kill(ctx, m: Node, weapon_id: String, part: String = "body", max_shots: int = 80, timeout_s: float = 40.0) -> Dictionary:
	## aim_at + fire until the machine is dead; knife: steps closer while out of reach
	var shots := []
	var t_end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	var interval := shot_interval(ctx, weapon_id)
	var reach: float = float(ctx.oracle.system("combat.knife_reach_m"))
	while not is_dead(m) and shots.size() < max_shots and Time.get_ticks_msec() < t_end:
		await ctx.call_api(ctx.game, "aim_at", [m, part])
		await ctx.physics_frames(1)
		var r: Variant = await ctx.call_api(ctx.game, "fire")
		var d: Dictionary = r if r is Dictionary else {}
		shots.append({"hit": d.get("hit"), "on_target": d.get("target") == m, "part": d.get("part"), "damage": d.get("damage")})
		if weapon_id == "knife" and not d.get("hit", false):
			# out of reach: step toward the machine (setup move, not part of the system under test)
			var pp: Vector3 = ctx.player_pos()
			var to: Vector3 = (m as Node3D).global_position - pp
			to.y = 0.0
			if to.length() > reach * 0.5:
				await ctx.call_api(ctx.game, "teleport", [pp + to.normalized() * minf(0.5, to.length() - reach * 0.5)])
		var ammo: Variant = ctx.player.call("ammo", weapon_id) if ctx.player != null and ctx.player.has_method("ammo") else null
		if (ammo is Vector2i or ammo is Vector2) and int(ammo.x) == 0 and weapon_id != "knife":
			# empty clip: CS reloads automatically; wait the reload time from the oracle
			var rt: float = ctx.oracle.num(ctx.oracle.weapon(weapon_id, "reload_time"))
			await ctx.wait((rt if not is_nan(rt) else 2.5) + 0.2)
		await ctx.wait(interval)
	var hits := shots.filter(func(s): return s.hit == true and s.on_target).size()
	var other := shots.filter(func(s): return s.hit == true and not s.on_target).size()
	return {"dead": is_dead(m), "shots": shots.size(), "hits": hits, "hits_on_other_targets": other}
