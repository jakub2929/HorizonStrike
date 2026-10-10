extends "res://autotest/lib/scenario.gd"
## t18 part A (child process, own --user-dir): choose the Karambit through the Esc menu (Esc, click "Knife", click
## its row, Esc), check it is in hand; Game.kill_player() (setup), after the respawn draw the knife with its slot key
## and check again; wait until loadout.json holds it. Part B (t18b, a new process with the same --user-dir) checks it
## after the restart. The runner runs A, then B, and combines them into the t18 row.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const KnifeMenu := preload("res://autotest/lib/knifemenu.gd")
const TARGET := "knife_karambit"


func _init() -> void:
	timeout_s = 1500.0


static func loadout_path() -> String:
	var a := PackedStringArray()
	a.append_array(OS.get_cmdline_args())
	a.append_array(OS.get_cmdline_user_args())
	var i := a.find("--user-dir")
	var dir := a[i + 1] if i >= 0 and i + 1 < a.size() else OS.get_environment("LOCALAPPDATA").path_join("HorizonStrike")
	var file := str(SystemsSheet.ROWS.get("persist.loadout_file", {}).get("value", "loadout.json"))
	return dir.replace("\\", "/").path_join(file)


static func read_loadout() -> Dictionary:
	var v: Variant = load("res://autotest/lib/oracle.gd").read_json(loadout_path())
	return v if v is Dictionary else {}


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player"], ["knife_ids", "knife_selected", "knife_model", "kill_player"], ["player_respawned"])):
		return false
	data.loadout_path = loadout_path()
	check("own --user-dir profile (never the player's)", OS.get_cmdline_user_args().has("--user-dir") or OS.get_cmdline_args().has("--user-dir"), data.loadout_path)
	var inp = InputSim.new(ctx)
	var km = KnifeMenu.new(ctx, inp)
	ctx.player.set("invulnerable", true)
	var t0 := Time.get_ticks_msec()
	var conv: bool = await km.wait_converted([TARGET], 1200.0)
	data.target_ready_s = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	if not check("%s converted and offered" % TARGET, conv, str(g.call("knife_ids"))):
		return false
	data.selected_at_start = str(g.call("knife_selected"))
	inp.capture_for_look()
	check("knife drawn with its slot key", await inp.equip("knife"), str(ctx.player.get("current_weapon")))
	var r: Dictionary = await km.choose(TARGET)
	data.menu = r
	var held: bool = await km.wait_in_hand(TARGET, 15.0)
	data.before_death = {"in_hand": km.in_hand(), "player.knife_id": str(ctx.player.get("knife_id")), "selected": str(g.call("knife_selected"))}
	check("chosen through the Esc menu (Esc, Knife, click, Esc)", r.ok, str(r.steps))
	check("knife in hand == %s before death" % TARGET, held and str(ctx.player.get("knife_id")) == TARGET, str(data.before_death))

	var resp = ctx.record(g, "player_respawned")
	ctx.player.set("invulnerable", false)
	await ctx.call_api(g, "kill_player")
	var delay: float = ctx.oracle.f(ctx.oracle.system("respawn.delay_s"))
	var back: bool = await ctx.wait_until(func(): return not resp.events.is_empty(), delay + 30.0)
	check("player respawned after kill_player (setup)", back, "%d respawn events" % resp.events.size())
	ctx.player.set("invulnerable", true)
	await ctx.wait(0.5)
	# respawn hands out the start loadout (pistol in hand): the player takes the knife with its slot key
	var drew: bool = await inp.equip("knife")
	var held2: bool = await km.wait_in_hand(TARGET, 10.0)
	data.after_respawn = {"slot_key": inp.describe("slot3"), "drawn": drew, "in_hand": km.in_hand(), "player.knife_id": str(ctx.player.get("knife_id"))}
	check("knife in hand == %s after respawn (slot key 3)" % TARGET, drew and held2, str(data.after_respawn))
	var saved: bool = await ctx.wait_until(func(): return str(read_loadout().get("knife", "")) == TARGET, 10.0)
	data.loadout = read_loadout()
	check("loadout.json holds knife %s" % TARGET, saved, str(data.loadout))
	return true
