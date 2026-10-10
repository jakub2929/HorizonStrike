extends "res://autotest/lib/scenario.gd"
## t17 Every listed knife loads with its contract. For every knife with state ok in cs2/knives/index.json: Esc (key),
## a click on "Knife" and on the knife's row (mouse), Esc; then the knife in hand must be that id, every bone of the
## weapons knife row's bone_roles (and of the knife's own meta.json bone_roles / points) must exist in the held model's
## skeleton and its clips must contain knives.required_clips. Failed knives: listed with a reason, absent from the menu.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const KnifeMenu := preload("res://autotest/lib/knifemenu.gd")
const EXPECTED_OK_ON_BUILD := {25815307: 22}  # sheet t17 pass criterion "22 on b25815307"


func _init() -> void:
	timeout_s = 2400.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player"], ["knife_ids", "knife_selected", "knife_model"])):
		return false
	var o = ctx.oracle
	var inp = InputSim.new(ctx)
	var km = KnifeMenu.new(ctx, inp)
	ctx.player.set("invulnerable", true)
	# knives are converted on demand after the start: wait until index.json has no pending entry
	var t0 := Time.get_ticks_msec()
	var settled: bool = await km.wait_index_settled(1500.0)
	data.index_wait_s = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	var idx: Dictionary = km.index()
	data.cs2_build = idx.get("cs2_build")
	var ok_ids: Array = km.ok_ids()
	var failed: Array = km.entries().filter(func(e): return str(e.get("state", "")) == "failed")
	data.index = {"entries": km.entries().size(), "ok": ok_ids.size(), "failed": failed.map(func(e): return {"id": e.get("id"), "reason": e.get("reason")}), "pending": km.pending()}
	check("index.json present and settled (no pending knife) after %.0f s" % data.index_wait_s, settled and not km.entries().is_empty(), str(data.index))
	if ok_ids.is_empty():
		return false
	var want_n: int = EXPECTED_OK_ON_BUILD.get(int(idx.get("cs2_build", 0)), -1)
	if want_n >= 0:
		check("%d knives ok on CS2 build %s" % [want_n, str(idx.get("cs2_build"))], ok_ids.size() == want_n, "%d ok" % ok_ids.size())
	else:
		note("CS2 build %s: no fixed knife count for this build; %d ok" % [str(idx.get("cs2_build")), ok_ids.size()])
	check("every ok knife offered by the game", await km.wait_converted(ok_ids, 120.0), "offered %s" % str(g.call("knife_ids")))

	# the contract the knife slot must satisfy: the weapons sheet's knife row (bone_roles, points)
	var stats_row := "knife"
	var sel: Variant = o.system("knives.selection")
	if sel is Dictionary and str(sel.get("stats_row", "")) != "":
		stats_row = str(sel.stats_row)
	var row: Dictionary = WeaponsSheet.ROWS.get(stats_row, {})
	var roles: Dictionary = row.get("bone_roles", {}) if row.get("bone_roles") is Dictionary else {}
	var points: Dictionary = row.get("points", {}) if row.get("points") is Dictionary else {}
	var required: Array = o.system("knives.required_clips") if o.system("knives.required_clips") is Array else []
	data.contract = {"row": stats_row, "bone_roles": roles, "points": points.keys(), "required_clips": required}

	inp.capture_for_look()
	if not check("knife drawn with its slot key (%s)" % inp.describe("slot3"), await inp.equip("knife"), str(ctx.player.get("current_weapon"))):
		return false
	var per := {}
	var bad := []
	for id in ok_ids:
		var r: Dictionary = await km.choose(id)
		var held: bool = await km.wait_in_hand(id, 15.0)
		var rec := {"menu": r.ok, "in_hand": km.in_hand(), "selected": str(g.call("knife_selected"))}
		if not r.ok:
			rec.steps = r.steps
			rec.why = r.why
		var model: Node3D = km.held_model()
		var sk: Skeleton3D = KnifeMenu.skeleton_of(model)
		var meta: Dictionary = km.meta_json(id)
		var missing := []
		if sk == null:
			missing.append("no skeleton")
		else:
			for role in roles:
				if sk.find_bone(str(roles[role])) < 0:
					missing.append("row role %s -> %s" % [role, roles[role]])
			for pn in points:
				var b := str((points[pn] as Dictionary).get("bone", ""))
				if sk.find_bone(b) < 0 and not (roles.has(b) and sk.find_bone(str(roles[b])) >= 0):
					missing.append("row point %s on %s" % [pn, b])
			var mroles: Dictionary = meta.get("bone_roles", {}) if meta.get("bone_roles") is Dictionary else {}
			for role in mroles:
				if sk.find_bone(str(mroles[role])) < 0:
					missing.append("meta role %s -> %s" % [role, mroles[role]])
			var mpts: Dictionary = meta.get("points", {}) if meta.get("points") is Dictionary else {}
			for pn in mpts:
				var b := str((mpts[pn] as Dictionary).get("bone", ""))
				if sk.find_bone(b) < 0 and not (mroles.has(b) and sk.find_bone(str(mroles[b])) >= 0):
					missing.append("meta point %s on %s" % [pn, b])
			rec.bones = sk.get_bone_count()
		var vm: Node = km.viewmodel()
		var clips: PackedStringArray = vm.call("clips") if vm != null and vm.has_method("clips") else PackedStringArray()
		var no_clip := required.filter(func(c): return not KnifeMenu.has_clip(clips, str(c)))
		rec.clips = clips.size()
		if not missing.is_empty():
			rec.missing_bones = missing
		if not no_clip.is_empty():
			rec.missing_clips = no_clip
		rec.meta_json = not meta.is_empty()
		per[id] = rec
		var good: bool = r.ok and held and missing.is_empty() and no_clip.is_empty() and not meta.is_empty()
		if not good:
			bad.append(id)
		ctx.note("t17 %s: menu %s, in hand %s, bones %s, clips %d%s" % [id, str(r.ok), rec.in_hand, str(rec.get("bones")), clips.size(), "" if good else " FAIL " + str(rec)])
	data.knives = per
	var chosen_ok := ok_ids.filter(func(i): return per[i].menu and per[i].in_hand == i)
	check("the knife in hand == the clicked id for every ok knife (%d/%d)" % [chosen_ok.size(), ok_ids.size()], chosen_ok.size() == ok_ids.size(), str(ok_ids.filter(func(i): return not chosen_ok.has(i))))
	var contract_ok := ok_ids.filter(func(i): return not per[i].has("missing_bones") and per[i].meta_json)
	check("every bone_roles bone and point of the knife contract exists in the knife skeleton (%d/%d)" % [contract_ok.size(), ok_ids.size()], contract_ok.size() == ok_ids.size(), str(ok_ids.filter(func(i): return not contract_ok.has(i)).map(func(i): return [i, per[i].get("missing_bones")])))
	var clips_ok := ok_ids.filter(func(i): return not per[i].has("missing_clips"))
	check("clips contain knives.required_clips %s (%d/%d)" % [str(required), clips_ok.size(), ok_ids.size()], clips_ok.size() == ok_ids.size(), str(ok_ids.filter(func(i): return not clips_ok.has(i)).map(func(i): return [i, per[i].get("missing_clips")])))
	# failed knives: a reason in index.json and not in the menu (the menu list as shown during the last choice)
	var menu_ids: Array = []
	var any_r: Dictionary = await km.choose(str(g.call("knife_selected")))
	menu_ids = any_r.get("menu_ids", [])
	var failed_bad := []
	for e in failed:
		if str(e.get("reason", "")) in ["", "<null>"] or menu_ids.has(str(e.get("id"))):
			failed_bad.append(e.get("id"))
	check("failed knives listed with a reason and absent from the menu (%d failed)" % failed.size(), failed_bad.is_empty(), str(failed_bad) if not failed_bad.is_empty() else str(data.index.failed))
	# leave the default knife selected for the following scenarios
	await km.choose(str(o.system("knives.default")))
	return true
