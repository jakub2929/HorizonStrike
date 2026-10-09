extends "res://autotest/lib/scenario.gd"
## t03 Buying subtracts the price - through the player's input only (simulated keyboard/mouse events in the game
## process, Input.parse_input_event): the buy key opens the wheel, the mouse moves onto the item's slot as it is
## drawn on screen (found by the item's displayed name and price, not by internal ids) and clicks it; one item is
## bought the other way a player does it, by releasing the buy key over the slot. Cases: a pistol, a rifle, a grenade
## and Kevlar each subtract the resolved price and give the item; then a buy with too little money is refused.
## Game.money is set as setup; Game.buy() is never called.

const InputSim := preload("res://autotest/lib/inputsim.gd")

const CASES := [
	{"id": "p250", "kind": "pistol", "how": "click"},
	{"id": "ak47", "kind": "rifle", "how": "click"},
	{"id": "hegrenade", "kind": "grenade", "how": "release buy key over the slot"},
	{"id": "kevlar", "kind": "armor", "how": "click"},
]
const REFUSED := "awp"


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["money", "player", "machines"]) + ctx.missing_api(p, ["inventory", "armor"])):
		return false
	var o = ctx.oracle
	var inp = InputSim.new(ctx)
	data.buy_key = inp.describe("buy")
	if not check("the game binds a buy key", inp.binding("buy") != null, data.buy_key):
		return false
	var busy := []
	for m in g.get("machines"):
		if is_instance_valid(m) and str(m.get("state")) in ["alert", "attack"]:
			busy.append("%s %s" % [m.get("machine_type"), m.get("state")])
	check("setup: no machine alerted", busy.is_empty(), str(busy))
	var inv0: Array = _inv(p)
	data.inventory_start = inv0
	var owned := CASES.filter(func(c): return c.id != "kevlar" and inv0.has(c.id))
	check("setup: the items to buy are not owned yet", owned.is_empty(), str(inv0))

	var total := 0
	for c in CASES:
		total += o.i(o.weapon(c.id, "price"))
	g.set("money", total)
	await ctx.frames(2)
	data.start_money = total
	var money_rec = ctx.record(g, "money_changed")
	var cases := []
	for c in CASES:
		cases.append(await _buy_case(ctx, inp, g, p, o, c))
	# too little money: the click must not buy
	var refused := await _refused_case(ctx, inp, g, p, o)
	cases.append(refused)
	data.cases = cases
	data.money_changed = money_rec.events.map(func(e): return e.args[0])
	data.input_sent = inp.sent.slice(0, 80)
	if await _wheel_open(ctx):
		await inp.tap("buy")
	return true


func _buy_case(ctx, inp, g: Node, p: Node, o, c: Dictionary) -> Dictionary:
	var id: String = c.id
	var price: int = o.i(o.weapon(id, "price"))
	var name := str(WeaponsSheet.ROWS[id].display_name)
	var info := {"item": id, "kind": c.kind, "how": c.how, "price": price}
	var money0 := int(g.get("money"))
	var armor0 := float(p.get("armor"))
	var label := "%s %s (%s)" % [c.kind, name, c.how]
	var slot: Dictionary
	if c.how == "click":
		slot = await _open_and_find(ctx, inp, name, false)
		if not slot.is_empty():
			await inp.click(slot.center)
			await ctx.wait(0.4)
	else:
		slot = await _open_and_find(ctx, inp, name, true)
		if not slot.is_empty():
			await inp.mouse_move(slot.center)
			await ctx.wait(0.3)
			inp.release("buy")
			await ctx.wait(0.4)
		else:
			inp.release("buy")
	info.slot = slot
	if not check("%s: wheel open and the slot visible on screen" % label, not slot.is_empty(), "buy key %s" % inp.describe("buy")):
		await _close(ctx, inp)
		return info
	check("%s: slot shows the resolved price $%d" % [label, price], int(slot.price_shown) == price, "shown $%s" % str(slot.price_shown))
	var money := int(g.get("money"))
	var inv: Array = _inv(p)
	info.money = [money0, money]
	info.inventory = inv
	check("%s: money %d - %d = %d" % [label, money0, price, money0 - price], money == money0 - price, "money %d" % money)
	if id == "kevlar":
		var ap: float = o.f(o.weapon("kevlar", "armor_points"))
		info.armor = [armor0, float(p.get("armor"))]
		check("%s: armor == %s" % [label, str(ap)], is_equal_approx(float(p.get("armor")), ap), "armor %s" % str(p.get("armor")))
	else:
		check("%s: inventory contains %s" % [label, id], inv.has(id), str(inv))
	await _close(ctx, inp)
	return info


func _refused_case(ctx, inp, g: Node, p: Node, o) -> Dictionary:
	var price: int = o.i(o.weapon(REFUSED, "price"))
	var name := str(WeaponsSheet.ROWS[REFUSED].display_name)
	g.set("money", maxi(0, price - 1))
	await ctx.frames(2)
	var money0 := int(g.get("money"))
	var inv0: Array = _inv(p)
	var label := "refused %s with $%d < $%d (click)" % [name, money0, price]
	var info := {"item": REFUSED, "how": "click", "price": price, "money_before": money0}
	var slot: Dictionary = await _open_and_find(ctx, inp, name, false)
	info.slot = slot
	if not check("%s: wheel open and the slot visible on screen" % label, not slot.is_empty()):
		await _close(ctx, inp)
		return info
	await inp.click(slot.center)
	await ctx.wait(0.4)
	var money := int(g.get("money"))
	var inv: Array = _inv(p)
	info.money_after = money
	check("%s: money unchanged" % label, money == money0, "money %d" % money)
	check("%s: %s not given" % [label, REFUSED], not inv.has(REFUSED) and inv == inv0, str(inv))
	await _close(ctx, inp)
	return info


func _open_and_find(ctx, inp, display_name: String, hold: bool) -> Dictionary:
	## press the buy key (and release it unless hold), then look for the item's slot on screen
	if await _wheel_open(ctx):
		await inp.tap("buy")
		await ctx.wait(0.3)
	if hold:
		inp.press("buy")
		await ctx.physics_frames(2)
	else:
		await inp.tap("buy")
	await ctx.wait(0.3)
	return _find_slot(ctx, display_name)


func _close(ctx, inp) -> void:
	if await _wheel_open(ctx):
		await inp.tap("buy")
		await ctx.wait(0.3)


func _wheel_open(ctx) -> bool:
	await ctx.frames(1)
	return not _slots(ctx).is_empty()


static func _slots(ctx) -> Array:
	return ctx.wheel_on_screen()


static func _find_slot(ctx, display_name: String) -> Dictionary:
	for s in _slots(ctx):
		if s.name == display_name:
			return s
	return {}


static func _inv(p: Node) -> Array:
	return Array(p.get("inventory")).map(func(x): return str(x))
