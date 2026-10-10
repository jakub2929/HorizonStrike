extends "res://autotest/lib/scenario.gd"
## t18 part B (a new process with the --user-dir of part A): after the restart the Karambit is still chosen and drawn
## by the knife slot key; loadout.json still holds it.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const KnifeMenu := preload("res://autotest/lib/knifemenu.gd")
const PartA := preload("res://autotest/scenarios/t18a_knife_choice.gd")


func _init() -> void:
	timeout_s = 900.0


func _run(ctx):
	data.loadout_at_start = PartA.read_loadout()
	data.loadout_path = PartA.loadout_path()
	if not check("world_ready", await ctx.need_world(800.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player"], ["knife_ids", "knife_selected", "knife_model"])):
		return false
	var inp = InputSim.new(ctx)
	var km = KnifeMenu.new(ctx, inp)
	ctx.player.set("invulnerable", true)
	# the saved knife is converted first after a start (it is in the cache from part A already)
	await km.wait_converted([PartA.TARGET], 300.0)
	data.selected = str(g.call("knife_selected"))
	inp.capture_for_look()
	var drew: bool = await inp.equip("knife")
	var held: bool = await km.wait_in_hand(PartA.TARGET, 15.0)
	data.after_restart = {"drawn": drew, "in_hand": km.in_hand(), "player.knife_id": str(ctx.player.get("knife_id")), "selected": data.selected}
	check("loadout.json holds knife %s at the start of the new process" % PartA.TARGET, str(data.loadout_at_start.get("knife", "")) == PartA.TARGET, str(data.loadout_at_start))
	check("knife in hand == %s after restart (slot key 3)" % PartA.TARGET, drew and held and str(ctx.player.get("knife_id")) == PartA.TARGET, str(data.after_restart))
	data.loadout_end = PartA.read_loadout()
	check("loadout.json still holds knife %s" % PartA.TARGET, str(data.loadout_end.get("knife", "")) == PartA.TARGET, str(data.loadout_end))
	return true
