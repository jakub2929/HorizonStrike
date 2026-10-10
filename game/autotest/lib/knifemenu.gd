extends RefCounted
## Knife models (0.3, t17-t19): the choice through the Esc menu with real input (Esc key, a click on "Knife", a click
## on the knife in the list, Esc) and read-only views of the result (Game.knife_selected / knife_model, the viewmodel's
## held model, cs2/knives/index.json and meta.json in the cache).

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Oracle := preload("res://autotest/lib/oracle.gd")

var ctx
var inp


func _init(p_ctx, p_inp = null) -> void:
	ctx = p_ctx
	inp = p_inp if p_inp != null else InputSim.new(p_ctx)


func index() -> Dictionary:
	## cs2/knives/index.json as the converter wrote it: {format, cs2_build, knives: [{id, state, reason, ...}]}
	var v: Variant = Oracle.read_json(ctx.oracle.cache_dir.path_join("cs2/knives/index.json"))
	return v if v is Dictionary else {}


func entries() -> Array:
	var v: Variant = index().get("knives", [])
	return v if v is Array else []


func ok_ids() -> Array:
	var out := []
	for e in entries():
		if e is Dictionary and str(e.get("state", "")) == "ok":
			out.append(str(e.get("id")))
	return out


func pending() -> Array:
	return entries().filter(func(e): return e is Dictionary and str(e.get("state", "")) not in ["ok", "failed"]).map(func(e): return str(e.get("id")))


func wait_converted(ids: Array, timeout_s: float) -> bool:
	## knives convert on demand after the start cells: wait until every id is offered by the game
	var g: Node = ctx.game
	return await ctx.wait_until(func():
		var have: Array = Array(g.call("knife_ids")) if g != null and g.has_method("knife_ids") else []
		for id in ids:
			if not have.has(id):
				return false
		return true, timeout_s)


func wait_index_settled(timeout_s: float) -> bool:
	## no knife left pending / queued in index.json (every entry ok or failed)
	return await ctx.wait_until(func(): return not entries().is_empty() and pending().is_empty(), timeout_s)


func menu_open() -> bool:
	var m: Control = inp.find_control("SettingsMenu")
	return m != null and m.visible


func choose(id: String) -> Dictionary:
	## Esc, click "Knife", click the knife's row in the list, Esc. {ok, steps, why}
	var steps := []
	if not menu_open():
		await inp.tap("menu")
		await ctx.frames(2)
	steps.append("Esc -> menu %s" % ("open" if menu_open() else "NOT open"))
	if not menu_open():
		return {"ok": false, "steps": steps, "why": "Esc did not open the menu"}
	if not await inp.click_control("KnifeButton"):
		await _close(steps)
		return {"ok": false, "steps": steps, "why": "KnifeButton not on screen"}
	await ctx.frames(3)
	var panel: Control = inp.find_control("KnifePanel")
	var list := inp.find_control("KnifeList") as ItemList
	steps.append("click Knife -> panel %s" % ("open" if panel != null and panel.is_visible_in_tree() else "NOT open"))
	if list == null or not list.is_visible_in_tree():
		await _close(steps)
		return {"ok": false, "steps": steps, "why": "KnifeList not on screen (the click on Knife did nothing)"}
	var menu_ids := []
	for i in list.item_count:
		menu_ids.append(str(list.get_item_metadata(i)))
	var r: Dictionary = await inp.click_list_item(list, id)
	steps.append("click %s: %s" % [id, str(r)])
	await ctx.frames(3)
	await inp.tap("menu")
	await ctx.frames(3)
	if menu_open():
		# Esc went to the focused list: the panel's Back button, then Esc (as a player would)
		steps.append("Esc did not close the menu: Back + Esc")
		await inp.click_control("KnifeBack")
		await inp.tap("menu")
		await ctx.frames(3)
	steps.append("menu %s" % ("still open" if menu_open() else "closed"))
	return {"ok": bool(r.get("ok", false)) and not menu_open(), "steps": steps, "menu_ids": menu_ids,
		"why": str(r.get("why", "")) if not r.get("ok", false) else ("menu still open" if menu_open() else "")}


func _close(steps: Array) -> void:
	## a failed choice must not leave the game paused for the rest of the run: Esc closes the menu
	if menu_open():
		await inp.tap("menu")
		await ctx.frames(3)
	steps.append("closed after the failure: %s" % str(not menu_open()))


func viewmodel() -> Node:
	var p: Node = ctx.player
	var w: Variant = p.get("weapons") if p != null else null
	return w.get("viewmodel") if w is Object and w.get("viewmodel") != null else null


func in_hand() -> String:
	## the knife model shown in the knife slot ("" when the knife is not drawn or a stand-in is shown)
	var p: Node = ctx.player
	var vm := viewmodel()
	if p == null or vm == null or str(p.get("current_weapon")) != "knife":
		return ""
	if vm.has_method("showing_fallback") and vm.call("showing_fallback"):
		return ""
	return str(vm.get("knife_model"))


func wait_in_hand(id: String, timeout_s: float = 10.0) -> bool:
	return await ctx.wait_until(func(): return in_hand() == id, timeout_s)


func held_model() -> Node3D:
	## the viewmodel's visible model (its child that is shown)
	var vm := viewmodel()
	if vm == null:
		return null
	for c in vm.get_children():
		if c is Node3D and (c as Node3D).visible and (c as Node3D).has_meta("knife_model"):
			return c
	return null


static func skeleton_of(n: Node) -> Skeleton3D:
	if n == null:
		return null
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := skeleton_of(c)
		if s != null:
			return s
	return null


func meta_json(id: String) -> Dictionary:
	var v: Variant = Oracle.read_json(ctx.oracle.cache_dir.path_join("cs2/knives/%s/meta.json" % id))
	return v if v is Dictionary else {}


static func has_clip(clips: PackedStringArray, clip: String) -> bool:
	for c in clips:
		if c == clip or c.ends_with("/" + clip):
			return true
	return false
