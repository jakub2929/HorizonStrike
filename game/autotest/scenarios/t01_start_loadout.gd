extends "res://autotest/lib/scenario.gd"
## t01 Start loadout knife + Glock + $800: inventory == start_loadout rows, money == economy.start_money,
## glock clip == weapons.glock clip_size (all from sheets / resolved cache).


func _init() -> void:
	timeout_s = 1500.0  # includes waiting for world_ready (a first-launch bootstrap converts weapons and machines)


func _run(ctx):
	var ready: bool = await ctx.need_world(1400.0)
	if not check("world_ready", ready, "Game.world_ready within 1400 s"):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["money", "player"]) + ctx.missing_api(p, ["inventory", "current_weapon"], ["ammo"])):
		return false
	var o = ctx.oracle
	var inv: Array = Array(p.get("inventory")).map(func(x): return str(x))
	var want: Array = o.start_loadout()
	var a := inv.duplicate()
	a.sort()
	var b := want.duplicate()
	b.sort()
	data.inventory = inv
	data.current_weapon = str(p.get("current_weapon"))
	check("inventory == start loadout %s" % str(want), a == b, "inventory %s" % str(inv))

	var money := int(g.get("money"))
	var start_money: int = o.i(o.system("economy.start_money"))
	data.money = money
	data.expected_money = start_money
	check("money == economy.start_money (%d)" % start_money, money == start_money, "money %d" % money)

	var ammo: Variant = await ctx.call_api(p, "ammo", ["glock"])
	var clip_size: int = o.i(o.weapon("glock", "clip_size"))
	data.glock_ammo = str(ammo)
	data.expected_clip = clip_size
	var clip := -1
	if ammo is Vector2i or ammo is Vector2:
		clip = int(ammo.x)
	check("glock clip == weapons.glock clip_size (%d)" % clip_size, clip == clip_size, "ammo(glock) = %s" % str(ammo))
	data.sources = {"start_money": o.used.get("systems.economy.start_money.value", {}), "clip_size": o.used.get("weapons.glock.clip_size", {})}
	return true
