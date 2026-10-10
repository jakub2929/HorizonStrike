extends RefCounted
## XP, levels, upgrade points and upgrades (0.3; systems xp.*, upgrades.*, persist.progression_file).
## progression.json {format: 1, xp, level, points, upgrades: {damage, max_health, bhop}} in Paths.user_dir(), written
## atomically on every change; survives death and restart. XP is separate from money (xp.separate_from_money).
## Level curve (xp.level_curve arithmetic): reaching level L (L >= 1) from L - 1 costs first + step x (L - 1) XP,
## max_level levels; every level-up gives xp.points_per_level points. xp is the running total.

const Sheets := preload("res://core/sheets.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Paths := preload("res://core/paths.gd")
const Log := preload("res://core/log.gd")

const FORMAT := 1
const KINDS := ["damage", "max_health", "bhop"]

static var data := {}
static var _path := ""


static func _blank() -> Dictionary:
	return {"format": FORMAT, "xp": 0, "level": 0, "points": 0, "upgrades": {"damage": 0, "max_health": 0, "bhop": 0}}


## Reads progression.json from the user dir (once per path).
static func ensure() -> void:
	var p := Paths.progression_file()
	if p == _path:
		return
	_path = p
	data = _blank()
	var v: Variant = FsUtil.read_json(p)
	if typeof(v) == TYPE_DICTIONARY:
		for k in ["xp", "level", "points"]:
			data[k] = int(v.get(k, 0))
		var up: Variant = v.get("upgrades", {})
		if typeof(up) == TYPE_DICTIONARY:
			for k in KINDS:
				data["upgrades"][k] = clampi(int(up.get(k, 0)), 0, max_upgrade(k))
	Log.info("progression: %s (%s)" % [JSON.stringify(data), p if FileAccess.file_exists(p) else "new"])


static func save() -> void:
	ensure()
	FsUtil.write_json_atomic(_path, data)


## A copy for readers (Game.progression).
static func snapshot() -> Dictionary:
	ensure()
	return data.duplicate(true)


## Test setup only: replaces the state (missing keys keep their value) and saves it.
static func set_state(d: Dictionary) -> void:
	ensure()
	for k in ["xp", "level", "points"]:
		if d.has(k):
			data[k] = int(d[k])
	if typeof(d.get("upgrades")) == TYPE_DICTIONARY:
		for k in KINDS:
			if d["upgrades"].has(k):
				data["upgrades"][k] = clampi(int(d["upgrades"][k]), 0, max_upgrade(k))
	save()
	Log.info("progression set (setup): %s" % JSON.stringify(data))


# ------------------------------------------------------------------ XP and levels

static func _curve() -> Dictionary:
	var c: Variant = Sheets.sys("xp.level_curve")
	return c if typeof(c) == TYPE_DICTIONARY else {"first": 300, "step": 150, "max_level": 15}


static func max_level() -> int:
	return int(_curve().get("max_level", 15))


## XP needed to go from level - 1 to level.
static func cost_of_level(level: int) -> int:
	var c := _curve()
	return int(c.get("first", 300)) + int(c.get("step", 150)) * (level - 1)


## Total XP at which `level` is reached.
static func total_for(level: int) -> int:
	var t := 0
	for l in range(1, level + 1):
		t += cost_of_level(l)
	return t


## XP for a kill: machines.xp_reward + the weak-spot and silent-strike bonuses (percent of the reward, additive).
static func kill_xp(machine_type: String, weak: bool, silent: bool) -> int:
	var base := Sheets.machine_num(machine_type, "xp_reward", 0.0)
	var pct := 0.0
	if weak:
		pct += Sheets.sys_num("xp.weak_spot_kill_bonus_pct", 0.0)
	if silent:
		pct += Sheets.sys_num("xp.silent_strike_bonus_pct", 0.0)
	return int(round(base * (1.0 + pct / 100.0)))


## Adds XP; returns the number of level-ups (each gives xp.points_per_level points).
static func add_xp(amount: int, reason: String) -> int:
	ensure()
	data["xp"] = int(data["xp"]) + amount
	var ups := 0
	while int(data["level"]) < max_level() and int(data["xp"]) >= total_for(int(data["level"]) + 1):
		data["level"] = int(data["level"]) + 1
		data["points"] = int(data["points"]) + int(Sheets.sys_num("xp.points_per_level", 1.0))
		ups += 1
	save()
	Log.info("xp +%d (%s): xp %d, level %d, points %d%s" % [amount, reason, data["xp"], data["level"], data["points"],
		"  LEVEL UP" if ups > 0 else ""])
	return ups


## XP inside the current level and the size of that level (for the HUD bar; max level -> full).
static func level_progress() -> Vector2i:
	ensure()
	var l := int(data["level"])
	if l >= max_level():
		return Vector2i(1, 1)
	return Vector2i(int(data["xp"]) - total_for(l), cost_of_level(l + 1))


# ------------------------------------------------------------------ upgrades

static func _row(kind: String) -> Dictionary:
	var v: Variant = Sheets.sys("upgrades." + kind)
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func max_upgrade(kind: String) -> int:
	return int(_row(kind).get("max_level", 0))


static func upgrade_level(kind: String) -> int:
	ensure()
	return int(data["upgrades"].get(kind, 0))


## "" when the upgrade can be bought, else the reason.
static func can_upgrade(kind: String) -> String:
	ensure()
	if not KINDS.has(kind):
		return "unknown upgrade"
	if upgrade_level(kind) >= max_upgrade(kind):
		return "max level"
	if int(data["points"]) < int(_row(kind).get("cost_points", 1)):
		return "no points"
	return ""


static func buy_upgrade(kind: String) -> bool:
	if can_upgrade(kind) != "":
		return false
	data["points"] = int(data["points"]) - int(_row(kind).get("cost_points", 1))
	data["upgrades"][kind] = upgrade_level(kind) + 1
	save()
	Log.info("upgrade %s -> level %d (points left %d)" % [kind, data["upgrades"][kind], data["points"]])
	return true


## Player damage multiplier (upgrades.damage: before armour and weak-spot multipliers, every weapon incl. knives).
static func damage_mult() -> float:
	return 1.0 + float(_row("damage").get("pct_per_level", 0.0)) / 100.0 * upgrade_level("damage")


static func max_health() -> float:
	var r := _row("max_health")
	return float(r.get("base", Sheets.sys_num("combat.player_max_health", 100.0))) + float(r.get("hp_per_level", 0.0)) * upgrade_level("max_health")


## Consecutive bhop jumps that keep speed (upgrades.bhop).
static func bhop_jumps() -> int:
	return int(_row("bhop").get("jumps_per_level", 1)) * upgrade_level("bhop")
